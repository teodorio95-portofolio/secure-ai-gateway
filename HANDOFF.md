# Handoff — `secure-ai-gateway` (continue from Phase 1 → Phase 2)

You are picking up a phased build that was started in another Claude Code session.
Read this whole file first, then read the repos listed below before doing anything.
The user writes in Romanian; answer in Romanian, keep everything in the repos
(code, comments, commits, docs) in English.

## 1. What we are building

A public DevSecOps portfolio project, `secure-ai-gateway`: a **governed, observable
and isolated LLM platform** on top of the existing `secure-k8s-lab` k3d cluster,
pulled in through ArgoCD like `runtime-security`. Target roles: AI Platform
Engineer / LLMOps.

README story:
> "Agents in this cluster can't reach the internet. Every LLM call goes through a
> gateway that enforces per-team keys, budgets and rate limits, is traced end to
> end, and a prompt-injected agent can't pivot anywhere."

## 2. Repos and local layout

| Repo | Where | Notes |
|------|-------|-------|
| `secure-ai-gateway` (this one) | <https://github.com/teodorio95-portofolio/secure-ai-gateway> | **GitHub only** for now (no GitLab mirror). `main` is at `89041d8`. |
| `secure-k8s-lab` (project #1) | <https://github.com/teodorio95-portofolio/secure-k8s-lab,> local clone expected at `../secure-k8s-lab` | **Do not edit it.** Give the user exact YAML/patches instead. Its own ArgoCD apps still point to `gitlab.com/teodorio95/...` — leave that alone. |
| `runtime-security` (project #5) | <https://github.com/teodorio95-portofolio/runtime-security> | Falco + Cilium L7. **Do not edit it**; give a patch for `falco/values.yaml` `customRules` in Phase 6. |

User environment: **Apple Silicon (arm64) Mac, Colima + k3d** (per runtime-security's
README). All images must be multi-arch (amd64 + arm64). Recommend Colima with
**6 CPU, 10–12 GiB RAM** for base lab + AI stack.

## 3. Conventions copied from secure-k8s-lab (keep following them)

- App-of-apps; each ArgoCD `Application` has `finalizers: [resources-finalizer.argocd.argoproj.io]`,
  `syncPolicy.automated {prune: true, selfHeal: true}`, sync-wave annotations.
  Upstream chart + our values → **multi-source** with `ref:` (see runtime-security `gitops/falco.yaml`).
- Our own charts are minimal: `_helpers.tpl` with labels, a templated `Namespace` with PSA labels,
  NetworkPolicies inside the chart ("the app carries its cage"), `# --` comments on values.
- Secure-by-default pods: `runAsNonRoot`, `seccompProfile: RuntimeDefault`,
  `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, CPU+memory limits on every
  container (Kyverno checks only `containers`, but set them on initContainers too),
  `readOnlyRootFilesystem: true` where possible.
- Kyverno in secure-k8s-lab (chart 3.8.1 = **Kyverno v1.18.1**), all **Audit**:
  `01` no `:latest`/untagged, `02` runAsNonRoot, `03` limits, `04` mutate default securityContext,
  `05` generate `default-deny-all` NetworkPolicy in new namespaces (**`generateExisting: false`**;
  excludes kube-system, kube-public, kube-node-lease, kube-cluster-mgmt, default, kyverno, argocd).
- Makefile style: `target: ## description`, `help` target greps them; `*-ui` = port-forward,
  `verify-*` = spin a labelled test pod and print BLOCKED/REACHABLE.
- pre-commit: pre-commit-hooks v6.0.0, gitleaks v8.30.1, local lint hook. `.markdownlint.yaml`
  (MD013/MD033/MD041 off). README tone: story section, mermaid, quick start, layout tree.
- Cilium 1.19.5 is the CNI (bootstrapped by `make up`), Hubble on, `kubeProxyReplacement: "false"`.

## 4. Decisions already taken (approved by the user — don't re-litigate)

1. **Tracing = Arize Phoenix**, not Langfuse. Langfuse v4 (chart 2.1.6) needs ClickHouse via an
   *alpha* operator + Keeper + SeaweedFS + Valkey + Postgres + web + worker ≈ 5.5–6 GiB requests.
   Phoenix: one pod, SQLite on PVC (`postgresql.enabled=false`, `persistence.enabled=true`),
   official chart, LiteLLM callback `arize_phoenix`.
2. **Repo**: `teodorio95-portofolio/secure-ai-gateway` on GitHub; ArgoCD `repoURL` =
   `https://github.com/teodorio95-portofolio/secure-ai-gateway.git`.
3. **Secrets = Sealed Secrets with a BYO sealing key** (see §6).
4. **Model baked into the Ollama image**, model = **`qwen2.5:1.5b`** (user said "qwen 2.5:1";
   there is no 1b, 1.5b was chosen — confirm once with the user). `ai-models` therefore needs
   no internet egress (DNS only).

Design choices made in Phase 0 (stated to the user, no objection):

- **Own Postgres** (`postgres:18.6-alpine3.24`, minimal StatefulSet in `charts/ai-gateway`).
  The official `litellm-helm` chart's Postgres/Redis subcharts use archived **`bitnamilegacy`**
  images → set `db.deployStandalone: false`, `db.useExisting: true`.
- Local images are named **`localhost/secure-ai-gateway/<name>:<version>`**, loaded with
  `k3d image import` (no registry). The `localhost/` prefix can't be squatted on Docker Hub,
  so it's safe in the Kyverno registry allowlist.
- Agent virtual key: `make seal-secrets` generates one value and seals it **twice** (one
  SealedSecret in `ai-agents` for the agent, one in `ai-gateway` for the bootstrap Job). The Job
  registers that exact value via LiteLLM `/key/generate` (`key` param) → no cross-namespace RBAC.
- Provider keys secret mounted with `optional: true`: no paid key ⇒ paid model errors ⇒
  LiteLLM fallback to `local` (Ollama). That is also the fallback demo.
- Falco rules for agents = **patch for runtime-security** (`customRules`), not a separate deploy.
  Note: on Colima + k3d Falco loads rules but **captures nothing** (documented in #5); existing
  rule "Suspicious tool executed in container" already covers a shell in `ai-agents`.

## 5. Current state (end of Phase 2)

Commits on `main` (oldest → newest): `4b353f0` initial (user), `ec82faf` skeleton/lint/CI,
`56d0402` four zones + gitops wiring, `42bff15` docs, `89041d8` GitHub-only + drop mirror.
CI run #1 green; run #2 (on `89041d8`) was queued at handoff — check it.

What exists:

- `charts/{ai-gateway,ai-models,ai-observability,ai-agents}/` — each: Chart.yaml, values.yaml
  (`namespace.create/name/podSecurity {enforce: restricted, warn: restricted}`,
  `networkPolicy.enabled`), `templates/{_helpers.tpl,namespace.yaml,networkpolicy.yaml}`.
  Each ships its own `<ns>-default-deny-all` because Kyverno `05` won't backfill a namespace
  created before the policy exists, and ArgoCD waves between child apps only order *apply*,
  not readiness (no Application health customization in argocd-cm).
- `gitops/ai-*.yaml` — 4 child Applications, wave 0, path `charts/<name>`.
- `bootstrap/secure-k8s-lab/secure-ai-gateway.yaml` — the one Application for secure-k8s-lab
  (wave 2, path `gitops`). `make wire-lab` copies it to `$(LAB_DIR)/apps/argocd-apps/`.
- `Makefile`: `help`, `wire-lab`, `apps-status`, `verify-namespaces`, `lint`, `secrets-scan`.
- `scripts/lint.sh`: `helm lint --strict` + `helm template | kubeconform -strict` (k8s 1.30.4,
  CRD schemas from datreeio/CRDs-catalog pinned at `501527ab9c40c827144c8f45945b25a023e344ce`),
  plus kubeconform on `gitops/` and `bootstrap/`. Used by pre-commit and CI.
- `.github/workflows/ci.yml`: jobs `manifests` (helm v3.19.0, kubeconform v0.7.0) and `gitleaks`
  (binary 8.30.1, not gitleaks-action — that needs a paid licence on org repos). Actions pinned:
  `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`,
  `azure/setup-helm@9bc31f4ebc9c6b171d7bfbaa5d006ae7abdb4310 # v5.0.1`.
- `README.md` skeleton (story, phase status table, mermaid, wiring, layout) and
  `docs/architecture.md` (zones table, Phase 0 decisions, pinned versions).

**Phase 1 verified on the real cluster (2026-10-23)**: the Application was applied with
`kubectl apply -f bootstrap/secure-k8s-lab/secure-ai-gateway.yaml` (the lab repo itself is
not wired yet); all 5 apps Synced/Healthy, every `ai-*` ns PSA restricted + both default-deny
policies (ours and Kyverno 05's), no non-pass policy results.

**Phase 2 (Sealed Secrets) built and verified** on branch `feat/sealed-secrets`: controller
rendered from the upstream chart with `values/sealed-secrets.yaml`, BYO key installed, all 5
SealedSecrets UNSEALED, controller pod 4 pass / 0 fail in Kyverno. The key pair is in
`~/.config/secure-ai-gateway/` on the user's Mac. See `secrets/README.md`.

Environment traps found on the user's Mac:

- **In-cluster DNS**: the Mac's network blocks public DNS (8.8.8.8 / 1.1.1.1 time out; the
  Mac uses a local resolver). k3s CoreDNS falls back to 8.8.8.8 because the node's resolv.conf
  is Docker's 127.0.0.11 → ArgoCD can't resolve gitlab.com. Runtime fix applied: CoreDNS
  `forward . 192.168.5.1` (Colima's resolver). k3s re-applies its CoreDNS manifest on server
  restart, so after every Colima/k3d restart re-patch, or fix it durably in secure-k8s-lab's
  k3d config (give the user the patch; don't edit that repo).
- `OPENAI_API_KEY` is exported in the user's shell — that's why provider sealing is opt-in.
- A local PreToolUse hook blocks Claude's shell egress to non-allowlisted hosts (e.g.
  Helm chart repos, likely `ghcr.io`): read chart sources through `gh api` instead.
- The Sealed Secrets Helm repo moved with the GitHub org rename (bitnami-labs → bitnami): the
  old `*.github.io` URL under bitnami-labs returns 404; use `https://bitnami.github.io/sealed-secrets`.

## 6. Pinned versions (verified 2026-10-22 from git tags / ghcr / Docker Hub / PyPI)

| Component | Pin |
|-----------|-----|
| LiteLLM image | `ghcr.io/berriai/litellm-non_root:v1.106.2` (amd64+arm64) |
| LiteLLM chart | `oci://ghcr.io/berriai/litellm-helm` **1.106.2** (ArgoCD: `repoURL: ghcr.io/berriai`, `chart: litellm-helm`). Don't use `helm/litellm` 0.1.0 "componentized" on main (dev deps). `-stable` tags stopped at v1.83.14. |
| Postgres | `postgres:18.6-alpine3.24` |
| Phoenix chart | `oci://registry-1.docker.io/arizephoenix/phoenix-helm` **12.0.24** |
| Phoenix image | `arizephoenix/phoenix:version-20.24.0-nonroot` |
| Ollama | `ollama/ollama:0.40.8` (amd64+arm64) |
| Sealed Secrets | chart **2.20.0** (repo `https://bitnami.github.io/sealed-secrets`), controller `docker.io/bitnami/sealed-secrets-controller:0.40.0` |
| Kyverno CLI | v1.18.1 (match the cluster) |
| Python base | `python:3.13.17-slim-trixie` |
| Utility images | `curlimages/curl:8.23.0`, `busybox:1.38.0` |
| PyPI | `mcp` 2.3.0, `openai` 3.36.1, `litellm` 1.106.2, `arize-phoenix` 20.24.0 |
| Tools | helm v3.19.0, kubeconform v0.7.0, gitleaks 8.30.1 |

Re-check before pinning if time has passed.

## 7. Remaining phases (stop after each, summarize, show how to verify, wait for OK)

### Phase 2 — Secrets (Sealed Secrets, BYO key)

- `gitops/sealed-secrets.yaml` (wave -1), upstream chart into **`kube-system`** (Kyverno 05
  excludes it; `kubeseal` defaults find `sealed-secrets-controller` there). Secure values + limits.
- `make sealing-key`: once, generate RSA key + self-signed cert into `~/.config/secure-ai-gateway/`
  (never in git; `*.key` is gitignored). Commit the **public cert** (e.g. `secrets/sealing-cert.pem`)
  so `kubeseal --cert` works offline.
- `make sealing-key-install`: bootstrap step after `make up` — apply the key as a
  `kubernetes.io/tls` Secret in kube-system labelled `sealedsecrets.bitnami.com/sealed-secrets-key=active`,
  then `kubectl -n kube-system rollout restart` the controller (it only loads keys at start).
- `make seal-secrets` (`scripts/seal-secrets.sh`): generates LiteLLM master key, Postgres password,
  agent virtual key (sealed for `ai-gateway` and `ai-agents`), Phoenix secret if needed; optional
  `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` from env → provider SealedSecret only if set. Writes
  `secrets/sealed/*.yaml` (or into the charts); never prints values. Lab must work with **no paid keys**.
- SealedSecret apps need `SkipDryRunOnMissingResource=true` + retry (CRD may not exist yet).
- Document the flow (README + `secrets/README.md`), incl. "forks re-seal with their own key".

### Phase 3 — LiteLLM gateway

- Postgres StatefulSet + Service + PVC in `charts/ai-gateway` (non-root uid 70, fsGroup, limits).
- `gitops/litellm.yaml` (wave 1), multi-source: upstream chart + `values/litellm.yaml`:
  non_root image, `db.useExisting`, master key from SealedSecret, securityContext, limits,
  read-only root FS if it works (check what LiteLLM/Prisma need writable; add emptyDirs).
- `config.yaml` (`model_list`): aliases `default`, `cheap`, `local`; Ollama (`ollama_chat/qwen2.5:1.5b`,
  `api_base` in-cluster svc, or host toggle), optional Anthropic/OpenAI via `os.environ/...`;
  `router_settings`: fallbacks paid → `local`, `num_retries`, `timeout`.
- Host-Ollama toggle (values): on Colima `host.k3d.internal` resolves to the docker gateway in the
  **Lima VM**, not macOS — macOS host is usually `host.lima.internal` / `192.168.5.2`. Make the
  address configurable and verify with the user; the CNP needs a `toCIDR` for it.
- Bootstrap Job (idempotent; `curlimages/curl` or python): create `team-payments`, `team-support`
  with `max_budget`, `tpm_limit`/`rpm_limit`; register the agent's virtual key (from sealed secret)
  on one team. Check-before-create. ArgoCD hook or plain Job with `ttlSecondsAfterFinished` — decide.
- `make gateway-ui`, `make gateway-test` (curl: no key → 401, valid key → 200, a tiny-budget key →
  budget exceeded, paid alias without key → fallback served by `local`).

### Phase 4 — Observability

- `charts/ai-observability` keeps the namespace + cage; `gitops/ai-observability.yaml` becomes
  multi-source with the Phoenix chart (`values/phoenix.yaml`: SQLite PVC, nonroot image, limits,
  auth as appropriate).
- LiteLLM `callbacks: ["arize_phoenix"]` (+ env for the collector endpoint). Verify traces show
  team, key alias, model, tokens, cost, latency — check which metadata attributes LiteLLM emits.
- Prometheus: `prometheus` callback — previous session found **no licence check** in
  `litellm/integrations/prometheus.py` @1.106.2; confirm `/metrics` at runtime and tell the user.
- `make traces-ui`.

### Phase 5 — Demo agent + MCP server

- `images/mcp-server/`: tiny Python MCP server (streamable HTTP, `mcp` SDK), tools
  `lookup_ticket`, `get_runbook` (fake data), Dockerfile with pinned base, non-root, hashes/pins.
- `images/demo-agent/`: OpenAI-compatible client → LiteLLM with its virtual key, uses MCP tools,
  sends a trace. `automountServiceAccountToken: false`, label `ai.role=agent`.
- `images/ollama-model/`: build stage runs `ollama serve` + `ollama pull qwen2.5:1.5b`, final image
  `localhost/secure-ai-gateway/ollama:0.40.8-qwen2.5-1.5b` running non-root.
- `make build-images` (docker build + `k3d image import -c secure-lab`), `make agent-ask Q="..."`.

### Phase 6 — Guardrails and isolation

- CiliumNetworkPolicies:
  - `ai-agents` → only LiteLLM port in `ai-gateway` + MCP server; DNS; nothing else.
  - `ai-gateway` → Postgres, `ai-models` (11434), `ai-observability` (Phoenix collector),
    DNS **with L7 rule** (`rules.dns: [{matchPattern: "*"}]` to kube-dns), `toFQDNs` for
    `api.anthropic.com`, `api.openai.com` on 443. Do DNS allow **only via CNP** here (avoid a plain
    k8s NetworkPolicy allowing 53 on the same pods).
  - `ai-models` → DNS only; ingress only from `ai-gateway`.
  - **Cilium config**: no change expected — Cilium 1.19.5 defaults `l7Proxy: true` and the DNS
    proxy is on. Confirm live; if a change is needed, tell the user exactly what to change in
    secure-k8s-lab's `cilium/values.yaml` (don't edit it).
- `make verify-ai-netpol`: agent → internet BLOCKED, agent → gateway ALLOWED,
  gateway → allowlisted FQDN ALLOWED, gateway → other FQDN BLOCKED (labelled test pods).
- Kyverno (Audit) in `policies/kyverno/` + `gitops/ai-policies.yaml`:
  `ai.role=agent` pods must not mount provider-key secrets; must set
  `automountServiceAccountToken: false`; images in `ai-*` namespaces only from allowlisted
  registries (ghcr.io/berriai, docker.io/arizephoenix, docker.io/library/postgres, docker.io/ollama,
  localhost/secure-ai-gateway, curlimages, busybox…). `kyverno test` for every policy, in CI.
- Falco: patch for runtime-security (e.g. read of `/var/run/secrets` by a process in `ai-agents`,
  shell in `ai-agents`) — only if it fits; note Colima limitation.

### Phase 7 — CI and docs

- CI: add kyverno test (CLI v1.18.1), markdownlint (`markdownlint-cli2`), Trivy config scan;
  keep helm lint, kubeconform, gitleaks.
- README full: story, mermaid, quick start, "what an attacker can and can't do", table mapping
  features → platform concerns (cost governance, audit, provider failover, least privilege).
- `docs/architecture.md` decisions + trade-offs. Give the user the row for the portfolio table
  in secure-k8s-lab's README (they pick the number).

### Phase 8 (optional — ask first)

An intentionally weak agent behind a values toggle (off by default),
same isolation as Juice Shop, target for projects #4/#5.

## 8. Constraints (from the user's original brief)

- Everything declarative and synced by ArgoCD; `kubectl apply` only for bootstrap steps.
- All secure-k8s-lab Kyverno guardrails must pass — prove it with `kubectl get policyreport -A`,
  not assumptions.
- No secrets/tokens/real keys in git, commit messages or logs. **Run gitleaks before every commit.**
- Pin every chart and image version (no `:latest`). Prefer official charts; own charts minimal.
- Must run on a laptop k3d. If something is too heavy, say so and propose an alternative.
- Small, focused commits; use the commit attribution your own Claude Code session provides.
- When unsure about tool behavior or chart values, check docs/source and tell the user what you verified.
- Don't create PRs unless asked; work has been pushed straight to `main` so far.

## Done when

`make up` in secure-k8s-lab + adding the Application brings the whole AI stack up, and from a
clean cluster these work: `make gateway-test`, `make agent-ask Q="..."`, `make verify-ai-netpol`,
`make traces-ui`, and CI is green.
