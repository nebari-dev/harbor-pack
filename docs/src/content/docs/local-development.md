---
title: Local Development
description: Run harbor-pack on a local kind cluster with the full Nebari stack — simple HTTP mode or the complete Keycloak SSO flow.
---

The `dev/` directory has a Makefile that stands up a [kind](https://kind.sigs.k8s.io/)
cluster with the full Nebari infrastructure stack — MetalLB, Envoy Gateway, cert-manager,
Keycloak, and the **nebari-operator** — then deploys Harbor with the `NebariApp` and Keycloak
SSO wired in. It's the fastest way to exercise the real operator integration end-to-end on
your machine.

## Prerequisites

- `docker`, `kind`, `helm`, `kubectl`, `python3`, and `git` on your `PATH`.
- Docker Desktop (or a Docker daemon that can publish host ports 80/443 without `sudo`).

All commands below run from the `dev/` directory:

```sh
cd dev
```

The first `make up`/`make up-sso` creates the cluster (`harbor-pack-dev`), installs the Nebari
stack, and clones the pinned nebari-operator into `dev/.cache/` — this takes a few minutes.
Subsequent runs reuse the existing cluster.

:::caution[Colima and other non-Docker-Desktop daemons]
Docker picks the `kind` bridge network's subnet itself, and on Colima it has been seen to pick
`192.168.1.0/24` — overlapping the LAN. Every pod's call to the API server then times out, and
the cluster comes up broken in ways that look like unrelated flakiness. Pin the network to a
`172.x` range *before* the first `make up-sso`:

```sh
docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'   # check
make down && docker network rm kind    # if it overlaps (the network is in use by the cluster)
docker network create --driver bridge --subnet 172.21.0.0/16 kind
```

kind reuses an existing `kind` network rather than recreating it, so this survives
`make down` / `make up-sso` cycles. (MetalLB's address pool is derived from whatever subnet
the network has, so it follows along.)
:::

## Simple mode — `make up`

Recommended for everyday work. This exercises the real `NebariApp`/operator integration, but
with **gateway TLS off (no cert)** and **OIDC off (Harbor's built-in database admin login)** —
so no cert warnings and no SSO plumbing to reason about:

```sh
make up              # create cluster (first run) + deploy NebariApp, HTTP, DB auth
make host-access     # bridge host :80/:443 to the gateway (no sudo) + print the /etc/hosts line
sudo sh -c 'echo "127.0.0.1 harbor.nebari.local keycloak.nebari.local" >> /etc/hosts'
# open http://harbor.nebari.local   (login: admin / Harbor12345)
```

If you want zero Nebari machinery at all — no operator, gateway, or hostnames — use
[Standalone mode](/installation/#standalone-local-no-nebari) from the installation guide
instead.

## Full Keycloak SSO — `make up-sso`

Deploys Harbor with the complete browser SSO flow working end-to-end:

```sh
make up-sso          # bootstraps the cluster + wires SSO + installs Harbor
make host-access     # bridge host :80/:443 to the gateway (no sudo) + print the /etc/hosts line
sudo sh -c 'echo "127.0.0.1 harbor.nebari.local keycloak.nebari.local" >> /etc/hosts'
# open https://harbor.nebari.local   → LOGIN VIA OIDC PROVIDER   (dev / dev-password)
make harbor-bootstrap   # after that first login: sysadmin + a project for the dev user
```

Log in as the Keycloak user **`dev` / `dev-password`** in the `nebari` realm, and accept the
self-signed cert warnings for both hosts.

`make up-sso` creates the kind cluster with host ports 80/443 published (see
`kind-config.yaml`), so `make host-access` can bridge them to the Envoy gateway via `socat` in
the node — no privileged `sudo kubectl port-forward` needed. The only `sudo` is the one-time
`/etc/hosts` line that `make host-access` prints.

Because Harbor uses a single OIDC endpoint for both the browser redirect and its own
server-side token calls, `enable-sso.sh` sets `KEYCLOAK_EXTERNAL_URL` on the operator, exposes
Keycloak at `keycloak.nebari.local` through the gateway, sets `KC_PROXY_HEADERS=xforwarded`,
and adds a CoreDNS `hosts` entry so the issuer is identical from the browser and from Harbor
core. It installs Harbor with `oidcSetup.verifyCert=false` (self-signed dev CA).

### Why not the realm admin

The realm admin `admin` / `nebari-admin` cannot be used as the Harbor SSO login. Harbor ships
a built-in local-DB user named `admin` (the `harborAdminPassword` account), so OIDC
auto-onboard refuses to create a second one and the callback fails with:

```
{"errors":[{"code":"UNKNOWN","message":"failed to create user record: user admin or email admin@nebari.local already exists"}]}
```

`make up-sso` therefore seeds a plain realm user with `dev/seed-user.sh` (an idempotent
`kcadm` create + set-password inside the Keycloak pod) and prints *that* as the SSO login.
`admin` / `Harbor12345` still works under **Login via Local DB**, and the realm admin remains
the Keycloak console account. `make seed-user` re-runs the seeding on its own.

The user, its password and the project name are Make variables passed to the scripts through
the environment, so overriding them is safe even with awkward values:

```sh
make up-sso SEED_USER=alice SEED_PASSWORD='s3cr3t &pass' HARBOR_PROJECT=scratch
```

An overridden password is never echoed back — the scripts print `(as configured)` in place of
anything that isn't the documented default.

### After the first SSO login — `make harbor-bootstrap`

The dev flow sets no `oidcSetup.adminGroup`, so a freshly onboarded OIDC user has no
privileges and no project to push to. Once `dev` has logged in through the browser at least
once (that login is what creates its Harbor record), `dev/harbor-bootstrap.sh` — via
`make harbor-bootstrap` — talks to Harbor's API as the local-DB admin over a port-forward and:

- grants `dev` Harbor system admin,
- creates a private `dev` project,
- adds `dev` as that project's admin,
- prints the matching `nebi registry add` command (see
  [Registry setup](/registry-setup/#add-this-registry-to-nebi) — you still generate a CLI
  secret in the UI, since OIDC users can't use their Keycloak password for the registry).

Run before that first login, it says so and exits rather than failing obscurely. Re-running it
later is a no-op beyond re-asserting the roles.

:::caution
The operator dev stack runs Keycloak in `start-dev` (in-memory H2), so any Keycloak pod
restart wipes the realm — and the seeded `dev` user with it. `enable-sso.sh` restarts Keycloak
*before* creating the realm to avoid this; if you restart Keycloak later, re-run
`.cache/nebari-operator/dev/scripts/services/keycloak/setup.sh` and then `make seed-user`.
:::

## Recovering a partially-failed cluster setup

The `cluster` target only checks whether kind knows the cluster name — so if a run dies
partway through setup (a timed-out `kubectl wait`, an image pull that took too long, a flaky
download), the next `make up-sso` reports *"Cluster 'harbor-pack-dev' already exists, skipping
setup"* and carries on against a half-built cluster.

The setup steps are individually re-runnable and idempotent, so pick up where it stopped:

```sh
make _metallb           # MetalLB + the IP address pool
make _services          # Envoy Gateway, cert-manager, Keycloak, Gateway, TLS
make _keycloak-setup    # the nebari realm
make _operator          # nebari-operator
make up-sso             # then the SSO wiring + Harbor itself
```

If you'd rather not guess which step failed, `make down` deletes the cluster and the next
`make up-sso` rebuilds it from scratch.

## Standalone — `make up-standalone`

Deploys Harbor with no Nebari integration (no operator, gateway, or Keycloak) using
`examples/standalone-values.yaml`, then tells you how to reach it via port-forward:

```sh
make up-standalone
kubectl port-forward -n harbor svc/harbor 8080:80
# open http://localhost:8080   (admin / Harbor12345)
```

## Tearing down

```sh
make down            # delete the kind cluster
```

## Make targets

| Target | What it does |
|---|---|
| `make up` | Deploy harbor-pack on Nebari (NebariApp + server-side OIDC off, HTTP, DB auth). |
| `make up-sso` | Deploy with the full browser SSO flow (see `dev/enable-sso.sh`). |
| `make host-access` | Bridge host :80/:443 to the gateway (no sudo) + print the `/etc/hosts` line. |
| `make seed-user` | (Re)create the `dev` Keycloak user the SSO flow logs in as (run by `up-sso`). |
| `make harbor-bootstrap` | After the first SSO login: grant `dev` sysadmin, create a project, print the `nebi registry add` line. |
| `make up-standalone` | Deploy Harbor standalone (no operator/Keycloak needed). |
| `make down` | Delete the kind cluster. |
