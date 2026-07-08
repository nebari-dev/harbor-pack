---
title: Harbor Pack
description: Run Harbor as a Nebari software pack — an OCI registry with Trivy scanning and Keycloak SSO.
---

**harbor-pack** runs [Harbor](https://goharbor.io/) — a CNCF, OCI-compliant registry for
container images, Helm charts, and OCI artifacts — as a [Nebari](https://www.nebari.dev/)
software pack. It wraps the upstream Harbor Helm chart and adds Nebari integration: gateway
routing, a landing-page card, and single sign-on through Keycloak.

## What you get

- A private registry for **container images, Helm charts, and OCI artifacts**.
- **Trivy** vulnerability scanning, RBAC projects, and robot accounts.
- **Keycloak SSO** — log in to the Harbor web UI with your Nebari identity.
- A card on the Nebari **landing page** and automatic routing + TLS through the shared gateway.

## How it fits together

The pack deploys the upstream Harbor chart as a subchart and emits a `NebariApp` custom
resource. The nebari-operator uses that resource to:

1. Route the pack's hostname to Harbor's front service (HTTPRoute + TLS via cert-manager).
2. Provision a **Keycloak OIDC client** and store its credentials in a Secret.
3. Render the Harbor **landing-page card**.

A post-install Job then switches Harbor into OIDC mode using the provisioned client.

Because Harbor performs OIDC itself — and CLI tools (`docker`, `oras`, `helm`) authenticate
with Basic auth against Harbor's own token endpoint — the pack does **not** enforce auth at
the gateway. See [Authentication](/authentication/) for the details.

## Next steps

- [Installation](/installation/) — deploy on Nebari or run standalone locally.
- [Authentication](/authentication/) — how Keycloak SSO and registry CLI login work.
- [Configuration](/configuration/) — storage backends, external DB/Redis, and values.
