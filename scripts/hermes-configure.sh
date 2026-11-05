# Runs INSIDE a Hermes container, fed on stdin (POSIX sh, no bash there):
#   kubectl -n ai-hermes exec -i deploy/hermes-<user> -- sh -s < scripts/hermes-configure.sh
#   docker compose ... exec -T hermes-<user> sh -s < scripts/hermes-configure.sh
# (make hermes-configure / make mac-configure). Uses the container's env:
#   LITELLM_BASE_URL  the gateway's OpenAI-compatible URL
#   LITELLM_MODEL     this person's Flash alias; suffixes -pro and -gpt select the others
#   OPENAI_API_KEY    this person's virtual key: only the ${...} template is written,
#                     Hermes expands it when it loads config.yaml
set -eu

key_ref='${OPENAI_API_KEY}'

hermes config set model.provider custom
hermes config set model.base_url "$LITELLM_BASE_URL"
hermes config set model.default "$LITELLM_MODEL-gpt"
hermes config set model.api_key "$key_ref"

# Hermes v0.22.7 probes a bare custom endpoint without its API key, leaving the
# dashboard picker with only the default model. A named provider with an explicit
# allowlist avoids that discovery path and keeps the other user's models hidden.
hermes config set --force providers.family \
  "{\"name\": \"Family\", \"base_url\": \"$LITELLM_BASE_URL\", \"key_env\": \"OPENAI_API_KEY\", \"models\": [\"$LITELLM_MODEL-gpt\", \"$LITELLM_MODEL\", \"$LITELLM_MODEL-pro\"], \"discover_models\": false}"

# `/model gpt`, `/model flash`, `/model pro` (`--once` for one question).
# --force: `config set` warns that model_aliases is unrecognized (it is missing
# from its defaults table), but the /model switcher reads exactly this key
# (hermes_cli/model_switch.py, _load_direct_aliases); `model_overrides`, the
# suggested key, is model metadata, not aliases.
for alias in flash pro gpt; do
  case $alias in
    flash) target=$LITELLM_MODEL ;;
    pro) target=$LITELLM_MODEL-pro ;;
    gpt) target=$LITELLM_MODEL-gpt ;;
  esac
  hermes config set --force "model_aliases.$alias" \
    "{\"model\": \"$target\", \"provider\": \"custom\", \"base_url\": \"$LITELLM_BASE_URL\", \"api_key\": \"$key_ref\"}"
done
echo "configured: default $LITELLM_MODEL-gpt, aliases gpt / flash / pro"
