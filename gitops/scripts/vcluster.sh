#!/usr/bin/env bash
# vcluster.sh — manage vClusters (virtual Kubernetes clusters) the GitOps way.
#
# Each vCluster is one Argo CD Application file in gitops/apps/ pointing at the
# upstream vcluster Helm chart. Creating/deleting a vCluster = adding/removing
# that file (this script also commits + pushes it for you, since git push is
# the deploy mechanism).
#
#   vcluster.sh create <name> [--port <nodeport>] [--no-push]
#   vcluster.sh kubeconfig <name>
#   vcluster.sh delete <name> [--yes] [--no-push]
#   vcluster.sh list
#
# The vCluster API is exposed on a pinned NodePort, so the kubeconfig works
# from anywhere on the LAN — no port-forward, no vcluster CLI. Kubeconfigs are
# written to ~/.kube/vcluster-<name>.yaml.
#
# Requires: kubectl (pointed at the host cluster) + git.
set -euo pipefail

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"
APPS_DIR="$REPO_ROOT/gitops/apps"

CHART_VERSION="0.35.1"          # https://github.com/loft-sh/vcluster/releases
API_SERVER_IP="192.168.40.171"  # control-plane VIP (kube-vip); a NodePort answers on any node IP
PORT_BASE=31800                 # first NodePort to try (valid range 30000-32767)

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

app_file()   { echo "$APPS_DIR/vcluster-$1.yaml"; }
kubeconfig_path() { echo "$HOME/.kube/vcluster-$1.yaml"; }

validate_name() {
  [[ "$1" =~ ^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$ ]] \
    || die "name must be lowercase alphanumeric/dashes (RFC 1123), max 32 chars"
}

# Next free NodePort: max of ports already claimed by vcluster-*.yaml files, +1.
# Each vCluster claims a pair: httpsNodePort=N, kubeletNodePort=N+1 (both pinned,
# otherwise the auto-assigned kubelet port keeps the Argo app permanently OutOfSync).
next_port() {
  local max=$((PORT_BASE - 1)) p
  for f in "$APPS_DIR"/vcluster-*.yaml; do
    [[ -e "$f" ]] || continue
    while read -r p; do
      [[ -n "$p" && "$p" -gt "$max" ]] && max=$p
    done < <(sed -n 's/.*\(https\|kubelet\)NodePort: \([0-9]*\).*/\2/p' "$f")
  done
  echo $((max + 1))
}

refresh_app_of_apps() {
  kubectl -n argocd annotate application app-of-apps \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

cmd_create() {
  local name="" port="" push=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      --no-push) push=false; shift ;;
      -*) die "unknown flag: $1" ;;
      *) name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || die "usage: vcluster.sh create <name> [--port <nodeport>] [--no-push]"
  validate_name "$name"
  local file; file=$(app_file "$name")
  [[ -e "$file" ]] && die "vCluster '$name' already exists ($file)"
  [[ -n "$port" ]] || port=$(next_port)
  [[ "$port" -ge 30000 && "$port" -le 32766 ]] || die "NodePort $port outside 30000-32766 (needs $port+1 too)"

  cat > "$file" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vcluster-$name
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://charts.loft.sh
    chart: vcluster
    targetRevision: $CHART_VERSION
    helm:
      releaseName: $name
      valuesObject:
        controlPlane:
          service:
            httpsNodePort: $port
            kubeletNodePort: $((port + 1))
            spec:
              type: NodePort
          proxy:
            extraSANs:
              - $API_SERVER_IP
        exportKubeConfig:
          context: vcluster-$name
          server: https://$API_SERVER_IP:$port
  destination:
    server: https://kubernetes.default.svc
    namespace: vcluster-$name
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
  info "wrote $file (API at https://$API_SERVER_IP:$port)"

  if ! $push; then
    info "skipping git (--no-push) — commit + push the file to deploy, then run: vcluster.sh kubeconfig $name"
    return
  fi

  git -C "$REPO_ROOT" add "$file"
  git -C "$REPO_ROOT" commit -q -m "vcluster: add $name (NodePort $port)" -- "$file"
  git -C "$REPO_ROOT" push -q
  info "pushed — waiting for Argo CD to bring vcluster-$name up (this pulls images on first run)"
  refresh_app_of_apps

  local deadline=$((SECONDS + 420))
  until kubectl -n "vcluster-$name" get secret "vc-$name" >/dev/null 2>&1; do
    [[ $SECONDS -lt $deadline ]] || die "timed out waiting for secret vc-$name — check: kubectl -n argocd get application vcluster-$name"
    sleep 5
  done
  # secret appears slightly before the API is ready; give the pod a moment
  kubectl -n "vcluster-$name" wait --for=condition=Ready pod -l app=vcluster,release="$name" --timeout=180s >/dev/null 2>&1 || true
  cmd_kubeconfig "$name"
}

cmd_kubeconfig() {
  local name="${1:-}"; [[ -n "$name" ]] || die "usage: vcluster.sh kubeconfig <name>"
  local out; out=$(kubeconfig_path "$name")
  kubectl -n "vcluster-$name" get secret "vc-$name" -o jsonpath='{.data.config}' 2>/dev/null | base64 -d > "$out" \
    || die "no kubeconfig secret vc-$name in namespace vcluster-$name — is the vCluster up?"
  [[ -s "$out" ]] || die "kubeconfig secret vc-$name was empty"
  chmod 600 "$out"
  info "kubeconfig written to $out"
  echo
  echo "  export KUBECONFIG=$out"
  echo "  kubectl get ns"
}

cmd_delete() {
  local name="" yes=false push=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=true; shift ;;
      --no-push) push=false; shift ;;
      -*) die "unknown flag: $1" ;;
      *) name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || die "usage: vcluster.sh delete <name> [--yes] [--no-push]"
  local file; file=$(app_file "$name")
  [[ -e "$file" ]] || die "no such vCluster: $name ($file not found)"

  if ! $yes; then
    read -r -p "Delete vCluster '$name' and ALL its data? [y/N] " ans
    [[ "$ans" == y || "$ans" == Y ]] || { echo "aborted"; exit 0; }
  fi

  if git -C "$REPO_ROOT" ls-files --error-unmatch "$file" >/dev/null 2>&1; then
    git -C "$REPO_ROOT" rm -q "$file"
    if ! $push; then
      info "removed $file (--no-push) — commit + push to delete the vCluster"
      return
    fi
    git -C "$REPO_ROOT" commit -q -m "vcluster: remove $name" -- "$file"
    git -C "$REPO_ROOT" push -q
    refresh_app_of_apps
    info "pushed — waiting for Argo CD to prune vcluster-$name"
    local deadline=$((SECONDS + 300))
    while kubectl -n argocd get application "vcluster-$name" >/dev/null 2>&1; do
      if [[ $SECONDS -ge $deadline ]]; then
        info "Argo didn't prune in time — deleting the Application directly"
        kubectl -n argocd delete application "vcluster-$name" --ignore-not-found
        break
      fi
      sleep 5
    done
  else
    # never committed (created with --no-push) — nothing to push, delete directly
    rm -f "$file"
    kubectl -n argocd delete application "vcluster-$name" --ignore-not-found
  fi
  # namespace + PVC aren't Argo-managed; clean them up
  kubectl delete namespace "vcluster-$name" --ignore-not-found
  rm -f "$(kubeconfig_path "$name")"
  info "vCluster '$name' deleted"
}

cmd_list() {
  local found=false f name port
  printf '%-16s %-6s %-10s %-10s %s\n' NAME PORT SYNC HEALTH KUBECONFIG
  for f in "$APPS_DIR"/vcluster-*.yaml; do
    [[ -e "$f" ]] || continue
    found=true
    name=$(basename "$f" .yaml); name=${name#vcluster-}
    port=$(sed -n 's/.*httpsNodePort: \([0-9]*\).*/\1/p' "$f" | head -1)
    read -r sync health < <(kubectl -n argocd get application "vcluster-$name" \
      -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null || echo "- -") || true
    printf '%-16s %-6s %-10s %-10s %s\n' "$name" "${port:--}" "${sync:--}" "${health:--}" "$(kubeconfig_path "$name")"
  done
  $found || echo "(no vClusters — create one with: vcluster.sh create <name>)"
}

case "${1:-}" in
  create)     shift; cmd_create "$@" ;;
  kubeconfig) shift; cmd_kubeconfig "$@" ;;
  delete)     shift; cmd_delete "$@" ;;
  list)       shift; cmd_list "$@" ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
