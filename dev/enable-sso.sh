#!/usr/bin/env bash
# Enable the full browser SSO flow for harbor-pack on a local kind Nebari stack.
#
# Prerequisite: `make cluster` has brought up the infra + nebari-operator + Keycloak.
# This script wires the pieces the stock operator dev stack does not, then installs
# Harbor so the OIDC login flow works from your host browser:
#
#   1. Set KEYCLOAK_EXTERNAL_URL on the operator so the issuer-url it provisions for
#      Harbor is browser-facing (not the in-cluster service URL).
#   2. Expose Keycloak through the shared gateway at keycloak.nebari.local.
#   3. Make Keycloak honor X-Forwarded-* so it emits https issuer URLs behind the gateway.
#      NOTE: this restarts Keycloak, and the operator dev stack runs Keycloak in
#      `start-dev` (in-memory H2) - a restart WIPES the realm. So we restart FIRST,
#      then (re)create the realm, so the realm survives.
#   4. Seed a non-admin realm user to log in with (dev/seed-user.sh). Harbor has its own
#      built-in `admin`, so the realm admin can never onboard over OIDC.
#   5. Add a CoreDNS hosts entry so in-cluster pods (Harbor core) resolve
#      keycloak.nebari.local to the SAME issuer the browser uses (required: Harbor
#      uses one OIDC endpoint for both browser redirects and server-side token calls).
#   6. Install Harbor with oidcSetup.verifyCert=false (self-signed gateway CA).
#
# After it finishes, follow the printed host-access steps (need sudo).
set -euo pipefail

CLUSTER=${CLUSTER_NAME:-harbor-pack-dev}
export CLUSTER_NAME=$CLUSTER
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_REPO="${OPERATOR_REPO:-$SCRIPT_DIR/.cache/nebari-operator}"
CHART="$SCRIPT_DIR/../chart"
KC_EXTERNAL_URL="https://keycloak.nebari.local/auth"
HOSTNAME_HARBOR="harbor.nebari.local"
HARBOR_ADMIN_PW="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"
SEED_USER="${SEED_USER:-dev}"
SEED_PASSWORD="${SEED_PASSWORD:-dev-password}"

kubectl config use-context "kind-$CLUSTER"

echo "==> 1. operator KEYCLOAK_EXTERNAL_URL=$KC_EXTERNAL_URL"
kubectl -n nebari-operator-system set env deploy/nebari-operator-controller-manager \
  KEYCLOAK_EXTERNAL_URL="$KC_EXTERNAL_URL"
kubectl -n nebari-operator-system rollout status deploy/nebari-operator-controller-manager --timeout=180s

echo "==> 2. expose Keycloak at keycloak.nebari.local via the gateway"
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak
  namespace: keycloak
spec:
  parentRefs:
    - name: nebari-gateway
      namespace: envoy-gateway-system
  hostnames: ["keycloak.nebari.local"]
  rules:
    - backendRefs:
        - name: keycloak-keycloakx-http
          port: 80
EOF

echo "==> 3. Keycloak KC_PROXY_HEADERS=xforwarded (restart BEFORE realm create)"
kubectl -n keycloak set env statefulset/keycloak-keycloakx KC_PROXY_HEADERS=xforwarded
kubectl -n keycloak rollout status statefulset/keycloak-keycloakx --timeout=240s

echo "==> 3b. (re)create the nebari realm now that Keycloak is in its final state"
"$OPERATOR_REPO/dev/scripts/services/keycloak/setup.sh"

echo "==> 4. seed a non-admin realm user for the SSO login (Harbor owns the name 'admin')"
SEED_USER="$SEED_USER" SEED_PASSWORD="$SEED_PASSWORD" bash "$SCRIPT_DIR/seed-user.sh"

echo "==> 5. CoreDNS: resolve keycloak.nebari.local to the Envoy gateway ClusterIP in-cluster"
ENVOY_SVC=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=nebari-gateway -o jsonpath='{.items[0].metadata.name}')
ENVOY_CIP=$(kubectl get svc -n envoy-gateway-system "$ENVOY_SVC" -o jsonpath='{.spec.clusterIP}')
echo "    Envoy gateway service: $ENVOY_SVC  clusterIP: $ENVOY_CIP"
python3 - "$ENVOY_CIP" <<'PY'
import json, re, subprocess, sys
cip = sys.argv[1]
cm = json.loads(subprocess.check_output(["kubectl","get","cm","coredns","-n","kube-system","-o","json"]))
corefile = cm["data"]["Corefile"]
corefile = re.sub(r"    hosts \{\n(?:.*\n)*?    \}\n", "", corefile, count=1) if "keycloak.nebari.local" in corefile else corefile
block = f"    hosts {{\n        {cip} keycloak.nebari.local\n        fallthrough\n    }}\n"
out, inserted = [], False
for ln in corefile.splitlines(keepends=True):
    out.append(ln)
    if not inserted and ln.strip() == "ready":
        out.append(block); inserted = True
cm["data"]["Corefile"] = "".join(out)
subprocess.run(["kubectl","apply","-f","-"], input=json.dumps(cm).encode(), check=True)
print("    CoreDNS patched: keycloak.nebari.local ->", cip)
PY
kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns --timeout=120s

echo "==> 6. install/upgrade Harbor with SSO (verifyCert=false for self-signed CA)"
kubectl create namespace harbor --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace harbor nebari.dev/managed=true --overwrite
helm dependency update "$CHART"
helm upgrade --install harbor "$CHART" -n harbor \
  --set nebariapp.enabled=true \
  --set nebariapp.hostname="$HOSTNAME_HARBOR" \
  --set harbor.externalURL="https://$HOSTNAME_HARBOR" \
  --set harbor.harborAdminPassword="$HARBOR_ADMIN_PW" \
  --set oidcSetup.verifyCert=false \
  --timeout 20m --wait

kubectl wait --for=condition=Ready nebariapp/harbor-harbor-pack -n harbor --timeout=300s
kubectl wait --for=condition=complete job/harbor-harbor-pack-oidc-setup -n harbor --timeout=420s

echo ""
echo "=================================================================="
echo " Harbor is configured for Keycloak SSO. To reach it from your host:"
echo ""
echo "   make host-access     # bridges :80/:443 to the gateway (no sudo)"
echo "   # then the one-time /etc/hosts line it prints (needs sudo)"
echo ""
echo " Then open https://$HOSTNAME_HARBOR  -> LOGIN VIA OIDC PROVIDER"
echo ""
echo "   SSO login (Keycloak realm 'nebari'):  $SEED_USER / $SEED_PASSWORD"
echo ""
echo " (accept the self-signed cert warning for both hostnames)"
echo ""
echo " Other accounts, NOT the SSO login:"
echo "   admin / nebari-admin   - Keycloak realm admin. Harbor already has a local user"
echo "                            named 'admin', so this one can never onboard over OIDC."
echo "   admin / $HARBOR_ADMIN_PW    - Harbor's built-in local DB admin (Login via Local DB)."
echo ""
echo " After the first SSO login, give '$SEED_USER' admin + a project to push to:"
echo "   make harbor-bootstrap"
echo "=================================================================="
