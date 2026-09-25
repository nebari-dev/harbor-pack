---
title: Configuration
description: Storage backends, external database/Redis, and the pack-specific values for harbor-pack.
---

Everything under the `harbor:` key in `values.yaml` is passed straight to the upstream Harbor
chart. The pack adds `nebariapp.*`, `oidcSetup.*` and `bootstrap.*`.

## Declarative projects

Harbor never auto-creates projects, so a fresh install comes up with only `library` until
someone clicks through the UI. Declare them instead, and a post-install/upgrade Job applies
them through Harbor's API:

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
          repoPattern: "**"        # defaults to ** (all repositories in the project)
```

The Job (`<release>-harbor-pack-bootstrap-projects`) runs at hook weight `10`, after the OIDC
Job, authenticating with the same admin Secret. It is idempotent — every project, member and
rule is looked up before it is created — so a repeat `helm upgrade` makes no changes. For
projects and members Harbor's own `409 Conflict` is a second line of defence; immutable tag
rules have none (Harbor will insert an equivalent rule), so the Job compares each rule's
`tag_selectors` and `scope_selectors` separately and refuses to continue rather than risk a
duplicate — if `X-Total-Count` says a project has more members or rules than the single page it
reads (100, Harbor's maximum page size), or if a rule cannot be parsed. It needs no
Kubernetes API access, and so works on standalone installs (`nebariapp.enabled: false`) as
well, running as the namespace `default` ServiceAccount.

Values are rendered into the Job's shell script as quoted literals, and `helm template` fails
if a name, group or pattern contains a double quote, backslash or control character.

Members are **OIDC group** bindings, so they only grant access once SSO is configured
(see [Authentication](/authentication/)); a user picks up the role on their next login.

The Job only adds missing state: it never updates or deletes existing projects, members or
rules. Changing `public:` for a project that already exists, or removing an entry from
`projects`, has no effect on Harbor.

Follow the Job with `kubectl logs job/<release>-harbor-pack-bootstrap-projects -n <ns>`; it
prints one line per project, member, rule and webhook.

## Webhook policies

Systems that mirror or index what lands in Harbor subscribe to a project webhook. Declare
those in the same `bootstrap:` block and the same Job applies them, after the projects:

```yaml
bootstrap:
  webhooks:
    - project: cogs                # must be in bootstrap.projects, or already exist
      name: collab-hub-cog-index
      endpoint: https://collab-hub.example.com/cogs/registry-events
      events: [PUSH_ARTIFACT, DELETE_ARTIFACT]
      payloadFormat: Default       # Default | CloudEvents (default: Default)
      authHeader:                  # optional; sent verbatim as the Authorization header
        secretName: harbor-webhook-cog-index
        secretKey: authorization
      skipCertVerify: false
      enabled: true                # false keeps the policy but stops delivery
```

### The auth header

`authHeader` names a Secret, never a literal — the value stays out of values files and out of
Git. Create it in the release namespace before installing:

```bash
kubectl create secret generic harbor-webhook-cog-index -n harbor \
  --from-literal=authorization="Bearer $(cat token)"
```

The kubelet injects it into the Job as an environment variable (`WEBHOOK_AUTH_<index>`), so
the Job still needs no Kubernetes API access. The value goes straight into the request body
and is never logged: it is kept off curl's command line, and the response body of a webhook
create or update is never read. Harbor quotes the offending request back in some error
bodies, and redacting that reliably is not something a regular expression can do — a quote
inside the value ends the match early and leaks the rest — so those failures report the HTTP
status only. The harbor-core logs have the detail when a 4xx needs chasing
(`kubectl logs deploy/harbor-core`; the Deployment is `<release>-harbor-core` when the
release name does not contain "harbor").

Omit `authHeader` for an endpoint that needs no credential; the `auth_header` field is then
left out of the policy entirely.

The value must be printable. A trailing CR/LF (which `--from-literal` and especially
`--from-file` tend to add) is stripped, but any other control character would need a JSON
escape this shell script deliberately does not implement, so the Job fails with a message
naming the webhook and the Secret — never the value itself.

If the Secret is missing, the Job's Pod will not start — `kubectl describe pod` reports
`CreateContainerConfigError`.

### Updates and validation

Webhooks are the one part of `bootstrap` that updates in place. The Job matches an existing
policy by `(project, name)` and `PUT`s the full desired body, so editing `endpoint` or
`events` and running `helm upgrade` changes that policy rather than creating a duplicate. It
still never deletes: dropping an entry from values leaves the policy in Harbor.

That lookup is the only thing preventing a duplicate — Harbor's `409` on the create means the
lookup missed, and is treated as fatal — so it is held to the same standard as the immutable
tag rules: one page bounded by `X-Total-Count`, and a loud failure if the policy is found but
its id cannot be read.

Event types are checked at run time against `GET /projects/{name}/webhook/events` on the
running Harbor, so a typo fails the Job with the supported list printed rather than creating
a policy that never fires. A webhook whose `project` does not exist fails with a message
naming it — list the project in `bootstrap.projects` (it is created earlier in the same run)
or create it first.

## Declarative robot accounts

Harbor reveals a robot account's secret **exactly once**, in the create response — there is no
"show it again" API. A robot created by hand in the UI therefore cannot be recovered and does
not survive a fresh install. Declare them instead and a second bootstrap Job captures each
secret straight into a Kubernetes Secret:

```yaml
bootstrap:
  enabled: true
  robots:
    - name: hub-cog-indexer
      level: project             # project | system
      project: cogs              # required for level: project
      duration: -1               # days; -1 = never expires (the default)
      permissions: []            # [] = read-only enumeration + pull: repository:list,
                                 #      repository:pull, artifact:read, artifact:list,
                                 #      tag:list
      secret:
        name: harbor-robot-hub-cog-indexer
        namespace: ""            # defaults to the release namespace
```

Each Secret carries what a consumer needs to build a docker-style auth entry without a second
lookup:

| Key | Value |
|---|---|
| `username` | The **full** name Harbor returns, e.g. `robot$cogs+hub-cog-indexer` |
| `password` | The robot secret |
| `registry` | The host of `harbor.externalURL`, e.g. `harbor.nebari.example.com` |

Each Secret also carries a `harbor-pack.nebari.dev/robot-id` annotation recording which Harbor
robot the credential belongs to.

:::caution Always set `duration`
Harbor's instance default `robot_token_duration` is 30 days. A robot created without an
explicit duration expires silently and the consumer starts getting `401`s a month later. `-1`
means never; `0` and fractional values are rejected at render time so they cannot quietly fall
back to that default.
:::

The Job (`<release>-harbor-pack-bootstrap-robots`) runs at hook weight `11`, after the projects
Job, so a project-level robot's project already exists. It is idempotent, and on every run it
first reconciles the robot itself with what values declare:

| Robot state in Harbor | Action |
|---|---|
| Expired (`expires_at` has passed) | `DELETE` + `POST /robots`, then write the Secret. Harbor only recomputes the expiry when the duration changes, so an expired robot cannot be revived in place |
| Disabled | `PATCH /robots/{id}` to rotate the secret and rewrite the Secret, and only **then** the `PUT` below re-enables it — so a credential someone cut off stays dead, and a crash in between leaves the robot disabled (the next run rotates again) instead of enabled behind a dead Secret |
| Present | `PUT /robots/{id}` re-asserts the declared description, `duration`, `permissions` and `disable: false`; the secret is untouched. If the duration changed, the new expiry is re-read and an already-past one is recreated as above |

It then decides what to do with the credential by comparing the Secret's `robot-id` annotation
against the robot it found:

| State found | Action |
|---|---|
| Robot exists, Secret exists, ids agree | Merge-patch the Secret's `username`/`registry` keys if they drifted (e.g. `harbor.externalURL` changed); the password is left alone |
| Robot exists, Secret exists, ids differ (or no annotation) | `PATCH /robots/{id}` to mint a fresh secret, then rewrite the Secret |
| Robot exists, Secret missing | `PATCH /robots/{id}`, then write the Secret |
| Robot missing | `POST /robots`, then write the Secret |

Comparing ids rather than just "does a Secret exist" is what makes the Job crash-safe. If it
dies between creating the robot and writing the Secret, the next run sees the mismatch and
rotates instead of leaving a dead credential published forever. A Secret written before this
annotation existed gets exactly one rotation and is verifiable from then on.

An existing Secret's password is only overwritten when the robot behind it was created or
rotated in the same run, so deleting the Secret and re-running restores it with a freshly rotated credential.
Two robots may not target the same Secret — `helm template` fails if they do, rather than
letting them overwrite each other on every run.

Rotating the wrong robot would break whatever was using it, so the lookup is deliberately
strict. Project robots are listed by project id — `GET /robots` without a level silently means
*system* robots only, and the name cannot be filtered server-side because Harbor unescapes the
query string a second time, turning the `+` in `<project>+<name>` into a space — and matched
exactly on the stored name locally. System robots are filtered by exact name server-side. More
than one match, or a listing larger than one page, stops the Job.

The secret is never logged: the script never runs under `set -x`, never passes the secret (or
the ServiceAccount token, which goes to `curl` in a `0600` config file) as a command-line
argument, and prints only names, ids and API error messages — never a response body, since
robot and Secret payloads carry secret material. Response files are written under `umask 077`
and removed by an `EXIT` trap, so a mid-run failure leaves no credential behind in the pod.

Unlike the projects Job, this one must write to the Kubernetes API, so it runs as a dedicated
ServiceAccount whose Role grants `create` on Secrets plus `get`/`update`/`patch` restricted to exactly
the Secret names declared in values. It reaches the Kubernetes REST API with `curl` and the
pod's projected ServiceAccount token, so it reuses the same image as the other Jobs — no
`kubectl` binary and no extra image to pin.

:::note Cross-namespace Secrets
Setting `secret.namespace` also renders a Role/RoleBinding in that namespace, which must
already exist at install time — the chart then writes into a namespace it does not own. A
consuming chart that would rather own its Secret should leave `secret.namespace` empty and
reflect or copy the Secret out of the release namespace itself.
:::

:::note Not Helm-managed
The Secrets are written by the Job through the Kubernetes API, not by Helm, so
`helm uninstall` leaves them behind. Delete them yourself when you remove the release.
:::

Declared robots are reconciled, but undeclared ones are never deleted: removing an entry from
`robots` leaves the robot and its Secret alone. To retire a robot, remove it from values *and*
delete it in Harbor — a declared robot that is disabled by hand is rotated and re-enabled on the
next upgrade. Permissions are project-scope resources (permission `kind: project`); system-scope
permissions are not exposed.

To use the credential from a client, see [Registry Setup](/registry-setup/).

## Storage

By default the pack is self-contained: Harbor's bundled Postgres and Redis run on PVCs and
the registry stores blobs on a filesystem PVC. This is ideal for a quick start but not for
production scale.

### Object storage for the registry

```yaml
harbor:
  persistence:
    imageChartStorage:
      type: s3
      s3:
        region: us-east-1
        bucket: harbor-registry
        regionendpoint: https://s3.us-east-1.amazonaws.com   # or a MinIO endpoint
        accesskey: <access-key>
        secretkey: <secret-key>
        secure: true
```

### External managed Postgres and Redis

```yaml
harbor:
  database:
    type: external
    external:
      host: postgres.example.com
      port: "5432"
      username: harbor
      password: <password>
      coreDatabase: registry
      sslmode: require
  redis:
    type: external
    external:
      addr: redis.example.com:6379
      password: <password>
```

## PVC sizes (bundled mode)

```yaml
harbor:
  persistence:
    persistentVolumeClaim:
      registry:   { size: 50Gi }
      database:   { size: 5Gi }
      redis:      { size: 5Gi }
      trivy:      { size: 5Gi }
      jobservice: { jobLog: { size: 5Gi } }
```

## Pack-specific values

| Key | Default | Description |
|---|---|---|
| `nebariapp.enabled` | `false` | Emit the `NebariApp` CR (set true on Nebari). |
| `nebariapp.hostname` | — | Required when enabled; Harbor's external hostname. |
| `nebariapp.manageNamespace` | `false` | Emit a `nebari.dev/managed` Namespace, or label it yourself. |
| `nebariapp.auth.enabled` | `true` | Provision the Keycloak OIDC client. |
| `nebariapp.auth.enforceAtGateway` | `false` | Keep false — Harbor does OIDC itself. |
| `nebariapp.auth.redirectURI` | `/c/oidc/callback` | Harbor's OIDC callback path. |
| `nebariapp.auth.scopes` | `[openid, profile, email, offline_access, groups]` | Requested OIDC scopes. |
| `nebariapp.landingPage.*` | Harbor card | Landing-page card metadata. |
| `oidcSetup.enabled` | `true` | Run the Job that switches Harbor to `oidc_auth`. |
| `oidcSetup.adminGroup` | `""` | Keycloak group mapped to Harbor system-admin. |
| `oidcSetup.autoOnboard` | `true` | Auto-create Harbor users on first OIDC login. |
| `oidcSetup.image` | `curlimages/curl:8.11.0` | Image used by the config Job. |
| `oidcSetup.projectCreationRestriction` | `adminonly` | Who may create projects: `adminonly`, `everyone`, or `""` to leave Harbor's setting alone. |
| `oidcSetup.systemConfig` | `{}` | Extra Harbor system settings (config-API keys) merged into the same configuration call. |
| `bootstrap.enabled` | `false` | Run the Job that creates `bootstrap.projects` in Harbor. |
| `bootstrap.image` | `""` | Job image; defaults to `oidcSetup.image`. |
| `bootstrap.projects` | `[]` | Projects to create (see [above](#declarative-projects)). |
| `bootstrap.projects[].name` | — | Required; Harbor project name. |
| `bootstrap.projects[].public` | `false` | Project visibility. |
| `bootstrap.projects[].members[].group` | — | Keycloak/OIDC group name. |
| `bootstrap.projects[].members[].role` | — | `projectAdmin`, `maintainer`, `developer`, `guest`, or `limitedGuest`. |
| `bootstrap.projects[].immutableTags[].tagPattern` | — | Doublestar tag pattern made immutable. |
| `bootstrap.projects[].immutableTags[].repoPattern` | `**` | Repositories the rule applies to. |
| `bootstrap.webhooks` | `[]` | Project webhook policies (see [above](#webhook-policies)). |
| `bootstrap.webhooks[].project` | — | Required; project the policy belongs to. |
| `bootstrap.webhooks[].name` | — | Required; policy name, and the key used for updates. |
| `bootstrap.webhooks[].endpoint` | — | Required; `http://` or `https://` URL Harbor posts to. |
| `bootstrap.webhooks[].events` | — | Required; Harbor event types, e.g. `[PUSH_ARTIFACT, DELETE_ARTIFACT]`. |
| `bootstrap.webhooks[].payloadFormat` | `Default` | `Default` or `CloudEvents`. |
| `bootstrap.webhooks[].authHeader.secretName` | — | Secret holding the Authorization header value. |
| `bootstrap.webhooks[].authHeader.secretKey` | — | Key within that Secret. |
| `bootstrap.webhooks[].skipCertVerify` | `false` | Skip TLS verification of the endpoint. |
| `bootstrap.webhooks[].enabled` | `true` | `false` keeps the policy but stops delivery. |
| `bootstrap.robots` | `[]` | Robot accounts to create (see [above](#declarative-robot-accounts)). |
| `bootstrap.robots[].name` | — | Required; lower-case robot name. Harbor prefixes it (`robot$<project>+<name>`). |
| `bootstrap.robots[].level` | `project` | `project` or `system`. |
| `bootstrap.robots[].project` | `""` | Required for `level: project`; for `level: system` it scopes permissions to one project instead of all (`*`). |
| `bootstrap.robots[].duration` | `-1` | Whole days until expiry; `-1` = never. `0` and fractional values are rejected — do not rely on Harbor's 30-day instance default. |
| `bootstrap.robots[].permissions` | `[]` | `[]` = read-only enumeration + pull (`repository:list`, `repository:pull`, `artifact:read`, `artifact:list`, `tag:list`); otherwise explicit project-scope `{resource, action}` pairs. Re-applied to the existing robot on every run. |
| `bootstrap.robots[].secret.name` | — | Required; name of the Kubernetes Secret to write. |
| `bootstrap.robots[].secret.namespace` | `""` | Defaults to the release namespace; another namespace also renders a Role/RoleBinding there. |
| `harbor.externalURL` | — | Set to `https://<hostname>`. |
| `harbor.harborAdminPassword` | — | Admin password; supply at install time. |

## Harbor system settings

Harbor keeps settings such as `project_creation_restriction` in its database, not in Helm
values, so the OIDC config Job writes them with the same `PUT /api/v2.0/configurations` call
it uses for auth. Two values feed that payload:

```yaml
oidcSetup:
  # adminonly | everyone | "" (leave Harbor's current setting alone)
  projectCreationRestriction: adminonly
  systemConfig:
    robot_name_prefix: "robot$"
    robot_token_duration: 30             # days
    audit_log_forward_endpoint: "syslog://logger:5140"
```

`systemConfig` keys are Harbor config-API names and values keep their YAML type (numbers and
booleans are sent unquoted, strings quoted), so new settings need no chart change. Settings
with security implications keep an explicit value of their own: `auth_mode`, the `oidc_*`
settings, and `project_creation_restriction` are rejected in `systemConfig` (the render fails
naming the key) so they cannot silently override the chart-managed values.

With `oidcSetup.autoOnboard` enabled, everyone who can log in through Keycloak gets a Harbor
account, so the pack defaults `projectCreationRestriction` to `adminonly`. Harbor's own
default is `everyone`, so **upgrading an existing SSO install changes behaviour**: onboarded
users who could previously create projects no longer can. Set it to `everyone` to keep the
old behaviour, or to `""` to stop managing the setting entirely. Standalone installs
(`oidcSetup.enabled=false`) never run the Job and are unaffected.

See the [NebariApp CRD reference](/nebariapp-crd-reference/) for the full set of NebariApp
fields.
