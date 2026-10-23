# secure-ai-gateway

> A **governed, observable and isolated LLM platform** on top of the
> [secure-k8s-lab](https://github.com/teodorio95-portofolio/secure-k8s-lab)
> cluster: every model call goes through one gateway that knows who is calling,
> what it costs and where it is allowed to go.

## The story this repo tells

> "Agents in this cluster can't reach the internet. Every LLM call goes through a
> gateway that enforces per-team keys, budgets and rate limits, is traced end to
> end, and a prompt-injected agent can't pivot anywhere."

## Status

Built phase by phase; each phase is reviewed before the next one starts.

| Phase | Scope | State |
|-------|-------|-------|
| 0 | Exploration, versions, plan | ✅ |
| 1 | Repo skeleton + GitOps wiring (namespaces + their cages) | ✅ |
| 2 | Secrets (Sealed Secrets, BYO sealing key) | ✅ |
| 3 | LiteLLM gateway + Postgres + bootstrap Job | ✅ |
| 4 | Tracing (Arize Phoenix) + Prometheus metrics | ✅ |
| 5 | Demo agent + MCP server | ✅ |
| 6 | Cilium FQDN egress + AI-specific Kyverno policies | ✅ |
| 7 | CI + docs | ✅ |

## Architecture

```mermaid
flowchart LR
    subgraph agents["ai-agents — default-deny"]
        AG[demo agent]
        MCP[MCP server]
    end
    subgraph gw["ai-gateway — default-deny"]
        L[LiteLLM proxy<br/>keys · budgets · fallbacks]
        PG[(Postgres)]
    end
    subgraph models["ai-models — default-deny"]
        O[Ollama<br/>qwen2.5:1.5b baked in]
    end
    subgraph obs["ai-observability — default-deny"]
        P[Arize Phoenix]
    end
    AG -->|virtual key| L
    AG --> MCP
    L --> PG
    L --> O
    L -->|traces| P
    L -->|"FQDN allowlist only"| EXT["api.anthropic.com<br/>api.openai.com"]
    AG --x|blocked| NET((internet))
```

## Wiring it into secure-k8s-lab

This repo is pulled into the lab exactly like `runtime-security`: one
`Application` in secure-k8s-lab points at [gitops/](gitops/), which holds this
repo's own child Applications (cross-repo app-of-apps).

```bash
make wire-lab            # copies bootstrap/secure-k8s-lab/secure-ai-gateway.yaml
                         # into ../secure-k8s-lab/apps/argocd-apps/
# commit + push in secure-k8s-lab — the root app syncs it
make apps-status         # sync/health of the AI Applications
make verify-namespaces   # every ai-* namespace: PSA restricted + default-deny
```

## Quick start (from a clean cluster)

Prerequisites: secure-k8s-lab's tooling (Colima/Docker, k3d, kubectl, helm) plus
`kubeseal` 0.40 and `openssl`. Give Colima **6 CPU / 10 GiB** — the base lab plus
LiteLLM, Phoenix and a 1.5B model need it.

```bash
# in secure-k8s-lab (already wired to this repo)
make up

# here
make build-images          # Ollama+model, MCP server, agent → k3d (≈3 GB, once)
make sealing-key-install   # your BYO sealing key → the SealedSecrets in git decrypt
make apps-status           # wait for everything Synced/Healthy (~5 min first time)

make gateway-test          # auth · team scope · provider fallback · budget
make agent-ask Q="What is the status of ticket TCK-1003?"
make verify-ai-netpol      # 7 network paths, each BLOCKED or REACHABLE as designed
make traces-ui             # http://localhost:6006 — every call above, traced
```

A fork runs `make sealing-key && make seal-secrets` once first and commits the
result: the ciphertext in this repo only opens with the author's key.

## Secrets

Secrets are [Sealed Secrets](https://github.com/bitnami/sealed-secrets)
sealed with a **bring-your-own key**: the private key lives in
`~/.config/secure-ai-gateway/`, the public cert and the ciphertext live in git,
and every fresh cluster gets the same key — so what's committed always decrypts.
The lab runs with **no paid API keys**; they are an opt-in extra.

```bash
make sealing-key           # once: key pair + secrets/sealing-cert.pem
make seal-secrets          # generate + seal; prints file names, never values
make sealing-key-install   # per cluster, right after `make up` in secure-k8s-lab
make verify-secrets        # every SealedSecret → UNSEALED / MISSING
```

Details, the secret inventory and rotation: [secrets/README.md](secrets/README.md).

## The gateway

[LiteLLM](https://github.com/BerriAI/litellm) is the only door to a model. Clients
call aliases — `default` (Anthropic), `cheap` (OpenAI), `local` (Ollama in the
cluster) — with a virtual key that belongs to a team with a budget and rate
limits. Paid aliases fall back to the next provider and finally to `local`, so
the lab works with **no paid API key at all**.

```bash
make build-images     # Ollama + qwen2.5:1.5b baked in → imported into k3d
make gateway-test     # auth, team scope, provider fallback, budget → PASS/FAIL
make gateway-ui       # http://localhost:4000/ui (admin: the master key)
```

Why it's built this way: [docs/architecture.md](docs/architecture.md#phase-3-the-gateway).

## Agents, tools and traces

The demo agent (`ai-agents`) is an OpenAI-compatible client with exactly two
things it can reach: the LiteLLM port, with **its own virtual key** (team
`team-support`, $0.50, `cheap` + `local` only), and an **MCP server** with two
read-only tools (`lookup_ticket`, `get_runbook`). No provider key, no
ServiceAccount token, no internet.

Every call is traced to **Arize Phoenix** (team, key alias, model, tokens, cost,
latency) and counted on LiteLLM's Prometheus `/metrics`.

## What an attacker can and can't do

Assume the worst: a prompt injection in a ticket gets the agent to run whatever
the attacker wants.

| The attacker tries to… | What happens |
|------------------------|--------------|
| exfiltrate data to the internet | **Blocked** — agent egress is LiteLLM + MCP + DNS only (`verify-ai-netpol`) |
| steal a provider API key | **Nothing to steal** — only the gateway holds them; Kyverno flags any agent pod that references another secret |
| call the Kubernetes API | **No token, no route** — `automountServiceAccountToken: false` (Kyverno-checked) and the API server is outside the cage |
| call the model directly, skipping the gateway | **Blocked** — Ollama accepts the LiteLLM pods only |
| burn money with the agent's key | **Capped** — the key's own budget, then the team's; RPM/TPM limits; every call traced |
| use a paid model the team isn't allowed | **403** — keys are scoped to aliases (`gateway-test`) |
| pivot through the gateway to any host | **Blocked** — LiteLLM's egress is an FQDN allowlist (`api.anthropic.com`, `api.openai.com`) |
| drop a shell in the agent | Contained by all of the above; Falco rules in [docs/falco/](docs/falco/ai-agent-rules.yaml) alert on it (see ⚠️) |

What it **can** do: spend the agent key's remaining budget on the models that
key allows, and read the two fake tools' data — by design, that's the agent's job.

## Platform concerns this covers

| Concern | How |
|---------|-----|
| Cost governance | per-team and per-key budgets, internal chargeback rate for the local model |
| Abuse / noisy neighbours | RPM/TPM limits per team and per key |
| Provider failover | `default` → `cheap` → `local` router fallbacks |
| Least privilege | virtual keys scoped to aliases; agents hold one key, no SA token |
| Network isolation | four default-deny zones, CiliumNetworkPolicies, FQDN egress allowlist |
| Audit / observability | Phoenix traces per call, Prometheus metrics, LiteLLM spend logs |
| Secrets | Sealed Secrets with a BYO key; nothing in clear in git |
| Supply chain | images pinned by digest, hash-checked Python deps, registry allowlist (Kyverno), Trivy |
| Policy as code | Kyverno guardrails with `kyverno test` in CI |

## Repository layout

```text
secure-ai-gateway/
├── Makefile                     # lifecycle + verification targets
├── bootstrap/
│   └── secure-k8s-lab/
│       └── secure-ai-gateway.yaml  # the one Application added to secure-k8s-lab
├── gitops/                      # child ArgoCD Applications
│   ├── sealed-secrets.yaml      # controller in kube-system (wave -1)
│   ├── ai-gateway.yaml          # one per zone (wave 0)
│   ├── ai-models.yaml
│   ├── ai-observability.yaml
│   ├── ai-agents.yaml
│   ├── ai-policies.yaml         # AI Kyverno guardrails (wave -1)
│   ├── ai-secrets.yaml          # syncs secrets/sealed/
│   └── litellm.yaml             # the gateway (wave 1)
├── charts/                      # our own minimal charts: each zone carries its cage
│   ├── ai-gateway/
│   ├── ai-models/
│   ├── ai-observability/
│   └── ai-agents/
├── values/                      # our values for upstream charts (Sealed Secrets, LiteLLM, Phoenix)
├── images/                      # Dockerfiles for the MCP server, agent, Ollama+model
├── secrets/                     # public sealing cert + SealedSecrets (ciphertext only)
├── policies/kyverno/            # AI-specific guardrails (Audit) + kyverno tests
├── scripts/                     # lint.sh (same gate locally and in CI), seal-secrets.sh,
│                                # gateway-test.sh, verify-ai-netpol.sh
├── .github/workflows/           # CI: helm lint + kubeconform, gitleaks, kyverno test, Trivy, markdownlint
└── docs/
    ├── architecture.md          # design decisions and trade-offs
    └── falco/                   # AI-agent rules for runtime-security's Falco
```

## ⚠️ Notes

- **Laptop-sized.** The local model is `qwen2.5:1.5b` on CPU: answers take
  seconds, and it often *describes* a tool call instead of making one, so the
  agent looks tickets up through MCP before asking it. A paid model (opt-in key)
  uses the tools directly.
- **Falco on Colima + k3d** loads the rules but captures no syscalls (see
  runtime-security); the agent rules are for a real Linux node.
- Kyverno runs in **Audit**, like the rest of secure-k8s-lab: violations show up
  in `kubectl get policyreport -A`, they don't block admission.
- Phoenix's UI is only reachable through `make traces-ui`; the initial admin
  password is random and sealed, not `admin`.
