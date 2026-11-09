# secure-ai-gateway — agent context

Governed, observable, and network-isolated LLM platform on top of secure-k8s-lab k3d cluster with LiteLLM proxy, Arize Phoenix tracing, and Cilium policies. Runs on: k3d + ArgoCD (local macOS Colima) and homelab bare-metal k3s.

## Commands
- `make lint` — run helm lint + kubeconform across charts and Applications (quick/safe, same as CI)
- `make kyverno-test` — run Kyverno policy tests against good/bad fixtures
- `make secrets-scan` — run gitleaks over working tree and history
- `make build-images` — build local Ollama, MCP server, and agent images and import into k3d
- `make sealing-key-install` — load BYO sealing key from `~/.config/secure-ai-gateway/` into cluster
- `make apps-status` — check ArgoCD sync and health status for AI Applications
- `make gateway-test` — end-to-end gateway checks (auth, team scoping, provider fallback, budget)
- `make verify-ai-netpol` — verify 7 network isolation paths (blocked vs reachable)
- `make traces-ui` — port-forward Arize Phoenix tracing UI to http://localhost:6006
- `make gateway-ui` — port-forward LiteLLM UI to http://localhost:4000/ui (admin master key required)

## Layout
- `charts/` — custom zone charts (`ai-gateway`, `ai-models`, `ai-observability`, `ai-agents`)
- `gitops/` — child ArgoCD Application manifests (sync-waves -1 to 1)
- `images/` — Dockerfiles for Ollama (`qwen2.5:1.5b`), demo agent, and MCP server
- `policies/kyverno/` — AI-specific admission policies (no SA token, no provider secrets in agents)
- `secrets/` — public sealing certificate and encrypted SealedSecrets
- `values/` — upstream chart values for LiteLLM, Phoenix, Sealed Secrets
- `mac/` & `homelab/` — Hermes family chat deployment and test scripts

## How it works
- Agents in `ai-agents` hold virtual LiteLLM keys with strict budgets and rate limits; they have no provider keys or internet access.
- LiteLLM in `ai-gateway` acts as the single egress point, routing to external APIs (`api.anthropic.com`, `api.openai.com`) or fallback local Ollama in `ai-models`.
- CiliumNetworkPolicy enforces FQDN-based egress filtering for LiteLLM and default-deny for all `ai-*` namespaces.
- Every LLM invocation is logged to PostgreSQL, tracked for spend, and traced to Arize Phoenix.

## Gotchas
- Colima needs at least 6 CPU / 10 GiB RAM to host the base lab plus LiteLLM, Phoenix, and local LLM.
- After Colima/k3s restart, CoreDNS defaults back to `8.8.8.8` (blocked on macOS); repatch CoreDNS upstream to Colima resolver (`192.168.5.1`).
- macOS bash 3.2 fails on empty array expansion under `set -u` (`214fd4d`); use `${arr[@]+"${arr[@]}"}`.
- LiteLLM config updates require recreating pods to re-register virtual keys (`158918e`).
- Hermes model aliases must be applied with `--force` flag (`d856252`).

## Related repos
- `secure-k8s-lab` — base cluster, Traefik ingress, Cilium CNI, and parent root ArgoCD app.
- `homelab-apps` — shares BYO sealing key and hosts the mini PC deployment of the AI gateway.
- `runtime-security` — provides Falco daemonset and runtime threat detection rules.

## Do not
- Do not commit unsealed API keys or private keys (`sealing.key` stays in `~/.config/secure-ai-gateway/`).
- Do not add direct internet egress to `ai-agents` or `ai-models` pods.
- Do not remove `automountServiceAccountToken: false` on agent pods (Kyverno audit violation).
