#!/usr/bin/env bash
# Pause/resume the media-reencode worker without touching replicas or the
# NFS share by hand. Both Deployments (amd64 + arm64) read the same
# STATE dir on the shared NFS mount, so reaching any one running pod is
# enough to pause the whole fleet.
#
# Mechanism: STATE/pause is checked between files (not mid-encode), so
# "off" lets the current file finish before the worker idles.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/repos/k8s-fun/kubeconfig}"

NS=media-reencode
PAUSE=/media/.reencode/pause

pod() {
  kubectl get pod -n "$NS" -l 'app in (media-reencode,media-reencode-arm)' \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'
}

usage() { echo "usage: $0 {on|off|status}" >&2; exit 1; }

cmd="${1:-status}"
p=$(pod) || true
if [ -z "${p:-}" ]; then
  echo "no running media-reencode pod found" >&2
  exit 1
fi

case "$cmd" in
  off|pause)
    kubectl exec -n "$NS" "$p" -- touch "$PAUSE"
    echo "paused -- finishes the file in progress, then idles"
    ;;
  on|resume)
    kubectl exec -n "$NS" "$p" -- rm -f "$PAUSE"
    echo "resumed"
    ;;
  status)
    if kubectl exec -n "$NS" "$p" -- test -f "$PAUSE" 2>/dev/null; then
      echo "paused"
    else
      echo "running"
    fi
    ;;
  *)
    usage
    ;;
esac
