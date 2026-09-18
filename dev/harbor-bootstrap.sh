#!/usr/bin/env bash
# Give the seeded SSO user something to work with, once it has onboarded into Harbor:
#
#   1. grant it Harbor system admin (no `oidcSetup.adminGroup` is set in the dev flow, so a
#      freshly onboarded OIDC user has no privileges at all),
#   2. create a dev project (Harbor never auto-creates projects on push),
#   3. add the user as that project's admin,
#   4. print the `nebi registry add` line for it.
#
# Harbor only knows an OIDC user after that user's FIRST successful browser login
# (`oidc_auto_onboard` creates the record then) - so the order is:
#
#   make up-sso && make host-access     # + the /etc/hosts line it prints
#   # log in once at https://harbor.nebari.local as dev / dev-password
#   make harbor-bootstrap
#
# Talks to Harbor's API over a port-forward, as the built-in local-DB admin (the
# `harborAdminPassword` account) - so it needs neither the /etc/hosts entry nor trust in the
# self-signed dev CA. Idempotent: re-running just re-asserts the roles.
set -euo pipefail

NAMESPACE=${NAMESPACE:-harbor}
HARBOR_SVC=${HARBOR_SVC:-harbor}   # Harbor front service (harbor.expose.clusterIP.name)
HARBOR_ADMIN=${HARBOR_ADMIN:-admin}
HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD:-Harbor12345}
HARBOR_HOSTNAME=${HARBOR_HOSTNAME:-harbor.nebari.local}
SEED_USER=${SEED_USER:-dev}
PROJECT=${PROJECT:-dev}
LOCAL_PORT=${LOCAL_PORT:-18080}

API="http://127.0.0.1:${LOCAL_PORT}/api/v2.0"
BODY=$(mktemp)

cleanup() {
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true
  rm -f "$BODY"
}
trap cleanup EXIT

# api <METHOD> <PATH> [JSON] -> prints the HTTP status, writes the response body to $BODY
api() {
  local method=$1 path=$2 data=${3:-}
  if [ -n "$data" ]; then
    curl -s -o "$BODY" -w '%{http_code}' -X "$method" "$API$path" \
      -u "$HARBOR_ADMIN:$HARBOR_ADMIN_PASSWORD" \
      -H 'Content-Type: application/json' -d "$data"
  else
    curl -s -o "$BODY" -w '%{http_code}' -X "$method" "$API$path" \
      -u "$HARBOR_ADMIN:$HARBOR_ADMIN_PASSWORD"
  fi
}

die() { echo "ERROR: $*" >&2; exit 1; }

echo "==> port-forward svc/$HARBOR_SVC -n $NAMESPACE -> 127.0.0.1:$LOCAL_PORT"
kubectl -n "$NAMESPACE" port-forward "svc/$HARBOR_SVC" "$LOCAL_PORT:80" >/dev/null 2>&1 &
PF_PID=$!

ready=
for _ in $(seq 1 30); do
  if curl -sf -o /dev/null "$API/systeminfo"; then ready=yes; break; fi
  sleep 1
done
[ -n "$ready" ] || die "Harbor API did not answer on $API (is Harbor deployed? 'make up-sso')"

echo "==> look up OIDC user '$SEED_USER' in Harbor"
code=$(api GET "/users/search?username=$SEED_USER")
[ "$code" = "200" ] || die "user search returned HTTP $code: $(cat "$BODY")"

USER_ID=$(python3 - "$BODY" "$SEED_USER" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        users = json.load(fh)
except (ValueError, OSError):
    users = []
for u in users or []:
    if u.get("username") == want:
        print(u.get("user_id", ""))
        break
PY
)

if [ -z "$USER_ID" ]; then
  echo ""
  echo "Harbor has no user '$SEED_USER' yet - it onboards on its FIRST SSO login."
  echo "Complete one browser login, then re-run this:"
  echo ""
  echo "  make host-access     # + the one-time /etc/hosts line it prints"
  echo "  open https://$HARBOR_HOSTNAME   -> LOGIN VIA OIDC PROVIDER   ($SEED_USER / dev-password)"
  echo "  make harbor-bootstrap"
  echo ""
  exit 1
fi
echo "    user '$SEED_USER' is user_id=$USER_ID"

echo "==> grant '$SEED_USER' Harbor system admin"
code=$(api PUT "/users/$USER_ID/sysadmin" '{"sysadmin_flag": true}')
case "$code" in
  200|204) echo "    sysadmin granted" ;;
  *) die "sysadmin grant returned HTTP $code: $(cat "$BODY")" ;;
esac

echo "==> create project '$PROJECT'"
code=$(api POST "/projects" "{\"project_name\": \"$PROJECT\", \"metadata\": {\"public\": \"false\"}}")
case "$code" in
  201) echo "    project '$PROJECT' created (private)" ;;
  409) echo "    project '$PROJECT' already exists" ;;
  *) die "project create returned HTTP $code: $(cat "$BODY")" ;;
esac

code=$(api GET "/projects?name=$PROJECT")
[ "$code" = "200" ] || die "project lookup returned HTTP $code: $(cat "$BODY")"
PROJECT_ID=$(python3 - "$BODY" "$PROJECT" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        projects = json.load(fh)
except (ValueError, OSError):
    projects = []
for p in projects or []:
    if p.get("name") == want:
        print(p.get("project_id", ""))
        break
PY
)
[ -n "$PROJECT_ID" ] || die "could not resolve project id for '$PROJECT'"

echo "==> add '$SEED_USER' as project admin of '$PROJECT' (project_id=$PROJECT_ID)"
code=$(api POST "/projects/$PROJECT_ID/members" \
  "{\"role_id\": 1, \"member_user\": {\"username\": \"$SEED_USER\"}}")
case "$code" in
  201) echo "    project admin added" ;;
  409) echo "    already a project member" ;;
  *) die "member add returned HTTP $code: $(cat "$BODY")" ;;
esac

echo ""
echo "=================================================================="
echo " Harbor is bootstrapped for '$SEED_USER':"
echo "   system admin  +  project '$PROJECT' (project admin)"
echo ""
echo " CLI / Nebi credential: OIDC users cannot use their Keycloak password for the"
echo " registry. In the Harbor UI, open User Profile -> generate CLI secret, then:"
echo ""
echo "   nebi registry add \\"
echo "     --local \\"
echo "     --name harbor \\"
echo "     --url $HARBOR_HOSTNAME \\"
echo "     --namespace $PROJECT \\"
echo "     --username $SEED_USER \\"
echo "     --default"
echo ""
echo " (paste the CLI secret at the Password: prompt)"
echo "=================================================================="
