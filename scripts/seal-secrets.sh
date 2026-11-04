#!/usr/bin/env bash
# Generate the AI stack's secrets and seal them with the committed public cert
# (offline — no cluster needed). Values live only in memory: they are fed to
# kubectl through a process substitution (never argv, never a file) and the
# script prints file names only, never values.
#
# Idempotent: an existing sealed file is kept, because rotating e.g. the
# Postgres password would no longer match the database already on the PVC.
# ROTATE=1 re-seals everything with fresh values (wipe the PVCs alongside).
#
# Optional paid providers are opt-in: WITH_PROVIDERS=1 seals whichever of
# ANTHROPIC_API_KEY / OPENAI_API_KEY / DEEPSEEK_API_KEY is set into
# llm-provider-keys (re-sealed on every such run). Opt-in so a key that merely
# happens to be in your shell is never picked up. Without it the lab runs on the
# local model only.
#
# The family's Hermes (homelab, charts/ai-hermes) is opt-in too: WITH_HERMES=1
# makes, per person in HERMES_USERS, a LiteLLM virtual key (sealed for
# ai-gateway in family-virtual-keys and for ai-hermes in hermes-<user>) and a
# dashboard login. The login is what the Hermex app asks for, so it is also
# written to ~/.config/secure-ai-gateway/hermes-<user>.env (0600, never in git).
set -euo pipefail

CERT="${CERT:-secrets/sealing-cert.pem}"
OUT="${OUT:-secrets/sealed}"
ROTATE="${ROTATE:-0}"

[[ -f "$CERT" ]] || { echo "No sealing cert at $CERT — run 'make sealing-key' first." >&2; exit 1; }
mkdir -p "$OUT"

rand_hex() { openssl rand -hex "$1"; }

# seal <namespace> <name> KEY=VALUE...  → SealedSecret YAML on stdout.
# --scope strict (default): the ciphertext only decrypts as this name in this
# namespace, so a sealed file can't be replayed into another namespace.
seal() {
  local ns=$1 name=$2
  shift 2
  kubectl create secret generic "$name" --namespace "$ns" \
    --from-env-file=<(printf '%s\n' "$@") --dry-run=client -o json \
    | kubeseal --cert "$CERT" --format yaml
}

# write_once <file> <cmd...>: run cmd into file unless it exists (and !ROTATE).
write_once() {
  local file="$OUT/$1"
  shift
  if [[ -f "$file" && "$ROTATE" != "1" ]]; then
    echo "kept    $file"
    return
  fi
  "$@" >"$file.tmp"
  mv "$file.tmp" "$file"
  echo "sealed  $file"
}

# LiteLLM admin key. LiteLLM requires the sk- prefix.
masterkey() { seal ai-gateway litellm-masterkey "masterkey=sk-$(rand_hex 24)"; }

# One credential shared by our Postgres (POSTGRES_PASSWORD) and LiteLLM
# (db.useExisting reads username/password keys).
postgres() { seal ai-gateway litellm-postgres "username=litellm" "password=$(rand_hex 24)"; }

# The demo agent's virtual key: one value, sealed for both namespaces. The
# bootstrap Job in ai-gateway registers it via /key/generate; the agent in
# ai-agents presents it. No cross-namespace secret reads needed.
agent_key() {
  local key
  key="sk-$(rand_hex 24)"
  seal ai-gateway agent-virtual-key "api-key=$key"
  seal ai-agents agent-virtual-key "api-key=$key"
}

# Phoenix (auth on, chart's createSecret off: a chart-generated random secret
# would change on every ArgoCD render). The chart maps every key below to an
# env var; the Postgres/SMTP ones are unused here but must exist.
# The admin secret is also Phoenix's system bearer token: sealed a second time
# for ai-gateway as PHOENIX_API_KEY, so LiteLLM can send traces.
phoenix() {
  local admin
  admin=$(rand_hex 32)
  seal ai-observability phoenix-secret \
    "PHOENIX_SECRET=$(rand_hex 32)" \
    "PHOENIX_ADMIN_SECRET=$admin" \
    "PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD=$(rand_hex 16)" \
    "PHOENIX_POSTGRES_PASSWORD=$(rand_hex 16)" \
    "PHOENIX_SMTP_PASSWORD=$(rand_hex 16)"
  seal ai-gateway phoenix-api-key "PHOENIX_API_KEY=$admin"
}

# hermes_users: one virtual key + dashboard login per person, all sealed in one
# go so the key in family-virtual-keys and in hermes-<user> stay the same.
hermes_users() {
  local users local_dir="${HERMES_LOGIN_DIR:-$HOME/.config/secure-ai-gateway}"
  read -r -a users <<<"${HERMES_USERS:-teodor teodora}"
  local files=("$OUT/ai-gateway-family-virtual-keys.yaml")
  local u
  for u in "${users[@]}"; do files+=("$OUT/ai-hermes-hermes-$u.yaml" "$local_dir/hermes-$u.env"); done
  local missing=0 f
  for f in "${files[@]}"; do [[ -f "$f" ]] || missing=1; done
  if ((missing == 0)) && [[ "$ROTATE" != "1" ]]; then
    echo "kept    family-virtual-keys + hermes-<user> for: ${users[*]}"
    return
  fi
  mkdir -p "$local_dir"
  chmod 700 "$local_dir"
  local pairs=() key password
  for u in "${users[@]}"; do
    key="sk-$(rand_hex 24)"
    password=$(rand_hex 16)
    pairs+=("$u=$key")
    seal ai-hermes "hermes-$u" \
      "OPENAI_API_KEY=$key" \
      "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$u" \
      "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$password" \
      "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(rand_hex 32)" >"$OUT/ai-hermes-hermes-$u.yaml"
    (umask 077 && printf 'username=%s\npassword=%s\n' "$u" "$password" >"$local_dir/hermes-$u.env")
    echo "sealed  $OUT/ai-hermes-hermes-$u.yaml (login in $local_dir/hermes-$u.env)"
  done
  seal ai-gateway family-virtual-keys "${pairs[@]}" >"$OUT/ai-gateway-family-virtual-keys.yaml"
  echo "sealed  $OUT/ai-gateway-family-virtual-keys.yaml"
}

write_once ai-gateway-litellm-masterkey.yaml masterkey
write_once ai-gateway-litellm-postgres.yaml postgres
write_once agent-virtual-key.yaml agent_key
write_once phoenix-secret.yaml phoenix

if [[ "${WITH_HERMES:-0}" == "1" ]]; then
  hermes_users
else
  echo "skipped family Hermes secrets (WITH_HERMES=1 not set — homelab only)"
fi

if [[ "${WITH_PROVIDERS:-0}" != "1" ]]; then
  echo "skipped llm-provider-keys (WITH_PROVIDERS=1 not set — local model only)"
  exit 0
fi
providers=()
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && providers+=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
[[ -n "${OPENAI_API_KEY:-}" ]] && providers+=("OPENAI_API_KEY=$OPENAI_API_KEY")
[[ -n "${DEEPSEEK_API_KEY:-}" ]] && providers+=("DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY")
if ((${#providers[@]} == 0)); then
  echo "WITH_PROVIDERS=1 but none of ANTHROPIC_API_KEY / OPENAI_API_KEY / DEEPSEEK_API_KEY is set" >&2
  exit 1
fi
seal ai-gateway llm-provider-keys "${providers[@]}" >"$OUT/ai-gateway-llm-provider-keys.yaml"
echo "sealed  $OUT/ai-gateway-llm-provider-keys.yaml (${#providers[@]} provider key(s))"
