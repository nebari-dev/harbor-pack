---
title: Registry Setup
description: Connect a client to the Harbor registry this pack deploys — get credentials, log in, and verify with a push/pull round-trip.
---

Connecting to the Harbor registry deployed by this pack is a three-step flow: get credentials
from Harbor, log a client in, and verify the connection. Harbor performs OIDC itself, so CLI
clients (`docker`, `oras`, `helm`) authenticate with **Basic auth** — a username plus a token,
never your Keycloak password. See [Authentication](/authentication/) for how that wiring works;
this page is the task-oriented walkthrough.

Throughout, replace `harbor.nebari.example.com` with your Harbor hostname (the
`nebariapp.hostname` / `harbor.externalURL` you configured at install).

## Choose a credential: CLI secret or robot account

Harbor gives you two kinds of push/pull credential:

| Credential | Flag / scope | Where it's created | Use when |
|---|---|---|---|
| **CLI secret** | Tied to your user | Web UI → **User Profile → generate CLI secret** | You push and pull interactively as yourself |
| **Robot account** | Scoped per-project or system-wide | Web UI → **Project → Robot Accounts** | CI/CD or automation needs a long-lived, scoped token |

The rest of this walkthrough uses a CLI secret; swap in a robot account's name and token to
configure automation instead.

### Step 1: Get registry credentials

OIDC users cannot use their Keycloak password for the registry. Instead:

1. Log in to the Harbor web UI via **Login via OIDC Provider**.
2. Open **User Profile → generate CLI secret** (or create a robot account under a project for
   automation).

You'll come away with three things:

- The registry **hostname** (e.g. `harbor.nebari.example.com`)
- A **project** — Harbor's equivalent of a namespace (e.g. `library`, or one you create)
- A **username** and a **CLI secret** (or robot name and token) to authenticate with

### Step 2: Create a project to push into

Unlike some registries, Harbor does **not** create the repository on first push — the target
**project** must exist. Create one in the web UI (**Projects → New Project**), choosing public
or private, or reuse the built-in `library` project.

:::tip Public, read-only projects
To pull from a **public** project you don't need credentials at all — `docker pull` and
`oras pull` talk to Harbor directly. You only need to log in to **push**, or to pull from a
private project.
:::

### Step 3: Log in from the CLI

Authenticate your client against the Harbor hostname with your username and CLI secret. When
prompted for `Password:`, paste the **CLI secret** (or robot token) — not your Keycloak
password:

```sh
docker login harbor.nebari.example.com          # username + CLI secret
```

```sh title="Output"
Password:
Login Succeeded
```

To script this instead of typing, pipe the secret in with `--password-stdin`:

```sh
echo "$HARBOR_CLI_SECRET" | docker login harbor.nebari.example.com \
  --username your-username --password-stdin
```

`oras` and `helm registry login` use the same host and credentials.

### Step 4: Verify with a push/pull round-trip

The surest check that credentials work end-to-end is to push an image and pull it back:

```sh
# Tag and push into your project
docker tag alpine:latest harbor.nebari.example.com/library/alpine:test
docker push harbor.nebari.example.com/library/alpine:test

# Pull it back into a clean state to confirm it round-trips
docker rmi harbor.nebari.example.com/library/alpine:test
docker pull harbor.nebari.example.com/library/alpine:test
```

A successful `Login Succeeded` followed by a clean push and pull confirms the client is
connected. Harbor also runs a **Trivy scan** on pushed artifacts — check the project's
repository view in the web UI to see scan results.

:::note Troubleshooting
- **`denied` / `unauthorized` on push** — the CLI secret has expired (regenerate it under User
  Profile), or a robot account lacks push scope for the target project. Confirm the username
  matches the credential you generated.
- **`project ... not found` / repository errors** — the target **project** doesn't exist;
  create it in the web UI before pushing (Harbor does not auto-create projects).
- **`docker login` hangs or redirects** — auth must not be enforced at the gateway
  (`nebariapp.auth.enforceAtGateway` must be `false`); CLI clients cannot do the interactive
  OAuth redirect. See [Authentication](/authentication/#why-auth-is-not-enforced-at-the-gateway).
:::

## Add this registry to Nebi

If you use the [Nebi](https://nebi.nebari.dev) CLI to publish and share environments, you can
register this Harbor instance as a Nebi registry and publish workspaces straight to it.

Nebi stores a registry connection either **locally** (`--local`, on your machine) or on a shared
**Nebi server** (the default, after `nebi login`). The examples below use local mode; drop
`--local` to configure the connection on a server instead.

### Add the registry

Point Nebi at the Harbor hostname, using your project as the `--namespace` and the credentials
from Step 1. Mark it `--default` so `nebi publish` uses it automatically:

```sh
nebi registry add \
  --local \
  --name harbor \
  --url harbor.nebari.example.com \
  --namespace library \
  --username your-username \
  --default
```

```sh title="Output"
Password:
Added local registry 'harbor' (harbor.nebari.example.com)
```

When prompted for `Password:`, paste your Harbor **CLI secret** (or robot token) from Step 1. To
script it, pipe the secret in with `--password-stdin`:

```sh
echo "$HARBOR_CLI_SECRET" | nebi registry add \
  --local --name harbor --url harbor.nebari.example.com \
  --namespace library --username your-username \
  --default --password-stdin
```

### Publish and verify

Confirm the registry is registered and marked default (`*`):

```sh
nebi registry list --local
```

```sh title="Output"
NAME    URL                          DEFAULT
harbor  harbor.nebari.example.com    *
```

Then publish a tracked workspace and import it back to confirm the round-trip:

```sh
# From a tracked workspace, publish to the default (Harbor) registry
nebi publish --local --tag test

# Import it into a fresh directory to confirm it round-trips
nebi import harbor.nebari.example.com/library/<workspace>:test -o ./verify
```

:::note
The project you push to (`library` above, the Nebi `--namespace`) must already exist in Harbor —
create it first, as in [Step 2](#step-2-create-a-project-to-push-into). Harbor does not
auto-create projects on publish.
:::

## Related

If the client is a workload running in the same cluster as Harbor, see
[Consuming the Registry In-Cluster](/in-cluster-consumers/) — the Service to use, the token realm,
and which artifacts get scanned all differ there.

For OIDC and gateway details, see [Authentication](/authentication/); for storage and
pack-specific values, see [Configuration](/configuration/).
