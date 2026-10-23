LAB_DIR       ?= ../secure-k8s-lab
AI_NAMESPACES := ai-gateway ai-models ai-observability ai-agents
AI_APPS       := secure-ai-gateway sealed-secrets $(AI_NAMESPACES) ai-secrets litellm
# The BYO sealing key pair lives outside the repo; only the cert is committed.
SEALING_DIR    ?= $(HOME)/.config/secure-ai-gateway
SEALING_SECRET := secure-ai-gateway-sealing-key
SEALING_CERT   := secrets/sealing-cert.pem
# Local images: built here, imported into k3d, never pushed to a registry.
K3D_CLUSTER   ?= secure-lab
OLLAMA_IMAGE  := localhost/secure-ai-gateway/ollama:0.40.8-qwen2.5-1.5b

.PHONY: help wire-lab apps-status verify-namespaces sealing-key sealing-key-install \
	seal-secrets verify-secrets build-images gateway-ui gateway-test gateway-bootstrap \
	lint secrets-scan

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

wire-lab: ## Copy the ArgoCD Application into secure-k8s-lab (then commit + push there)
	cp bootstrap/secure-k8s-lab/secure-ai-gateway.yaml $(LAB_DIR)/apps/argocd-apps/
	@echo "==> Added $(LAB_DIR)/apps/argocd-apps/secure-ai-gateway.yaml"
	@echo "    Commit + push it in secure-k8s-lab; the root app picks it up."

apps-status: ## Show sync/health of the AI stack's ArgoCD Applications
	@kubectl -n argocd get applications $(AI_APPS) \
		-o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

verify-namespaces: ## Prove every AI namespace exists, enforces PSA and is default-deny
	@for ns in $(AI_NAMESPACES); do \
		psa=$$(kubectl get ns $$ns -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null); \
		deny=$$(kubectl -n $$ns get networkpolicy -o name 2>/dev/null | grep default-deny | tr '\n' ' '); \
		printf "%-18s PSA enforce=%-11s default-deny: %s\n" $$ns "$${psa:-MISSING}" "$${deny:-NONE}"; \
	done

sealing-key: ## Generate the BYO sealing key once (private key stays in ~/.config/secure-ai-gateway)
	@if [ -f $(SEALING_DIR)/sealing.key ]; then \
		echo "==> Keeping the existing key in $(SEALING_DIR)"; \
	else \
		mkdir -p $(SEALING_DIR) && chmod 700 $(SEALING_DIR) && \
		openssl req -x509 -noenc -newkey rsa:4096 -days 3650 \
			-subj "/CN=sealed-secret/O=secure-ai-gateway" \
			-keyout $(SEALING_DIR)/sealing.key -out $(SEALING_DIR)/sealing.crt 2>/dev/null && \
		chmod 600 $(SEALING_DIR)/sealing.key && \
		echo "==> New key pair in $(SEALING_DIR)"; \
	fi
	@mkdir -p $(dir $(SEALING_CERT)) && cp $(SEALING_DIR)/sealing.crt $(SEALING_CERT)
	@echo "==> Public cert copied to $(SEALING_CERT) (commit it; never the .key)"

sealing-key-install: ## Load the BYO key into the cluster (bootstrap step, right after `make up`)
	@kubectl -n kube-system create secret tls $(SEALING_SECRET) \
		--cert=$(SEALING_DIR)/sealing.crt --key=$(SEALING_DIR)/sealing.key \
		--dry-run=client -o yaml \
		| kubectl label --local -f - sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml \
		| kubectl apply --server-side --field-manager=secure-ai-gateway -f -
	@# The controller only loads keys at start-up.
	@if kubectl -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1; then \
		kubectl -n kube-system rollout restart deploy/sealed-secrets-controller && \
		kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=120s; \
	else \
		echo "==> Controller not deployed yet; it will pick the key up when ArgoCD starts it"; \
	fi

seal-secrets: ## Generate + seal the stack's secrets into secrets/sealed/ (values never printed)
	./scripts/seal-secrets.sh

verify-secrets: ## Prove every SealedSecret was decrypted into a Secret (names only, no values)
	@kubectl get sealedsecrets -A --no-headers \
		-o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null \
		| while read -r ns name; do \
			if kubectl -n $$ns get secret $$name >/dev/null 2>&1; then r=UNSEALED; else r=MISSING; fi; \
			printf "%-18s %-22s %s\n" $$ns $$name $$r; \
		done

build-images: ## Build the local images (Ollama + baked model) and import them into k3d
	docker build -t $(OLLAMA_IMAGE) images/ollama-model
	k3d image import -c $(K3D_CLUSTER) $(OLLAMA_IMAGE)

gateway-ui: ## Port-forward LiteLLM (API + admin UI) to http://localhost:4000/ui
	@echo "==> Admin login: user 'admin', password = the master key:"
	@echo "    kubectl -n ai-gateway get secret litellm-masterkey -o jsonpath='{.data.masterkey}' | base64 -d"
	kubectl -n ai-gateway port-forward svc/litellm 4000:4000

gateway-test: ## End-to-end gateway checks (auth, team scope, fallback, budget) → PASS/FAIL
	./scripts/gateway-test.sh

gateway-bootstrap: ## Re-run the bootstrap Job (teams + agent key) without waiting for a sync
	@kubectl -n ai-gateway delete job litellm-bootstrap --ignore-not-found
	@kubectl -n argocd patch application litellm --type merge \
		-p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'
	@echo "==> Sync requested; follow with: kubectl -n ai-gateway logs -f job/litellm-bootstrap"

lint: ## helm lint + kubeconform every chart and Application (same as CI)
	./scripts/lint.sh

secrets-scan: ## Run gitleaks over the working tree and history
	gitleaks git --redact --verbose .
