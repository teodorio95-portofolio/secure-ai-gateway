#!/usr/bin/env bash
# End-to-end checks of the Mac stack through LiteLLM on 127.0.0.1:14000, with the
# keys from mac/.env (never printed). One real DeepSeek call per person: a few
# hundredths of a cent.
#   own key  -> own alias      200 (DeepSeek answers)
#   own key  -> other's alias  refused (each key only allows its own alias)
#   no key                     refused
set -uo pipefail

ENV_FILE="${ENV_FILE:-$(cd "$(dirname "$0")" && pwd)/.env}"
URL="${LITELLM_URL:-http://127.0.0.1:14000}"
[[ -f "$ENV_FILE" ]] || { echo "no $ENV_FILE - run make mac-secrets" >&2; exit 1; }
# shellcheck disable=SC1090
set -a && . "$ENV_FILE" && set +a

FAILED=0

# status <key or ""> <model>: HTTP status of a tiny chat completion.
status() {
  local auth=()
  [[ -n "$1" ]] && auth=(-H "Authorization: Bearer $1")
  curl -s -o /dev/null -w '%{http_code}' -m 60 "$URL/v1/chat/completions" "${auth[@]}" \
    -H 'Content-Type: application/json' \
    -d "{\"model\": \"$2\", \"max_tokens\": 5, \"messages\": [{\"role\": \"user\", \"content\": \"Spune doar: ok\"}]}"
}

# check <description> <got> <want: 200 | refused>
check() {
  local got=$2 verdict
  if [[ "$3" == 200 ]]; then [[ "$got" == 200 ]] && verdict=PASS || verdict=FAIL
  else [[ "$got" =~ ^4 ]] && verdict=PASS || verdict=FAIL; fi
  [[ $verdict == FAIL ]] && FAILED=1
  printf "%s  %-40s expected %-8s got %s\n" "$verdict" "$1" "$3" "$got"
}

check "teodor  -> chat-teodor"  "$(status "$TEODOR_KEY" chat-teodor)" 200
check "teodora -> chat-teodora" "$(status "$TEODORA_KEY" chat-teodora)" 200
check "teodor  -> chat-teodora" "$(status "$TEODOR_KEY" chat-teodora)" refused
check "teodora -> chat-teodor"  "$(status "$TEODORA_KEY" chat-teodor)" refused
check "no key  -> chat-teodor"  "$(status "" chat-teodor)" refused
exit "$FAILED"
