# Makefile - orchestration for the k8s HPA autoscaling project.

CLUSTER_NAME := hpa-demo
KIND_CONFIG  := kind-config.yaml
PREREQS      := kind kubectl docker locust

# OS detection: MSYS/MINGW/CYGWIN = Windows native (git-bash); kernel "microsoft" = inside WSL;
# kernel "wsl2" = WSL2. Empty `uname` output (e.g. cmd.exe hosting) = detection failed.
UNAME_S      := $(shell uname -s)
UNAME_R_L    := $(shell echo $(shell uname -r) | tr 'A-Z' 'a-z')
IS_WINDOWS   := $(if $(or $(findstring MINGW,$(UNAME_S)),$(findstring MSYS,$(UNAME_S)),$(findstring CYGWIN,$(UNAME_S))),1,0)
IS_WSL       := $(if $(findstring microsoft,$(UNAME_R_L)),1,0)
IS_WSL2      := $(if $(findstring wsl2,$(UNAME_R_L)),1,0)
IS_UNKNOWN   := $(if $(UNAME_S),0,1)

.DEFAULT_GOAL := help

.PHONY: check-prereqs cluster teardown clean load-image deploy status port-forward help

help:
	@echo "k8s HPA autoscaling project - Makefile targets:"
	@echo "  check-prereqs   Verify docker, kind, kubectl, locust are installed; on Windows also verify the WSL2 backend"
	@echo "  cluster         Create the '$(CLUSTER_NAME)' kind cluster from $(KIND_CONFIG)"
	@echo "  teardown        Prompt, then destroy the cluster"
	@echo "  clean           Delete only app + HPA resources (keep cluster, Metrics Server, Prometheus)"
	@echo "  load-image      Load the fastapi-hpa image into the '$(CLUSTER_NAME)' kind cluster"
	@echo "  deploy          Build + load image, then apply Metrics Server, Prometheus, app, and HPA with readiness gates"
	@echo "  status          Show pods, services, and HPA in a compact wide view"
	@echo "  port-forward    Forward localhost:8080 to the FastAPI service for ad-hoc testing"

check-prereqs:
	@echo "Checking prerequisites for the k8s HPA demo..."
	@missing=0; \
	for cmd in $(PREREQS); do \
		if command -v "$$cmd" >/dev/null 2>&1; then \
			printf "[OK] %s\n" "$$cmd"; \
		else \
			printf "[MISSING] %s\n" "$$cmd"; \
			missing=1; \
		fi; \
	done; \
	if [ "$(IS_UNKNOWN)" = "1" ]; then \
		printf "[MISSING] Cannot detect OS - run make from git-bash or WSL2 (uname not found)\n" >&2; \
		missing=1; \
	elif [ "$(IS_WSL)" = "1" ]; then \
		if [ "$(IS_WSL2)" = "1" ]; then \
			echo "Inside WSL2 - checking Docker daemon reachability..."; \
			if command -v docker >/dev/null 2>&1; then \
				if docker info >/dev/null 2>&1; then \
					printf "[OK] Docker daemon reachable (WSL2 integration)\n"; \
				else \
					printf "[MISSING] Docker daemon not reachable inside WSL2 - enable Docker Desktop WSL2 integration\n" >&2; \
					missing=1; \
				fi; \
			fi; \
		else \
			printf "[MISSING] WSL1 detected - this project requires WSL2\n" >&2; \
			missing=1; \
		fi; \
	elif [ "$(IS_WINDOWS)" = "1" ]; then \
		echo "Windows native (git-bash/MSYS) - verifying Docker Desktop WSL2 backend..."; \
		if command -v docker >/dev/null 2>&1; then \
			kernel=$$(docker info --format '{{.KernelVersion}}' 2>/dev/null); \
			if [ -n "$$kernel" ]; then \
				if printf '%s\n' "$$kernel" | grep -qi 'wsl2'; then \
					printf "[OK] Docker Desktop WSL2 backend (kernel %s)\n" "$$kernel"; \
				else \
					printf "[MISSING] Docker Desktop not using the WSL2 backend (kernel %s) - enable 'Use the WSL 2 based engine' in Docker Desktop settings\n" "$$kernel" >&2; \
					missing=1; \
				fi; \
			else \
				printf "[MISSING] Cannot determine Docker Desktop backend (docker info failed) - is Docker Desktop running?\n" >&2; \
				missing=1; \
			fi; \
		fi; \
	else \
		printf "[OK] WSL2 backend not required (native Linux/macOS)\n"; \
	fi; \
	if [ "$$missing" = "1" ]; then \
		printf "Error: one or more prerequisites are missing - fix and re-run 'make check-prereqs'\n" >&2; \
		exit 1; \
	fi; \
	printf "All prerequisites satisfied\n"

cluster: check-prereqs
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		printf "Cluster '%s' already exists. Delete and recreate it? (y/N) " "$(CLUSTER_NAME)"; \
		read -r answer; \
		case "$$answer" in \
			y|Y) kind delete cluster --name "$(CLUSTER_NAME)" && kind create cluster --config "$(KIND_CONFIG)" ;; \
			*) printf "Keeping existing cluster. Run 'make teardown' to destroy it first.\n" ;; \
		esac; \
	else \
		kind create cluster --config "$(KIND_CONFIG)"; \
	fi

teardown:
	@printf "This will destroy the cluster and all data. Are screenshots and logs saved? (y/N) "; \
	read -r answer; \
	case "$$answer" in \
		y|Y) \
			kind delete cluster --name "$(CLUSTER_NAME)" || { printf "Error: failed to delete cluster '%s'\n" "$(CLUSTER_NAME)" >&2; exit 1; }; \
			if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
				printf "Error: cluster '%s' still exists\n" "$(CLUSTER_NAME)" >&2; \
				exit 1; \
			fi; \
			printf "Cluster '%s' torn down\n" "$(CLUSTER_NAME)" ;; \
		*) printf "Teardown cancelled\n" ;; \
	esac

clean:
	@kubectl delete --ignore-not-found -f k8s/app/ -f k8s/hpa/
	@echo "Cleaned app and HPA resources. Metrics Server and Prometheus remain."

load-image:
	@kind load docker-image fastapi-hpa:latest --name "$(CLUSTER_NAME)"

deploy: check-prereqs
	@docker build -t fastapi-hpa:latest .
	@kind load docker-image fastapi-hpa:latest --name "$(CLUSTER_NAME)"
	@kubectl apply -f k8s/metrics-server/
	@kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s
	@kubectl apply -f k8s/prometheus/
	@kubectl apply -f k8s/app/
	@kubectl wait --for=condition=ready pod -l app=fastapi-app --timeout=120s
	@kubectl apply -f k8s/hpa/
	@echo "Deploy complete"

status:
	@kubectl get pods,svc,hpa -o wide

port-forward:
	@kubectl port-forward svc/fastapi-app 8080:80
