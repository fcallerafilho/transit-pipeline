#!/usr/bin/env sh
# Secrets are provisioned out-of-band and NEVER committed (DESIGN §4.8/§12).
# The manifests reference these two secrets in the 'transit' namespace; recreate them:

kubectl create namespace transit --dry-run=client -o yaml | kubectl apply -f -

# SPTrans API token — read straight from .env so the value never lands in shell history:
kubectl create secret generic sptrans-token -n transit --from-env-file=.env

# Local DB credentials (throwaway local password) + the DSN the ingester reads:
kubectl create secret generic db-credentials -n transit \
  --from-literal=POSTGRES_USER=transit \
  --from-literal=POSTGRES_PASSWORD=transit_local \
  --from-literal=POSTGRES_DB=transit \
  --from-literal=DATABASE_URL='postgres://transit:transit_local@timescaledb:5432/transit?sslmode=disable'
