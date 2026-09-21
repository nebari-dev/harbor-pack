# Local development Makefile for harbor-pack
#
# Creates a kind cluster with the full Nebari infrastructure stack
# (MetalLB, Envoy Gateway, cert-manager, Keycloak, nebari-operator)
# and deploys Harbor with the NebariApp + Keycloak SSO wired in.
#
# Prerequisites: docker, kind, helm, kubectl, python3, git
#
# Usage:
#   make up               Deploy harbor-pack on Nebari (NebariApp + server-side OIDC)
#   make up-sso           Deploy with the FULL browser SSO flow (see dev/enable-sso.sh)
#   make host-access      Bridge host :80/:443 to the gateway (no sudo) + print /etc/hosts line
#   make seed-user        (Re)create the Keycloak SSO login used by the dev flow
#   make harbor-bootstrap Grant the SSO user admin + a project (after its first login)
#   make up-standalone    Deploy Harbor standalone (no operator/Keycloak needed)
#   make down             Delete the kind cluster
#
# Typical full-SSO run:
#   make up-sso && make host-access
#   sudo sh -c 'echo "127.0.0.1 harbor.nebari.local keycloak.nebari.local" >> /etc/hosts'
#   open https://harbor.nebari.local     # log in as dev / dev-password
#   make harbor-bootstrap                # after that first login
#
# If a run dies partway through cluster setup, the next `make up-sso` reuses the
# half-built cluster (the `cluster` target only checks that kind knows the name). Re-run
# the step that failed - `make _metallb` / `_services` / `_keycloak-setup` / `_operator` -
# or start clean with `make down`.

CHART         := ../chart
CLUSTER_NAME  := harbor-pack-dev
NAMESPACE     := harbor
HOSTNAME      := harbor.nebari.local
ADMIN_PW      := Harbor12345
CACHE_DIR     := .cache
OPERATOR_REPO := $(CACHE_DIR)/nebari-operator
OPERATOR_REF  := v0.1.0-alpha.19

define METALLB_POOL
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - METALLB_BASE_IP.255.200-METALLB_BASE_IP.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - kind-pool
endef
export METALLB_POOL

# --------------------------------------------------------------------------
# Settings for the dev SSO scripts (seed-user.sh, harbor-bootstrap.sh).
#
# These are `export`ed rather than interpolated into recipe lines: the scripts read
# them straight from the environment, so a value containing spaces, quotes or shell
# metacharacters (an overridden password, say) can neither break the recipe nor inject
# into it. Override on the command line, e.g. `make seed-user SEED_PASSWORD='s3 cr&t'`.
#
# SEED_USER must NOT be `admin`: Harbor has a built-in local-DB `admin`, and its OIDC
# auto-onboard refuses to create a second one.
# --------------------------------------------------------------------------
SEED_USER              := dev
SEED_PASSWORD          := dev-password
HARBOR_PROJECT         := dev
HARBOR_NAMESPACE       := $(NAMESPACE)
HARBOR_HOSTNAME        := $(HOSTNAME)
HARBOR_ADMIN_PASSWORD  := $(ADMIN_PW)
KUBECTL_CONTEXT        := kind-$(CLUSTER_NAME)
export SEED_USER SEED_PASSWORD HARBOR_PROJECT
export HARBOR_NAMESPACE HARBOR_HOSTNAME HARBOR_ADMIN_PASSWORD KUBECTL_CONTEXT

.PHONY: up up-sso host-access up-standalone down cluster update-hosts \
        seed-user harbor-bootstrap

# --------------------------------------------------------------------------
# cluster - create kind cluster with full Nebari infrastructure
# --------------------------------------------------------------------------
cluster:
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "Cluster '$(CLUSTER_NAME)' already exists, skipping setup"; \
	else \
		$(MAKE) _cluster-create; \
	fi

_cluster-create: _clone-operator _kind-create _metallb _services _keycloak-setup _operator
	@echo ""
	@echo "Cluster setup complete! Run 'make up' to deploy Harbor."

_clone-operator:
	@if [ ! -d "$(OPERATOR_REPO)" ]; then \
		echo "Cloning nebari-operator ($(OPERATOR_REF)) into $(OPERATOR_REPO)..."; \
		mkdir -p $(CACHE_DIR); \
		git clone --depth 1 --branch $(OPERATOR_REF) \
			https://github.com/nebari-dev/nebari-operator.git $(OPERATOR_REPO); \
	else \
		echo "nebari-operator already cloned"; \
	fi

_kind-create:
	@echo "Creating kind cluster: $(CLUSTER_NAME) (host ports 80/443 published)"
	kind create cluster --name $(CLUSTER_NAME) --config kind-config.yaml

_metallb:
	@echo "Installing MetalLB..."
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml 2>&1 | grep -v "unrecognized format" || true
	@# 180s, not 90s: the first run pulls the MetalLB images cold.
	kubectl wait --namespace metallb-system \
		--for=condition=available deployment/controller --timeout=180s
	kubectl wait --namespace metallb-system \
		--for=jsonpath='{.status.numberReady}'=1 daemonset/speaker --timeout=180s
	@KIND_NET_CIDR=$$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null | grep '\.' | head -n1); \
	BASE_IP=$$(echo $${KIND_NET_CIDR} | awk -F. '{print $$1"."$$2}'); \
	echo "MetalLB IP pool: $${BASE_IP}.255.200-$${BASE_IP}.255.250"; \
	echo "$$METALLB_POOL" | sed "s/METALLB_BASE_IP/$${BASE_IP}/g" | kubectl apply -f -
	@echo "MetalLB installed"

_services:
	@echo "Installing foundational services (Envoy Gateway, cert-manager, Keycloak, Gateway, TLS)..."
	@# The stock install.sh writes /etc/hosts via sudo, which blocks unattended runs.
	@# Generate a no-sudo variant (disable the hosts-write guard) and run that instead.
	sed 's/.*!= "pending".*then/if false; then/' \
		$(OPERATOR_REPO)/dev/scripts/services/install.sh \
		> $(OPERATOR_REPO)/dev/scripts/services/install-nosudo.sh
	CLUSTER_NAME=$(CLUSTER_NAME) bash $(OPERATOR_REPO)/dev/scripts/services/install-nosudo.sh

_keycloak-setup:
	@echo "Setting up Keycloak realm..."
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/services/keycloak/setup.sh

_operator:
	@echo "Installing nebari-operator..."
	kubectl apply -f https://github.com/nebari-dev/nebari-operator/releases/download/$(OPERATOR_REF)/install.yaml
	kubectl wait --for=condition=available deployment/nebari-operator-controller-manager \
		-n nebari-operator-system --timeout=120s
	@echo "nebari-operator is running"

# --------------------------------------------------------------------------
# up - deploy harbor-pack with NebariApp + Keycloak SSO
# --------------------------------------------------------------------------
# up - simple dev mode: NebariApp + operator (integration is exercised), but
#   gateway TLS OFF (no self-signed cert) and OIDC OFF (Harbor DB admin login).
#   Access over plain HTTP at http://harbor.nebari.local after `make host-access`.
# --------------------------------------------------------------------------
up: cluster
	helm dependency update $(CHART)
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl label namespace $(NAMESPACE) nebari.dev/managed=true --overwrite
	helm upgrade --install harbor $(CHART) -n $(NAMESPACE) \
		--set nebariapp.enabled=true \
		--set nebariapp.hostname=$(HOSTNAME) \
		--set nebariapp.routing.tls.enabled=false \
		--set nebariapp.auth.enabled=false \
		--set oidcSetup.enabled=false \
		--set harbor.externalURL=http://$(HOSTNAME) \
		--set harbor.harborAdminPassword=$(ADMIN_PW) \
		--wait --timeout 15m
	kubectl wait --for=condition=Ready nebariapp/harbor-harbor-pack -n $(NAMESPACE) --timeout=180s
	@# Ensure DB auth (clears oidc_auth if Harbor's DB carried it from a prior SSO run).
	bash reset-harbor-auth.sh $(NAMESPACE) $(ADMIN_PW) || true
	@echo ""
	@echo "Harbor deployed with NebariApp (HTTP, DB admin auth - no cert, no SSO)."
	@echo "  Run 'make host-access', add the /etc/hosts line, then open:"
	@echo "  http://$(HOSTNAME)   (login: admin / $(ADMIN_PW))"

# --------------------------------------------------------------------------
# up-sso - deploy with the full host browser SSO flow
#   Wires KEYCLOAK_EXTERNAL_URL, a Keycloak gateway route, X-Forwarded headers,
#   and in-cluster DNS so the Keycloak issuer is identical from browser and from
#   Harbor core. Seeds the SEED_USER realm user to log in as (see seed-user).
#   Prints the two sudo host-access commands at the end.
# --------------------------------------------------------------------------
up-sso: cluster
	OPERATOR_REPO=$(OPERATOR_REPO) CLUSTER_NAME=$(CLUSTER_NAME) bash ../dev/enable-sso.sh

# --------------------------------------------------------------------------
# seed-user - (re)create the Keycloak realm user the SSO flow logs in as
#   Run by up-sso already. Run it again by hand after a Keycloak pod restart: the dev
#   stack runs Keycloak in `start-dev` (in-memory H2), so a restart wipes realm + user
#   (recreate the realm first with
#   $(OPERATOR_REPO)/dev/scripts/services/keycloak/setup.sh).
# --------------------------------------------------------------------------
seed-user:
	bash seed-user.sh

# --------------------------------------------------------------------------
# harbor-bootstrap - make the SSO user useful, AFTER its first browser login
#   Grants system admin, creates a project, adds the user as project admin, and prints
#   the `nebi registry add` line. Harbor only knows an OIDC user once it has onboarded.
# --------------------------------------------------------------------------
harbor-bootstrap:
	bash harbor-bootstrap.sh

# --------------------------------------------------------------------------
# up-standalone - deploy Harbor without Nebari integration
# --------------------------------------------------------------------------
up-standalone:
	@if ! kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		kind create cluster --name $(CLUSTER_NAME); \
	fi
	helm dependency update $(CHART)
	helm upgrade --install harbor $(CHART) -n $(NAMESPACE) --create-namespace \
		-f ../examples/standalone-values.yaml --wait --timeout 15m
	@echo ""
	@echo "Harbor deployed standalone. Port-forward and open http://localhost:8080:"
	@echo "  kubectl port-forward -n $(NAMESPACE) svc/harbor 8080:80"

# --------------------------------------------------------------------------
# host-access - reach the gateway from the host without a privileged port-forward
#   Requires the cluster to have been created with kind-config.yaml (host 80/443
#   published). Installs socat in the node forwarding :80/:443 -> Envoy gateway LB,
#   then prints the one-time /etc/hosts line (needs sudo).
# --------------------------------------------------------------------------
host-access:
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/networking/port-forward.sh
	@echo ""
	@echo "One-time host DNS (needs sudo):"
	@echo "  sudo sh -c 'echo \"127.0.0.1 $(HOSTNAME) keycloak.nebari.local\" >> /etc/hosts'"
	@echo ""
	@echo "Then open https://$(HOSTNAME)  (accept the self-signed cert for both hosts)"

update-hosts:
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/networking/update-hosts.sh

down:
	kind delete cluster --name $(CLUSTER_NAME)
