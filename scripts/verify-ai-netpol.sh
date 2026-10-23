#!/usr/bin/env bash
# Prove the AI network cage with throwaway curl pods that carry the same
# labels as the real workloads, so the same CiliumNetworkPolicies apply.
# Each line: what was tried, what we expect, what happened.
set -uo pipefail

IMAGE="curlimages/curl:8.23.0@sha256:11e64e28c5f58c8d93ee95fcf22ac055f48b0bc440e0ce7d8013bbb5ad6aa8ac"
FAILED=0

# probe <namespace> <labels> <url>: prints the HTTP status, or 000 if it never connected.
probe() {
  local ns=$1 labels=$2 url=$3
  local overrides
  overrides=$(cat <<EOF
{"spec": {
  "automountServiceAccountToken": false,
  "securityContext": {"runAsNonRoot": true, "runAsUser": 100, "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{
    "name": "probe", "image": "$IMAGE",
    "args": ["-s", "-k", "-o", "/dev/null", "-m", "6", "-w", "%{http_code}", "$url"],
    "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true,
                        "capabilities": {"drop": ["ALL"]}},
    "resources": {"limits": {"cpu": "100m", "memory": "64Mi"}}
  }]
}}
EOF
)
  kubectl -n "$ns" run "netpol-probe-$RANDOM" --rm -i --restart=Never --quiet \
    --image="$IMAGE" --labels="$labels" --overrides="$overrides" 2>/dev/null | grep -oE '[0-9]{3}' | tail -1
}

# check <description> <namespace> <labels> <url> <BLOCKED|REACHABLE>
check() {
  local code got
  code=$(probe "$2" "$3" "$4")
  if [[ -z "$code" || "$code" == 000 ]]; then got=BLOCKED; else got=REACHABLE; fi
  if [[ "$got" == "$5" ]]; then printf "PASS  "; else printf "FAIL  "; FAILED=1; fi
  printf "%-42s expected %-9s got %-9s (http %s)\n" "$1" "$5" "$got" "${code:-none}"
}

AGENT="ai.role=agent"
GATEWAY="app.kubernetes.io/name=litellm"

check "agent -> internet (example.com)"        ai-agents  "$AGENT"   https://example.com BLOCKED
check "agent -> gateway (LiteLLM :4000)"       ai-agents  "$AGENT"   http://litellm.ai-gateway.svc.cluster.local:4000/health/liveliness REACHABLE
check "agent -> Ollama directly (bypass)"      ai-agents  "$AGENT"   http://ollama.ai-models.svc.cluster.local:11434/ BLOCKED
check "agent -> Kubernetes API"                ai-agents  "$AGENT"   https://kubernetes.default.svc/version BLOCKED
check "gateway -> api.anthropic.com (allowed)" ai-gateway "$GATEWAY" https://api.anthropic.com/ REACHABLE
check "gateway -> example.com (not allowed)"   ai-gateway "$GATEWAY" https://example.com BLOCKED
check "models zone -> internet (ollama.com)"   ai-models  "ai.role=netpol-probe" https://ollama.com BLOCKED

exit "$FAILED"
