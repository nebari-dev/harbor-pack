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
| Projects | `bootstrap.projects[]` declares projects, group roles, and tag immutability rules; an idempotent post-install Job applies them. See [Declarative projects](#declarative-projects). |
| Webhooks | `bootstrap.webhooks[]` declares project webhook policies (endpoint, events, Secret-sourced auth header); the same Job creates or updates them. See [Webhook policies](#webhook-policies). |
| Robot accounts | `bootstrap.robots[]` declares long-lived, scoped pull/push credentials; a second post-install Job creates them and writes each secret into a Kubernetes Secret. See [Declarative robot accounts](#declarative-robot-accounts). |
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
# open https://harbor.nebari.local, log in as dev / dev-password, then:
make harbor-bootstrap   # sysadmin + a `dev` project for that user
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

Then open `https://harbor.nebari.local` → **LOGIN VIA OIDC PROVIDER** and sign in as the
Keycloak user **`dev` / `dev-password`** (realm `nebari`; accept the self-signed cert
warnings). `make up-sso` seeds that user via `dev/seed-user.sh`.

The realm admin `admin` / `nebari-admin` is *not* an SSO login: Harbor has a built-in local
user called `admin`, so its OIDC auto-onboard refuses to create a second one and the callback
fails with `user admin or email admin@nebari.local already exists`. Use `admin` /
`Harbor12345` for **Login via Local DB**, and the realm admin only for the Keycloak console.

A freshly onboarded OIDC user has no privileges and no project to push to. After that first
login, `make harbor-bootstrap` grants it system admin, creates a `dev` project with the user
as project admin, and prints the matching `nebi registry add` line.

> **Caveat:** the operator dev stack runs Keycloak in `start-dev` (in-memory H2), so any
> Keycloak pod restart wipes the realm — and the seeded `dev` user with it.
> `enable-sso.sh` restarts Keycloak *before* creating the realm to avoid this; if you restart
> Keycloak later, re-run
> `CLUSTER_NAME=harbor-pack-dev .cache/nebari-operator/dev/scripts/services/keycloak/setup.sh`
> (the operator script needs the cluster name) and then `make seed-user`.

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

## Declarative projects

Harbor never auto-creates projects, so a fresh install (or a re-deploy onto a new cluster)
otherwise comes up with only `library`. Declare them in values and a post-install Job applies
them through Harbor's API — see [`examples/bootstrap-values.yaml`](examples/bootstrap-values.yaml):

```yaml
bootstrap:
  enabled: true
  projects:
    - name: cogs
      public: false
      members:                     # optional: Keycloak (OIDC) groups → project roles
        - group: cog-publishers
          role: developer          # projectAdmin | maintainer | developer | guest | limitedGuest
      immutableTags:               # optional: tag immutability rules
        - tagPattern: "sha-*"
          repoPattern: "**"
```

The `harbor-harbor-pack-bootstrap-projects` Job runs after the OIDC Job (hook weight `10` vs
`5`) using the same admin Secret, and is idempotent: it looks each item up before creating it,
so repeat `helm upgrade`s make no changes. Duplicate projects and members are impossible
(Harbor answers `409 Conflict` if the lookup ever misses); immutable tag rules have no such
server-side guard — Harbor inserts an equivalent rule without comparing selectors — so the Job
matches the tag pattern against the rule's `tag_selectors` and the repo pattern against its
`scope_selectors`. It reads one page of each listing and checks `X-Total-Count`, so if a
project has more members or rules than fit (100, Harbor's maximum page size) the Job fails and
says so instead of acting on a truncated list.

It also works with `nebariapp.enabled: false` (standalone installs need projects too), where it
runs as the namespace `default` ServiceAccount — the Job talks only to Harbor's API and needs
no Kubernetes permissions.

Group members map **OIDC groups** (`group_type: 3`), so they take effect once SSO is
configured; Keycloak group members get the role on their next login. Names, groups and
patterns are rendered into the Job's script as quoted literals; `helm template` fails if one
contains a double quote, backslash or control character.

## Webhook policies

Anything that needs to react to what lands in Harbor — a mirror, an index, a downstream
build — subscribes to a project webhook. Those are per-project database state too, so declare
them alongside the projects and the same Job applies them:

```yaml
bootstrap:
  webhooks:
    - project: cogs                # must be in bootstrap.projects, or already exist
      name: collab-hub-cog-index
      endpoint: https://collab-hub.example.com/cogs/registry-events
      events: [PUSH_ARTIFACT, DELETE_ARTIFACT]
      payloadFormat: Default       # Default | CloudEvents
      authHeader:                  # optional; sent verbatim as the Authorization header
        secretName: harbor-webhook-cog-index
        secretKey: authorization
      skipCertVerify: false
      enabled: true
```

The auth header value comes **only from a Secret**, never from values — create it in the
release namespace before installing:

```bash
kubectl create secret generic harbor-webhook-cog-index -n harbor \
  --from-literal=authorization="Bearer $(cat token)"
```

The kubelet injects it into the bootstrap Job as an environment variable, so the Job still
needs no Kubernetes permissions; the value is written straight into the request body and is
never logged. It is kept off curl's command line, and because Harbor quotes the request back
in some error bodies — where no redaction rule can be trusted, since a quote inside the value
ends the match early — the Job never reads the response body of a webhook create or update at
all: those failures report the HTTP status only, and the harbor-core logs
(`kubectl logs deploy/harbor-core` — for a release name that does not contain "harbor",
`deploy/<release>-harbor-core`) have the detail. The value must be printable: CR/LF are stripped, and any other control character (a
stray tab, say) fails the Job with a message naming the Secret, not its contents.

Unlike projects, webhooks are **updated in place**: the Job matches an existing policy by
`(project, name)` and `PUT`s the full desired body, so editing `endpoint` or `events` and
re-running `helm upgrade` changes the existing policy instead of adding a second one. As with
immutable tag rules that lookup is the only guard against duplicates — a `409` there means it
missed — so it is bounded by `X-Total-Count` and gives up loudly rather than guessing. Event
types are validated against what the running Harbor reports at
`GET /projects/{name}/webhook/events`, so a typo fails the Job with the supported list rather
than quietly creating a policy that never fires. Setting `enabled: false` keeps the policy but
stops delivery; removing an entry from values does **not** delete the policy from Harbor.
## Declarative robot accounts

CI and in-cluster consumers need a credential that is not a human's CLI secret. Harbor's answer
is a robot account, but Harbor reveals a robot's secret **exactly once**, in the create
response — so a robot made by hand in the UI cannot be re-read and does not survive a fresh
install. Declare them instead and the pack captures each secret straight into a Kubernetes
Secret:

```yaml
bootstrap:
  enabled: true
  robots:
    - name: hub-cog-indexer
      level: project             # project | system
      project: cogs              # required for level: project
      duration: -1               # days; -1 = never expires (the default)
      permissions: []            # [] = pull-only (repository:pull, artifact:read/list, tag:list)
      secret:
        name: harbor-robot-hub-cog-indexer
        namespace: ""            # defaults to the release namespace
```

The resulting Secret carries everything a consumer needs to build a docker-style auth entry:

| Key | Value |
|---|---|
| `username` | The **full** name Harbor returns, e.g. `robot$cogs+hub-cog-indexer` |
| `password` | The robot secret (only ever visible at create/rotate time) |
| `registry` | The host of `harbor.externalURL`, e.g. `harbor.nebari.example.com` |

Each Secret also carries a `harbor-pack.nebari.dev/robot-id` annotation recording which Harbor
robot the credential belongs to.

Always set `duration`. Harbor's instance default is 30 days, so a robot created without one
starts returning `401` a month later with nothing in the logs to explain it; `-1` means never.
`0` and fractional values are rejected at render time rather than silently falling back to that
default.

The `harbor-harbor-pack-bootstrap-robots` Job runs at hook weight `11`, after the projects Job
(`10`), so a project-level robot's project already exists. It is idempotent, and decides what
to do by comparing the Secret's `robot-id` annotation against the robot it finds in Harbor:

| State found | Action |
|---|---|
| Robot exists, Secret exists, ids agree | Nothing — a repeat `helm upgrade` is a no-op |
| Robot exists, Secret exists, ids differ (or no annotation) | `PATCH /robots/{id}` to mint a fresh secret, then rewrite the Secret |
| Robot exists, Secret missing | `PATCH /robots/{id}`, then write the Secret |
| Robot missing | `POST /robots`, then write the Secret |

Comparing ids rather than just "does a Secret exist" is what makes the Job crash-safe: if it
dies between creating the robot and writing the Secret, the next run sees the mismatch and
rotates, instead of leaving a dead credential published forever. Legacy Secrets without the
annotation get exactly one rotation and are verifiable from then on.

An existing Secret is only overwritten when the robot behind it was created or rotated in the
same run — deleting the Secret and re-running restores it with a freshly rotated credential.
Two robots may not target the same Secret; `helm template` fails if they do.

The lookup itself is careful, because a false positive would rotate an unrelated robot's secret:
project robots are listed by project id (`GET /robots` without a level silently means *system*
robots only) and matched exactly on `<project>+<name>` locally, system robots are filtered
server-side by exact name, and more than one match — or a listing larger than one page — stops
the Job.

The secret is never logged: the script never runs under `set -x`, never passes the secret (or
the ServiceAccount token, which goes to `curl` in a `0600` config file) as a command-line
argument, and prints only names, ids and API error messages — never a response body, since
robot and Secret payloads carry secret material. Response files are written under `umask 077`
and removed by an `EXIT` trap, so a mid-run failure leaves no credential behind in the pod.

Unlike the projects Job, this one needs Kubernetes API access to write Secrets, so it runs as
its own ServiceAccount with a Role granting `create` on Secrets plus `get`/`update` restricted
to exactly the Secret names you declared. It talks to the Kubernetes REST API with `curl` and
the pod's ServiceAccount token, so it shares the same image as the other Jobs — no `kubectl`,
no extra image.

> **Cross-namespace Secrets.** Setting `secret.namespace` also renders a Role/RoleBinding in
> that namespace, which must already exist at install time. That means this chart writes into a
> namespace it does not own; a consuming chart that would rather own its Secret should leave
> `secret.namespace` empty and reflect/copy the Secret out of the release namespace itself.

> **Not Helm-managed.** The Secrets are written through the Kubernetes API by the Job, not by
> Helm, so `helm uninstall` leaves them behind. Delete them yourself when you remove the
> release.

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

Under Helm the ServiceAccount/Role/RoleBinding are deleted once the hook event succeeds
(`hook-delete-policy: hook-succeeded`), so `helm uninstall` leaves nothing behind. Under
Argo CD they persist between syncs (each sync replaces them; per-resource `HookSucceeded`
deletion there could remove the ServiceAccount before the Job pod starts) — delete the three
`*-stable-secrets` RBAC objects by hand when retiring the app.

Set `provision: false` to bring your own Secrets instead (SealedSecrets, ExternalSecrets, or
`kubectl create secret`); the `harbor:` block is identical either way.

The Job uses three small, pinned, stock images because no single stock image ships all three
tools it needs and the containers run with a read-only root filesystem (so packages cannot be
installed at runtime): `httpd` (2.4, tag pinned in values) for bcrypt `htpasswd`, `alpine/openssl` for the key
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
| `bootstrap.enabled` | `false` | Run the Job that creates `bootstrap.projects` in Harbor. |
| `bootstrap.image` | `""` | Job image; defaults to `oidcSetup.image`. |
| `bootstrap.projects` | `[]` | Projects to create (see [Declarative projects](#declarative-projects)). |
| `bootstrap.projects[].name` | — | Required; Harbor project name. |
| `bootstrap.projects[].public` | `false` | Project visibility. |
| `bootstrap.projects[].members[].group` | — | Keycloak/OIDC group name. |
| `bootstrap.projects[].members[].role` | — | `projectAdmin`, `maintainer`, `developer`, `guest`, or `limitedGuest`. |
| `bootstrap.projects[].immutableTags[].tagPattern` | — | Doublestar tag pattern made immutable. |
| `bootstrap.projects[].immutableTags[].repoPattern` | `**` | Repositories the rule applies to. |
| `bootstrap.webhooks` | `[]` | Project webhook policies (see [Webhook policies](#webhook-policies)). |
| `bootstrap.webhooks[].project` | — | Required; project the policy belongs to. Must be in `bootstrap.projects` or already exist. |
| `bootstrap.webhooks[].name` | — | Required; policy name. Identifies the policy for updates. |
| `bootstrap.webhooks[].endpoint` | — | Required; `http://` or `https://` URL Harbor posts to. |
| `bootstrap.webhooks[].events` | — | Required; Harbor event types, e.g. `[PUSH_ARTIFACT, DELETE_ARTIFACT]`. Validated against the running Harbor. |
| `bootstrap.webhooks[].payloadFormat` | `Default` | `Default` or `CloudEvents`. |
| `bootstrap.webhooks[].authHeader.secretName` | — | Secret holding the Authorization header value. Omit `authHeader` entirely for an unauthenticated endpoint. |
| `bootstrap.webhooks[].authHeader.secretKey` | — | Key within that Secret. |
| `bootstrap.webhooks[].skipCertVerify` | `false` | Skip TLS verification of the endpoint. |
| `bootstrap.webhooks[].enabled` | `true` | `false` keeps the policy but stops delivery. |
| `bootstrap.robots` | `[]` | Robot accounts to create (see [Declarative robot accounts](#declarative-robot-accounts)). |
| `bootstrap.robots[].name` | — | Required; lower-case robot name. Harbor prefixes it (`robot$<project>+<name>`). |
| `bootstrap.robots[].level` | `project` | `project` or `system`. |
| `bootstrap.robots[].project` | `""` | Required for `level: project`; for `level: system` it scopes permissions to one project instead of all (`*`). |
| `bootstrap.robots[].duration` | `-1` | Whole days until expiry; `-1` = never. `0` and fractional values are rejected — do not rely on Harbor's 30-day instance default. |
| `bootstrap.robots[].permissions` | `[]` | `[]` = pull-only (`repository:pull`, `artifact:read`, `artifact:list`, `tag:list`); otherwise explicit project-scope `{resource, action}` pairs. |
| `bootstrap.robots[].secret.name` | — | Required; name of the Kubernetes Secret to write. |
| `bootstrap.robots[].secret.namespace` | `""` | Defaults to the release namespace; another namespace also renders a Role/RoleBinding there. |
| `harbor.*` | — | Passed to the upstream Harbor chart. |

## Troubleshooting

- **NebariApp stuck / `NamespaceNotOptedIn`** — label the namespace:
  `kubectl label ns <ns> nebari.dev/managed=true --overwrite`.
- **OIDC-setup Job failing** — check logs:
  `kubectl logs job/harbor-harbor-pack-oidc-setup -n <ns>`. Common causes: the OIDC Secret
  not yet created by the operator (Job retries via `backoffLimit`), or a wrong admin password
  (`HARBOR_ADMIN_PASSWORD` must match `harbor.harborAdminPassword`).
- **Projects missing after install** — check the bootstrap Job:
  `kubectl logs job/harbor-harbor-pack-bootstrap-projects -n <ns>`. It logs one line per
  project/member/rule/webhook; a non-2xx response is printed with Harbor's error body (except
  for webhook writes — see below).
- **Webhook not created** — same Job. `event type X ... not supported` means a typo in
  `events` (the supported list is printed); `project X does not exist` means the webhook's
  `project` is not in `bootstrap.projects`; `unsupported control characters` means the
  `authHeader` Secret holds a tab or similar. If the Pod never starts, that Secret is probably
  missing from the release namespace — `kubectl describe pod` shows
  `CreateContainerConfigError`. A webhook create/update that fails with a bare HTTP status
  prints no response body on purpose (Harbor may echo the auth header back); the reason is in
  the harbor-core logs (`deploy/harbor-core`, or `deploy/<release>-harbor-core` when the
  release name does not contain "harbor").
- **Robot Secret missing after install** — check the robot Job:
  `kubectl logs job/harbor-harbor-pack-bootstrap-robots -n <ns>`. It logs one line per robot
  (never the secret). A `403` writing the Secret means the target namespace has no
  Role/RoleBinding — it must be named in a `bootstrap.robots[].secret.namespace` and exist at
  install time.
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
- **OIDC callback: `user ... already exists`** — the Keycloak username collides with a Harbor
  local-DB user (`admin` does). Log in as a differently-named realm user; in dev that's the
  seeded `dev` user (`make seed-user`).
- **dev: `make up-sso` reuses a half-built kind cluster** — the `cluster` target only checks
  that kind knows the cluster name, so a run that died partway through setup is silently
  reused. Re-run the step that failed (`make _metallb` / `_services` / `_keycloak-setup` /
  `_operator`), or `make down` and start clean.
- **dev on Colima: every pod times out talking to the API server** — Docker may give the
  `kind` network a subnet that overlaps your LAN (e.g. `192.168.1.0/24`). Pre-create it on
  `172.x` before `make up-sso`; see
  [Local development](docs/src/content/docs/local-development.md).

## Known limitations

- Object storage and external Postgres/Redis are exposed via values but exercised only via
  `helm template` in CI (integration tests use bundled filesystem/Postgres/Redis).
- `bootstrap.projects` applies missing state only: it creates projects, group members and
  immutability rules, but does not update or remove ones that already exist (changing
  `public:` for an existing project, or deleting an entry, has no effect).
- `bootstrap.webhooks` creates and updates policies but never deletes them: removing an entry
  from values leaves the policy in Harbor (set `enabled: false` to stop delivery, or delete it
  in the UI). Like the other listings, the policy lookup reads one page and fails on
  `X-Total-Count` rather than acting on a truncated list.
- `bootstrap.robots` is likewise create-only: an existing robot's `duration` or `permissions`
  are never rewritten, and removing an entry leaves the robot and its Secret in place. Robot
  `permissions` are project-scope resources (permission `kind: project`); system-scope
  permissions are not exposed.
- Upgrades follow upstream Harbor's chart; review upstream release notes before major bumps.

## License

Apache-2.0. See [LICENSE](LICENSE).
