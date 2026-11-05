# Runs INSIDE a Hermes container, fed on stdin (POSIX sh, no bash there):
#   kubectl -n ai-hermes exec -i deploy/hermes-<user> -- sh -s < scripts/hermes-configure.sh
#   docker compose ... exec -T hermes-<user> sh -s < scripts/hermes-configure.sh
# (make hermes-configure / make mac-configure). Uses the container's env:
#   LITELLM_BASE_URL  the gateway's OpenAI-compatible URL
#   LITELLM_MODEL     this person's default alias, chat-<user>; chat-<user>-pro is the Pro one
#   OPENAI_API_KEY    this person's virtual key: only the ${...} template is written,
#                     Hermes expands it when it loads config.yaml
set -eu

key_ref='${OPENAI_API_KEY}'

hermes config set model.provider custom
hermes config set model.base_url "$LITELLM_BASE_URL"
hermes config set model.default "$LITELLM_MODEL"
hermes config set model.api_key "$key_ref"

# `/model flash` and `/model pro` in a chat (`/model pro --once` for one question).
for alias in flash pro; do
  case $alias in
    flash) target=$LITELLM_MODEL ;;
    pro) target=$LITELLM_MODEL-pro ;;
  esac
  hermes config set "model_aliases.$alias" \
    "{\"model\": \"$target\", \"provider\": \"custom\", \"base_url\": \"$LITELLM_BASE_URL\", \"api_key\": \"$key_ref\"}"
done
echo "configured: default $LITELLM_MODEL, aliases flash -> $LITELLM_MODEL, pro -> $LITELLM_MODEL-pro"
