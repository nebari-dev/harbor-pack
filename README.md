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
all: those failures report the HTTP status only, and `kubectl logs deploy/harbor-core` has the
detail. The value must be printable: CR/LF are stripped, and any other control character (a
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

## Storage & backing services

Defaults are bundled (Harbor's in-chart Postgres/Redis on PVCs, filesystem registry storage)
for a quick start. For production, switch to object storage and external managed backends via
the `harbor.*` values — see the commented blocks in [`chart/values.yaml`](chart/values.yaml)
and [`examples/nebari-values.yaml`](examples/nebari-values.yaml):

- Registry backend → `harbor.persistence.imageChartStorage.type: s3` + `.s3.*`
- Database → `harbor.database.type: external` + `harbor.database.external.*`
- Redis → `harbor.redis.type: external` + `harbor.redis.external.*`

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
  `kubectl logs deploy/harbor-core`.
- **"Login via OIDC Provider" missing** — the Job didn't complete; confirm
  `GET /api/v2.0/configurations` shows `auth_mode=oidc_auth`.
- **`docker login` fails** — use a **CLI secret** or robot account, not your Keycloak
  password (OIDC users cannot use their IdP password for the registry).
- **Keycloak `redirect_uri` error** — ensure `nebariapp.auth.redirectURI` is
  `/c/oidc/callback` and `harbor.externalURL` matches `https://<hostname>`.

## Known limitations

- Object storage and external Postgres/Redis are exposed via values but exercised only via
  `helm template` in CI (integration tests use bundled filesystem/Postgres/Redis).
- `bootstrap.projects` applies missing state only: it creates projects, group members and
  immutability rules, but does not update or remove ones that already exist (changing
  `public:` for an existing project, or deleting an entry, has no effect). Robot accounts are
  not covered yet.
- `bootstrap.webhooks` creates and updates policies but never deletes them: removing an entry
  from values leaves the policy in Harbor (set `enabled: false` to stop delivery, or delete it
  in the UI). Like the other listings, the policy lookup reads one page and fails on
  `X-Total-Count` rather than acting on a truncated list.
- Upgrades follow upstream Harbor's chart; review upstream release notes before major bumps.

## License

Apache-2.0. See [LICENSE](LICENSE).
