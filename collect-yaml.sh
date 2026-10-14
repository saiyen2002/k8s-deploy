#!/bin/bash
# collect-istio-yaml.sh
#
# Collect Istio, Gateway API, and core Kubernetes resources as YAML.
# Pure `kubectl get -o yaml` — no exec, no logs, no proxy dumps, no tar.
# Designed to stay reliable on large clusters where `istioctl bug-report`
# times out or fails.
#
# Output layout:
#   istio-config/<timestamp>/
#     cluster-scoped/<kind>.yaml        # global resources
#     namespaces/<ns>/<kind>.yaml       # namespaced resources
#
# Usage: collect-istio-yaml.sh [--context <ctx>] [--concurrency <n>] [--timeout <dur>] [namespace ...]

set -uo pipefail

REQUEST_TIMEOUT="30s"
MAX_CONCURRENT=5
CONTEXT=""
NAMESPACES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --context)     CONTEXT="$2"; shift 2 ;;
    --concurrency) MAX_CONCURRENT="$2"; shift 2 ;;
    --timeout)     REQUEST_TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--context <ctx>] [--concurrency <n>] [--timeout <dur>] [namespace ...]"
      exit 0 ;;
    *)             NAMESPACES="$NAMESPACES $1"; shift ;;
  esac
done
NAMESPACES=$(echo "$NAMESPACES" | xargs)

# Wrap kubectl so every call honours the optional --context (no spaces in
# context names, so unquoted expansion is safe here).
kctl() {
  kubectl ${CONTEXT:+--context "$CONTEXT"} "$@"
}

# --- Curated core Kubernetes kinds (group-qualified to avoid ambiguity) ---
CORE_NS=(
  pods services endpoints serviceaccounts configmaps secrets
  deployments.apps replicasets.apps daemonsets.apps statefulsets.apps
  horizontalpodautoscalers.autoscaling
  ingresses.networking.k8s.io networkpolicies.networking.k8s.io
  persistentvolumeclaims events
)
CORE_CLUSTER=(
  nodes namespaces
  customresourcedefinitions.apiextensions.k8s.io
  mutatingwebhookconfigurations.admissionregistration.k8s.io
  validatingwebhookconfigurations.admissionregistration.k8s.io
  persistentvolumes storageclasses.storage.k8s.io
)

# --- Identify the cluster we are collecting from ---
CONTEXT_NAME="${CONTEXT:-$(kubectl config current-context 2>/dev/null || echo "")}"
CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CONTEXT_NAME\")].context.cluster}" 2>/dev/null || echo "")
[ -z "$CLUSTER_NAME" ] && CLUSTER_NAME="$CONTEXT_NAME"
[ -z "$CLUSTER_NAME" ] && CLUSTER_NAME="unknown"
SERVER=$(kctl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
# Sanitise for use in a path (keep alnum . _ -; collapse the rest to '-').
CLUSTER_SLUG=$(printf '%s' "$CLUSTER_NAME" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')
[ -z "$CLUSTER_SLUG" ] && CLUSTER_SLUG="unknown"

OUTPUT_DIR="istio-config/${CLUSTER_SLUG}_$(date +%Y%m%d-%H%M%S)"
CLUSTER_DIR="$OUTPUT_DIR/cluster-scoped"
NS_BASE="$OUTPUT_DIR/namespaces"
mkdir -p "$CLUSTER_DIR" "$NS_BASE"
ERROR_LOG="$OUTPUT_DIR/errors.log"
: > "$ERROR_LOG"

log_error() { echo "[ERROR] $1" >> "$ERROR_LOG"; }

# Count non-empty lines in a (possibly empty/multiline) string.
count() { printf '%s\n' "$1" | grep -c . 2>/dev/null || true; }

# Throttle background jobs to MAX_CONCURRENT.
wait_for_slot() {
  while [ "$(jobs -r | wc -l)" -ge "$MAX_CONCURRENT" ]; do
    sleep 0.2
  done
}

# get_resource <outfile> <desc> <kubectl-get-args...>
# Writes YAML to <outfile>. Skips empty lists. Logs (never aborts) on failure.
get_resource() {
  local outfile="$1"; local desc="$2"; shift 2
  local tmp err
  tmp=$(mktemp); err=$(mktemp)
  if kctl get "$@" -o yaml --request-timeout="$REQUEST_TIMEOUT" >"$tmp" 2>"$err"; then
    if grep -q '^items: \[\]' "$tmp" 2>/dev/null; then
      :  # empty list — skip so we don't litter empty files
    else
      mv "$tmp" "$outfile"
    fi
  else
    log_error "$desc: $(tr '\n' ' ' <"$err" | sed 's/  */ /g')"
  fi
  rm -f "$tmp" "$err"
}

# --- Discover Istio & Gateway API resource types dynamically ---
echo "==> Discovering Istio & Gateway API resource types"
ISTIO_FILTER='\.istio\.io$|\.gateway\.networking\.k8s\.io$'
ISTIO_NS_RES=$(kctl api-resources --namespaced=true  --verbs=list -o name 2>/dev/null | grep -E "$ISTIO_FILTER" | sort -u || true)
ISTIO_CLUSTER_RES=$(kctl api-resources --namespaced=false --verbs=list -o name 2>/dev/null | grep -E "$ISTIO_FILTER" | sort -u || true)
echo "   Namespaced:     $(count "$ISTIO_NS_RES") Istio/Gateway kind(s)"
echo "   Cluster-scoped: $(count "$ISTIO_CLUSTER_RES") Istio/Gateway kind(s)"

# --- Resolve target namespaces ---
if [ -z "$NAMESPACES" ]; then
  NAMESPACES=$(kctl get namespaces -o jsonpath='{.items[*].metadata.name}' --request-timeout="$REQUEST_TIMEOUT" 2>/dev/null || true)
fi
NS_COUNT=$(count "$NAMESPACES" | head -1)
[ -z "$NS_COUNT" ] && NS_COUNT=$(printf '%s' "$NAMESPACES" | wc -w | xargs)

echo "============================================"
echo " Istio / K8s YAML Collector"
echo "============================================"
echo "Cluster:      $CLUSTER_NAME"
echo "Context:      ${CONTEXT_NAME:-<current>}"
echo "Server:       ${SERVER:-<unknown>}"
echo "Namespaces:   $(printf '%s' "$NAMESPACES" | wc -w | xargs)"
echo "Concurrency:  $MAX_CONCURRENT"
echo "Timeout:      $REQUEST_TIMEOUT per request"
echo "Output:       $OUTPUT_DIR"
echo "============================================"

# --- Record what/where this dump came from ---
{
  echo "cluster:    $CLUSTER_NAME"
  echo "context:    $CONTEXT_NAME"
  echo "server:     $SERVER"
  echo "collected:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "namespaces: $(printf '%s' "$NAMESPACES" | wc -w | xargs)"
} > "$OUTPUT_DIR/collection-info.txt"

# --- Cluster-scoped resources (parallel, throttled) ---
echo "==> Collecting cluster-scoped resources"
for RES in "${CORE_CLUSTER[@]}" $ISTIO_CLUSTER_RES; do
  wait_for_slot
  get_resource "$CLUSTER_DIR/$RES.yaml" "cluster-scoped/$RES" "$RES" &
done
wait

# --- Namespaced resources (parallel across namespaces, throttled globally) ---
for NS in $NAMESPACES; do
  NS_DIR="$NS_BASE/$NS"
  mkdir -p "$NS_DIR"
  echo "==> Namespace: $NS"
  for RES in "${CORE_NS[@]}" $ISTIO_NS_RES; do
    wait_for_slot
    get_resource "$NS_DIR/$RES.yaml" "$NS/$RES" "$RES" -n "$NS" &
  done
done
wait

# --- Cleanup empty namespace directories ---
find "$OUTPUT_DIR" -type d -empty -delete 2>/dev/null || true

# --- Summary ---
FILE_COUNT=$(find "$OUTPUT_DIR" -type f -name '*.yaml' 2>/dev/null | wc -l | xargs)
DIR_SIZE=$(du -sh "$OUTPUT_DIR" 2>/dev/null | awk '{print $1}')
ERR_COUNT=$(grep -c '^\[ERROR\]' "$ERROR_LOG" 2>/dev/null || true); ERR_COUNT=${ERR_COUNT:-0}

echo ""
echo "============================================"
echo " Done: $FILE_COUNT YAML file(s), $DIR_SIZE"
echo " Output: $OUTPUT_DIR"
if [ "$ERR_COUNT" -gt 0 ]; then
  echo " WARNING: $ERR_COUNT error(s) — see $ERROR_LOG"
else
  rm -f "$ERROR_LOG"
  echo " No errors."
fi
echo "============================================"
