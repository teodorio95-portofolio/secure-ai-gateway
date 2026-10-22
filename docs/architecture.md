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

### Model delivery: baked into the image

The model (`qwen2.5:1.5b`) is pulled at **image build time** on the host and baked
into a local Ollama image (`localhost/secure-ai-gateway/...`, imported into k3d).
The `ai-models` namespace therefore never needs internet egress. The trade-off
is disk: the image exists in Docker and again in the k3d node.

## Pinned versions (verified 2026-10-22)

| Component | Version |
|-----------|---------|
| LiteLLM image (`ghcr.io/berriai/litellm-non_root`) | v1.106.2 |
| LiteLLM chart (`oci://ghcr.io/berriai/litellm-helm`) | 1.106.2 |
| Postgres (`postgres`) | 18.6-alpine3.24 |
| Arize Phoenix chart (`oci://registry-1.docker.io/arizephoenix/phoenix-helm`) | 12.0.24 |
| Arize Phoenix image | version-20.24.0-nonroot |
| Ollama (`ollama/ollama`) | 0.40.8 |
| Sealed Secrets chart / controller | 2.20.0 / 0.40.0 |
| Kyverno CLI (matches the cluster's chart 3.8.1) | v1.18.1 |
