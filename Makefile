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
MCP_IMAGE     := localhost/secure-ai-gateway/mcp-server:0.1.0
AGENT_IMAGE   := localhost/secure-ai-gateway/demo-agent:0.1.1
Q             ?= What is the status of ticket TCK-1003 and how do I resolve it?
KYVERNO       ?= kyverno
# Homelab mini PC (bare-metal k3s, see secure-k8s-lab/homelab/README.md),
# reached over Tailscale. Its model must match charts/ai-models/values-homelab.yaml.
HOMELAB_HOST         ?= homelab
HOMELAB_USER         ?= teodorio
# Served on the Radeon 760M through Vulkan (image built with VULKAN=1).
HOMELAB_MODEL        ?= qwen3.5:9b
HOMELAB_OLLAMA_IMAGE := localhost/secure-ai-gateway/ollama:0.40.8-$(subst :,-,$(HOMELAB_MODEL))-vulkan
# Family Hermes (homelab, charts/ai-hermes): <user>:<tailnet https port>:<ClusterIP>.
# The ClusterIPs must match charts/ai-hermes/values.yaml.
HERMES_SERVE ?= teodor:9443:10.43.219.19 teodora:9444:10.43.219.20
HERMES_USERS := $(foreach s,$(HERMES_SERVE),$(word 1,$(subst :, ,$(s))))
LITELLM_PIN  := 1.106.2
# Mac test stack (mac/compose.yaml): the same family chat in Colima's Docker.
MAC_COMPOSE := docker compose -f mac/compose.yaml --project-directory mac --env-file mac/.env
TAILSCALE   ?= $(shell command -v tailscale 2>/dev/null || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)

.PHONY: help wire-lab apps-status verify-namespaces sealing-key sealing-key-install \
	seal-secrets verify-secrets build-images gateway-ui gateway-test gateway-bootstrap traces-ui \
	agent-ask verify-ai-netpol kyverno-test lint secrets-scan wire-lab-homelab homelab-images \
	hermes-configure hermes-serve hermes-status check-budget-fallback \
	mac-secrets mac-render mac-up mac-configure mac-serve mac-logins mac-test mac-status mac-down

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

wire-lab: ## Copy the ArgoCD Application into secure-k8s-lab (then commit + push there)
	cp bootstrap/secure-k8s-lab/secure-ai-gateway.yaml $(LAB_DIR)/apps/argocd-apps/
	@echo "==> Added $(LAB_DIR)/apps/argocd-apps/secure-ai-gateway.yaml"
	@echo "    Commit + push it in secure-k8s-lab; the root app picks it up."

wire-lab-homelab: ## Copy the homelab Application into secure-k8s-lab's apps/homelab/
	mkdir -p $(LAB_DIR)/apps/homelab
	cp bootstrap/secure-k8s-lab/secure-ai-gateway-homelab.yaml $(LAB_DIR)/apps/homelab/secure-ai-gateway.yaml
	@echo "==> Added $(LAB_DIR)/apps/homelab/secure-ai-gateway.yaml (used by root-app-homelab.yaml)"

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

build-images: ## Build the local images (Ollama + model, MCP server, agent) and import them into k3d
	docker build -t $(OLLAMA_IMAGE) images/ollama-model
	docker build -t $(MCP_IMAGE) images/mcp-server
	docker build -t $(AGENT_IMAGE) images/demo-agent
	k3d image import -c $(K3D_CLUSTER) $(OLLAMA_IMAGE) $(MCP_IMAGE) $(AGENT_IMAGE)

homelab-images: ## Build the local images on the homelab mini PC (amd64) and import them into its k3s
	HOMELAB_HOST=$(HOMELAB_HOST) HOMELAB_USER=$(HOMELAB_USER) HOMELAB_MODEL=$(HOMELAB_MODEL) \
	HOMELAB_OLLAMA_IMAGE=$(HOMELAB_OLLAMA_IMAGE) MCP_IMAGE=$(MCP_IMAGE) AGENT_IMAGE=$(AGENT_IMAGE) \
		./scripts/homelab-images.sh

agent-ask: ## Ask the demo agent a question (Q="..."), through the gateway + MCP tools
	kubectl -n ai-agents exec deploy/demo-agent -- python agent.py ask "$(Q)"

gateway-ui: ## Port-forward LiteLLM (API + admin UI) to http://localhost:4000/ui
	@echo "==> Admin login: user 'admin', password = the master key:"
	@echo "    kubectl -n ai-gateway get secret litellm-masterkey -o jsonpath='{.data.masterkey}' | base64 -d"
	kubectl -n ai-gateway port-forward svc/litellm 4000:4000

gateway-test: ## End-to-end gateway checks (auth, team scope, fallback, budget) → PASS/FAIL
	./scripts/gateway-test.sh

traces-ui: ## Port-forward Arize Phoenix (traces) to http://localhost:6006
	@echo "==> Login: admin@localhost / password:"
	@echo "    kubectl -n ai-observability get secret phoenix-secret -o jsonpath='{.data.PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD}' | base64 -d"
	kubectl -n ai-observability port-forward svc/phoenix-svc 6006:6006

gateway-bootstrap: ## Re-run the bootstrap Job (teams + agent key) without waiting for a sync
	@kubectl -n ai-gateway delete job litellm-bootstrap --ignore-not-found
	@kubectl -n argocd patch application litellm --type merge \
		-p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'
	@echo "==> Sync requested; follow with: kubectl -n ai-gateway logs -f job/litellm-bootstrap"

verify-ai-netpol: ## Prove the AI network cage with labelled curl pods → PASS/FAIL per path
	./scripts/verify-ai-netpol.sh

hermes-configure: ## (homelab) Point each family Hermes at its LiteLLM aliases (flash default, `/model pro`), restart it
	@for u in $(HERMES_USERS); do \
		echo "==> hermes-$$u"; \
		kubectl -n ai-hermes exec -i deploy/hermes-$$u -- sh -s < scripts/hermes-configure.sh \
		&& kubectl -n ai-hermes rollout restart deploy/hermes-$$u; \
	done

hermes-serve: ## (homelab) Publish each Hermes dashboard on the tailnet with `tailscale serve` (HTTPS)
	@for s in $(HERMES_SERVE); do \
		u=$${s%%:*}; rest=$${s#*:}; port=$${rest%%:*}; ip=$${rest#*:}; \
		echo "==> $$u: https://$(HOMELAB_HOST).<tailnet>.ts.net:$$port -> $$ip:9119"; \
		ssh $(HOMELAB_USER)@$(HOMELAB_HOST) "sudo tailscale serve --bg --https=$$port http://$$ip:9119"; \
	done
	@echo "==> Logins for the Hermex app: $(SEALING_DIR)/hermes-<user>.env"

hermes-status: ## (homelab) Hermes pods, their volumes and what tailscale serve publishes
	kubectl -n ai-hermes get pods,pvc,svc -o wide
	ssh $(HOMELAB_USER)@$(HOMELAB_HOST) tailscale serve status

check-budget-fallback: ## Offline: prove a spent per-person DeepSeek budget falls back to `local` (pinned LiteLLM)
	uv run --no-project --with litellm==$(LITELLM_PIN) python scripts/check-budget-fallback.py

mac-secrets: ## (Mac) Generate mac/.env once: keys, logins, DeepSeek key (prompted, hidden)
	TAILSCALE="$(TAILSCALE)" ./mac/secrets.sh

mac-render: ## (Mac) Render LiteLLM config + key bootstrap from values/litellm*.yaml into mac/.generated/
	uv run --no-project --with pyyaml==6.0.2 python mac/render.py

mac-up: mac-render ## (Mac) Start or update LiteLLM + Postgres + both Hermes in Colima (needs mac/.env)
	@test -f mac/.env || { echo "no mac/.env - run make mac-secrets first"; exit 1; }
	LITELLM_CONFIG_SUM=$$(cksum < mac/.generated/litellm-config.yaml | cut -d' ' -f1) \
	LITELLM_KEYS_SUM=$$(cksum < mac/.generated/bootstrap/keys.json | cut -d' ' -f1) \
		$(MAC_COMPOSE) up -d
	@echo "==> a changed config recreates LiteLLM (its budget count restarts) and re-registers the keys"
	@echo "==> first start pulls ~1 GB per Hermes image; then: make mac-configure mac-serve mac-test"

mac-configure: ## (Mac) Point each Hermes at its LiteLLM aliases (flash default, `/model pro`), restart it
	@for u in $(HERMES_USERS); do \
		echo "==> hermes-$$u"; \
		$(MAC_COMPOSE) exec -T hermes-$$u sh -s < scripts/hermes-configure.sh \
		&& $(MAC_COMPOSE) restart hermes-$$u; \
	done

mac-serve: ## (Mac) Publish both dashboards on the tailnet: https://<mac>:9443 (teodor), :9444 (teodora)
	"$(TAILSCALE)" serve --bg --https=9443 http://127.0.0.1:19119
	"$(TAILSCALE)" serve --bg --https=9444 http://127.0.0.1:19120
	"$(TAILSCALE)" serve status

mac-logins: ## (Mac) Show the Hermex sign-in for each person (server URL, username, password)
	@. mac/.env && \
		printf "teodor : %s  user teodor   password %s\n" "$$HERMES_TEODOR_URL" "$$HERMES_TEODOR_PASSWORD" && \
		printf "teodora: %s  user teodora  password %s\n" "$$HERMES_TEODORA_URL" "$$HERMES_TEODORA_PASSWORD"

mac-test: ## (Mac) Each key reaches its own DeepSeek alias only (one real call per person)
	./mac/test.sh

mac-status: ## (Mac) Containers, LiteLLM key bootstrap log and what tailscale serve publishes
	$(MAC_COMPOSE) ps -a
	$(MAC_COMPOSE) logs --no-log-prefix bootstrap | tail -5
	"$(TAILSCALE)" serve status

mac-down: ## (Mac) Stop the stack; WIPE=1 also deletes chat history, keys and spend (volumes)
	$(MAC_COMPOSE) down $(if $(filter 1,$(WIPE)),-v,)

kyverno-test: ## Run the AI Kyverno policies against good/bad fixtures (CLI v1.18.1, as in CI)
	$(KYVERNO) test policies/kyverno/tests

lint: ## helm lint + kubeconform every chart and Application (same as CI)
	./scripts/lint.sh

secrets-scan: ## Run gitleaks over the working tree and history
	gitleaks git --redact --verbose .
