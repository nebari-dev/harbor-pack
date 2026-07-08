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

- `docker`, `kind`, `helm`, `kubectl`, and `git` on your `PATH`.
- Docker Desktop (or a Docker daemon that can publish host ports 80/443 without `sudo`).

All commands below run from the `dev/` directory:

```sh
cd dev
```

The first `make up`/`make up-sso` creates the cluster (`harbor-pack-dev`), installs the Nebari
stack, and clones the pinned nebari-operator into `dev/.cache/` — this takes a few minutes.
Subsequent runs reuse the existing cluster.

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
# open https://harbor.nebari.local   → LOGIN VIA OIDC PROVIDER
```

Log in as the Keycloak user `admin` / `nebari-admin` in the `nebari` realm, and accept the
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

:::caution
The operator dev stack runs Keycloak in `start-dev` (in-memory H2), so any Keycloak pod
restart wipes the realm. `enable-sso.sh` restarts Keycloak *before* creating the realm to avoid
this; if you restart Keycloak later, re-run
`.cache/nebari-operator/dev/scripts/services/keycloak/setup.sh`.
:::

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
| `make up-standalone` | Deploy Harbor standalone (no operator/Keycloak needed). |
| `make down` | Delete the kind cluster. |
