#!/usr/bin/env bash
# Render every chart and validate it + the ArgoCD Applications against the
# Kubernetes / CRD JSON schemas. Same script runs locally (make lint) and in CI.
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.30.4}"  # matches cluster/k3d-config.yaml in secure-k8s-lab
# CRD schemas (Application, CiliumNetworkPolicy, SealedSecret, ...) pinned to a
# known commit of the community catalog.
CRD_CATALOG="https://raw.githubusercontent.com/datreeio/CRDs-catalog/501527ab9c40c827144c8f45945b25a023e344ce"

kc() {
  kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" \
    -schema-location default \
    -schema-location "$CRD_CATALOG/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    "$@"
}

for chart in charts/*/; do
  echo "==> helm lint $chart"
  helm lint --strict "$chart"
  echo "==> kubeconform $chart"
  helm template "$(basename "$chart")" "$chart" | kc -
done

echo "==> kubeconform gitops/ + bootstrap/"
kc gitops bootstrap
