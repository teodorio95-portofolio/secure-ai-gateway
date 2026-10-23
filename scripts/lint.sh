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

echo "==> kubeconform gitops/ + bootstrap/ + secrets/sealed/"
kc gitops bootstrap secrets/sealed

# Upstream charts with our values: repo, chart, version and value files are read
# from the multi-source Applications themselves, so the pins live in one place.
# Needs network + yq; LINT_UPSTREAM=0 skips it (offline pre-commit runs).
if [[ "${LINT_UPSTREAM:-1}" == "0" ]]; then
  echo "==> upstream charts: skipped (LINT_UPSTREAM=0)"
  exit 0
fi
for app in gitops/*.yaml; do
  src='.spec.sources[] | select(has("chart"))'
  chart=$(yq "$src | .chart" "$app")
  [[ -n "$chart" ]] || continue
  repo=$(yq "$src | .repoURL" "$app")
  version=$(yq "$src | .targetRevision" "$app")
  release=$(yq "$src | .helm.releaseName // \"$chart\"" "$app")
  ns=$(yq '.spec.destination.namespace' "$app")
  args=()
  while read -r vf; do
    args+=(-f "${vf#\$sag/}")
  done < <(yq "$src | .helm.valueFiles[]" "$app")
  if [[ "$repo" == http* ]]; then
    ref=(--repo "$repo" "$chart")
  else
    ref=("oci://$repo/$chart")
  fi
  echo "==> kubeconform $chart $version (from $app)"
  helm template "$release" "${ref[@]}" --version "$version" -n "$ns" "${args[@]}" | kc -
done
