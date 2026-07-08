# Local development Makefile for harbor-pack
#
# Creates a kind cluster with the full Nebari infrastructure stack
# (MetalLB, Envoy Gateway, cert-manager, Keycloak, nebari-operator)
# and deploys Harbor with the NebariApp + Keycloak SSO wired in.
#
# Prerequisites: docker, kind, helm, kubectl, git
#
# Usage:
#   make up             Deploy harbor-pack on Nebari (NebariApp + OIDC enabled)
#   make up-standalone  Deploy Harbor standalone (no operator/Keycloak needed)
#   make update-hosts   Update /etc/hosts with the Harbor hostname
#   make down           Delete the kind cluster

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

.PHONY: up up-standalone down cluster update-hosts

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
	@echo "Creating kind cluster: $(CLUSTER_NAME)"
	kind create cluster --name $(CLUSTER_NAME)

_metallb:
	@echo "Installing MetalLB..."
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml 2>&1 | grep -v "unrecognized format" || true
	kubectl wait --namespace metallb-system \
		--for=condition=available deployment/controller --timeout=90s
	kubectl wait --namespace metallb-system \
		--for=jsonpath='{.status.numberReady}'=1 daemonset/speaker --timeout=90s
	@KIND_NET_CIDR=$$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null | grep '\.' | head -n1); \
	BASE_IP=$$(echo $${KIND_NET_CIDR} | awk -F. '{print $$1"."$$2}'); \
	echo "MetalLB IP pool: $${BASE_IP}.255.200-$${BASE_IP}.255.250"; \
	echo "$$METALLB_POOL" | sed "s/METALLB_BASE_IP/$${BASE_IP}/g" | kubectl apply -f -
	@echo "MetalLB installed"

_services:
	@echo "Installing foundational services (Envoy Gateway, cert-manager, Keycloak, Gateway, TLS)..."
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/services/install.sh

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
up: cluster
	helm dependency update $(CHART)
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl label namespace $(NAMESPACE) nebari.dev/managed=true --overwrite
	helm upgrade --install harbor $(CHART) -n $(NAMESPACE) \
		--set nebariapp.enabled=true \
		--set nebariapp.hostname=$(HOSTNAME) \
		--set harbor.externalURL=https://$(HOSTNAME) \
		--set harbor.harborAdminPassword=$(ADMIN_PW) \
		--wait --timeout 15m
	kubectl wait --for=condition=Ready nebariapp/harbor-harbor-pack -n $(NAMESPACE) --timeout=180s
	kubectl wait --for=condition=complete job/harbor-harbor-pack-oidc-setup -n $(NAMESPACE) --timeout=300s
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/networking/update-hosts.sh
	@echo ""
	@echo "Harbor deployed with NebariApp + Keycloak SSO."
	@echo "  https://$(HOSTNAME)   (click 'LOGIN VIA OIDC PROVIDER')"
	@echo "  Keycloak login: admin / nebari-admin"

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

update-hosts:
	CLUSTER_NAME=$(CLUSTER_NAME) $(OPERATOR_REPO)/dev/scripts/networking/update-hosts.sh

down:
	kind delete cluster --name $(CLUSTER_NAME)
