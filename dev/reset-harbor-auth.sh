#!/usr/bin/env bash
# Force Harbor back to built-in database auth (admin login), clearing any oidc_auth
# left in Harbor's DB from a prior SSO run. Used by `make up` (simple dev mode).
set -euo pipefail
NS=${1:-harbor}
PW=${2:-Harbor12345}
SVC=${3:-harbor}   # Harbor front service name (harbor.expose.clusterIP.name)

kubectl -n "$NS" run harbor-authreset-$$ --rm -i --restart=Never \
  --image=curlimages/curl:8.11.0 --quiet --command -- \
  sh -c "curl -sf -o /dev/null -w 'auth reset HTTP %{http_code}\n' -X PUT \
    http://${SVC}:80/api/v2.0/configurations \
    -u admin:${PW} -H 'Content-Type: application/json' \
    -d '{\"auth_mode\":\"db_auth\"}'"
