LAB_DIR       ?= ../secure-k8s-lab
AI_NAMESPACES := ai-gateway ai-models ai-observability ai-agents
AI_APPS       := secure-ai-gateway $(AI_NAMESPACES)

.PHONY: help wire-lab apps-status verify-namespaces lint secrets-scan

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

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

lint: ## helm lint + kubeconform every chart and Application (same as CI)
	./scripts/lint.sh

secrets-scan: ## Run gitleaks over the working tree and history
	gitleaks git --redact --verbose .
