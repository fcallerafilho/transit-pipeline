# transit-pipeline — build & deploy helpers.
# On Windows run these from git-bash, or run the underlying commands directly.

CLUSTER    ?= transit
NS         ?= transit
PLATFORMS  ?= linux/amd64,linux/arm64

# Images live in GHCR. VERSION is an immutable release tag: a new build gets a new
# tag rather than overwriting one, which is what makes imagePullPolicy IfNotPresent
# safe in the manifests. Bump this and the two image: lines in k8s/ together.
REGISTRY   ?= ghcr.io/fcallerafilho
VERSION    ?= v0.1.0-beta
IMAGE      ?= $(REGISTRY)/transit-ingester:$(VERSION)
READ_IMAGE ?= $(REGISTRY)/transit-readapi:$(VERSION)

# --- Remote host (DESIGN 9.4 step 6) ----------------------------------------
# The Layer A box. Its firewall allows port 22 and nothing else (the Cloudflare
# Tunnel is outbound), so the k8s API is NOT exposed to the internet and remote
# kubectl runs over SSH rather than against a public API server.
HOST       ?= 46.62.200.132

# A dedicated, passphrase-less deploy key, not the operator personal key. Two
# reasons: automation cannot answer a passphrase prompt, and a key scoped to one
# job can be revoked from the box without disturbing anything else. IdentitiesOnly
# stops ssh from first offering the personal key, which would prompt and hang.
SSH_KEY    ?= ~/.ssh/id_transit_deploy
SSH_OPTS   ?= -i $(SSH_KEY) -o IdentitiesOnly=yes
SSH        ?= ssh $(SSH_OPTS) root@$(HOST)
SCP        ?= scp $(SSH_OPTS)
REMOTE_DIR ?= /opt/transit
KUBECTL_R  ?= $(SSH) k3s kubectl

# Scratch dir for the one-key env files used to build secrets without putting
# values into argv or shell history.
TMPDIR     ?= .make-tmp

.PHONY: cluster image import buildx secrets deploy verify logs port-forward map clean bootstrap-remote secrets-remote deploy-remote verify-remote logs-remote kube-tunnel tunnel-secret

# Create the local single-node k3s cluster.
cluster:
	k3d cluster create $(CLUSTER) --wait

# Build both service images for the local (amd64) node, tagged exactly as the
# manifests reference them so k3d can side-load them and no pull is attempted.
image:
	docker build -t $(IMAGE) ./ingester
	docker build -t $(READ_IMAGE) ./readapi

# Load the locally-built images into the k3d cluster (no registry needed).
import: image
	k3d image import $(IMAGE) $(READ_IMAGE) -c $(CLUSTER)

# Multi-arch RELEASE build (DESIGN 6.1). Pushes manifest lists to GHCR.
# Requires `docker login ghcr.io` with a PAT carrying write:packages.
buildx:
	docker buildx build --platform $(PLATFORMS) -t $(IMAGE) --push ./ingester
	docker buildx build --platform $(PLATFORMS) -t $(READ_IMAGE) --push ./readapi

# (Re)create secrets from .env and local literals. Never committed (DESIGN §4.8).
secrets:
	@mkdir -p $(TMPDIR)
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl delete secret sptrans-token -n $(NS) --ignore-not-found
	@grep '^SPTRANS_TOKEN=' .env > $(TMPDIR)/sptrans.env
	kubectl create secret generic sptrans-token -n $(NS) --from-env-file=$(TMPDIR)/sptrans.env
	@rm -f $(TMPDIR)/sptrans.env
	kubectl delete secret db-credentials -n $(NS) --ignore-not-found
	kubectl create secret generic db-credentials -n $(NS) \
	  --from-literal=POSTGRES_USER=transit \
	  --from-literal=POSTGRES_PASSWORD=transit_local \
	  --from-literal=POSTGRES_DB=transit \
	  --from-literal=DATABASE_URL='postgres://transit:transit_local@timescaledb:5432/transit?sslmode=disable'

# Deploy the stack. Rebuilds + imports images and recreates secrets first.
deploy: import secrets
	kubectl apply -f k8s/namespace.yaml
	kubectl create configmap db-init -n $(NS) --from-file=init.sql=db/init.sql --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/timescaledb.yaml
	kubectl apply -f k8s/readapi.yaml
	kubectl delete job ingester -n $(NS) --ignore-not-found   # remove the old 1a/1b one-shot Job
	kubectl apply -f k8s/ingester.yaml

# Wait for rollouts and show how many rows have accumulated.
verify:
	kubectl -n $(NS) rollout status deploy/ingester --timeout=120s
	kubectl -n $(NS) rollout status deploy/readapi --timeout=120s
	kubectl -n $(NS) exec deploy/timescaledb -- psql -U transit -d transit \
	  -c "SELECT line_id, count(*) FROM positions GROUP BY line_id ORDER BY line_id;" \
	  -c "SELECT count(*) AS total_rows, count(DISTINCT vehicle_id) AS vehicles FROM positions;"

# Tail the ingester logs.
logs:
	kubectl -n $(NS) logs -l app=ingester --tail=50

# Forward the Read API to localhost:8080 (for curl or the map). Ctrl-C to stop.
port-forward:
	kubectl -n $(NS) port-forward svc/readapi 8080:8080

# Serve the static map at http://localhost:8000 (run `make port-forward` in another shell first).
map:
	cd web && python -m http.server 8000

# Delete the whole cluster.
clean:
	k3d cluster delete $(CLUSTER)

# ============================================================================
# Remote (the Layer A host) — DESIGN §9.4 step 6
#
# Layer B is copied to the box and applied there, unchanged. If any of these
# targets needed a modified manifest, that would be a bug in Layer B (DESIGN §6).
# ============================================================================

# Install k3s on the box. Idempotent.
bootstrap-remote:
	$(SSH) 'mkdir -p $(REMOTE_DIR)'
	$(SCP) bootstrap/k3s-install.sh root@$(HOST):$(REMOTE_DIR)/
	$(SSH) 'bash $(REMOTE_DIR)/k3s-install.sh'

# Create the namespace and all three application secrets on the box.
#
# Each secret is rendered locally with --dry-run=client and piped over SSH, so no
# secret value is ever passed as an argument to a command running on the remote
# host, where it would sit in `ps` output for anything else on the box to read.
#
# Reads from .env: SPTRANS_TOKEN, POSTGRES_PASSWORD_PROD, GHCR_USER, GHCR_TOKEN.
secrets-remote:
	@mkdir -p $(TMPDIR)
	SSH_TARGET=root@$(HOST) SSH_KEY=$(SSH_KEY) NS=$(NS) TMPDIR_LOCAL=$(TMPDIR) bash scripts/remote-secrets.sh

# The tunnel private credentials file, written by `cloudflared tunnel create`.
# Kept out of secrets-remote because it is produced by an interactive login and
# only ever needs creating once.
tunnel-secret:
	@test -n "$(CREDS)" || { echo "usage: make tunnel-secret CREDS=path/to/<uuid>.json"; exit 1; }
	kubectl create secret generic cloudflared-credentials -n $(NS) --from-file=credentials.json=$(CREDS) --dry-run=client -o yaml | $(KUBECTL_R) apply -f -

# Copy Layer B to the box and apply it. The manifests are NOT transformed here —
# same files, same bytes as the local cluster gets.
deploy-remote:
	$(SSH) 'mkdir -p $(REMOTE_DIR)'
	$(SCP) -r k8s db root@$(HOST):$(REMOTE_DIR)/
	$(KUBECTL_R) apply -f $(REMOTE_DIR)/k8s/namespace.yaml
	$(KUBECTL_R) create configmap db-init -n $(NS) --from-file=init.sql=$(REMOTE_DIR)/db/init.sql --dry-run=client -o yaml | $(KUBECTL_R) apply -f -
	$(KUBECTL_R) apply -f $(REMOTE_DIR)/k8s/timescaledb.yaml
	$(KUBECTL_R) apply -f $(REMOTE_DIR)/k8s/readapi.yaml
	$(KUBECTL_R) apply -f $(REMOTE_DIR)/k8s/ingester.yaml
	$(KUBECTL_R) apply -f $(REMOTE_DIR)/k8s/cloudflared.yaml

verify-remote:
	$(KUBECTL_R) -n $(NS) rollout status deploy/ingester --timeout=180s
	$(KUBECTL_R) -n $(NS) rollout status deploy/readapi --timeout=180s
	$(KUBECTL_R) -n $(NS) rollout status deploy/cloudflared --timeout=180s
	$(KUBECTL_R) -n $(NS) exec deploy/timescaledb -- psql -U transit -d transit \
	  -c "SELECT line_id, count(*) FROM positions GROUP BY line_id ORDER BY line_id;" \
	  -c "SELECT count(*) AS total_rows, count(DISTINCT vehicle_id) AS vehicles FROM positions;"

logs-remote:
	$(KUBECTL_R) -n $(NS) logs -l app=ingester --tail=50

# Interactive kubectl against the box without opening 6443 to the internet.
# Run this in one shell; in another, use
#   kubectl --kubeconfig $(TMPDIR)/remote.kubeconfig -n $(NS) get pods
# The fetched kubeconfig already points at 127.0.0.1:6443, which is what the
# forward below lands on.
kube-tunnel:
	@mkdir -p $(TMPDIR)
	$(SSH) cat /etc/rancher/k3s/k3s.yaml > $(TMPDIR)/remote.kubeconfig
	@echo "kubeconfig: $(TMPDIR)/remote.kubeconfig - holding tunnel on :6443 (Ctrl-C to stop)"
	ssh $(SSH_OPTS) -N -L 6443:127.0.0.1:6443 root@$(HOST)
