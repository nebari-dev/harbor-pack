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
#
# Read from the environment (the dev Makefile exports them): SEED_USER, HARBOR_PROJECT,
# HARBOR_NAMESPACE, HARBOR_HOSTNAME, HARBOR_SVC, HARBOR_ADMIN, HARBOR_ADMIN_PASSWORD, and
# LOCAL_PORT (default: a free loopback port picked at run time).
set -euo pipefail

HARBOR_NAMESPACE=${HARBOR_NAMESPACE:-harbor}
HARBOR_SVC=${HARBOR_SVC:-harbor}   # Harbor front service (harbor.expose.clusterIP.name)
HARBOR_ADMIN=${HARBOR_ADMIN:-admin}
HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD:-Harbor12345}
HARBOR_HOSTNAME=${HARBOR_HOSTNAME:-harbor.nebari.local}
SEED_USER=${SEED_USER:-dev}
HARBOR_PROJECT=${HARBOR_PROJECT:-dev}

BODY=$(mktemp)
PF_LOG=$(mktemp)
CURL_CFG=$(mktemp)

cleanup() {
  if [ -n "${PF_PID:-}" ]; then kill "$PF_PID" 2>/dev/null || true; fi
  rm -f "$BODY" "$PF_LOG" "$CURL_CFG"
}
trap cleanup EXIT

# Hand the admin credential to curl through a 0600 config file instead of `-u` on the
# command line, so it does not sit in `ps` output for the life of each request.
chmod 600 "$CURL_CFG"
printf 'user = %s:%s\n' "$HARBOR_ADMIN" "$HARBOR_ADMIN_PASSWORD" > "$CURL_CFG"

# api <METHOD> <PATH> [JSON] -> prints the HTTP status, writes the response body to $BODY
api() {
  local method=$1 path=$2 data=${3:-}
  if [ -n "$data" ]; then
    curl -s -K "$CURL_CFG" -o "$BODY" -w '%{http_code}' -X "$method" "$API$path" \
      -H 'Content-Type: application/json' -d "$data"
  else
    curl -s -K "$CURL_CFG" -o "$BODY" -w '%{http_code}' -X "$method" "$API$path"
  fi
}

die() { echo "ERROR: $*" >&2; exit 1; }

# Ask the kernel for a free loopback port rather than squatting on a fixed one: a stale
# port-forward from another cluster (or another copy of this script) must never end up
# receiving these privilege grants.
if [ -z "${LOCAL_PORT:-}" ]; then
  LOCAL_PORT=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')
fi
API="http://127.0.0.1:${LOCAL_PORT}/api/v2.0"

echo "==> port-forward svc/$HARBOR_SVC -n $HARBOR_NAMESPACE -> 127.0.0.1:$LOCAL_PORT"
kubectl -n "$HARBOR_NAMESPACE" port-forward "svc/$HARBOR_SVC" "$LOCAL_PORT:80" >"$PF_LOG" 2>&1 &
PF_PID=$!

# Only proceed once OUR port-forward reports it owns the port. If the port was taken,
# kubectl says so in $PF_LOG ("address already in use") and exits - do not fall through to
# whatever else is listening there.
forwarded=
for _ in $(seq 1 30); do
  if grep -q "Forwarding from 127.0.0.1:${LOCAL_PORT}" "$PF_LOG" 2>/dev/null; then
    forwarded=yes
    break
  fi
  kill -0 "$PF_PID" 2>/dev/null || break
  sleep 1
done
if [ -z "$forwarded" ]; then
  echo "ERROR: could not port-forward svc/$HARBOR_SVC (-n $HARBOR_NAMESPACE) to 127.0.0.1:$LOCAL_PORT" >&2
  sed 's/^/       /' "$PF_LOG" >&2
  echo "       Retry, or pick a free port with LOCAL_PORT=... make harbor-bootstrap" >&2
  exit 1
fi

ready=
for _ in $(seq 1 30); do
  kill -0 "$PF_PID" 2>/dev/null || die "port-forward died: $(cat "$PF_LOG")"
  if curl -sf -o "$BODY" "$API/systeminfo" && grep -q 'harbor_version' "$BODY"; then
    ready=yes
    break
  fi
  sleep 1
done
[ -n "$ready" ] || die "no Harbor API on $API (is Harbor deployed? 'make up-sso')"

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
  echo "  open https://$HARBOR_HOSTNAME   -> LOGIN VIA OIDC PROVIDER   (as '$SEED_USER')"
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

echo "==> create project '$HARBOR_PROJECT'"
code=$(api POST "/projects" \
  "{\"project_name\": \"$HARBOR_PROJECT\", \"metadata\": {\"public\": \"false\"}}")
case "$code" in
  201) echo "    project '$HARBOR_PROJECT' created (private)" ;;
  409) echo "    project '$HARBOR_PROJECT' already exists" ;;
  *) die "project create returned HTTP $code: $(cat "$BODY")" ;;
esac

code=$(api GET "/projects?name=$HARBOR_PROJECT")
[ "$code" = "200" ] || die "project lookup returned HTTP $code: $(cat "$BODY")"
PROJECT_ID=$(python3 - "$BODY" "$HARBOR_PROJECT" <<'PY'
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
[ -n "$PROJECT_ID" ] || die "could not resolve project id for '$HARBOR_PROJECT'"

echo "==> add '$SEED_USER' as project admin of '$HARBOR_PROJECT' (project_id=$PROJECT_ID)"
code=$(api POST "/projects/$PROJECT_ID/members" \
  "{\"role_id\": 1, \"member_user\": {\"username\": \"$SEED_USER\"}}")
case "$code" in
  201)
    echo "    project admin added"
    ;;
  409)
    # Already a member - but possibly as developer/guest from an earlier run or a manual
    # edit. Find the membership and force the role to project admin rather than claiming
    # a privilege the user does not have.
    code=$(api GET "/projects/$PROJECT_ID/members?entityname=$SEED_USER")
    [ "$code" = "200" ] || die "member lookup returned HTTP $code: $(cat "$BODY")"
    MEMBER_ID=$(python3 - "$BODY" "$SEED_USER" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        members = json.load(fh)
except (ValueError, OSError):
    members = []
for m in members or []:
    if m.get("entity_name") == want:
        print(m.get("id", ""))
        break
PY
)
    [ -n "$MEMBER_ID" ] || die "'$SEED_USER' reported as an existing member, but no membership found"
    code=$(api PUT "/projects/$PROJECT_ID/members/$MEMBER_ID" '{"role_id": 1}')
    case "$code" in
      200|204) echo "    existing membership set to project admin" ;;
      *) die "member role update returned HTTP $code: $(cat "$BODY")" ;;
    esac
    ;;
  *) die "member add returned HTTP $code: $(cat "$BODY")" ;;
esac

echo ""
echo "=================================================================="
echo " Harbor is bootstrapped for '$SEED_USER':"
echo "   system admin  +  project '$HARBOR_PROJECT' (project admin)"
echo ""
echo " CLI / Nebi credential: OIDC users cannot use their Keycloak password for the"
echo " registry. In the Harbor UI, open User Profile -> generate CLI secret, then:"
echo ""
echo "   nebi registry add \\"
echo "     --local \\"
echo "     --name harbor \\"
echo "     --url $HARBOR_HOSTNAME \\"
echo "     --namespace $HARBOR_PROJECT \\"
echo "     --username $SEED_USER \\"
echo "     --default"
echo ""
echo " (paste the CLI secret at the Password: prompt)"
echo "=================================================================="
