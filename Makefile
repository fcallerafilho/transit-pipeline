# transit-pipeline — build & deploy helpers (steps 1b–1d).
# On Windows run these from git-bash, or run the underlying commands directly.

CLUSTER    ?= transit
IMAGE      ?= transit-ingester:dev
READ_IMAGE ?= transit-readapi:dev
NS         ?= transit
PLATFORMS  ?= linux/amd64,linux/arm64
# Set REGISTRY once a deploy host/registry is chosen (step 6) to push multi-arch images.
REGISTRY   ?=

.PHONY: cluster image import buildx secrets deploy verify logs port-forward map clean

# Create the local single-node k3s cluster.
cluster:
	k3d cluster create $(CLUSTER) --wait

# Build both service images for the local (amd64) node.
image:
	docker build -t $(IMAGE) ./ingester
	docker build -t $(READ_IMAGE) ./readapi

# Load the locally-built images into the k3d cluster (no registry needed).
import: image
	k3d image import $(IMAGE) $(READ_IMAGE) -c $(CLUSTER)

# Multi-arch RELEASE build (DESIGN §6.1). Needs REGISTRY set; pushes manifest lists.
buildx:
	docker buildx build --platform $(PLATFORMS) -t $(REGISTRY)/$(IMAGE) --push ./ingester
	docker buildx build --platform $(PLATFORMS) -t $(REGISTRY)/$(READ_IMAGE) --push ./readapi

# (Re)create secrets from .env and local literals. Never committed (DESIGN §4.8).
secrets:
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl delete secret sptrans-token -n $(NS) --ignore-not-found
	kubectl create secret generic sptrans-token -n $(NS) --from-env-file=.env
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
	kubectl delete job ingester -n $(NS) --ignore-not-found
	kubectl apply -f k8s/ingester-job.yaml

# Wait for the ingester Job and show the row it wrote.
verify:
	kubectl -n $(NS) wait --for=condition=complete job/ingester --timeout=120s
	kubectl -n $(NS) exec deploy/timescaledb -- psql -U transit -d transit -c "SELECT * FROM positions;"

# Tail the ingester logs.
logs:
	kubectl -n $(NS) logs -l app=ingester --all-containers --tail=50

# Forward the Read API to localhost:8080 (for curl or the map). Ctrl-C to stop.
port-forward:
	kubectl -n $(NS) port-forward svc/readapi 8080:8080

# Serve the static map at http://localhost:8000 (run `make port-forward` in another shell first).
map:
	cd web && python -m http.server 8000

# Delete the whole cluster.
clean:
	k3d cluster delete $(CLUSTER)
