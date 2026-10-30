#!/usr/bin/env bash

set -euo pipefail

# Debug logging - set DEBUG=1 to enable
DEBUG=${DEBUG:-0}

# Smoke test - set SMOKE_TEST=1 to run LoadBalancer connectivity test per cluster
SMOKE_TEST=${SMOKE_TEST:-0}

# Parallel cluster creation - set PARALLEL=1 to enable
PARALLEL=${PARALLEL:-0}

# Show live prefixed output in parallel mode (default: log files with summary)
PARALLEL_LIVE=${PARALLEL_LIVE:-0}

log_debug() {
  if [[ "${DEBUG}" == "1" ]]; then
    echo "[DEBUG] $(date '+%H:%M:%S') $*" >&2
  fi
}

log_info() {
  echo "[INFO] $*"
}

log_error() {
  echo "[ERROR] $*" >&2
}

usage() {
  cat <<EOF
Usage: $0 [CLUSTER_COUNT] [NODES_PER_CLUSTER] [REGION]
       $0 add COUNT [--region REGION] [--nodes NODES]

Commands:
  (default)          Create a fresh environment, deleting existing clusters
  add COUNT          Add COUNT new clusters to existing environment

Arguments (default mode):
  CLUSTER_COUNT      Number of clusters (default: 3)
  NODES_PER_CLUSTER  Worker nodes per cluster (default: 1)
  REGION             AWS-style region for all clusters (default: eu-west-2)

Arguments (add mode):
  COUNT              Number of clusters to add
  --region REGION    Region for new clusters (default: eu-west-2)
  --nodes NODES      Worker nodes per cluster (default: 1)

Environment Variables:
  REGIONS            Comma-separated regions (cycles for new clusters)
  DEBUG              Set to 1 for debug logging
  SMOKE_TEST         Set to 1 to run LoadBalancer connectivity test per cluster
  PARALLEL           Set to 1 for parallel cluster creation (2-3x faster)
  PARALLEL_LIVE      Set to 1 for live prefixed output in parallel mode (default: log files)
  KIND_IMAGE         Override the kind node image
  METALLB_VERSION    Override MetalLB version (default: v0.14.8)

Examples (default mode):
  $0 3 2 us-west-1                   # 3 clusters, 2 nodes, us-west-1
  $0 2                               # 2 clusters, 1 node, eu-west-2
  REGIONS="us-west-1,eu-west-2" $0 2 # 2 clusters in different regions

Examples (add mode):
  $0 add 2                           # Add 2 clusters with default region
  $0 add 1 --region ap-south-1       # Add 1 cluster in ap-south-1
  REGIONS="eu-west-1,ap-south-1" $0 add 2  # Add 2 clusters, cycling regions
EOF
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

# Subcommand handling
ADD_MODE=""
if [[ "${1:-}" == "add" ]]; then
  ADD_MODE=1
  shift  # Remove "add" from arguments

  # In add mode, first arg is cluster count
  CLUSTER_COUNT=${1:-1}
  shift || true

  # Parse optional flags
  NODES_PER_CLUSTER=1
  REGION=eu-west-2
  while [[ $# -gt 0 ]]; do
    case $1 in
      --region)
        REGION="$2"
        shift 2
        ;;
      --nodes)
        NODES_PER_CLUSTER="$2"
        shift 2
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done
fi

# Node images, newest first. Digests are the multi-arch manifest lists taken from
# the kind release notes that published them, so they are the exact images that
# kind version is tested against. "needs kind" is that minimum kind version -
# an image newer than your kind binary can fail at `kubeadm init` because the
# kubeadm config API version kind writes is no longer accepted.
#
# Check yours with `kind version`; upgrade with `brew upgrade kind`.
# Allow override via environment variable
KIND_IMAGE=${KIND_IMAGE:-kindest/node:v1.32.0@sha256:c48c62eac5da28cdadcf560d1d8616cfa6783b58f0d94cf63ad1bf49600cb027}
METALLB_VERSION=${METALLB_VERSION:-v0.14.8}

# --- needs kind v0.33.0 or newer -------------------------------------------
# v1.37.0:
# KIND_IMAGE=kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5

# v1.36.4:
# KIND_IMAGE=kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed

# v1.35.8:
# KIND_IMAGE=kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0

# v1.34.11:
# KIND_IMAGE=kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d

# --- needs kind v0.32.0 or newer -------------------------------------------
# v1.36.1:
# KIND_IMAGE=kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5

# v1.35.5:
# KIND_IMAGE=kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95

# v1.34.8:
# KIND_IMAGE=kindest/node:v1.34.8@sha256:02722c2dedddcfc00febf5d27fbeb9b7b2c14294c82109ff4a85d89ac9ba3256

# v1.33.12:
# KIND_IMAGE=kindest/node:v1.33.12@sha256:3f5c8443c620245e4d355cfe09e96a91ead32ceaa569d3f1ca9edf0cb2fe2ff4

# --- needs kind v0.31.0 or newer -------------------------------------------
# v1.35.0:
# KIND_IMAGE=kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f

# v1.34.3:
# KIND_IMAGE=kindest/node:v1.34.3@sha256:08497ee19eace7b4b5348db5c6a1591d7752b164530a36f855cb0f2bdcbadd48

# v1.33.7:
# KIND_IMAGE=kindest/node:v1.33.7@sha256:d26ef333bdb2cbe9862a0f7c3803ecc7b4303d8cea8e814b481b09949d353040

# v1.32.11:
# KIND_IMAGE=kindest/node:v1.32.11@sha256:5fc52d52a7b9574015299724bd68f183702956aa4a2116ae75a63cb574b35af8

# v1.31.14:
# KIND_IMAGE=kindest/node:v1.31.14@sha256:6f86cf509dbb42767b6e79debc3f2c32e4ee01386f0489b3b2be24b0a55aac2b

# --- work with kind v0.30.0 (the version this script was last run with) ----
# v1.34.0:
# KIND_IMAGE=kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a

# v1.33.4:
# KIND_IMAGE=kindest/node:v1.33.4@sha256:25a6018e48dfcaee478f4a59af81157a437f15e6e140bf103f85a2e7cd0cbbf2

# v1.32.8:
# KIND_IMAGE=kindest/node:v1.32.8@sha256:abd489f042d2b644e2d033f5c2d900bc707798d075e8186cb65e3f1367a9d5a1

# v1.31.12:
# KIND_IMAGE=kindest/node:v1.31.12@sha256:0f5cc49c5e73c0c2bb6e2df56e7df189240d83cf94edfa30946482eb08ec57d2

# --- older, pre-built for kind v0.26 ---------------------------------------
# v1.32.0:
# KIND_IMAGE=kindest/node:v1.32.0@sha256:c48c62eac5da28cdadcf560d1d8616cfa6783b58f0d94cf63ad1bf49600cb027

# v1.31.4:
# KIND_IMAGE=kindest/node:v1.31.4@sha256:2cb39f7295fe7eafee0842b1052a599a4fb0f8bcf3f83d96c7f4864c357c6c30

# v1.30.8:
#KIND_IMAGE=kindest/node:v1.30.8@sha256:17cd608b3971338d9180b00776cb766c50d0a0b6b904ab4ff52fd3fc5c6369bf

# v1.29.12:
# KIND_IMAGE=kindest/node:v1.29.12@sha256:62c0672ba99a4afd7396512848d6fc382906b8f33349ae68fb1dbfe549f70dec


# Skip positional args in add mode (already parsed above)
if [[ -z "${ADD_MODE}" ]]; then
  CLUSTER_COUNT=${1:-3}
  NODES_PER_CLUSTER=${2:-1}
  REGION=${3:-eu-west-2}
fi

CPUMAX=$(((${CLUSTER_COUNT} + 1) * 2))
CPUS=$((CPUMAX > 6 ? 6 : CPUMAX))
MEMMAX=$(((${CLUSTER_COUNT} + 2) * 4))
MEMORY=$((MEMMAX > 20 ? 20 : MEMMAX))

if ! [ "${CLUSTER_COUNT}" -eq "${CLUSTER_COUNT}" ] 2>/dev/null || [ "${CLUSTER_COUNT}" -le 0 ]; then
  echo "[ERROR] Number of clusters must be > 0"
  exit 1
fi

if ! [ "${NODES_PER_CLUSTER}" -eq "${NODES_PER_CLUSTER}" ] 2>/dev/null || [ "${NODES_PER_CLUSTER}" -le 0 ]; then
  echo "[ERROR] Number of nodes per cluster must be > 0"
  exit 2
fi

if ! (type colima >/dev/null 2>&1 && type docker >/dev/null 2>&1 && type kind >/dev/null 2>&1 && type kubectl >/dev/null 2>&1 && type jq >/dev/null 2>&1); then
  echo "[ERROR] colima, docker, kind, kubectl and jq must be installed"
  exit 3
fi

# Multi-region support: REGIONS env var overrides single REGION
# Format: REGIONS="us-west-1,eu-west-2,ap-south-1"
if [[ -n "${REGIONS:-}" ]]; then
  IFS=',' read -ra REGION_ARRAY <<< "${REGIONS}"
  REGION_COUNT=${#REGION_ARRAY[@]}
  if [[ ${REGION_COUNT} -ne ${CLUSTER_COUNT} ]]; then
    log_info "WARN: ${REGION_COUNT} regions specified but creating ${CLUSTER_COUNT} clusters - regions will cycle"
  fi
fi

# Helper function to get region for a cluster (supports cycling)
get_cluster_region() {
  local cluster_idx=$1
  if [[ -n "${REGIONS:-}" ]]; then
    # Cycle through regions if fewer than clusters
    echo "${REGION_ARRAY[$((cluster_idx % REGION_COUNT))]}"
  else
    echo "${REGION}"
  fi
}

# Create a single cluster - used by both sequential and parallel modes
# Arguments: CLUSTER_INDEX ACTUAL_CLUSTER_NUM CONTEXT_NAME CLUSTER_NAME NODES_IN_THIS_CLUSTER
# Required global vars: KIND_IMAGE, CONTAINERD_REGISTRY_MIRRORS, METALLB_VERSION, NETWORK_PREFIX, REGISTRY_PORT, SMOKE_TEST
create_single_cluster() {
  local CLUSTER_INDEX=$1
  local ACTUAL_CLUSTER_NUM=$2
  local CONTEXT_NAME=$3
  local CLUSTER_NAME=$4
  local NODES_IN_THIS_CLUSTER=$5
  local STATUS_FILE=${6:-}

  local CLUSTER_REGION
  CLUSTER_REGION=$(get_cluster_region ${ACTUAL_CLUSTER_NUM})
  log_debug "Cluster ${CLUSTER_NAME}: region=${CLUSTER_REGION}"

  local CLUSTER_CONFIG_FILE=/tmp/k8s-${CLUSTER_NAME}-config.yaml

  cat <<EOF >$CLUSTER_CONFIG_FILE
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
EOF

  local NODE_INDEX=-1
  while [ $((++NODE_INDEX)) -lt ${NODES_IN_THIS_CLUSTER} ]; do
    local ZONE=${CLUSTER_REGION}$(echo $(((${ACTUAL_CLUSTER_NUM} + ${NODE_INDEX}) % 3)) | tr 012 abc)

    if [ "${NODE_INDEX}" == 0 ]; then
      cat <<EOF >>$CLUSTER_CONFIG_FILE
- role: control-plane
  image: ${KIND_IMAGE}
EOF
    else
      cat <<EOF >>$CLUSTER_CONFIG_FILE
- role: worker
  image: ${KIND_IMAGE}
EOF
    fi

    cat <<EOF >>$CLUSTER_CONFIG_FILE
  labels:
    ingress-ready: true
    topology.kubernetes.io/region: ${CLUSTER_REGION}
    topology.kubernetes.io/zone: ${ZONE}
EOF
  done

  cat <<EOF >>$CLUSTER_CONFIG_FILE
containerdConfigPatches:
- |-
$(echo -e "${CONTAINERD_REGISTRY_MIRRORS}")
EOF

  kind create cluster --name ${CLUSTER_NAME} --config ${CLUSTER_CONFIG_FILE} --wait 120s
  rm ${CLUSTER_CONFIG_FILE}

  # Serialize kubeconfig modifications (race condition protection)
  # Use mkdir as portable atomic lock (works on macOS and Linux)
  local LOCK_DIR="/tmp/kubeconfig.lock"
  local MAX_WAIT=30
  local waited=0
  while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [[ $waited -ge $((MAX_WAIT * 10)) ]]; then
      log_error "Timeout waiting for kubeconfig lock"
      rm -rf "${LOCK_DIR}" 2>/dev/null || true
      mkdir "${LOCK_DIR}" 2>/dev/null || true
      break
    fi
  done
  # Ensure we clean up lock on exit from this subshell
  trap "rm -rf ${LOCK_DIR} 2>/dev/null" EXIT
  kubectl config delete-context ${CONTEXT_NAME} >/dev/null 2>&1 || true
  kubectl config rename-context kind-${CLUSTER_NAME} ${CONTEXT_NAME}
  rm -rf "${LOCK_DIR}" 2>/dev/null || true
  trap - EXIT

  kubectl --context=${CONTEXT_NAME} apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

  printf "Installing MetalLB...\n"
  kubectl --context ${CONTEXT_NAME} apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml >/dev/null
  printf "Waiting for MetalLB...\n"
  kubectl --context ${CONTEXT_NAME} -n metallb-system wait --for=jsonpath='{.status.readyReplicas}'=1 --timeout=120s deploy/controller

  local LB_RANGE_START=${NETWORK_PREFIX}.$((${ACTUAL_CLUSTER_NUM} + 10)).1
  local LB_RANGE_END=${NETWORK_PREFIX}.$((${ACTUAL_CLUSTER_NUM} + 10)).254

  printf "Configuring MetalLB with IP range ${LB_RANGE_START}-${LB_RANGE_END}...\n"
  kubectl --context ${CONTEXT_NAME} apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: pool
  namespace: metallb-system
spec:
  addresses:
  - ${LB_RANGE_START}-${LB_RANGE_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2
  namespace: metallb-system
EOF

  # Smoke test: deploy echo-server, expose via LoadBalancer, verify connectivity
  if [[ "${SMOKE_TEST}" == "1" ]]; then
    printf "Running smoke test for ${CONTEXT_NAME}...\n"

    # Deploy ealen/echo-server with cluster info as env vars
    kubectl --context ${CONTEXT_NAME} apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smoke-test
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: smoke-test
  template:
    metadata:
      labels:
        app: smoke-test
    spec:
      containers:
      - name: echo
        image: ealen/echo-server:0.9.2
        ports:
        - containerPort: 80
        env:
        - name: PORT
          value: "80"
        - name: CLUSTER_NAME
          value: "${CLUSTER_NAME}"
        - name: CONTEXT_NAME
          value: "${CONTEXT_NAME}"
        - name: REGION
          value: "${CLUSTER_REGION}"
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
---
apiVersion: v1
kind: Service
metadata:
  name: smoke-test
  namespace: default
spec:
  type: LoadBalancer
  selector:
    app: smoke-test
  ports:
  - port: 80
    targetPort: 80
EOF

    # Wait for deployment to be ready
    kubectl --context ${CONTEXT_NAME} rollout status deployment/smoke-test --timeout=60s >/dev/null 2>&1 || true

    # Wait for external IP (up to 60s)
    printf "Waiting for LoadBalancer IP..."
    local EXTERNAL_IP=""
    for i in {1..30}; do
      EXTERNAL_IP=$(kubectl --context ${CONTEXT_NAME} get svc smoke-test -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
      if [[ -n "${EXTERNAL_IP}" ]]; then
        break
      fi
      printf "."
      sleep 2
    done
    echo ""

    if [[ -z "${EXTERNAL_IP}" ]]; then
      log_error "Smoke test FAILED: No external IP assigned within 60s"
      [[ -n "${STATUS_FILE}" ]] && echo "FAILED" > "${STATUS_FILE}"
      return 1
    else
      # Test connectivity and show cluster info
      local RESPONSE
      RESPONSE=$(curl -sf --connect-timeout 5 "http://${EXTERNAL_IP}/?echo_env_body=CLUSTER_NAME,CONTEXT_NAME,REGION,NODE_NAME" 2>/dev/null) || true
      if [[ -n "${RESPONSE}" ]]; then
        log_info "Smoke test PASSED: ${CONTEXT_NAME} @ ${EXTERNAL_IP}"
        log_debug "Response: ${RESPONSE}"
      else
        log_error "Smoke test FAILED: Could not reach ${EXTERNAL_IP}"
        [[ -n "${STATUS_FILE}" ]] && echo "FAILED" > "${STATUS_FILE}"
        # Cleanup before returning
        kubectl --context ${CONTEXT_NAME} delete deployment,svc smoke-test --ignore-not-found >/dev/null 2>&1
        return 1
      fi
    fi

    # Cleanup
    kubectl --context ${CONTEXT_NAME} delete deployment,svc smoke-test --ignore-not-found >/dev/null 2>&1
  fi

  printf "\nFinished creating cluster ${CLUSTER_NAME}. "
  printf "You can alias this with:\n  alias k${CLUSTER_INDEX}=\"kubectl --context ${CONTEXT_NAME}\"\n\n"

  # Write success status if status file provided (parallel mode)
  [[ -n "${STATUS_FILE}" ]] && echo "SUCCESS" > "${STATUS_FILE}"
  return 0
}

# Find the highest existing cluster number for the given prefix
get_next_cluster_number() {
  local prefix=$1
  local max_num=0
  for cluster in $(kind get clusters 2>/dev/null); do
    if [[ "${cluster}" == ${prefix}cluster* ]]; then
      # Extract number from cluster name (e.g., gloo-cluster3 -> 3)
      num=${cluster##*cluster}
      if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -gt $max_num ]]; then
        max_num=$num
      fi
    fi
  done
  echo $((max_num + 1))
}

cleanup() {
  log_error "Script failed. Check logs above for details."
}
trap cleanup ERR

COLIMA_PROFILE=gloo
# echo "--- colima profile: ${COLIMA_PROFILE}"
# colima list
# VM_INFO=$(colima list -p ${COLIMA_PROFILE} -j)

# if [ -z "${VM_INFO}" ]; then
#   printf "Creating VM for \"${COLIMA_PROFILE}\"...\n"

#   colima start -t vz -c${CPUS} -m${MEMORY} -d40 --network-address=true ${COLIMA_PROFILE}
#   STARTED_VM=1
# elif [ $(jq -n -r ${VM_INFO}.status) != "Running" ]; then

#   printf "Starting existing \"${COLIMA_PROFILE}\" VM...\n"
#   colima restart ${COLIMA_PROFILE}
#   STARTED_VM=1
# else
#   printf "\"${COLIMA_PROFILE}\" VM is already running\n"
# fi

echo "--- colima profile: ${COLIMA_PROFILE}"
colima list
EXISTING_PROFILES=$(colima list | awk 'NR>1 {print $1}') # Skip header row and print the first column (Profile)

profile_exists=false
while IFS= read -r profile; do
  if [[ "$profile" == "$COLIMA_PROFILE" ]]; then
    profile_exists=true
    break
  fi
done <<< "$EXISTING_PROFILES"

if ! "$profile_exists"; then
  printf "Creating VM for \"${COLIMA_PROFILE}\"...\n"
  colima start -t vz -c"${CPUS}" -m"${MEMORY}" -d250 --network-address=true "${COLIMA_PROFILE}"
  STARTED_VM=1
else
  VM_INFO=$(colima list -p "${COLIMA_PROFILE}" -j)
  if [ "$(jq -n -r "${VM_INFO}".status)" != "Running" ]; then
    printf "Starting existing \"${COLIMA_PROFILE}\" VM...\n"
    colima restart "${COLIMA_PROFILE}"
    STARTED_VM=1
  else
    printf "\"${COLIMA_PROFILE}\" VM is already running\n"
  fi
fi





# inotify limits are a per-UID pool shared by every kind node container in the VM,
# not a per-container one. The old value of 512 instances is exhausted somewhere
# around 4 clusters and surfaces as kube-proxy CrashLoopBackOff with
#   "failed complete: too many open files"
# which then cascades into coredns NotReady, local-path-provisioner restarts, and
# metallb failing (no service VIP -> controller can't reach 10.96.0.1 -> it never
# creates the "memberlist" secret -> speaker stuck in ContainerCreating).
# These are kind's own recommended values.
INOTIFY_MAX_USER_WATCHES=${INOTIFY_MAX_USER_WATCHES:-1048576}
INOTIFY_MAX_USER_INSTANCES=${INOTIFY_MAX_USER_INSTANCES:-8192}

log_info "Setting inotify limits in the VM (watches=${INOTIFY_MAX_USER_WATCHES}, instances=${INOTIFY_MAX_USER_INSTANCES})"

# Persist across VM restarts, so a `colima restart` outside this script keeps them.
colima ssh -p ${COLIMA_PROFILE} -- sudo tee /etc/sysctl.d/99-kind-inotify.conf >/dev/null <<EOF
fs.inotify.max_user_watches = ${INOTIFY_MAX_USER_WATCHES}
fs.inotify.max_user_instances = ${INOTIFY_MAX_USER_INSTANCES}
EOF

# Apply now, without needing a restart.
colima ssh -p ${COLIMA_PROFILE} -- sudo sysctl -q \
  fs.inotify.max_user_watches=${INOTIFY_MAX_USER_WATCHES} \
  fs.inotify.max_user_instances=${INOTIFY_MAX_USER_INSTANCES}

# Fail fast with a clear message rather than letting kube-proxy crashloop later.
INOTIFY_APPLIED=$(colima ssh -p ${COLIMA_PROFILE} -- sysctl -n fs.inotify.max_user_instances)
if [ "${INOTIFY_APPLIED}" -lt "${INOTIFY_MAX_USER_INSTANCES}" ]; then
  log_error "fs.inotify.max_user_instances is ${INOTIFY_APPLIED}, expected ${INOTIFY_MAX_USER_INSTANCES}"
  log_error "Clusters will come up with kube-proxy in CrashLoopBackOff (\"too many open files\")"
  exit 5
fi
log_debug "inotify max_user_instances = ${INOTIFY_APPLIED}"

HOST_IF=col0
DOCKER_HOST_IP=$(colima ssh -p ${COLIMA_PROFILE} -- ip -4 addr show ${HOST_IF} 2>/dev/null | grep inet | awk -F' ' '{print $2 }' | cut -d/ -f1)

if [ -z "${DOCKER_HOST_IP}" ]; then
  echo "[ERROR] No IP address was assigned to the Docker host"
  echo "[ERROR] Consider running \`colima ssh -p ${COLIMA_PROFILE} -- sudo ip address add 192.168.106.2/24 broadcast + dev ${HOST_IF}\`"
  echo "[ERROR] then re-running this script"
  exit 4
fi

docker context use colima-${COLIMA_PROFILE}

DOCKER_NETWORK=kind
docker network create \
  -o "com.docker.network.bridge.enable_ip_masquerade"="true" \
  -o "com.docker.network.driver.mtu"="1500" \
  ${DOCKER_NETWORK} || true
export KIND_EXPERIMENTAL_DOCKER_NETWORK=${DOCKER_NETWORK}
NETWORK_PREFIX=$(docker network inspect ${DOCKER_NETWORK} | jq -r '.[0].IPAM.Config[0].Subnet' | cut -d'.' -f1-2)

printf "Setting up image registries...\n"

# Local registry first...
REGISTRY_NAME=local-registry
REGISTRY_PORT=5000

REGISTRY_RUNNING="$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)"
if [ "${REGISTRY_RUNNING}" != 'true' ]; then
  docker run -d --restart=always \
    -p "0.0.0.0:${REGISTRY_PORT}:${REGISTRY_PORT}" \
    --name "${REGISTRY_NAME}" \
    --network ${DOCKER_NETWORK} \
    registry:2
fi

CONTAINERD_REGISTRY_MIRRORS="  [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"localhost:${REGISTRY_PORT}\"]
    endpoint = [\"http://${REGISTRY_NAME}:${REGISTRY_PORT}\"]"

# ...then remote mirrors
REGISTRIES="docker https://registry-1.docker.io docker.io
gcr https://gcr.io
quay https://quay.io
artifact-registry https://us-docker.pkg.dev
ghcr https://ghcr.io"
CACHE_PORT=5000

REGISTRY_CONFIG_DIR=${HOME}/.registry_cache
mkdir -p ${REGISTRY_CONFIG_DIR}

while read cache_name cache_url cache_alias; do

  REGISTRY_RUNNING=$(docker inspect -f '{{.State.Running}}' "${cache_name}" 2>/dev/null || true)
  if [ "${REGISTRY_RUNNING}" = 'true' ]; then
    docker network connect ${DOCKER_NETWORK} ${cache_name} 2>/dev/null || true
  else
    CACHE_CONFIG_FILE=${REGISTRY_CONFIG_DIR}/${cache_name}-config.yml
    cat <<EOF >${CACHE_CONFIG_FILE}
version: 0.1
proxy:
  remoteurl: ${cache_url}
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :${CACHE_PORT}
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
    printf "Starting \"${cache_name}\" cache: "
    docker run -d --restart=always \
      -v ${CACHE_CONFIG_FILE}:/etc/docker/registry/config.yml \
      --name "${cache_name}" \
      --network ${DOCKER_NETWORK} \
      registry:2
  fi

  CACHE_ALIAS=${cache_alias:=$(echo ${cache_url#*//})}
  REGISTRY_MIRROR_LINE_1="[plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"${CACHE_ALIAS}\"]"
  REGISTRY_MIRROR_LINE_2="endpoint = [\"http://${cache_name}:${CACHE_PORT}\"]"
  REGISTRY_MIRROR_LINE_3="[plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${CACHE_ALIAS}\".tls]"
  REGISTRY_MIRROR_LINE_4="insecure_skip_verify = true"
  CONTAINERD_REGISTRY_MIRRORS="${CONTAINERD_REGISTRY_MIRRORS}\n  ${REGISTRY_MIRROR_LINE_1}\n    ${REGISTRY_MIRROR_LINE_2}\n  ${REGISTRY_MIRROR_LINE_3}\n    ${REGISTRY_MIRROR_LINE_4}"

done <<<"${REGISTRIES}"

printf "Creating ${CLUSTER_COUNT} Kubernetes cluster(s)...\n"
CLUSTER_PREFIX=gloo-

if [[ -z "${ADD_MODE}" ]]; then
  log_info "Deleting existing Kubernetes clusters matching prefix '${CLUSTER_PREFIX:-<all>}'..."
  for cluster in $(kind get clusters 2>/dev/null); do
    if [[ -z "${CLUSTER_PREFIX}" ]] || [[ "${cluster}" == ${CLUSTER_PREFIX}* ]]; then
      log_debug "Deleting cluster: ${cluster}"
      kind delete cluster --name "${cluster}"
    fi
  done
fi

# In add mode, find the next available cluster number
if [[ -n "${ADD_MODE}" ]]; then
  START_CLUSTER_NUM=$(get_next_cluster_number "${CLUSTER_PREFIX}")
  log_info "Adding ${CLUSTER_COUNT} cluster(s) starting from cluster${START_CLUSTER_NUM}..."
else
  START_CLUSTER_NUM=0
fi

# Build list of clusters to create
declare -a CLUSTER_SPECS=()
CLUSTER_INDEX=-1
while [ $((++CLUSTER_INDEX)) -lt ${CLUSTER_COUNT} ]; do
  ACTUAL_CLUSTER_NUM=$((START_CLUSTER_NUM + CLUSTER_INDEX))

  NODES_IN_THIS_CLUSTER=${NODES_PER_CLUSTER}
  if [[ -z "${ADD_MODE}" ]] && [ "${CLUSTER_INDEX}" == 0 ]; then
    if [ "${CLUSTER_COUNT}" -le 1 ]; then
      CONTEXT_NAME=cluster1
    else
      CONTEXT_NAME=mgmt
      NODES_IN_THIS_CLUSTER=1
    fi
  else
    CONTEXT_NAME=cluster${ACTUAL_CLUSTER_NUM}
  fi
  CLUSTER_NAME=${CLUSTER_PREFIX}${CONTEXT_NAME}

  # Store as: CLUSTER_INDEX:ACTUAL_CLUSTER_NUM:CONTEXT_NAME:CLUSTER_NAME:NODES_IN_THIS_CLUSTER
  CLUSTER_SPECS+=("${CLUSTER_INDEX}:${ACTUAL_CLUSTER_NUM}:${CONTEXT_NAME}:${CLUSTER_NAME}:${NODES_IN_THIS_CLUSTER}")

  # Track final context for use after loop
  if [ "${CLUSTER_INDEX}" -le 1 ]; then
    FINAL_CONTEXT=${CONTEXT_NAME}
  fi
done

# Parallel cluster creation
if [[ "${PARALLEL}" == "1" ]]; then
  log_info "Creating ${CLUSTER_COUNT} cluster(s) in parallel..."

  # Create temp directory for status files and logs
  PARALLEL_TEMP_DIR=$(mktemp -d)
  trap "rm -rf ${PARALLEL_TEMP_DIR}" EXIT

  declare -a PIDS=()
  declare -a CONTEXT_NAMES=()

  for spec in "${CLUSTER_SPECS[@]}"; do
    IFS=':' read -r CLUSTER_INDEX ACTUAL_CLUSTER_NUM CONTEXT_NAME CLUSTER_NAME NODES_IN_THIS_CLUSTER <<< "$spec"
    CONTEXT_NAMES+=("${CONTEXT_NAME}")

    STATUS_FILE="${PARALLEL_TEMP_DIR}/${CONTEXT_NAME}.status"
    LOG_FILE="${PARALLEL_TEMP_DIR}/${CONTEXT_NAME}.log"

    if [[ "${PARALLEL_LIVE}" == "1" ]]; then
      # Live prefixed output mode
      (
        create_single_cluster "${CLUSTER_INDEX}" "${ACTUAL_CLUSTER_NUM}" "${CONTEXT_NAME}" "${CLUSTER_NAME}" "${NODES_IN_THIS_CLUSTER}" "${STATUS_FILE}" 2>&1 | sed "s/^/[${CONTEXT_NAME}] /"
      ) &
    else
      # Log file mode (default)
      (
        create_single_cluster "${CLUSTER_INDEX}" "${ACTUAL_CLUSTER_NUM}" "${CONTEXT_NAME}" "${CLUSTER_NAME}" "${NODES_IN_THIS_CLUSTER}" "${STATUS_FILE}" > "${LOG_FILE}" 2>&1
      ) &
    fi
    PIDS+=($!)
    log_debug "Started cluster ${CONTEXT_NAME} with PID ${PIDS[-1]}"
  done

  # Wait for all clusters to complete
  log_info "Waiting for all clusters to complete..."
  FAILED=0
  for i in "${!PIDS[@]}"; do
    pid=${PIDS[$i]}
    ctx=${CONTEXT_NAMES[$i]}
    # Capture exit status without triggering set -e
    wait_status=0
    wait $pid || wait_status=$?
    if [[ $wait_status -eq 0 ]]; then
      log_info "Cluster ${ctx} completed successfully"
    else
      log_error "Cluster ${ctx} failed (PID ${pid}, exit code ${wait_status})"
      FAILED=$((FAILED + 1))
    fi
  done

  # Summary
  echo ""
  log_info "=== Parallel Cluster Creation Summary ==="
  for ctx in "${CONTEXT_NAMES[@]}"; do
    STATUS_FILE="${PARALLEL_TEMP_DIR}/${ctx}.status"
    LOG_FILE="${PARALLEL_TEMP_DIR}/${ctx}.log"

    if [[ -f "${STATUS_FILE}" ]] && [[ "$(cat ${STATUS_FILE})" == "SUCCESS" ]]; then
      log_info "  ${ctx}: SUCCESS"
    else
      log_error "  ${ctx}: FAILED"
      # Show log for failed clusters
      if [[ -f "${LOG_FILE}" ]] && [[ "${PARALLEL_LIVE}" != "1" ]]; then
        echo "--- Log for ${ctx} ---"
        cat "${LOG_FILE}"
        echo "--- End log for ${ctx} ---"
      fi
    fi
  done

  if [[ $FAILED -gt 0 ]]; then
    log_error "${FAILED} cluster(s) failed to create"
  else
    log_info "All ${CLUSTER_COUNT} cluster(s) created successfully"
  fi

else
  # Sequential cluster creation (original behavior)
  for spec in "${CLUSTER_SPECS[@]}"; do
    IFS=':' read -r CLUSTER_INDEX ACTUAL_CLUSTER_NUM CONTEXT_NAME CLUSTER_NAME NODES_IN_THIS_CLUSTER <<< "$spec"

    log_info "Creating cluster $((CLUSTER_INDEX + 1)) of ${CLUSTER_COUNT}..."
    create_single_cluster "${CLUSTER_INDEX}" "${ACTUAL_CLUSTER_NUM}" "${CONTEXT_NAME}" "${CLUSTER_NAME}" "${NODES_IN_THIS_CLUSTER}"
  done
fi

kubectl config use-context ${FINAL_CONTEXT}

printf "Setting up IP forwarding from the guest VM to Kubernetes clusters...\n"
BRIDGE_IF=$(route get ${DOCKER_HOST_IP} | grep interface: | awk '{print $2}')
SRC_IP_GW=$(ifconfig ${BRIDGE_IF} | grep "inet " | cut -d' ' -f2)
DST_NET=$(docker network inspect ${DOCKER_NETWORK} --format '{{(index .IPAM.Config 0).Subnet}}')
INTERFACE_PREFIX=$(docker network inspect ${DOCKER_NETWORK} --format '{{.Id}}' | cut -c -5)
K8S_NETWORK_IF=$(colima ssh -p ${COLIMA_PROFILE} -- ip -j link show | jq -r --arg if_prefix "${INTERFACE_PREFIX}" '.[] | select(.ifname | contains($if_prefix)).ifname')

# FIX: Remove old TCP-only rules if they exist, then add new rules at position 1 (before DOCKER chains)
# This allows all IP protocols (TCP, UDP, ICMP, etc.) to be forwarded correctly
colima ssh -p ${COLIMA_PROFILE} -- sudo iptables -D FORWARD -s ${DOCKER_HOST_IP} -d ${DST_NET} -j ACCEPT -i ${HOST_IF} -o ${K8S_NETWORK_IF} >/dev/null 2>&1 || true
colima ssh -p ${COLIMA_PROFILE} -- sudo iptables -I FORWARD 1 -s ${DOCKER_HOST_IP} -d ${DST_NET} -j ACCEPT -i ${HOST_IF} -o ${K8S_NETWORK_IF}

colima ssh -p ${COLIMA_PROFILE} -- sudo iptables -D FORWARD -s ${SRC_IP_GW} -d ${DST_NET} -j ACCEPT -i ${HOST_IF} -o ${K8S_NETWORK_IF} >/dev/null 2>&1 || true
colima ssh -p ${COLIMA_PROFILE} -- sudo iptables -I FORWARD 1 -s ${SRC_IP_GW} -d ${DST_NET} -j ACCEPT -i ${HOST_IF} -o ${K8S_NETWORK_IF}


log_debug "Network Configuration:"
log_debug "  INTERFACE_PREFIX=${INTERFACE_PREFIX}"
log_debug "  BRIDGE_IF=${BRIDGE_IF}"
log_debug "  HOST_IF=${HOST_IF}"
log_debug "  K8S_NETWORK_IF=${K8S_NETWORK_IF}"
log_debug "  SRC_IP_GW=${SRC_IP_GW}"
log_debug "  DST_NET=${DST_NET}"
log_debug "  NETWORK_PREFIX=${NETWORK_PREFIX}"
log_debug "  DOCKER_HOST_IP=${DOCKER_HOST_IP}"
log_debug "  DOCKER_NETWORK=${DOCKER_NETWORK}"

printf "\nFinished setting up ${COLIMA_PROFILE}.\n"

printf "\nTo allow access to services from your machine, routes will be added to this host by running: \n  sudo route -nv delete -net ${DST_NET} \n  sudo route -nv add -net ${DST_NET} ${DOCKER_HOST_IP}\n"
if [ ! -z "${STARTED_VM:-}" ]; then
  answer=y
  if [ -t 0 ]; then
    printf "Shall I do this now? (y/N) "
    read answer
  fi
  if [ "$answer" != "${answer#[Yy]}" ]; then
    sudo route -nv delete -net ${DST_NET} >/dev/null 2>&1 || true
    sudo route -nv add -net ${DST_NET} ${DOCKER_HOST_IP}
  else
    printf "Skipping route config\n"
  fi
fi
