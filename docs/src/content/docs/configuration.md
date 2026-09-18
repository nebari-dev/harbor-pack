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
prints one line per project, member and rule.

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
      permissions: []            # [] = pull-only: repository:pull, artifact:read,
                                 #      artifact:list, tag:list
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

:::caution Always set `duration`
Harbor's instance default `robot_token_duration` is 30 days. A robot created without an
explicit duration expires silently and the consumer starts getting `401`s a month later. `-1`
means never.
:::

The Job (`<release>-harbor-pack-bootstrap-robots`) runs at hook weight `11`, after the projects
Job, so a project-level robot's project already exists. It is idempotent:

| State found | Action |
|---|---|
| Robot exists **and** its Secret exists | Nothing — a repeat `helm upgrade` is a no-op |
| Robot exists, Secret missing | `PATCH /robots/{id}` to mint a fresh secret, then write the Secret |
| Robot missing | `POST /robots`, then write the Secret |

An existing Secret is only overwritten when the robot behind it was created or rotated in the
same run, so deleting the Secret and re-running restores it with a freshly rotated credential.
Rotating the wrong robot would break whatever was using it, so the lookup is an exact-name
query cross-checked against `X-Total-Count`: an ambiguous or truncated result fails the Job.

The secret is never logged: the script never runs under `set -x`, never passes the secret as a
command-line argument, and prints only names, ids and API error messages — never a response
body, since robot and Secret payloads carry secret material.

Unlike the projects Job, this one must write to the Kubernetes API, so it runs as a dedicated
ServiceAccount whose Role grants `create` on Secrets plus `get`/`update` restricted to exactly
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

Like the projects Job, this one only adds missing state: an existing robot's `duration` and
`permissions` are never rewritten, and removing an entry from `robots` leaves the robot and its
Secret alone. Permissions are project-scope resources (permission `kind: project`); system-scope
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
| `bootstrap.robots` | `[]` | Robot accounts to create (see [above](#declarative-robot-accounts)). |
| `bootstrap.robots[].name` | — | Required; lower-case robot name. Harbor prefixes it (`robot$<project>+<name>`). |
| `bootstrap.robots[].level` | `project` | `project` or `system`. |
| `bootstrap.robots[].project` | `""` | Required for `level: project`; for `level: system` it scopes permissions to one project instead of all (`*`). |
| `bootstrap.robots[].duration` | `-1` | Days until expiry; `-1` = never. Do not rely on Harbor's 30-day instance default. |
| `bootstrap.robots[].permissions` | `[]` | `[]` = pull-only; otherwise explicit project-scope `{resource, action}` pairs. |
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
