CLUSTER   ?= devops-live
NS        ?= devops-live
IMAGE     ?= devops-live-api
# Fully-qualified so Podman doesn't tag it as localhost/... (pods would get ErrImagePull)
IMAGE_REF := docker.io/library/$(IMAGE)
# Names used by the manifests in k8s/
API       ?= devops-live-api
DB        ?= devops-live-db

# Use kind's podman provider when `docker` is really podman
KIND_EXPERIMENTAL_PROVIDER ?= $(shell docker --version 2>/dev/null | grep -qi podman && echo podman)
export KIND_EXPERIMENTAL_PROVIDER

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- before the live
.PHONY: preflight
preflight: ## Check tools + pre-pull every image (run ~1h before going live)
	@for t in docker kubectl kind curl; do command -v $$t >/dev/null && echo "ok   $$t" || { echo "MISSING $$t"; exit 1; }; done
	docker pull python:3.12-slim
	docker pull postgres:16-alpine
	docker pull jaegertracing/jaeger:2.10.0
	$(MAKE) build build-v2
	@echo "Warming up the kind node image (creates + deletes a throwaway cluster)..."
	kind create cluster --name preflight
	kind delete cluster --name preflight
	@echo "Preflight done. You're ready to go live."

# ---------------------------------------------------------------- Part 1: compose
.PHONY: compose-up compose-down
compose-up: ## Run the app with podman-compose (localhost:8000)
	podman-compose up --build -d

compose-down: ## Stop podman-compose and remove its volumes
	podman-compose down -v

# ---------------------------------------------------------------- images
.PHONY: build build-v2
build: ## Build devops-live-api:1.0
	docker build -t $(IMAGE_REF):1.0 --build-arg APP_VERSION=1.0 app

build-v2: ## Build devops-live-api:2.0 (for the rolling update)
	docker build -t $(IMAGE_REF):2.0 --build-arg APP_VERSION=2.0 app

# ---------------------------------------------------------------- cluster
.PHONY: cluster cluster-delete load load-v2 load-postgres load-jaeger
cluster: ## Create the Kind cluster (1 control-plane + 2 workers)
	kind create cluster --name $(CLUSTER) --config kind-config.yaml
	kubectl get nodes

cluster-delete: ## Delete the Kind cluster
	kind delete cluster --name $(CLUSTER)

load: ## Load devops-live-api:1.0 into the Kind nodes
	kind load docker-image $(IMAGE_REF):1.0 --name $(CLUSTER)

load-v2: ## Load devops-live-api:2.0 into the Kind nodes
	kind load docker-image $(IMAGE_REF):2.0 --name $(CLUSTER)

load-jaeger: ## Pre-load the Jaeger image into Kind (bonus observability segment)
	kind load docker-image docker.io/jaegertracing/jaeger:2.10.0 --name $(CLUSTER)

load-postgres: ## Pre-load postgres:16-alpine into Kind (avoids Docker Hub pulls live)
	kind load docker-image docker.io/library/postgres:16-alpine --name $(CLUSTER)

# ---------------------------------------------------------------- ingress
INGRESS_NGINX_VERSION ?= v1.15.1
.PHONY: ingress-controller
ingress-controller: ## Install the ingress-nginx controller (kind flavour) and wait for it
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-$(INGRESS_NGINX_VERSION)/deploy/static/provider/kind/deploy.yaml
	@# Pin it to the control-plane: that's the node whose 80/443 are mapped to localhost:8081/8443
	kubectl -n ingress-nginx patch deployment ingress-nginx-controller \
	  -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true"}}}}}'
	kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
	@# "rolled out" != webhook reachable: wait for the admission Service to have a ready endpoint,
	@# otherwise the first `kubectl apply` of an Ingress fails with "failed calling webhook"
	@until kubectl -n ingress-nginx get endpointslices -l kubernetes.io/service-name=ingress-nginx-controller-admission \
	  -o jsonpath='{.items[*].endpoints[*].conditions.ready}' | grep -q true; do sleep 2; done
	@sleep 3
	@echo "ingress-nginx ready: try http://localhost:8081 (expect nginx 404 until an Ingress exists)"

# ---------------------------------------------------------------- deploy
.PHONY: ns deploy deploy-final port-forward status lb-demo traffic observability jaeger-ui reset
ns: ## Create the namespace and make it the default for kubectl
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl config set-context --current --namespace=$(NS)

deploy: ## Apply k8s/db + k8s/api (DB, API, Ingress) and wait (recovery button)
	kubectl -n $(NS) apply -f k8s/db/ -f k8s/api/
	kubectl -n $(NS) rollout status deployment/$(DB)
	kubectl -n $(NS) rollout status deployment/$(API)

deploy-final: ## [old runbook] Apply the backend/postgres manifests from final/k8s/
	kubectl apply -f final/k8s/
	kubectl -n $(NS) rollout status deployment/postgres
	kubectl -n $(NS) rollout status deployment/backend

port-forward: ## localhost:8000 -> service/devops-live-api:8000
	kubectl -n $(NS) port-forward service/$(API) 8000:8000

status: ## Show everything in the namespace
	kubectl -n $(NS) get deploy,rs,pods,svc,endpointslices,ingress -o wide

lb-demo: ## Call the Service 10x from INSIDE the cluster: see different pods answer
	kubectl -n $(NS) exec deploy/$(API) -- python -c "import urllib.request as u; [print(u.urlopen('http://$(API):8000/').read().decode()) for _ in range(10)]"

traffic: ## Continuous requests to the Service from a separate Pod (watch the rolling update)
	kubectl -n $(NS) run traffic --rm -it --restart=Never --image=$(IMAGE_REF):1.0 -- python traffic.py http://$(API):8000/

observability: ## [old runbook] Bonus: deploy Jaeger + turn on FastAPI's native OpenTelemetry via the ConfigMap
	kubectl apply -f final/observability/
	kubectl -n $(NS) rollout restart deployment/backend
	kubectl -n $(NS) rollout status deployment/jaeger
	kubectl -n $(NS) rollout status deployment/backend

jaeger-ui: ## [old runbook] localhost:16686 -> Jaeger UI
	kubectl -n $(NS) port-forward service/jaeger 16686:16686

reset: ## Delete the namespace (everything we deployed) and start over
	kubectl delete namespace $(NS) --ignore-not-found
