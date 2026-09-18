---
title: Consuming the Registry In-Cluster
description: Talk to Harbor from a workload running in the same cluster — which Service and paths to use, why the bearer token realm is unusable in-cluster, and which artifacts Trivy does not scan.
---

[Registry Setup](/registry-setup/) covers connecting from a laptop, where everything goes through
the Nebari gateway over HTTPS. A workload running **inside the same cluster** — an indexer, a CI
runner, another pack — usually talks to the Harbor front Service directly over plain HTTP, and two
things behave differently there:

- The token realm in Harbor's bearer challenge on `/v2/` takes its **scheme** from
  `harbor.externalURL`, so an in-cluster client is told to fetch its token over **HTTPS** from a
  Service that only serves HTTP. Following the realm fails either way.
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
| `/v2/...` | The **OCI registry API** — manifests, blobs, tags | Bearer token from the token service (Basic auth also accepted) |
| `/service/token` | Harbor's **token service** — mints the bearer tokens OCI clients use | Basic auth, or anonymous for public projects |

:::note
The bearer-token exchange is the **standard OCI flow**: a client calls `/v2/`, gets a `401` with a
token realm, fetches a token from that realm, and retries. `docker`, `oras`, and `helm` all do this
for you. It is not the only option, though — Harbor also accepts **Basic auth** directly on `/v2/`
(send an `Authorization: Basic ...` header and it authenticates the request rather than issuing a
token challenge), which is often the simplest thing for a small in-cluster consumer. `/api/v2.0/`
always takes the username and secret directly.
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

## The token realm is not usable in-cluster

Ask the in-cluster Service for a manifest without a token and Harbor replies with the standard
bearer challenge — but look at the realm:

```sh
curl -sI http://harbor.harbor.svc.cluster.local/v2/
```

```sh title="Output"
HTTP/1.1 401 Unauthorized
Www-Authenticate: Bearer realm="https://harbor.harbor.svc.cluster.local/service/token",service="harbor-registry"
```

The **host** comes from the request, the **scheme** comes from `harbor.externalURL`. Harbor builds
the realm in `tokenSvcURL` (`src/server/middleware/v2auth/auth.go`):

1. If the request's `Host` matches the host of Harbor's configured internal core URL (`CORE_URL`,
   which the upstream chart sets to `http://<release>-harbor-core:80`; the comparison normalizes
   default ports), the realm is that internal URL plus `/service/token` — plain HTTP.
2. Otherwise Harbor takes the scheme from the configured external endpoint and glues it onto the
   request's own `Host`: `<scheme of externalURL>://<request Host>/service/token`. The bundled
   nginx passes the client's `Host` through unchanged on `/v2/`, so that is whatever hostname the
   consumer dialled.
3. Only if the request carries no `Host` at all does Harbor fall back to the external endpoint
   (again with `/service/token` appended).

`harbor.externalURL` must be the public **HTTPS** hostname for the browser OIDC flow to work, so
branch 2 hands an in-cluster consumer an `https://` realm on the in-cluster Service — which this
pack deliberately serves over plain HTTP only (`harbor.expose.tls.enabled: false`, TLS terminates
at the Nebari gateway). Following that realm fails at TLS, and no amount of CA trust fixes it,
because there is no TLS listener on the other end.

The same logic explains the other failure people hit: a consumer that dials Harbor by its
**external** hostname gets the external realm back, goes out and in through the Nebari gateway, and
then has to verify the gateway certificate — self-signed (`nebari-dev-ca`) in the local dev stack —
failing with a certificate error that gives no hint it came from the registry. In-cluster DNS also
has to resolve the external hostname, which is not a given.

So: pick (a) whenever you control the HTTP calls — it is the reliable in-cluster path. (b) applies
only to consumers that reach Harbor through the gateway on its external hostname.

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
  -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  "$HARBOR/v2/library/alpine/manifests/latest"
```

:::note
Send every manifest media type you can handle in `Accept`. A tag often points at an **index**
(multi-arch manifest list) rather than a single image manifest, and a registry may refuse the
request if the type it holds is not in your `Accept` header.
:::

:::tip
Tokens are scoped to what you asked for and are short-lived. Request one scope per repository you
touch (repeat `scope=` to ask for several at once), and re-request rather than caching for long.
The response also carries `expires_in` and `issued_at` if you want to reuse a token until it ages
out.
:::

### (b) Mount the gateway CA — for consumers that use the external hostname

If the consumer is a standard OCI client (`docker`, `oras`, `helm`), it will always follow the
advertised realm, so point it at Harbor's **external hostname** and let the whole exchange go
through the Nebari gateway. Both the `/v2/` call and the realm it returns then use that hostname
over HTTPS, and the only thing left to fix is trusting the gateway certificate. Mount the CA
certificate into the pod and point the client's TLS trust at it:

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
connection is a real credential. Where the gateway certificate is publicly trusted, this step drops
away entirely — the client follows the realm and verifies normally. Going through the external
hostname does mean the traffic leaves and re-enters the cluster, so for a chatty consumer (a) is
still the better shape.
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
- **Branch on the artifact `type`, not on the presence of `scan_overview`.** A missing
  `scan_overview` only means *no scan report is available* — which is equally true of an ordinary
  image that simply has not been scanned yet. Harbor itself distinguishes "Not Scanned" from
  "Unsupported"; a consumer that reads "no scan_overview" as "unscannable" (or, worse, as "scan
  clean") will get both cases wrong.

So in a repository that mixes images and custom artifacts: use the artifact `type` (and its
manifest media type / `artifactType`) to decide whether vulnerability data is applicable at all,
and only then look at `scan_overview` to see whether a scan has actually run.

## Related

- [Registry Setup](/registry-setup/) — credentials, `docker login`, and the push/pull round-trip
  from outside the cluster.
- [Authentication](/authentication/) — why auth is not enforced at the gateway, and how Harbor's
  own OIDC is wired.
- [Configuration](/configuration/) — the pack values behind `harbor.externalURL` and the front
  Service.
