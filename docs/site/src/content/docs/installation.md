---
title: Installation
description: Deploy harbor-pack on a Nebari cluster or run it standalone for local testing.
---

## Prerequisites

- A Nebari cluster with the standard NIC stack: **nebari-operator**, **Envoy Gateway**,
  **cert-manager**, and **Keycloak**.
- The install namespace labeled for the operator.
- A Harbor admin password supplied at install time (never commit one).
- For production: object storage (S3/MinIO) and/or managed Postgres + Redis if you turn off
  the bundled backends — see [Configuration](/configuration/).

## On Nebari

```sh
kubectl create namespace harbor
kubectl label namespace harbor nebari.dev/managed=true --overwrite

helm install harbor ./chart -n harbor \
  -f examples/nebari-values.yaml \
  --set nebariapp.hostname=harbor.nebari.example.com \
  --set harbor.externalURL=https://harbor.nebari.example.com \
  --set harbor.harborAdminPassword="$(openssl rand -base64 24)"
```

Verify the rollout:

```sh
kubectl get nebariapp harbor-harbor-pack -n harbor        # wait for Ready
kubectl get job harbor-harbor-pack-oidc-setup -n harbor   # should Complete
```

Then open `https://harbor.nebari.example.com` and click **LOGIN VIA OIDC PROVIDER**.

## Standalone (local, no Nebari)

For local development on kind/k3d without the operator or Keycloak:

```sh
helm dependency update ./chart
helm install harbor ./chart -n harbor --create-namespace \
  -f examples/standalone-values.yaml
kubectl -n harbor port-forward svc/harbor 8080:80
# open http://localhost:8080  (admin / Harbor12345)
```

Standalone mode sets `nebariapp.enabled=false` and `oidcSetup.enabled=false`, so no
`NebariApp` or OIDC Job is created and Harbor uses local database auth.

## Via ArgoCD

Once the chart is published to the Nebari Helm repository, deploy it with the
`Application` in `examples/argocd-application.yaml`. Ensure the target namespace carries the
`nebari.dev/managed=true` label.
