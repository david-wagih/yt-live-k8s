CLUSTER   ?= devops-live
NS        ?= devops-live
IMAGE     ?= devops-live-api

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- before the live
.PHONY: preflight
preflight: ## Check tools + pre-pull every image (run ~1h before going live)
	@for t in docker kubectl kind curl; do command -v $$t >/dev/null && echo "ok   $$t" || echo "MISSING $$t"; done
	docker pull python:3.12-slim
	docker pull postgres:16-alpine
	$(MAKE) build build-v2
	@echo "Warming up the kind node image (creates + deletes a throwaway cluster)..."
	kind create cluster --name preflight
	kind delete cluster --name preflight
	@echo "Preflight done. You're ready to go live."

# ---------------------------------------------------------------- Part 1: compose
.PHONY: compose-up compose-down
compose-up: ## Run the app with docker compose (localhost:8000)
	docker compose up --build

compose-down: ## Stop docker compose and remove its volumes
	docker compose down -v

# ---------------------------------------------------------------- images
.PHONY: build build-v2
build: ## Build devops-live-api:1.0
	docker build -t $(IMAGE):1.0 --build-arg APP_VERSION=1.0 app

build-v2: ## Build devops-live-api:2.0 (for the rolling update)
	docker build -t $(IMAGE):2.0 --build-arg APP_VERSION=2.0 app

# ---------------------------------------------------------------- cluster
.PHONY: cluster cluster-delete load load-v2 load-postgres
cluster: ## Create the Kind cluster (1 control-plane + 2 workers)
	kind create cluster --name $(CLUSTER) --config kind-config.yaml
	kubectl get nodes

cluster-delete: ## Delete the Kind cluster
	kind delete cluster --name $(CLUSTER)

load: ## Load devops-live-api:1.0 into the Kind nodes
	kind load docker-image $(IMAGE):1.0 --name $(CLUSTER)

load-v2: ## Load devops-live-api:2.0 into the Kind nodes
	kind load docker-image $(IMAGE):2.0 --name $(CLUSTER)

load-postgres: ## Pre-load postgres:16-alpine into Kind (avoids Docker Hub pulls live)
	kind load docker-image postgres:16-alpine --name $(CLUSTER)

# ---------------------------------------------------------------- deploy
.PHONY: ns deploy-final port-forward status lb-demo traffic reset
ns: ## Create the namespace and make it the default for kubectl
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	kubectl config set-context --current --namespace=$(NS)

deploy-final: ## Apply the known-good manifests (recovery button)
	kubectl apply -f final/k8s/
	kubectl -n $(NS) rollout status deployment/postgres
	kubectl -n $(NS) rollout status deployment/backend

port-forward: ## localhost:8080 -> service/backend:80
	kubectl -n $(NS) port-forward service/backend 8080:80

status: ## Show everything in the namespace
	kubectl -n $(NS) get deploy,rs,pods,svc,endpoints,cm,secret -o wide

lb-demo: ## Call the Service 10x from INSIDE the cluster: see different pods answer
	kubectl -n $(NS) exec deploy/backend -- python -c "import urllib.request as u; [print(u.urlopen('http://backend/').read().decode()) for _ in range(10)]"

traffic: ## Continuous requests to the Service from a separate Pod (watch the rolling update)
	kubectl -n $(NS) run traffic --rm -it --restart=Never --image=$(IMAGE):1.0 -- python traffic.py

reset: ## Delete the namespace (everything we deployed) and start over
	kubectl delete namespace $(NS) --ignore-not-found
