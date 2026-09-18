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
`tag_selectors` and `scope_selectors` separately and refuses to continue if a project has more
than 100 rules — Harbor's maximum page size — rather than risk a duplicate. It needs no
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
| `bootstrap.enabled` | `false` | Run the Job that creates `bootstrap.projects` in Harbor. |
| `bootstrap.image` | `""` | Job image; defaults to `oidcSetup.image`. |
| `bootstrap.projects` | `[]` | Projects to create (see [above](#declarative-projects)). |
| `bootstrap.projects[].name` | — | Required; Harbor project name. |
| `bootstrap.projects[].public` | `false` | Project visibility. |
| `bootstrap.projects[].members[].group` | — | Keycloak/OIDC group name. |
| `bootstrap.projects[].members[].role` | — | `projectAdmin`, `maintainer`, `developer`, `guest`, or `limitedGuest`. |
| `bootstrap.projects[].immutableTags[].tagPattern` | — | Doublestar tag pattern made immutable. |
| `bootstrap.projects[].immutableTags[].repoPattern` | `**` | Repositories the rule applies to. |
| `harbor.externalURL` | — | Set to `https://<hostname>`. |
| `harbor.harborAdminPassword` | — | Admin password; supply at install time. |

See the [NebariApp CRD reference](/nebariapp-crd-reference/) for the full set of NebariApp
fields.
