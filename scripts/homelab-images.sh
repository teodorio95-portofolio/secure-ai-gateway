#!/usr/bin/env bash
# Build the local images ON the homelab mini PC and import them into its k3s.
# Runs from the Mac (`make homelab-images`): the Mac is arm64, the mini PC is
# amd64, so building there avoids emulating the Ollama model pull.
#
# Copies images/ + the remote half of this script over Tailscale SSH, then runs
# it with sudo (one password prompt). Never touches a registry.
set -euo pipefail

host="${HOMELAB_USER:?}@${HOMELAB_HOST:?}"
model="${HOMELAB_MODEL:?}"
ollama_img="${HOMELAB_OLLAMA_IMAGE:?}"
mcp_img="${MCP_IMAGE:?}"
agent_img="${AGENT_IMAGE:?}"
remote_dir="secure-ai-gateway-images"

echo "==> Copying build contexts to $host:$remote_dir"
rsync -a --delete images/ scripts/homelab-build-remote.sh "$host:$remote_dir/"

echo "==> Building on $host ($model) and importing into k3s"
ssh -t "$host" sudo bash "$remote_dir/homelab-build-remote.sh" \
  "$remote_dir" "$model" "$ollama_img" "$mcp_img" "$agent_img"
