# Replicating sidecar `REGISTRY_ONLY` on Solo Enterprise Istio ambient

A copy-paste walkthrough. Every command below was run start to finish on a
local kind cluster with **Solo Enterprise Istio 1.31.1**, and the output shown
is the real output. You should be able to paste these in order and see the same
thing.

**What this proves:** an ambient-enrolled pod cannot reach an external host
unless that host is declared in a `ServiceEntry` — the ambient equivalent of
`outboundTrafficPolicy: REGISTRY_ONLY`.

**Time:** about 15 minutes.

---

## Before you start

You need:

- a running kind cluster
- Helm access to the Solo chart registry and image registry
- your Solo licence key

Set these once:

```bash
export LICENSE_KEY="<your Solo licence key>"
export ISTIO_VERSION=1.31.1-solo
export HELM_REPO=us-docker.pkg.dev/soloio-img/istio-helm
export HUB=us-docker.pkg.dev/soloio-img/istio
```

---

## Part 1 — Install Solo Enterprise Istio in ambient mode

These steps follow the
[Solo manual install guide](https://docs.solo.io/istio/1.31.x/setup/install/manual/)
exactly, so what you install here matches what that page describes.

### 1.1 Gateway API CRDs

Ambient requires the Kubernetes Gateway API CRDs.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
```


### 1.2 Base

```bash
helm upgrade --install istio-base oci://${HELM_REPO}/base \
  --namespace istio-system --create-namespace \
  --version ${ISTIO_VERSION} -f - <<EOF
defaultRevision: ""
profile: ambient
EOF
```

### 1.3 istiod

```bash
helm upgrade --install istiod oci://${HELM_REPO}/istiod \
  --namespace istio-system --version ${ISTIO_VERSION} --wait -f - <<EOF
global:
  hub: ${HUB}
  proxy:
    clusterDomain: cluster.local
  tag: ${ISTIO_VERSION}
meshConfig:
  accessLogFile: /dev/stdout
  defaultConfig:
    proxyMetadata:
      ISTIO_META_DNS_CAPTURE: "true"
env:
  PILOT_ENABLE_IP_AUTOALLOCATE: "true"
  PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
pilot:
  cni:
    namespace: istio-system
    enabled: true
profile: ambient
license:
  value: ${LICENSE_KEY}
EOF
```

### 1.4 CNI

```bash
helm upgrade --install istio-cni oci://${HELM_REPO}/cni \
  --namespace istio-system --version ${ISTIO_VERSION} --wait -f - <<EOF
ambient:
  dnsCapture: true
excludeNamespaces:
  - istio-system
  - kube-system
global:
  hub: ${HUB}
  tag: ${ISTIO_VERSION}
profile: ambient
EOF
```

### 1.5 ztunnel

```bash
helm upgrade --install ztunnel oci://${HELM_REPO}/ztunnel \
  --namespace istio-system --version ${ISTIO_VERSION} --wait -f - <<EOF
configValidation: true
enabled: true
env:
  L7_ENABLED: "true"
hub: ${HUB}
istioNamespace: istio-system
namespace: istio-system
profile: ambient
proxy:
  clusterDomain: cluster.local
tag: ${ISTIO_VERSION}
terminationGracePeriodSeconds: 29
variant: distroless
EOF
```

### 1.6 Confirm

```bash
kubectl -n istio-system get pods
```

```
NAME                      READY   STATUS    RESTARTS   AGE
istio-cni-node-sc9s2      1/1     Running   0          5s
istiod-5856784cb5-6zg77   1/1     Running   0          20s
ztunnel-5tm97             1/1     Running   0          2s
```

---

## Part 2 — Create the test namespaces

Four namespaces. **`ns-a` and `ns-b` are ambient-enrolled; `ns-c` and `ns-d`
are not.** The unenrolled pair is deliberate — it shows the boundary of the
control as well as the control itself.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: ns-a, labels: {istio.io/dataplane-mode: ambient}}
---
apiVersion: v1
kind: Namespace
metadata: {name: ns-b, labels: {istio.io/dataplane-mode: ambient}}
---
apiVersion: v1
kind: Namespace
metadata: {name: ns-c}
---
apiVersion: v1
kind: Namespace
metadata: {name: ns-d}
EOF
```

A curl pod in each:

```bash
for ns in ns-a ns-b ns-c ns-d; do
  kubectl -n $ns run curl --image=curlimages/curl:latest \
    --restart=Never --command -- sleep 36000
done

for ns in ns-a ns-b ns-c ns-d; do
  kubectl -n $ns wait --for=condition=Ready pod/curl --timeout=120s
done
```

Confirm enrolment:

```bash
kubectl get ns ns-a ns-b ns-c ns-d -L istio.io/dataplane-mode
```

```
NAME   STATUS   AGE   DATAPLANE-MODE
ns-a   Active   3s    ambient
ns-b   Active   3s    ambient
ns-c   Active   3s
ns-d   Active   3s
```

---

## Part 3 — Confirm egress is wide open

Save this probe script — you will run it three times.

```bash
cat > probe.sh <<'EOF'
#!/usr/bin/env bash
#   DECLARED   = httpbin.org      (gets a ServiceEntry in Part 5)
#   UNDECLARED = api.github.com   (never gets one)
echo "### $1"
printf '%-8s %-10s %-14s %-14s\n' "NS" "AMBIENT" "httpbin.org" "api.github.com"
printf '%-8s %-10s %-14s %-14s\n' "------" "-------" "------------" "--------------"
for ns in ns-a ns-b ns-c ns-d; do
  amb=$(kubectl get ns $ns -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')
  [ -z "$amb" ] && amb="no" || amb="yes"
  r1=$(kubectl -n $ns exec curl -- curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://httpbin.org/get 2>/dev/null)
  r2=$(kubectl -n $ns exec curl -- curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://api.github.com/ 2>/dev/null)
  printf '%-8s %-10s %-14s %-14s\n' "$ns" "$amb" "${r1:-000}" "${r2:-000}"
done
EOF
chmod +x probe.sh
./probe.sh "BEFORE any egress controls"
```

```
### BEFORE any egress controls
NS       AMBIENT    httpbin.org    api.github.com
------   -------    ------------   --------------
ns-a     yes        200            200
ns-b     yes        200            200
ns-c     no         200            200
ns-d     no         200            200
```

Everything reaches everything. This is the starting point.

---

## Part 4 — Turn on the egress controls

Two Helm upgrades. No application changes.

### 4.1 ztunnel — the registry-only backstop

```bash
helm upgrade ztunnel oci://${HELM_REPO}/ztunnel \
  --version ${ISTIO_VERSION} \
  -n istio-system --reuse-values \
  --set enableEgressGateway=true \
  --set-json 'egressPolicies=[
    {"namespaces":["istio-system"],"policy":"Passthrough"},
    {"matchCidrs":["0.0.0.0/0","::/0"],"policy":"Deny"}
  ]' \
  --wait
```

Two entries, and **the order matters — the catch-all `Deny` must be last**:

```
1. namespaces: [istio-system]   policy: Passthrough
   Exempts the egress gateway namespace, so gateway traffic does not loop.

2. matchCidrs: 0.0.0.0/0, ::/0  policy: Deny
   No `namespaces` field, so this matches EVERY namespace - including ones
   created later. This is the REGISTRY_ONLY equivalent.
```

Confirm it reached the data plane:

```bash
kubectl -n istio-system get ds ztunnel \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EGRESS_CONFIGS")].value}'
```

```json
[{"namespaces":["istio-system"],"policy":"Passthrough"},{"matchCidrs":["0.0.0.0/0","::/0"],"policy":"Deny"}]
```

### 4.2 istiod — ServiceEntry visibility

By default a `ServiceEntry` created in one namespace is visible mesh-wide, so
one team's declaration would open that host for everyone. This makes a
`ServiceEntry` private to its own namespace unless published.

```bash
helm upgrade istiod oci://${HELM_REPO}/istiod \
  --version ${ISTIO_VERSION} \
  -n istio-system --reuse-values \
  --set meshConfig.serviceEntryVisibility.defaultVisibility=NAMESPACE \
  --wait
```

### 4.3 Confirm egress is now closed

```bash
./probe.sh "AFTER egress controls, no ServiceEntry yet"
```

```
### AFTER egress controls, no ServiceEntry yet
NS       AMBIENT    httpbin.org    api.github.com
------   -------    ------------   --------------
ns-a     yes        000            000
ns-b     yes        000            000
ns-c     no         200            200
ns-d     no         200            200
```

**The two ambient namespaces are now fully blocked.** Nothing was declared, so
nothing may leave.

`ns-c` and `ns-d` are unchanged, because they are not ambient-enrolled — there
is no ztunnel in their path to enforce anything. Worth noting as a governance
point: **this control applies to ambient-enrolled namespaces only.**

And the reason, in the ztunnel log:

```bash
kubectl -n istio-system logs ds/ztunnel --since=2m | grep "egress policy"
```

```
warn  access  connection failed  src.addr=10.244.0.9:59030
      dst.addr=18.227.178.96:443  direction="outbound"
      error="request denied due to egress policy"
```

That is the line that proves the control is live. It is a **policy denial**,
not a timeout and not a DNS failure.

---

## Part 5 — Declare the destinations that are allowed

### 5.1 The egress gateway

A single cluster-wide Gateway in `istio-system`. It is backed by the existing
ztunnel DaemonSet — **no new pods are deployed.**

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ztunnel-egress
  namespace: istio-system
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: solo-ztunnel-egress
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
    allowedRoutes:
      namespaces:
        from: All
---
# ALLOW with no rules = deny everything through the Gateway unless a more
# specific ALLOW permits it.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: default-deny-ztunnel-egress
  namespace: istio-system
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: ztunnel-egress
  action: ALLOW
  rules: []
EOF
```

Confirm. The Gateway takes a few seconds to programme, so wait on the
condition rather than reading it straight away:

```bash
kubectl -n istio-system wait --for=condition=Programmed gateway/ztunnel-egress --timeout=60s

kubectl -n istio-system get gateway ztunnel-egress \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
```

```
gateway.gateway.networking.k8s.io/ztunnel-egress condition met
Accepted=True (Accepted)
Programmed=True (Programmed)
ResolvedRefs=True (ResolvedRefs)
```

If you read the status immediately after `kubectl apply` instead, you will
briefly see `Programmed=False (AddressNotUsable)`. That is the normal
pre-programmed state, not a failure — it clears within a few seconds.

### 5.2 Declare `httpbin.org` for `ns-a` only

Three resources: the `ServiceEntry` that registers the host, and two
AuthorizationPolicies — one at the gateway layer, one at the ServiceEntry layer.

```bash
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: httpbin-org
  namespace: ns-a
  labels:
    istio.io/use-waypoint: ztunnel-egress
    istio.io/use-waypoint-namespace: istio-system
spec:
  hosts:
  - httpbin.org
  ports:
  - number: 443
    name: https
    protocol: TLS
  resolution: DNS
  location: MESH_EXTERNAL
---
# Gateway layer - which namespaces may transit the egress gateway.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-ns-a-through-egress
  namespace: istio-system
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: ztunnel-egress
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["ns-a"]
---
# ServiceEntry layer - which namespaces may reach this specific host.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-ns-a-to-httpbin
  namespace: ns-a
spec:
  targetRefs:
  - kind: ServiceEntry
    group: networking.istio.io
    name: httpbin-org
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["ns-a"]
EOF
```

Confirm the ServiceEntry bound to the gateway **and** that visibility applied:

```bash
kubectl -n ns-a get serviceentry httpbin-org \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
```

```
istio.io/WaypointBound=True (WaypointAccepted)
istio.io/VisibilityApplied=True (Namespace)
```

Both features are visible on the one resource: it is attached to the egress
gateway, and it is scoped to its own namespace.

The host also gets an allocated address, from `PILOT_ENABLE_IP_AUTOALLOCATE`
in step 1.3:

```bash
kubectl -n ns-a get serviceentry httpbin-org -o jsonpath='{.status.addresses}'
```

```json
[{"host":"httpbin.org","value":"240.240.0.1"},{"host":"httpbin.org","value":"2001:2::1"}]
```

---

## Part 6 — The proof

```bash
./probe.sh "THE PROOF"
```

```
### THE PROOF
NS       AMBIENT    httpbin.org    api.github.com
------   -------    ------------   --------------
ns-a     yes        200            000
ns-b     yes        000            000
ns-c     no         200            200
ns-d     no         200            200
```

Reading each row:

```
ns-a   DECLARED host reachable, UNDECLARED host blocked.
       This is REGISTRY_ONLY behaviour.

ns-b   BOTH blocked. The ServiceEntry lives in ns-a and is scoped to ns-a by
       serviceEntryVisibility, so from ns-b httpbin.org is simply not in the
       registry - and the catch-all Deny applies.

ns-c   Unchanged. Not ambient-enrolled, so no ztunnel in the path.
ns-d   Unchanged. Same reason.
```

### 6.1 The logs behind each outcome

A **denied** request — one line, no gateway hop:

```bash
kubectl -n istio-system logs ds/ztunnel --since=2m | grep "egress policy"
```

```
warn  access  connection failed
      src.addr=10.244.0.10:32888          <- the curl pod in ns-b
      dst.addr=3.137.48.32:443
      direction="outbound"
      error="request denied due to egress policy"
```

An **allowed** request from `ns-a` — two lines, showing the gateway hop and
then the traffic actually leaving:

```bash
kubectl -n istio-system logs ds/ztunnel --since=2m | grep 'src.namespace="ns-a"'
```

```
info  access  connection complete
      src.workload="curl"  src.namespace="ns-a"
      src.identity="spiffe://cluster.local/ns/ns-a/sa/default"
      dst.service="httpbin.org"
      dst.workload="ztunnel-bzhgm"  dst.namespace="istio-system"   <- gateway hop
      direction="outbound"

info  access  connection complete
      src.workload="curl"  src.namespace="ns-a"
      dst.addr=3.137.48.32:443  dst.service="httpbin.org"
      direction="egress"  tls.sni=httpbin.org                       <- leaving
      bytes_sent=4267  bytes_recv=1920  duration="333ms"
```

`bytes_recv=1920` on a `direction="egress"` line is the positive proof that
traffic reached the external host.

---

## What this demonstrates

```
+---------------------------------------+------------------------------------+
| Sidecar today                         | Ambient equivalent, proven above   |
+---------------------------------------+------------------------------------+
| outboundTrafficPolicy: REGISTRY_ONLY  | ztunnel egressPolicies with a      |
|                                       | trailing catch-all policy: Deny    |
+---------------------------------------+------------------------------------+
| ServiceEntry.exportTo for namespace   | meshConfig.serviceEntryVisibility  |
| scoping                               | defaultVisibility: NAMESPACE       |
+---------------------------------------+------------------------------------+
| Sidecar egress host lists             | AuthorizationPolicy on the         |
|                                       | ServiceEntry and on the Gateway    |
+---------------------------------------+------------------------------------+
```

Three properties worth stating explicitly:

1. **Default-deny, with no namespace enumeration.** The catch-all entry has no
   `namespaces` field, so it covers every ambient namespace — including ones
   created after the policy was written. A new team onboarding does not get
   unpoliced egress by default.
2. **The registry is the gate.** A destination is reachable only if a
   `ServiceEntry` declares it. That moves the control point to "who may create
   a ServiceEntry", which for most organisations is already a
   configuration-repository decision.
3. **Namespace scoping is preserved.** With `serviceEntryVisibility: NAMESPACE`,
   one team declaring a host does not open it for every other team.

---

## Adding another destination

For each additional external host a namespace needs, repeat 5.2: a
`ServiceEntry` with the two `use-waypoint` labels, plus an `AuthorizationPolicy`
targeting it. Nothing in Part 4 changes.

---

## Reverting

Reverting takes **three** steps, not two. Removing the Helm values alone is not
enough — the `AuthorizationPolicy` resources outlive them and keep enforcing.

```bash
# 1. Remove the policy resources
kubectl -n ns-a delete serviceentry httpbin-org
kubectl -n ns-a delete authorizationpolicy allow-ns-a-to-httpbin
kubectl -n istio-system delete authorizationpolicy allow-ns-a-through-egress
kubectl -n istio-system delete authorizationpolicy default-deny-ztunnel-egress
kubectl -n istio-system delete gateway ztunnel-egress

# 2. Clear the egress policies
helm upgrade ztunnel oci://${HELM_REPO}/ztunnel --version ${ISTIO_VERSION} \
  -n istio-system --reuse-values --set-json 'egressPolicies=[]' --wait

# 3. Return ServiceEntry visibility to the default
helm upgrade istiod oci://${HELM_REPO}/istiod --version ${ISTIO_VERSION} \
  -n istio-system --reuse-values \
  --set meshConfig.serviceEntryVisibility.defaultVisibility=PUBLIC --wait
```

```bash
./probe.sh "FULL REVERT"
```

```
### FULL REVERT
NS       AMBIENT    httpbin.org    api.github.com
------   -------    ------------   --------------
ns-a     yes        200            200
ns-b     yes        200            200
ns-c     no         200            200
ns-d     no         200            200
```

If you do steps 2 and 3 but skip step 1, you will see `ns-b` still blocked on
`httpbin.org`. That is the ServiceEntry-layer `AuthorizationPolicy` still doing
its job — the ztunnel log shows
`error="resource-rbac denied: allow policies exist, but none allowed"` rather
than an egress-policy denial. It is a useful thing to see once, because it
shows the two layers are independent.

---

## Reference

- [L4 ztunnel-native egress](https://docs.solo.io/istio/1.31.x/traffic-management/egress/ztunnel-egress/)
- [Migrate egress controls from sidecar to ambient](https://docs.solo.io/istio/1.31.x/traffic-management/egress/migrate-sidecar/)
- [ServiceEntry visibility](https://docs.solo.io/istio/1.31.x/traffic-management/serviceentry-visibility/)
