---
title: Consuming the Registry In-Cluster
description: Talk to Harbor from a workload running in the same cluster — which Service and paths to use, why the bearer token realm points at the external URL, and which artifacts Trivy does not scan.
---

[Registry Setup](/registry-setup/) covers connecting from a laptop, where everything goes through
the Nebari gateway over HTTPS. A workload running **inside the same cluster** — an indexer, a CI
runner, another pack — usually talks to the Harbor front Service directly over plain HTTP, and two
things behave differently there:

- Harbor's bearer challenge on `/v2/` always advertises a token realm on the **external** URL, so a
  naive client gets bounced back out through the gateway and has to trust its certificate.
- Trivy scans container images only. Custom OCI artifacts (Pixi/Nebi bundles and friends) are
  reported as type `UNKNOWN` with no scan data at all.

Both are explained below, with the workarounds.

## Which Service, port, and paths

Harbor exposes everything through a single front (nginx) Service. This pack installs the upstream
Harbor chart with `harbor.expose.type: clusterIP`, and the upstream chart names that Service
literally after `harbor.expose.clusterIP.name` (default `harbor`) on `harbor.expose.clusterIP.ports.httpPort`
(default `80`) — it is **not** release-prefixed:

```sh
http://harbor.<namespace>.svc.cluster.local/
```

Inside the same namespace `http://harbor/` is enough. This is the same Service the `NebariApp` routes
to and the same one the pack's own OIDC config Job calls, so it is the supported in-cluster entry
point. Chart authors building on top of this pack can reuse the helpers in
`chart/templates/_helpers.tpl` rather than hardcoding the values:

```yaml
http://{{ include "harbor-pack.harbor-service-name" . }}:{{ include "harbor-pack.harbor-service-port" . }}
```

Three path prefixes matter, all served by that one Service and port:

| Path | What it is | Auth |
|---|---|---|
| `/api/v2.0/...` | Harbor **management API** — projects, repositories, artifacts, webhooks, config | Basic auth (user + CLI secret, or robot) |
| `/v2/...` | The **OCI registry API** — manifests, blobs, tags | Bearer token from the token service |
| `/service/token` | Harbor's **token service** — mints the bearer tokens `/v2/` requires | Basic auth, or anonymous for public projects |

:::note
The two APIs use different credentials in different ways. `/api/v2.0/` takes your username and
secret directly on every request; `/v2/` never does — it takes a short-lived bearer token that you
first fetch from `/service/token`. Clients like `docker` and `oras` do that exchange for you.
:::

## Anonymous pulls vs. authenticated access

Whether you need a credential at all depends on the project:

- **Public projects** — pull is anonymous. Request a token from `/service/token` with no
  credentials and you get one back that carries pull access; use it against `/v2/`.
- **Private projects** — you need a credential. For a workload, prefer a **robot account** (scoped
  per-project, long-lived) over a per-user CLI secret, which is tied to a human's OIDC identity and
  expires with it. See
  [Choose a credential](/registry-setup/#choose-a-credential-cli-secret-or-robot-account) for how
  the two differ and where they are created.

Everything on `/api/v2.0/` requires a credential except a handful of unauthenticated endpoints such
as `/api/v2.0/health`.

## The token realm points at the external URL

Ask the in-cluster Service for a manifest without a token and Harbor replies with the standard
bearer challenge:

```sh
curl -sI http://harbor.harbor.svc.cluster.local/v2/
```

```sh title="Output"
HTTP/1.1 401 Unauthorized
Www-Authenticate: Bearer realm="https://harbor.nebari.example.com/service/token",service="harbor-registry"
```

The realm is built from `harbor.externalURL`, which **must** be the public HTTPS hostname for the
browser OIDC flow to work. So a client that dutifully follows the challenge leaves the cluster,
comes back in through the Nebari gateway, and has to complete TLS against the gateway certificate.
In the local dev stack that certificate is signed by a self-signed CA (`nebari-dev-ca`), and the
consumer fails with a certificate-verification error that gives no hint it came from the registry.
In-cluster DNS also has to resolve the external hostname, which is not a given.

There are two ways out. Pick (a) if you control the HTTP calls; pick (b) if you are driving a
standard client like `docker`, `oras`, or `helm`, which always follow the advertised realm.

### (a) Ask the in-cluster token service directly

The token service is served from the same front Service as `/v2/`, so you can skip the realm
entirely and request the token over plain HTTP in-cluster. Two query parameters matter: `service`
(the token service name from the challenge, `harbor-registry`) and `scope`, which is
`repository:<project>/<repo>:<actions>` — `pull`, or `pull,push`, and `registry:catalog:*` for
catalog listing.

```sh
HARBOR=http://harbor.harbor.svc.cluster.local

# Public project: no credentials needed.
TOKEN=$(curl -s \
  "$HARBOR/service/token?service=harbor-registry&scope=repository:library/alpine:pull" \
  | jq -r .token)

# Private project: add the robot account (or user + CLI secret).
TOKEN=$(curl -s -u "$HARBOR_USERNAME:$HARBOR_SECRET" \
  "$HARBOR/service/token?service=harbor-registry&scope=repository:library/alpine:pull" \
  | jq -r .token)
```

Then use the token against `/v2/` on the same in-cluster URL:

```sh
curl -s -H "Authorization: Bearer $TOKEN" \
  "$HARBOR/v2/library/alpine/tags/list"

curl -s -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "$HARBOR/v2/library/alpine/manifests/latest"
```

:::tip
Tokens are scoped to what you asked for and are short-lived. Request one scope per repository you
touch (repeat `scope=` to ask for several at once), and re-request rather than caching for long.
The response also carries `expires_in` and `issued_at` if you want to reuse a token until it ages
out.
:::

### (b) Mount the gateway CA into the consumer

If the consumer is a standard OCI client, it will follow the realm out to the gateway, so the fix
is to make the gateway certificate verifiable. Mount the CA certificate into the pod and point the
client's TLS trust at it:

```yaml
volumes:
  - name: gateway-ca
    secret:
      secretName: <gateway-tls-secret>   # the CA that signed the gateway certificate
      items:
        - key: ca.crt
          path: ca.crt

volumeMounts:
  - name: gateway-ca
    mountPath: /etc/ssl/certs/gateway-ca.crt
    subPath: ca.crt
```

Most runtimes then need to be told where to look — `SSL_CERT_FILE` for Go and OpenSSL-based tools,
`REQUESTS_CA_BUNDLE` for Python `requests`, `NODE_EXTRA_CA_CERTS` for Node. Images with
`update-ca-certificates` can instead take the file in `/usr/local/share/ca-certificates/` and refresh
the bundle at startup.

:::caution
This is a workaround for a self-signed or private CA, not a licence to disable verification. Do not
reach for `--insecure` / `verifyCert: false` in a consumer: the token it fetches over that
connection is a real credential. With a publicly trusted gateway certificate neither workaround is
needed — the client follows the realm and verifies normally.
:::

## What Trivy scans — and what it does not

The pack ships Harbor's bundled Trivy scanner, and Harbor scans **container images**: artifacts
whose manifest carries a recognized image config media type. Everything else — Pixi/Nebi
environment bundles, and other custom OCI artifacts with their own `artifactType` or config media
type — is stored and served correctly but is not something Trivy knows how to open.

Those artifacts show up in the management API with `"type": "UNKNOWN"` and **no** `scan_overview`
field. You can check any repository's artifacts for yourself:

```sh
curl -s -u "$HARBOR_USERNAME:$HARBOR_SECRET" \
  "$HARBOR/api/v2.0/projects/library/repositories/<repo>/artifacts?with_scan_overview=true" \
  | jq '.[] | {digest, type, scan_overview}'
```

Two consequences for anything consuming Harbor programmatically:

- **Do not wait on `SCANNING_COMPLETED`.** No scan is queued for a non-image artifact, so that
  webhook never fires and a consumer that blocks on it hangs forever. Key off `PUSH_ARTIFACT`
  instead, which fires for every artifact type.
- **Do not expect vulnerability data**, and do not treat its absence as "scan clean". A
  `scan_overview` that is missing means *not scannable*; only an image with a completed scan
  carries a real severity summary.

If a repository mixes images and custom artifacts, branch on the artifact `type` before deciding
whether scan results are even applicable.

## Related

- [Registry Setup](/registry-setup/) — credentials, `docker login`, and the push/pull round-trip
  from outside the cluster.
- [Authentication](/authentication/) — why auth is not enforced at the gateway, and how Harbor's
  own OIDC is wired.
- [Configuration](/configuration/) — the pack values behind `harbor.externalURL` and the front
  Service.
