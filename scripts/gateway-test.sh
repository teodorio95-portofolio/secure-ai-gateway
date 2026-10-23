#!/usr/bin/env bash
# End-to-end checks against the LiteLLM gateway through a port-forward.
# Keys are read from the cluster into variables and never printed; the two
# temporary keys this script creates are deleted on exit.
set -uo pipefail

NS="${NS:-ai-gateway}"
PORT="${PORT:-4000}"
URL="http://127.0.0.1:${PORT}"
FAILED=0

secret() { kubectl -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d; }
MASTER=$(secret "$NS" litellm-masterkey masterkey)
AGENT=$(secret ai-agents agent-virtual-key api-key)

kubectl -n "$NS" port-forward svc/litellm "${PORT}:4000" >/dev/null 2>&1 &
PF=$!
TMP_KEYS=()
cleanup() {
  for k in "${TMP_KEYS[@]}"; do
    curl -s -o /dev/null -X POST "$URL/key/delete" -H "Authorization: Bearer $MASTER" \
      -H 'Content-Type: application/json' -d "{\"keys\": [\"$k\"]}"
  done
  kill "$PF" 2>/dev/null
}
trap cleanup EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null "$URL/health/liveliness" && break; sleep 1; done

# chat <key> <model>: prints "<http status> <served model> <attempted fallbacks>"
chat() {
  local auth=()
  [[ -n "$1" ]] && auth=(-H "Authorization: Bearer $1")
  curl -s -o /tmp/gw-body.$$ -D /tmp/gw-head.$$ -w '%{http_code}' "$URL/v1/chat/completions" \
    "${auth[@]}" -H 'Content-Type: application/json' \
    -d "{\"model\": \"$2\", \"max_tokens\": 16, \"messages\": [{\"role\": \"user\", \"content\": \"Say pong.\"}]}" \
    >/tmp/gw-code.$$
  local served fb
  served=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model","-"))' /tmp/gw-body.$$ 2>/dev/null || echo -)
  fb=$(grep -i '^x-litellm-attempted-fallbacks:' /tmp/gw-head.$$ | tr -d '\r' | awk '{print $2}')
  echo "$(cat /tmp/gw-code.$$) ${served} ${fb:-0}"
  rm -f /tmp/gw-body.$$ /tmp/gw-head.$$ /tmp/gw-code.$$
}

# new_key <team alias> <json extras>: creates a temporary key, prints it.
new_key() {
  local team_id key
  team_id=$(curl -s "$URL/team/list" -H "Authorization: Bearer $MASTER" |
    python3 -c 'import json,sys; print(next(t["team_id"] for t in json.load(sys.stdin) if t["team_alias"]==sys.argv[1]))' "$1")
  key=$(curl -s -X POST "$URL/key/generate" -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
    -d "{\"team_id\": \"$team_id\", \"key_alias\": \"gateway-test-$RANDOM\", $2}" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
  echo "$key"
}

check() { # check <name> <condition result 0/1> <detail>
  if [[ "$2" == 0 ]]; then printf "PASS  %-48s %s\n" "$1" "$3"; else printf "FAIL  %-48s %s\n" "$1" "$3"; FAILED=1; fi
}

r=$(chat "" local)
[[ ${r%% *} == 401 ]]; check "no key -> 401" $? "($r)"

r=$(chat "$AGENT" local)
[[ ${r%% *} == 200 ]]; check "agent key, model local -> 200" $? "($r)"

r=$(chat "$AGENT" default)
[[ ${r%% *} =~ ^(401|403)$ ]]; check "agent key, model default -> denied (team scope)" $? "($r)"

PAID=$(new_key team-payments '"models": ["default", "cheap", "local"]')
TMP_KEYS+=("$PAID")
r=$(chat "$PAID" default)
read -r code served fb <<<"$r"
[[ $code == 200 && $served == *qwen* ]]; check "paid alias, no provider key -> served by local" $? "($r)"

TINY=$(new_key team-payments '"models": ["local"], "max_budget": 0.000001')
TMP_KEYS+=("$TINY")
r1=$(chat "$TINY" local)
r2=""
for _ in $(seq 1 10); do # spend is written asynchronously
  sleep 3
  r2=$(chat "$TINY" local)
  [[ ${r2%% *} != 200 ]] && break
done
[[ ${r1%% *} == 200 && ${r2%% *} =~ ^(400|429)$ ]]; check "tiny budget -> first ok, then budget exceeded" $? "($r1 | $r2)"

exit "$FAILED"
