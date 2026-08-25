#!/usr/bin/env bash
#
# Create the namespace and the three application secrets on the remote cluster.
#
# Every secret is rendered LOCALLY with `--dry-run=client -o yaml` and piped over
# SSH into `kubectl apply -f -`. Nothing secret is ever passed as an argument to a
# command running on the box, where it would sit in `ps` output for any other
# process to read. The tunnel credentials are handled separately (make tunnel-secret)
# because they come from an interactive cloudflared login.
#
# Reads from .env: SPTRANS_TOKEN, POSTGRES_PASSWORD_PROD, GHCR_USER, GHCR_TOKEN.
set -euo pipefail

NS="${NS:-transit}"
ENV_FILE="${ENV_FILE:-.env}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_transit_deploy}"
SSH_TARGET="${SSH_TARGET:?SSH_TARGET must be set, e.g. root@46.62.200.132}"
TMP="${TMPDIR_LOCAL:-.make-tmp}"

[ -r "$ENV_FILE" ] || { echo "cannot read $ENV_FILE" >&2; exit 1; }
set -a
. "./$ENV_FILE"
set +a

: "${SPTRANS_TOKEN:?set SPTRANS_TOKEN in .env}"
: "${POSTGRES_PASSWORD_PROD:?set POSTGRES_PASSWORD_PROD in .env (see .env.example)}"
: "${GHCR_USER:?set GHCR_USER in .env}"
: "${GHCR_TOKEN:?set GHCR_TOKEN in .env}"

mkdir -p "$TMP"

# Pipe a locally-rendered manifest into the remote cluster.
apply_remote() {
  ssh -i "$SSH_KEY" -o IdentitiesOnly=yes "$SSH_TARGET" k3s kubectl apply -f -
}

echo "==> namespace"
kubectl create namespace "$NS" --dry-run=client -o yaml | apply_remote

# Only the token line, so nothing else in .env is swept into this secret.
echo "==> sptrans-token"
grep '^SPTRANS_TOKEN=' "$ENV_FILE" > "$TMP/sptrans.env"
kubectl create secret generic sptrans-token -n "$NS" --from-env-file="$TMP/sptrans.env" --dry-run=client -o yaml | apply_remote
rm -f "$TMP/sptrans.env"

# The password is alphanumeric by construction so it is safe to interpolate into
# the DSN without percent-encoding (see .env.example).
echo "==> db-credentials"
DSN="postgres://transit:${POSTGRES_PASSWORD_PROD}@timescaledb:5432/transit?sslmode=disable"
kubectl create secret generic db-credentials -n "$NS" --from-literal=POSTGRES_USER=transit --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD_PROD" --from-literal=POSTGRES_DB=transit --from-literal=DATABASE_URL="$DSN" --dry-run=client -o yaml | apply_remote

# The GHCR images are private, so the kubelet needs a pull credential.
echo "==> ghcr pull secret"
kubectl create secret docker-registry ghcr -n "$NS" --docker-server=ghcr.io --docker-username="$GHCR_USER" --docker-password="$GHCR_TOKEN" --dry-run=client -o yaml | apply_remote

echo
echo "secrets applied. Tunnel credentials are separate: make tunnel-secret CREDS=<uuid>.json"
