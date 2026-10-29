# Replicating sidecar `REGISTRY_ONLY` on Solo Enterprise Istio ambient

### A guided walkthrough, for people new to ambient mode

Every command below was run start to finish on a local kind cluster with
**Solo Enterprise Istio 1.31.1**, and the output shown is the real output.
You should be able to paste these in order and see the same thing.

**What this proves:** an ambient-enrolled pod cannot reach an external host
unless that host is declared in a `ServiceEntry` — the ambient equivalent of
`outboundTrafficPolicy: REGISTRY_ONLY`.

**Time:** about 15 minutes of work, plus reading.

> If you already know ambient well and just want the commands, skip to Part 1.
> Everything in **Background** is explanation, not instruction.

---

# Background

## 1. What changes when you move from sidecars to ambient

In sidecar mode every pod gets its own Envoy proxy, injected next to the
application container. That proxy sees all of the pod's traffic, understands
HTTP, and enforces policy on the way out.

Ambient removes it.

```
  SIDECAR MODE                          AMBIENT MODE

  pod                                   pod
  +----------------------+              +----------------------+
  |  app  |  istio-proxy |              |         app          |
  +----------------------+              +----------------------+
           ^                                       |
           |                                       | traffic is redirected
     one Envoy per POD                             | out of the pod by
     L7, reads VirtualService                      | istio-cni
     enforces egress policy                        v
                                        +------------------------+
                                        |       ztunnel          |
                                        |  one per NODE, L4 only |
                                        |     (DaemonSet)        |
                                        +------------------------+
```

Three consequences matter for egress:

- **There is no proxy inside the pod any more.** Anything that used to be
  enforced by the pod's own sidecar has to be enforced somewhere else.
- **ztunnel is shared.** One ztunnel serves every pod on the node, for every
  namespace.
- **ztunnel is Layer 4.** It handles TCP and mTLS identity. It does not parse
  HTTP, and it does not read `VirtualService`. For Layer 7 work you add a
  *waypoint* — an Envoy proxy deployed per namespace or per service. This
  walkthrough does not need one, because egress control here is an L4 decision.

## 2. What `REGISTRY_ONLY` did, and why it does not carry over

In sidecar mode you set this in `MeshConfig`:

```yaml
outboundTrafficPolicy:
  mode: REGISTRY_ONLY
```

It means: **a sidecar may only send traffic to destinations that exist in the
service registry.** The registry is Istio's internal catalogue of everything it
knows about — Kubernetes `Service` objects, plus any `ServiceEntry` you have
declared. Anything not in it is refused.

That is a powerful control. It means nothing leaves the cluster unless somebody
declared it first, usually through a configuration repository with review.

It does not carry over, for the simple reason above: **it was enforced by the
sidecar, and there is no sidecar.** Setting `REGISTRY_ONLY` in an ambient mesh
does nothing for ambient workloads.

So the question this document answers is: *can we get the same property back,
and prove it?*

## 3. The three Solo Enterprise features we use

Ambient mode, ztunnel and waypoints are all upstream open-source Istio. The
three capabilities below are **specific to Solo Enterprise for Istio** — they do
not exist in upstream Istio, and they are what make this possible.

```
+---+--------------------------------+-----------------------------------------+
| # | Feature                        | What it gives you                       |
+---+--------------------------------+-----------------------------------------+
| 1 | ztunnel egressPolicies         | A default-deny backstop. Lets you tell  |
|   | (Helm value on the ztunnel     | ztunnel to refuse any destination that  |
|   |  chart)                        | is not in the service registry. This is |
|   |                                | the direct REGISTRY_ONLY replacement.   |
+---+--------------------------------+-----------------------------------------+
| 2 | solo-ztunnel-egress            | An egress gateway backed by the ztunnel |
|   | GatewayClass                   | DaemonSet you already run. Creating it  |
|   |                                | deploys NO new pods. Gives you a place  |
|   |                                | to attach authorization policy, and     |
|   |                                | makes traffic leave from ztunnel's      |
|   |                                | network namespace rather than the app's.|
+---+--------------------------------+-----------------------------------------+
| 3 | serviceEntryVisibility         | Makes a ServiceEntry private to its own |
|   | (meshConfig on istiod)         | namespace by default, instead of        |
|   |                                | visible mesh-wide. This is what replaces|
|   |                                | `exportTo` scoping.                     |
+---+--------------------------------+-----------------------------------------+
```

## 4. How the pieces fit together

Once configured, an outbound connection from an ambient pod is decided like
this:

```
   pod makes an outbound connection
              |
              v
   +----------------------------------------+
   | Is the destination in the registry?    |
   | (a Kubernetes Service, or a            |
   |  ServiceEntry VISIBLE to this          |
   |  namespace)                            |
   +----------------------------------------+
         |                        |
        YES                      NO
         |                        |
         v                        v
   +------------------+    +---------------------------+
   | Routed via the   |    | egressPolicies apply      |
   | egress gateway.  |    | -> catch-all policy: Deny |
   | AuthorizationPo- |    | -> connection refused     |
   | licy decides who |    |                           |
   | may use it.      |    | "request denied due to    |
   |                  |    |  egress policy"           |
   +------------------+    +---------------------------+
```

The important subtlety: **`egressPolicies` are only consulted for destinations
that are NOT in the registry.** A declared destination skips them entirely and
is governed by `AuthorizationPolicy` instead. That is why both controls are
needed — one blocks the unknown, the other governs the known.

---

# The walkthrough

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

An ambient installation is four Helm charts:

```
  base     the CRDs and cluster roles Istio needs
  istiod   the control plane - watches your config, programmes the data plane
  cni      a node agent that redirects pod traffic into ztunnel.
           It does NOT replace your cluster CNI; it installs a small plugin
           alongside it.
  ztunnel  the per-node L4 data plane
```

### 1.1 Gateway API CRDs

Ambient is built on the Kubernetes Gateway API, so its CRDs must exist before
Istio starts. They are maintained by the Kubernetes project, not by Solo.

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

Two settings here matter later in this walkthrough:

- **`PILOT_ENABLE_IP_AUTOALLOCATE`** — gives each external hostname in a
  `ServiceEntry` a synthetic IP address from the `240.240.0.0/16` range. ztunnel
  uses that address internally to recognise which declared destination a
  connection is for.
- **`ISTIO_META_DNS_CAPTURE`** — lets the mesh answer DNS for declared external
  hostnames, which is what makes the hostname resolvable to that synthetic
  address.

Without these two, a `ServiceEntry` for an external hostname will not behave as
you expect.

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

`excludeNamespaces` keeps the node agent away from `istio-system` and
`kube-system` — you do not want to redirect the control plane's own traffic
into the data plane it is programming.

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

`terminationGracePeriodSeconds: 29` is how long ztunnel waits for existing
connections to finish during an upgrade.

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

Three pods on a single-node cluster. On a real cluster you would see one
`istio-cni-node` and one `ztunnel` **per node**, because both are DaemonSets,
and one or more `istiod` pods.

---

## Part 2 — Create the test namespaces

A namespace joins the mesh by being labelled — **no pod restart is required**,
and the application is not modified in any way.

```yaml
labels:
  istio.io/dataplane-mode: ambient
```

We create four namespaces. `ns-a` and `ns-b` are enrolled; `ns-c` and `ns-d`
are deliberately **not**.

The unenrolled pair is there to show you the boundary of the control as well as
the control itself. Egress policy is enforced by ztunnel, and ztunnel is only in
the path for pods whose namespace is enrolled. A namespace outside the mesh is
outside this control — worth seeing deliberately rather than discovering later.

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

A plain curl pod in each. Note there is nothing Istio-specific about these pods
— no annotations, no injected container, no awareness of the mesh at all.

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

If you want to confirm the pods really are enrolled, ztunnel logs a line for
each one it adopts:

```bash
kubectl -n istio-system logs ds/ztunnel | grep "pod received"
```

---

## Part 3 — Confirm egress is wide open

Always establish the "before" state. If you only ever see the end state, you
cannot tell the difference between a working control and a broken network.

We use two destinations throughout:

```
  httpbin.org      will be DECLARED in a ServiceEntry later
  api.github.com   will NEVER be declared - the control case
```

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

`200` means the request reached the external site. `000` will mean it did not.

Everything reaches everything, including the two enrolled namespaces. **Joining
the mesh does not restrict egress by itself** — you have to ask for it. That is
what Part 4 does.

---

## Part 4 — Turn on the egress controls

Two Helm upgrades. No application changes, no pod restarts of your workloads.

### 4.1 ztunnel — the registry-only backstop

> **Solo Enterprise feature:** `egressPolicies`

This is the direct replacement for `outboundTrafficPolicy: REGISTRY_ONLY`.

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

Reading that configuration:

```
1. namespaces: [istio-system]   policy: Passthrough
   Exempts the egress gateway's own namespace. Without this, traffic that the
   gateway itself is sending outward would be caught by rule 2 and blocked,
   and you would have a loop.

2. matchCidrs: 0.0.0.0/0, ::/0  policy: Deny
   Matches every destination address, v4 and v6. Note there is NO `namespaces`
   field - an entry without one matches EVERY namespace, including namespaces
   that do not exist yet. This is what makes it a true default-deny rather
   than a list you have to maintain.
```

**The list is evaluated in order and the first match wins, so the catch-all
`Deny` must be last.** If you put it first, every entry below it is silently
ignored — there is no warning and no error.

`enableEgressGateway=true` switches on the egress data path inside ztunnel. It
is off by default.

Confirm the policy reached the data plane. Helm values are turned into an
environment variable on the ztunnel DaemonSet, so this is the authoritative
check:

```bash
kubectl -n istio-system get ds ztunnel \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EGRESS_CONFIGS")].value}'
```

```json
[{"namespaces":["istio-system"],"policy":"Passthrough"},{"matchCidrs":["0.0.0.0/0","::/0"],"policy":"Deny"}]
```

### 4.2 istiod — ServiceEntry visibility

> **Solo Enterprise feature:** `meshConfig.serviceEntryVisibility`

By default — in upstream Istio and in Solo — a `ServiceEntry` created in **any**
namespace is visible to the **whole mesh**. That means one team declaring
`payments-api.example.com` would open that host for every other team too.

In sidecar mode you would have controlled that with `exportTo`. In ambient,
`exportTo` is not enforced, so this setting replaces it:

```bash
helm upgrade istiod oci://${HELM_REPO}/istiod \
  --version ${ISTIO_VERSION} \
  -n istio-system --reuse-values \
  --set meshConfig.serviceEntryVisibility.defaultVisibility=NAMESPACE \
  --wait
```

`NAMESPACE` means a `ServiceEntry` is visible only inside the namespace that
created it. The default is `PUBLIC`. You can still publish specific namespaces
mesh-wide with a selector if you need to.

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

**The two ambient namespaces are now fully blocked.** Nothing has been declared,
so nothing may leave. This is `REGISTRY_ONLY` behaviour.

`ns-c` and `ns-d` are unchanged, because they are not ambient-enrolled — there
is no ztunnel in their path to enforce anything.

Now look at *why* a request failed. This matters: a blocked request and a broken
network look identical from inside the pod, and only the log tells them apart.

```bash
kubectl -n istio-system logs ds/ztunnel --since=2m | grep "egress policy"
```

```
warn  access  connection failed  src.addr=10.244.0.9:59030
      dst.addr=18.227.178.96:443  direction="outbound"
      error="request denied due to egress policy"
```

That is a **policy denial** — Istio made a decision. It is not a timeout, not a
DNS failure, and not a connection reset from the far end. This is the single
line that proves the control is live.

---

## Part 5 — Declare the destinations that are allowed

Blocking everything is easy. The real test is allowing exactly what should be
allowed, and nothing more.

### 5.1 The egress gateway

> **Solo Enterprise feature:** the `solo-ztunnel-egress` GatewayClass

This creates a cluster-wide egress gateway in `istio-system`. The important
thing to understand: **it is backed by the ztunnel DaemonSet you are already
running, so no new pods are deployed.** It is a logical attachment point, not
another proxy tier.

It does two jobs. It gives declared traffic a defined path out of the cluster,
and it gives you somewhere to attach an `AuthorizationPolicy` that governs who
may use that path.

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

Two details worth understanding:

- **`protocol: HBONE`, port 15008.** HBONE is how ambient carries traffic
  between ztunnels — mTLS inside an HTTP/2 tunnel. You will see port 15008 in
  the logs later.
- **`action: ALLOW` with `rules: []`.** This is the Istio idiom for default
  deny. An ALLOW policy that matches nothing means "allowed only if some other
  ALLOW policy matches". Leaving this out would let any namespace use the
  gateway.

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

Three resources. Here is what each is for before you apply them:

```
ServiceEntry             Puts httpbin.org INTO the service registry, and binds
                         it to the egress gateway with the two use-waypoint
                         labels. This is what lifts it out of the catch-all Deny.

AuthorizationPolicy      Gateway layer. Which namespaces may use the egress
(in istio-system)        gateway at all.

AuthorizationPolicy      ServiceEntry layer. Which namespaces may reach THIS
(in ns-a)                specific host.
```

Two layers may look redundant on a single host. It stops being redundant as
soon as you have twenty: the gateway layer is a coarse "may this namespace
egress at all", the ServiceEntry layer is "and specifically to what".

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

A note on the `ServiceEntry` fields, since they are easy to copy without
reading:

- **`location: MESH_EXTERNAL`** — this host is outside the mesh. Istio will not
  try to apply mesh identity to the far end.
- **`resolution: DNS`** — resolve the hostname with DNS at connection time.
- **`protocol: TLS` on port 443** — the client originates its own TLS. ztunnel
  reads the SNI to tell which host is being requested but does not decrypt.
- **the two `use-waypoint` labels** — these bind the ServiceEntry to the egress
  gateway. Without them the `AuthorizationPolicy` targeting this ServiceEntry
  attaches to nothing and silently enforces nothing.

Confirm the ServiceEntry bound to the gateway **and** that visibility applied:

```bash
kubectl -n ns-a get serviceentry httpbin-org \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
```

```
istio.io/WaypointBound=True (WaypointAccepted)
istio.io/VisibilityApplied=True (Namespace)
```

Both enterprise features are reporting on this one resource: it is attached to
the egress gateway (`WaypointBound`), and it is scoped to its own namespace
(`VisibilityApplied`). **Check these conditions whenever egress does not behave
as you expect** — they are the fastest way to tell configuration that is live
from configuration that merely exists.

The host also gets an allocated address, from `PILOT_ENABLE_IP_AUTOALLOCATE`
in step 1.3:

```bash
kubectl -n ns-a get serviceentry httpbin-org -o jsonpath='{.status.addresses}'
```

```json
[{"host":"httpbin.org","value":"240.240.0.1"},{"host":"httpbin.org","value":"2001:2::1"}]
```

That `240.240.0.1` is not a real address on the internet. It is a synthetic
handle the mesh uses internally to recognise this declared destination.

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
       This is REGISTRY_ONLY behaviour, demonstrated.

ns-b   BOTH blocked - and this is the interesting one. The ServiceEntry lives
       in ns-a and is scoped to ns-a by serviceEntryVisibility, so from ns-b's
       point of view httpbin.org was never declared at all. It falls through
       to the catch-all Deny.
       Without serviceEntryVisibility, ns-b would have reached httpbin.org
       on the strength of ns-a's declaration.

ns-c   Unchanged. Not ambient-enrolled, so no ztunnel in the path.
ns-d   Unchanged. Same reason.
```

### 6.1 The logs behind each outcome

A **denied** request — one line, and no gateway involved:

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

An **allowed** request from `ns-a` — two lines, because the connection is
observed twice: once as it is handed to the egress gateway, and once as it
actually leaves the cluster.

```bash
kubectl -n istio-system logs ds/ztunnel --since=2m | grep 'src.namespace="ns-a"'
```

```
info  access  connection complete
      src.workload="curl"  src.namespace="ns-a"
      src.identity="spiffe://cluster.local/ns/ns-a/sa/default"   <- who, cryptographically
      dst.service="httpbin.org"
      dst.workload="ztunnel-bzhgm"  dst.namespace="istio-system" <- the gateway hop
      direction="outbound"

info  access  connection complete
      src.workload="curl"  src.namespace="ns-a"
      dst.addr=3.137.48.32:443  dst.service="httpbin.org"
      direction="egress"  tls.sni=httpbin.org                    <- actually leaving
      bytes_sent=4267  bytes_recv=1920  duration="333ms"
```

Things worth noticing in that output:

- **`src.identity`** is a SPIFFE ID — the workload's cryptographic identity,
  not just a name. Authorization decisions are made on this, not on IP address.
- **`direction="egress"`** is the measurement taken as traffic leaves the
  cluster. `direction="outbound"` is the earlier hop.
- **`bytes_recv=1920`** is positive proof the external host answered. A policy
  denial always shows `bytes_recv=0`.

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
targeting it. Nothing in Part 4 changes — the backstop is written once.

If the namespace has never egressed before, it also needs an entry at the
gateway layer, like `allow-ns-a-through-egress`.

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
than an egress-policy denial. It is worth seeing once, because it shows the two
layers really are independent.

---

## Glossary

```
ambient mode      Istio without per-pod sidecars. Traffic is handled by a
                  per-node ztunnel (L4) and, where L7 is needed, by waypoints.

ztunnel           The per-node data plane. A DaemonSet. Handles TCP and mTLS
                  identity. Does not parse HTTP.

waypoint          An Envoy proxy for L7 work, deployed per namespace or per
                  service. Not needed in this walkthrough.

istio-cni         A node agent that redirects enrolled pods' traffic into
                  ztunnel. Does not replace your cluster CNI.

HBONE             HTTP/2-based mTLS tunnel used between ztunnels. Port 15008.

service registry  Istio's catalogue of known destinations: Kubernetes Services
                  plus declared ServiceEntries.

ServiceEntry      A declaration that adds an external destination to the
                  registry.

SPIFFE ID         A workload's cryptographic identity, e.g.
                  spiffe://cluster.local/ns/ns-a/sa/default

egressPolicies    SOLO ENTERPRISE. ztunnel Helm value; default-deny backstop
                  for destinations not in the registry.

solo-ztunnel-     SOLO ENTERPRISE. An egress gateway backed by the existing
egress            ztunnel DaemonSet. Deploys no new pods.

serviceEntry-     SOLO ENTERPRISE. istiod meshConfig setting; makes a
Visibility        ServiceEntry private to its namespace by default.
```

---

## Reference

- [Manual install](https://docs.solo.io/istio/1.31.x/setup/install/manual/)
- [L4 ztunnel-native egress](https://docs.solo.io/istio/1.31.x/traffic-management/egress/ztunnel-egress/)
- [Migrate egress controls from sidecar to ambient](https://docs.solo.io/istio/1.31.x/traffic-management/egress/migrate-sidecar/)
- [ServiceEntry visibility](https://docs.solo.io/istio/1.31.x/traffic-management/serviceentry-visibility/)
