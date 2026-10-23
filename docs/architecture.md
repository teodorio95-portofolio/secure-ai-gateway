# Architecture & design decisions

## How it plugs into secure-k8s-lab

secure-k8s-lab's root app-of-apps gets one extra `Application`
([bootstrap/secure-k8s-lab/secure-ai-gateway.yaml](../bootstrap/secure-k8s-lab/secure-ai-gateway.yaml)),
which syncs [gitops/](../gitops/) from this repo. Every file there is a child
`Application`, so the whole AI stack is declarative and pruned/self-healed by
ArgoCD — the same cross-repo pattern as `runtime-security`.

## Four zones, four namespaces

| Namespace | Holds | May talk to |
|-----------|-------|-------------|
| `ai-agents` | demo agent, MCP server | LiteLLM port, MCP server |
| `ai-gateway` | LiteLLM, Postgres | Postgres, `ai-models`, `ai-observability`, FQDN allowlist |
| `ai-models` | Ollama | DNS only |
| `ai-observability` | Arize Phoenix | (ingress from the gateway only) |

Each zone is our own minimal chart that templates the namespace (Pod Security
`restricted`) **and** a default-deny NetworkPolicy. Explicit allows are added as
`CiliumNetworkPolicy` objects.

**Why the chart carries its own default-deny** even though secure-k8s-lab's
Kyverno policy `05` generates one: that policy uses `generateExisting: false`,
and ArgoCD sync waves between child Applications only order the *apply*, not
readiness. If a namespace is created before the generate policy exists, Kyverno
never backfills it. Shipping the deny with the chart removes that race; when
Kyverno's copy exists too, the two are identical in effect.

## Decisions taken in phase 0

### Tracing: Arize Phoenix instead of Langfuse

Langfuse v4 (chart 2.1.6) needs ClickHouse through an **alpha** operator
(`clickhouse.com/v1alpha1`) plus Keeper, SeaweedFS (S3), Valkey, Postgres, a web
and a worker pod — about 5.5–6 GiB of *requests* with the chart defaults, on top
of the existing lab. Phoenix is a single pod (SQLite on a PVC), has an official
chart, speaks OpenTelemetry natively and has a first-class LiteLLM callback
(`arize_phoenix`). It still shows model, tokens, cost and latency per call.

### Postgres: our own, not the LiteLLM chart's subchart

The official `litellm-helm` chart pulls Postgres from Bitnami's
**`bitnamilegacy`** images — archived builds that no longer receive patches. The
gateway's database instead runs the official `postgres` image in a minimal
StatefulSet, and LiteLLM uses it via `db.useExisting`.

### Secrets: Sealed Secrets with a bring-your-own sealing key

Sealed Secrets needs no external backend, which suits a laptop lab. The sealing
key pair is generated once and kept **outside the repo**
(`~/.config/secure-ai-gateway/`), then installed into each fresh cluster — so the
SealedSecrets committed here stay decryptable across `make down && make up`.
Forks re-seal with their own key.

How it's wired (phase 2):

- The controller runs in **`kube-system`** (`gitops/sealed-secrets.yaml`, wave
  -1): `kubeseal` finds `sealed-secrets-controller` there without flags, and
  Kyverno `05` doesn't drop a default-deny on it. The upstream chart is already
  non-root / read-only / drop-ALL; our values add limits and the pod-level
  `runAsNonRoot` that Kyverno `02` checks.
- **Automatic key renewal is off** (`keyrenewperiod: "0"`). With renewal on, the
  controller would mint a new key every 30 days; old keys would keep decrypting,
  but the cluster would drift from the "one key, kept outside git" model.
- Sealing is **offline** (`kubeseal --cert secrets/sealing-cert.pem`) with strict
  scope: a ciphertext only opens under its own name and namespace.
- The key is installed with `kubectl apply --server-side`, so the private key
  isn't duplicated into a `last-applied-configuration` annotation.
- `ai-secrets` is a plain directory Application over `secrets/sealed/` with
  `SkipDryRunOnMissingResource` and retry/backoff: child-app waves order the
  apply, not readiness, so the CRD or a namespace may arrive a few seconds later.
- `seal-secrets.sh` is idempotent, because rotating the Postgres password blindly
  would break the database already on the PVC. Values reach `kubectl` through a
  process substitution (never argv, never a file) and are never printed. Paid
  provider keys are opt-in (`WITH_PROVIDERS=1`), so a key that just happens to be
  exported in the shell is never sealed by accident.

### Model delivery: baked into the image

The model (`qwen2.5:1.5b`) is pulled at **image build time** on the host and baked
into a local Ollama image (`localhost/secure-ai-gateway/...`, imported into k3d).
The `ai-models` namespace therefore never needs internet egress. The trade-off
is disk: the image exists in Docker and again in the k3d node.

The upstream image is ~7 GB, 3.6 GB of it CUDA/JetPack libraries a CPU-only k3d
node never loads. The final build stage copies only the `ollama` binary and its
CPU libraries onto the same Ubuntu 24.04 base: **9 GB → 2.2 GB** with the model.

## Phase 3: the gateway

### Model aliases and failover

| Alias | Backend | Without a paid key |
|-------|---------|--------------------|
| `default` | `anthropic/claude-sonnet-5-5` | falls back to `cheap`, then `local` |
| `cheap` | `openai/gpt-6-luna` | falls back to `local` |
| `local` | `ollama_chat/qwen2.5:1.5b` in `ai-models` | always available |

Clients only ever see aliases, so swapping a provider is a config change, not a
client change. The `local` model is priced at an internal **chargeback rate**
($1 / $2 per million input / output tokens), so budgets, spend tracking and the
budget-exceeded path all work in a lab with zero paid keys.

### Teams, keys, budgets

The PostSync bootstrap Job (`values/litellm-bootstrap.yaml`) creates
`team-payments` (budget $5 / 30 days, all aliases) and `team-support` ($1, no
`default`), each with token and request rate limits, and registers the demo
agent's virtual key on `team-support` ($0.50, `cheap` + `local`). It looks each
object up before creating it, so every sync is safe to re-run, and it reuses
the proxy image (Python is already there — no extra image to pull or allow).

### Network cage (this phase's part)

| From | To | Why |
|------|----|-----|
| LiteLLM | Postgres :5432 | its database |
| LiteLLM | `ollama.ai-models` :11434 | the local model |
| LiteLLM | kube-dns :53 via Cilium's DNS proxy | needed for `toFQDNs` |
| LiteLLM | `api.anthropic.com`, `api.openai.com` :443 | paid providers, nothing else |
| bootstrap Job | LiteLLM :4000 | admin API |
| Ollama | — | **no egress at all**, not even DNS |

The policies ship in `charts/ai-gateway` (wave 0), not in the LiteLLM app: the
chart's Prisma migrations Job is a **PreSync** hook, so it runs before anything
in the LiteLLM app's own sync phase and must already reach Postgres. LiteLLM
also tries to fetch its model cost map from GitHub at start-up;
`LITELLM_LOCAL_MODEL_COST_MAP=True` uses the copy bundled in the image instead.

### Things that bit (and the fix)

- The chart mounts writable `emptyDir`s for a read-only root FS **only in the
  Deployment**. The migrations Job crashed with "No usable temporary directory";
  a shared `/var/tmp` volume (Python's second candidate) fixes both pods without
  clashing with the chart's own `/tmp` mount.
- The migrations Job is OOMKilled at 1 GiB right after `prisma migrate deploy`
  succeeds; it gets 2 GiB.
- ArgoCD fetches the OCI chart from `ghcr.io` without a repository secret
  (checked on ArgoCD v3.4.4).

## Pinned versions (verified 2026-10-22; Sealed Secrets re-checked 2026-10-23)

| Component | Version |
|-----------|---------|
| LiteLLM image (`ghcr.io/berriai/litellm-non_root`) | v1.106.2 |
| LiteLLM chart (`oci://ghcr.io/berriai/litellm-helm`) | 1.106.2 |
| Postgres (`postgres`) | 18.6-alpine3.24 |
| Arize Phoenix chart (`oci://registry-1.docker.io/arizephoenix/phoenix-helm`) | 12.0.24 |
| Arize Phoenix image | version-20.24.0-nonroot |
| Ollama (`ollama/ollama`) | 0.40.8 (runtime copied onto `ubuntu:24.04`) |
| Model | `qwen2.5:1.5b` |
| Sealed Secrets chart / controller | 2.20.0 / 0.40.0 |
| Kyverno CLI (matches the cluster's chart 3.8.1) | v1.18.1 |
