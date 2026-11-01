#!/usr/bin/env bash
# Remote half of scripts/homelab-images.sh: runs as root ON the homelab.
# Builds the three local images with Docker and imports them into k3s's
# containerd (k8s.io namespace), where `imagePullPolicy: Never` pods find them.
set -euo pipefail

dir="$1" model="$2" ollama_img="$3" mcp_img="$4" agent_img="$5"

docker build --build-arg MODEL="$model" -t "$ollama_img" "$dir/ollama-model"
docker build -t "$mcp_img" "$dir/mcp-server"
docker build -t "$agent_img" "$dir/demo-agent"

echo "==> Importing into k3s (containerd, namespace k8s.io)"
docker save "$ollama_img" "$mcp_img" "$agent_img" | k3s ctr -n k8s.io images import -
k3s crictl images | grep secure-ai-gateway
