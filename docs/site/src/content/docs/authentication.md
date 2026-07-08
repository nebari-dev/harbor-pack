---
title: Authentication
description: How harbor-pack wires Keycloak SSO into Harbor, and how CLI registry login works.
---

Harbor performs OIDC **itself**: the web UI shows a "Login via OIDC Provider" button, and CLI
clients (`docker`, `oras`, `helm`) authenticate with Basic auth using a per-user **CLI
secret** or a **robot account** against Harbor's own token endpoint. harbor-pack is wired
around that reality.

## Why auth is not enforced at the gateway

`nebariapp.auth.enforceAtGateway` is **`false`** and must stay that way. The nebari-operator
still provisions a confidential Keycloak client and stores its credentials in the
`harbor-harbor-pack-oidc-client` Secret (keys `client-id`, `client-secret`, `issuer-url`),
but it does **not** create an Envoy `SecurityPolicy`. If the gateway enforced browser OAuth
on every path, `docker login` and CLI push/pull would break — those clients cannot perform
the interactive OAuth redirect dance.

This is the "app-native OAuth" pattern described in the
[Authentication Flow](/auth-flow/#app-native-oauth) reference.

## What configures Harbor's OIDC

Harbor stores its OIDC settings in its database (set through the config API), not via Helm
values. The `harbor-harbor-pack-oidc-setup` Job runs after install/upgrade, reads the
operator-created Secret, and calls `PUT /api/v2.0/configurations` to:

- set `auth_mode` to `oidc_auth`,
- point `oidc_endpoint` at the Keycloak realm issuer,
- supply `oidc_client_id` / `oidc_client_secret`,
- request scopes including `offline_access` (needed to mint CLI secrets) and `groups`,
- optionally map a Keycloak group to Harbor system-admin (`oidcSetup.adminGroup`).

The Job runs as the NebariApp's ServiceAccount, which the operator grants read access to the
OIDC Secret.

## The OIDC redirect

`nebariapp.auth.redirectURI` is `/c/oidc/callback` (Harbor's callback path). The operator
registers this on the Keycloak client, and `harbor.externalURL` must equal
`https://<hostname>` so Harbor builds the correct redirect URL.

## Logging in from the CLI

OIDC users cannot use their Keycloak password for the registry. Instead:

1. Log in to the Harbor web UI via OIDC.
2. Open **User Profile → generate CLI secret** (or create a robot account for a project).
3. Use that secret with the registry:

```sh
docker login harbor.nebari.example.com          # username + CLI secret
docker push harbor.nebari.example.com/library/alpine:latest
```

## Troubleshooting

- **"Login via OIDC Provider" missing** — the OIDC Job did not complete; check
  `kubectl logs job/harbor-harbor-pack-oidc-setup -n <ns>` and confirm
  `GET /api/v2.0/configurations` shows `auth_mode=oidc_auth`.
- **Job failing on a missing Secret** — the operator has not created the OIDC Secret yet; the
  Job retries via `backoffLimit`.
- **Keycloak `redirect_uri` error** — ensure `redirectURI` is `/c/oidc/callback` and
  `harbor.externalURL` matches the hostname.
