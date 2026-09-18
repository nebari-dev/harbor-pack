# harbor-pack

A [Nebari](https://www.nebari.dev/) software pack that runs [Harbor](https://goharbor.io/)
— a CNCF, OCI-compliant registry for container images, Helm charts, and OCI artifacts, with
built-in Trivy vulnerability scanning and RBAC. This pack wraps the upstream Harbor Helm
chart and adds Nebari integration: gateway routing, a landing-page card, and **Keycloak SSO**.

- **Who it's for:** Nebari platform teams and their users who need a private, self-hosted
  registry for images and OCI artifacts, with single sign-on.
- **Level:** `alpha` (see [`pack-metadata.yaml`](pack-metadata.yaml)). Installs and runs the
  happy path on a current Nebari dev cluster; APIs and values may change.

## How it works

| Concern | How the pack handles it |
|---|---|
| Deployment | Wraps `harbor/harbor` (chart `1.19.1`, app `2.15.1`) as a Helm subchart under the `harbor:` values key. |
| Routing / TLS | A `NebariApp` CR points the nebari-operator at Harbor's nginx front Service; the shared gateway terminates TLS and routes to it. |
| Landing card | `NebariApp.spec.landingPage` renders a Harbor card on the Nebari landing page. |
| **SSO** | The operator provisions a Keycloak OIDC client + Secret; a post-install Job switches Harbor into `oidc_auth` mode using those credentials. See [Authentication](#authentication). |
| Storage | Bundled Postgres/Redis + filesystem registry storage by default; toggles for S3/MinIO object storage and external managed Postgres/Redis. |

## Prerequisites

- A Nebari cluster with the **nebari-operator**, **Envoy Gateway**, **cert-manager**, and
  **Keycloak** (the standard NIC stack).
- The install namespace labeled for the operator:
  `kubectl label namespace <ns> nebari.dev/managed=true --overwrite`.
- A Harbor admin password supplied at install time (never commit one).
- For production: an object-storage bucket (S3/MinIO) and/or managed Postgres + Redis if you
  switch off the bundled backends.

## Quick start (on Nebari)

```sh
kubectl create namespace harbor
kubectl label namespace harbor nebari.dev/managed=true --overwrite

helm install harbor ./chart -n harbor \
  -f examples/nebari-values.yaml \
  --set nebariapp.hostname=harbor.nebari.example.com \
  --set harbor.externalURL=https://harbor.nebari.example.com \
  --set harbor.harborAdminPassword="$(openssl rand -base64 24)"
```

Then:

```sh
kubectl get nebariapp harbor-harbor-pack -n harbor        # wait for Ready
kubectl get job harbor-harbor-pack-oidc-setup -n harbor   # should Complete
```

Open `https://harbor.nebari.example.com` and click **LOGIN VIA OIDC PROVIDER**.

## Standalone (local, no Nebari)

```sh
helm dependency update ./chart
helm install harbor ./chart -n harbor --create-namespace -f examples/standalone-values.yaml
kubectl -n harbor port-forward svc/harbor 8080:80
# open http://localhost:8080  (admin / Harbor12345)
```

## Local dev on kind

`dev/` has a Makefile that stands up the full Nebari stack (Envoy Gateway, cert-manager,
Keycloak, nebari-operator) on kind. There are two dev modes:

### Simple mode (recommended for everyday work) — `make up`

Exercises the real NebariApp/operator integration, but with **gateway TLS off (no cert)** and
**OIDC off (Harbor's built-in DB admin login)** — so no cert warnings and no SSO plumbing:

```sh
cd dev
make up              # NebariApp on, HTTP, DB auth
make host-access     # bridges host :80/:443 to the gateway (no sudo) + prints the /etc/hosts line
sudo sh -c 'echo "127.0.0.1 harbor.nebari.local keycloak.nebari.local" >> /etc/hosts'
# open http://harbor.nebari.local   (login: admin / Harbor12345)
```

If you want zero Nebari machinery at all (no operator/gateway/hostnames), use
[Standalone](#standalone-local-no-nebari) instead.

### Full Keycloak SSO — `make up-sso`

Deploys Harbor with the complete browser SSO flow working end-to-end:

```sh
cd dev
make up-sso          # bootstraps the cluster + wires SSO + installs Harbor
make host-access     # bridges host :80/:443 to the gateway (no sudo) + prints the /etc/hosts line
```

`make up-sso` creates the kind cluster with host ports 80/443 published (`kind-config.yaml`),
so `make host-access` can bridge them to the Envoy gateway via socat in the node — no
privileged `sudo kubectl port-forward` needed. The only `sudo` is a one-time `/etc/hosts` line
that `make host-access` prints:

```sh
sudo sh -c 'echo "127.0.0.1 harbor.nebari.local keycloak.nebari.local" >> /etc/hosts'
```

Because Harbor uses a single OIDC endpoint for both the browser redirect and its own
server-side token calls, `enable-sso.sh` sets `KEYCLOAK_EXTERNAL_URL` on the operator, exposes
Keycloak at `keycloak.nebari.local` through the gateway, sets `KC_PROXY_HEADERS=xforwarded`,
and adds a CoreDNS `hosts` entry so the issuer is identical from the browser and from Harbor
core. It installs Harbor with `oidcSetup.verifyCert=false` (self-signed dev CA).

Then open `https://harbor.nebari.local` → **LOGIN VIA OIDC PROVIDER** (Keycloak user
`admin` / `nebari-admin`, realm `nebari`; accept the self-signed cert warnings).

> **Caveat:** the operator dev stack runs Keycloak in `start-dev` (in-memory H2), so any
> Keycloak pod restart wipes the realm. `enable-sso.sh` restarts Keycloak *before* creating
> the realm to avoid this; if you restart Keycloak later, re-run
> `.cache/nebari-operator/dev/scripts/services/keycloak/setup.sh`.

## Authentication

Harbor performs OIDC **itself** (the portal shows a "Login via OIDC Provider" button), and
CLI clients (`docker`, `oras`, `helm`) authenticate with Basic auth using a per-user **CLI
secret** or a **robot account** against Harbor's own token endpoint. Because of this:

- `nebariapp.auth.enforceAtGateway` is **`false`** and must stay that way. The operator still
  provisions the Keycloak client and the `harbor-harbor-pack-oidc-client` Secret, but does
  **not** create an Envoy `SecurityPolicy`. Gateway-enforced browser OAuth would break
  `docker login` and CLI push/pull.
- `nebariapp.auth.redirectURI` is `/c/oidc/callback` (Harbor's callback), which the operator
  registers on the Keycloak client.
- `offline_access` is included in the requested scopes so Harbor can refresh tokens and mint
  CLI secrets.

Harbor's OIDC settings live in its database (not Helm values), so the
`harbor-harbor-pack-oidc-setup` Job reads the operator-created Secret and calls
`PUT /api/v2.0/configurations` to enable `oidc_auth`. The Job runs as the NebariApp's
ServiceAccount, which the operator grants read access to the OIDC Secret.

### Who can create projects

The same Job also sets Harbor's `project_creation_restriction`. With `oidcSetup.autoOnboard`
(the default) every user who can log in through Keycloak gets a Harbor account, so the pack
defaults to **`adminonly`**: only Harbor system admins create projects.

> **Upgrade note:** this changes behaviour for existing SSO installs. Harbor's own default is
> `everyone`, so before this change any onboarded OIDC user could create projects; after
> upgrading, they cannot. To keep the old behaviour, set
> `oidcSetup.projectCreationRestriction: everyone`, or set it to `""` to leave whatever is
> currently configured in Harbor untouched. Standalone installs (`oidcSetup.enabled=false`)
> do not run the Job and are unaffected.

Other editable Harbor system settings can be set through the same call without a chart change:

```yaml
oidcSetup:
  systemConfig:
    robot_name_prefix: "robot$"
    robot_token_duration: 30             # days
    audit_log_forward_endpoint: "syslog://logger:5140"
```

Keys are Harbor config-API names and values keep their YAML type (numbers and booleans are
sent unquoted). Keys the Job manages itself — `auth_mode`, the `oidc_*` settings, and
`project_creation_restriction` — are rejected at render time with a message naming the key,
so they cannot silently override the chart; use the dedicated `oidcSetup` option instead.

### Pushing images / artifacts

```sh
# In the Harbor UI: create a project, then "User Profile → generate CLI secret".
docker login harbor.nebari.example.com          # username + CLI secret
docker tag alpine harbor.nebari.example.com/library/alpine:latest
docker push harbor.nebari.example.com/library/alpine:latest
```

## Storage & backing services

Defaults are bundled (Harbor's in-chart Postgres/Redis on PVCs, filesystem registry storage)
for a quick start. For production, switch to object storage and external managed backends via
the `harbor.*` values — see the commented blocks in [`chart/values.yaml`](chart/values.yaml)
and [`examples/nebari-values.yaml`](examples/nebari-values.yaml):

- Registry backend → `harbor.persistence.imageChartStorage.type: s3` + `.s3.*`
- Database → `harbor.database.type: external` + `harbor.database.external.*`
- Redis → `harbor.redis.type: external` + `harbor.redis.external.*`

## Stable secrets (GitOps)

The upstream Harbor chart mints credentials **at render time** when they are not supplied
(`randAlphaNum` for the core/jobservice/registry secrets, `genCA` for the token-signing key
pair, `htpasswd` for the registry credential), reusing what is already in the cluster via
`lookup`. A GitOps controller renders *without* cluster access, so `lookup` finds nothing:
every sync draws fresh values, re-keys four Secrets, and rolls `core`, `jobservice` and
`registry`. This is Argo CD's documented
[random-data](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/#random-data) failure
mode — two `helm template` runs of this chart differ in seven objects by default.

`stableSecrets` moves those credentials into two Secrets that live in the cluster, so nothing
is generated at render time and repeated renders are byte-identical (CI checks exactly that):

```yaml
stableSecrets:
  enabled: true
  provision: true                           # create the Secrets if they are missing
  internalSecret: harbor-internal
  tokenSigningSecret: harbor-token-signing
  adminPassword:
    enabled: true                           # optional: generate the admin password too
    secretName: harbor-admin
```

Helm cannot write a subchart's values from a parent template, so enabling this does **not**
rewrite the `harbor:` values for you — the seven upstream keys must be set alongside it.
[`examples/gitops-values.yaml`](examples/gitops-values.yaml) is the ready-made file; the chart
fails the render with the exact block to paste if any key is missing or mismatched.

### What the Secrets hold

| Secret | Type | Keys | Protects |
|---|---|---|---|
| `harbor-internal` | `Opaque` | `secretKey` (16 chars) | **Encrypts robot-account and registry credentials stored in Harbor's database.** Back it up *with* the database — without it those credentials are unrecoverable. |
| | | `secret` (16) | `core` ↔ component shared secret. |
| | | `CSRF_KEY` (32 exactly) | Portal CSRF tokens; `harbor-core` validates the length. |
| | | `JOBSERVICE_SECRET` (16) | `jobservice` API authentication. |
| | | `REGISTRY_HTTP_SECRET` (16) | Registry upload-state HMAC; must be identical across registry replicas. |
| | | `REGISTRY_PASSWD` | Plaintext password `core`/`jobservice` send to the registry. |
| | | `REGISTRY_HTPASSWD` | `<username>:<bcrypt hash of REGISTRY_PASSWD>`. Username defaults to `harbor_registry_user` (`harbor.registry.credentials.username`). bcrypt only. |
| `harbor-token-signing` | `kubernetes.io/tls` | `tls.crt`, `tls.key` | Signs the JWTs the registry accepts for pull/push. The key must be PKCS#1 (`BEGIN RSA PRIVATE KEY`) — Harbor's libtrust rejects PKCS#8. |
| `harbor-admin` | `Opaque` | `HARBOR_ADMIN_PASSWORD` | Harbor's built-in `admin` account (optional). |

Key names are fixed: the Job writes the defaults above, so `harbor.core.existingXsrfSecretKey`,
`harbor.jobservice.existingSecretKey` and `harbor.registry.existingSecretKey` must keep their
upstream defaults (`CSRF_KEY`, `JOBSERVICE_SECRET`, `REGISTRY_HTTP_SECRET`). The chart fails
the render if they are renamed, rather than letting the pods reference a key that is not there.

When `adminPassword.enabled` is set, `harbor.existingSecretAdminPassword` points Harbor at
`harbor-admin` and upstream then *omits* the password from its core Secret — so the OIDC-setup
Job follows it automatically (`oidcSetup.adminPasswordSecret` still overrides).

### Provisioning

With `provision: true` a **pre-install/pre-upgrade** hook Job (annotated
`argocd.argoproj.io/hook: PreSync`, since the pods mount these Secrets at startup) creates
whichever Secrets are absent and leaves existing ones alone — its Role grants only `get` and
`create` on Secrets, so overwriting is impossible by construction, not by convention. Values
are never logged. It runs under its own ServiceAccount/Role/RoleBinding, rendered as hooks at
a lower weight, and does not depend on `nebariapp`.

Set `provision: false` to bring your own Secrets instead (SealedSecrets, ExternalSecrets, or
`kubectl create secret`); the `harbor:` block is identical either way.

The Job uses three small, pinned, stock images because no single stock image ships all three
tools it needs and the containers run with a read-only root filesystem (so packages cannot be
installed at runtime): `httpd:2.4-alpine` for bcrypt `htpasswd`, `alpine/openssl` for the key
pair, and `curlimages/curl` to create the Secrets through the Kubernetes API. Override them
under `stableSecrets.images` to pull from a mirror.

### Migrating an existing install

**Do not just switch `stableSecrets.enabled` on over a running Harbor.** As soon as
`harbor.existingSecretSecretKey` is set, upstream stops writing `secretKey` into its core
Secret; a freshly generated one would replace the key that encrypts the robot-account and
registry credentials already in Harbor's database, and they become undecryptable. The
provisioning Job detects this (core Secret still carries a chart-generated `secretKey`, the
internal Secret does not exist) and **refuses to run**.

Copy the existing material across first. With the default release name `harbor`, upstream's
Secrets are `harbor-core`, `harbor-jobservice`, `harbor-registry` and
`harbor-registry-htpasswd` (otherwise `<release>-harbor-*`):

```sh
NS=harbor
CORE=harbor-core
JOBSVC=harbor-jobservice
REG=harbor-registry
HTPASSWD=harbor-registry-htpasswd

get() { kubectl -n "$NS" get secret "$1" -o "jsonpath={.data.$2}" | base64 -d; }

kubectl -n "$NS" create secret generic harbor-internal \
  --from-literal=secretKey="$(get $CORE secretKey)" \
  --from-literal=secret="$(get $CORE secret)" \
  --from-literal=CSRF_KEY="$(get $CORE CSRF_KEY)" \
  --from-literal=JOBSERVICE_SECRET="$(get $JOBSVC JOBSERVICE_SECRET)" \
  --from-literal=REGISTRY_HTTP_SECRET="$(get $REG REGISTRY_HTTP_SECRET)" \
  --from-literal=REGISTRY_PASSWD="$(get $CORE REGISTRY_CREDENTIAL_PASSWORD)" \
  --from-literal=REGISTRY_HTPASSWD="$(get $HTPASSWD REGISTRY_HTPASSWD)"

# The token-signing key pair lives in the same core Secret (keys tls.crt/tls.key).
umask 077
get $CORE 'tls\.crt' > /tmp/harbor-token.crt
get $CORE 'tls\.key' > /tmp/harbor-token.key
kubectl -n "$NS" create secret tls harbor-token-signing \
  --cert=/tmp/harbor-token.crt --key=/tmp/harbor-token.key
rm -f /tmp/harbor-token.crt /tmp/harbor-token.key

# Only if you also want stableSecrets.adminPassword.enabled and the password is
# still in the core Secret (i.e. harbor.existingSecretAdminPassword was unset):
kubectl -n "$NS" create secret generic harbor-admin \
  --from-literal=HARBOR_ADMIN_PASSWORD="$(get $CORE HARBOR_ADMIN_PASSWORD)"
```

Then enable `stableSecrets` together with the `harbor:` fan-out and upgrade. The Job sees the
Secrets already exist, leaves them untouched, and the credentials never change — which is the
whole point.

`stableSecrets.allowFreshOnExisting: true` overrides the refusal and generates fresh
credentials instead. Use it only on an install whose stored credentials you are willing to
lose (a dev cluster, or a Harbor with no robot accounts and no replication endpoints yet).

Two paths the preflight check **cannot** catch — the refusal keys off the chart-generated
`secretKey` still sitting in the core Secret, which is absent in both:

- **Already using your own `harbor.existingSecretSecretKey`?** Point
  `stableSecrets.internalSecret` at a Secret that carries your *current* key material (either
  your existing Secret, extended with the other six keys, or a new one built from it). Naming
  a Secret that does not exist yet makes the Job generate a *fresh* `secretKey`, with the same
  data loss described above.
- **Never delete the internal Secret while Harbor holds data.** The Job provisions whatever is
  absent, so a deleted `harbor-internal` is regenerated — with a new `secretKey` — on the next
  sync. Back it up alongside the database (see the note on `secretKey` below).

### Rotating a credential

There is no in-place rotation: recreate the Secret and restart whatever mounts it.

```sh
# Example: rotate the jobservice secret.
kubectl -n harbor get secret harbor-internal -o yaml > /tmp/harbor-internal.bak.yaml
kubectl -n harbor patch secret harbor-internal \
  -p "{\"stringData\":{\"JOBSERVICE_SECRET\":\"$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)\"}}"
kubectl -n harbor rollout restart deploy/harbor-core deploy/harbor-jobservice deploy/harbor-registry
```

Notes per key:

- `secretKey` — **do not rotate casually.** Robot-account and registry credentials already in
  the database are encrypted with it and become unreadable if it changes.
- `REGISTRY_PASSWD` — must be rotated together with `REGISTRY_HTPASSWD` (the bcrypt hash of
  the new password, `htpasswd -nbB -C 10 harbor_registry_user <new>`), or the registry will
  reject `core` and `jobservice`.
- `tls.crt`/`tls.key` — replacing them invalidates every issued pull/push token; in-flight
  `docker pull`s fail until clients re-authenticate. The provisioned certificate is valid for
  `stableSecrets.tokenCertDays` (default 3650) precisely so this is a deliberate act.
- Deleting a Secret entirely and re-running the hook (`helm upgrade`, or an Argo CD sync)
  regenerates it — the same rotation, with the same restart requirement.

## Values reference (pack-specific)

| Key | Default | Description |
|---|---|---|
| `nebariapp.enabled` | `false` | Emit the `NebariApp` CR (set true on Nebari). |
| `nebariapp.hostname` | — | Required when enabled; Harbor's external hostname. |
| `nebariapp.manageNamespace` | `false` | Emit a `nebari.dev/managed` Namespace (else label it yourself). |
| `nebariapp.auth.enabled` | `true` | Provision the Keycloak OIDC client. |
| `nebariapp.auth.enforceAtGateway` | `false` | Keep false — Harbor does OIDC itself. |
| `nebariapp.auth.redirectURI` | `/c/oidc/callback` | Harbor's OIDC callback path. |
| `nebariapp.auth.scopes` | `[openid, profile, email, offline_access, groups]` | Requested OIDC scopes. |
| `nebariapp.landingPage.*` | Harbor card | Landing-page card metadata. |
| `oidcSetup.enabled` | `true` | Run the Job that switches Harbor to `oidc_auth`. |
| `oidcSetup.adminGroup` | `""` | Keycloak group mapped to Harbor system-admin. |
| `oidcSetup.autoOnboard` | `true` | Auto-create Harbor users on first OIDC login. |
| `oidcSetup.projectCreationRestriction` | `adminonly` | Who may create projects: `adminonly`, `everyone`, or `""` to leave Harbor's setting alone. |
| `oidcSetup.systemConfig` | `{}` | Extra Harbor system settings (config-API keys) merged into the same configuration call. |
| `stableSecrets.enabled` | `false` | Use pre-created Secrets instead of render-time generation (see [Stable secrets](#stable-secrets-gitops)). |
| `stableSecrets.provision` | `true` | Run the PreSync hook Job that creates missing Secrets. |
| `stableSecrets.allowFreshOnExisting` | `false` | Override the refusal to re-key an existing install (destroys stored credentials). |
| `stableSecrets.internalSecret` | `harbor-internal` | Opaque Secret holding the seven internal credentials. |
| `stableSecrets.tokenSigningSecret` | `harbor-token-signing` | `kubernetes.io/tls` Secret signing registry tokens. |
| `stableSecrets.tokenCertDays` | `3650` | Lifetime of the provisioned token-signing certificate. |
| `stableSecrets.adminPassword.enabled` | `false` | Also generate the Harbor admin password Secret when absent. |
| `stableSecrets.images.*` | pinned | Images for the provisioning Job (`htpasswd`, `openssl`, `apiClient`). |
| `harbor.*` | — | Passed to the upstream Harbor chart. |

## Troubleshooting

- **NebariApp stuck / `NamespaceNotOptedIn`** — label the namespace:
  `kubectl label ns <ns> nebari.dev/managed=true --overwrite`.
- **OIDC-setup Job failing** — check logs:
  `kubectl logs job/harbor-harbor-pack-oidc-setup -n <ns>`. Common causes: the OIDC Secret
  not yet created by the operator (Job retries via `backoffLimit`), or a wrong admin password
  (`HARBOR_ADMIN_PASSWORD` must match `harbor.harborAdminPassword`).
- **"Login via OIDC Provider" missing** — the Job didn't complete; confirm
  `GET /api/v2.0/configurations` shows `auth_mode=oidc_auth`.
- **`docker login` fails** — use a **CLI secret** or robot account, not your Keycloak
  password (OIDC users cannot use their IdP password for the registry).
- **Render fails with "stableSecrets.enabled is true, but …"** — the seven `harbor.*` keys are
  missing or point somewhere else; paste the block from the error message, or use
  [`examples/gitops-values.yaml`](examples/gitops-values.yaml).
- **Stable-secrets Job failing** — `kubectl logs job/<release>-harbor-pack-stable-secrets -n <ns>`
  (add `-c preflight` / `-c generate-material` / `-c generate-token-cert` for the init
  containers). It only ever prints Secret names and HTTP status codes. A `403` means the
  hook's Role/RoleBinding did not land first (they are hooks at a lower weight/sync-wave).
- **"REFUSING to generate new credentials"** — you enabled `stableSecrets` on an install that
  already has chart-generated credentials; follow
  [Migrating an existing install](#migrating-an-existing-install).
- **Pods stuck in `CreateContainerConfigError` after enabling `stableSecrets`** — the named
  Secrets do not exist and `provision` is `false`; create them or turn provisioning on.
- **Keycloak `redirect_uri` error** — ensure `nebariapp.auth.redirectURI` is
  `/c/oidc/callback` and `harbor.externalURL` matches `https://<hostname>`.

## Known limitations

- Object storage and external Postgres/Redis are exposed via values but exercised only via
  `helm template` in CI (integration tests use bundled filesystem/Postgres/Redis).
- No automated Harbor→Keycloak group→project role mapping beyond `oidc_admin_group`.
- Upgrades follow upstream Harbor's chart; review upstream release notes before major bumps.

## License

Apache-2.0. See [LICENSE](LICENSE).
