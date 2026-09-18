#!/usr/bin/env bash
# Seed a plain (non-admin) user in the Keycloak `nebari` realm for the dev SSO flow.
#
# Why this exists: Harbor ships a built-in local-DB user named `admin` (the
# `harborAdminPassword` account), and the operator dev stack's realm user is ALSO called
# `admin`. Harbor's OIDC auto-onboard therefore refuses to create a second `admin`, and
# signing in as the realm admin dies at the callback with:
#
#   failed to create user record: user admin or email admin@nebari.local already exists
#
# Seeding a differently-named user (default `dev`) gives the SSO quick start a login that
# can actually onboard. The realm admin stays what it is - a Keycloak console account.
#
# Idempotent: an existing user is left in place, and the password is (re)set every run.
#
# NOTE: the operator dev stack runs Keycloak in `start-dev` (in-memory H2), so a Keycloak
# pod restart wipes the realm along with this user - re-run `make seed-user` after one
# (after re-running the operator's keycloak/setup.sh, which recreates the realm).
set -euo pipefail

REALM=${REALM:-nebari}
SEED_USER=${SEED_USER:-dev}
SEED_PASSWORD=${SEED_PASSWORD:-dev-password}
SEED_EMAIL=${SEED_EMAIL:-${SEED_USER}@nebari.local}
SEED_FIRST_NAME=${SEED_FIRST_NAME:-Dev}
SEED_LAST_NAME=${SEED_LAST_NAME:-User}

KC_NAMESPACE=${KC_NAMESPACE:-keycloak}
KC_SERVER=${KC_SERVER:-http://localhost:8080/auth}
KC_ADMIN=${KC_ADMIN:-admin}
KC_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD:-admin}

KC_POD=${KC_POD:-}
if [ -z "$KC_POD" ]; then
  KC_POD=$(kubectl get pods -n "$KC_NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -m1 '^keycloak' || true)
fi
if [ -z "$KC_POD" ]; then
  echo "ERROR: no Keycloak pod found in namespace '$KC_NAMESPACE'." >&2
  echo "       Bring the dev stack up first (cd dev && make up-sso)," >&2
  echo "       or point this script at another pod with KC_POD=..." >&2
  exit 1
fi

kc() { kubectl exec -n "$KC_NAMESPACE" "$KC_POD" -- /opt/keycloak/bin/kcadm.sh "$@"; }

echo "==> seed realm user '$SEED_USER' in realm '$REALM' (pod: $KC_POD)"
kc config credentials --server "$KC_SERVER" --realm master \
  --user "$KC_ADMIN" --password "$KC_ADMIN_PASSWORD" >/dev/null

if kc get users -r "$REALM" -q "username=$SEED_USER" --fields username 2>/dev/null \
  | grep -q "\"$SEED_USER\""; then
  echo "    user '$SEED_USER' already exists"
else
  kc create users -r "$REALM" \
    -s "username=$SEED_USER" \
    -s "email=$SEED_EMAIL" \
    -s "firstName=$SEED_FIRST_NAME" \
    -s "lastName=$SEED_LAST_NAME" \
    -s enabled=true \
    -s emailVerified=true
  echo "    user '$SEED_USER' created ($SEED_EMAIL)"
fi

kc set-password -r "$REALM" --username "$SEED_USER" --new-password "$SEED_PASSWORD"
echo "    password set"
echo ""
echo "    Harbor SSO login: $SEED_USER / $SEED_PASSWORD   (Keycloak realm: $REALM)"
