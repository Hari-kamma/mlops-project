#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — Pre-flight check for AKS + KServe v0.16 deployment
# ---------------------------------------------------------------------------
# This script verifies all prerequisites are in place on your AKS cluster
# before deploying the InferenceService.
#
# Usage:
#   ./scripts/setup.sh
# ---------------------------------------------------------------------------

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

KSERVE_NS="kserve"
ISTIO_NS="istio-gateway"
GATEWAY_NAME="ingressgateway"
EXPECTED_KSERVE_VERSION="v0.16"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  AKS + KServe Pre-flight Check${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# ---------------------------------------------------------------------------
# 1. kubectl connected to AKS
# ---------------------------------------------------------------------------
info "Checking kubectl context ..."
CONTEXT=$(kubectl config current-context 2>/dev/null) || die "kubectl not configured or cluster unreachable"
ok "kubectl context: $CONTEXT"

# ---------------------------------------------------------------------------
# 2. KServe CRDs
# ---------------------------------------------------------------------------
info "Checking KServe CRDs ..."
kubectl get crd inferenceservices.serving.kserve.io &>/dev/null \
  || die "KServe CRDs not found. Is KServe installed?"
ok "KServe CRDs present"

# ---------------------------------------------------------------------------
# 3. KServe controller running
# ---------------------------------------------------------------------------
info "Checking KServe controller ..."
KSERVE_READY=$(kubectl get pods -n "$KSERVE_NS" \
  -l "control-plane=kserve-controller-manager" \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
[[ "$KSERVE_READY" == "True" ]] || warn "KServe controller pod not Ready — check: kubectl get pods -n $KSERVE_NS"
[[ "$KSERVE_READY" == "True" ]] && ok "KServe controller is Running"

# ---------------------------------------------------------------------------
# 4. Istio ingress gateway
# ---------------------------------------------------------------------------
info "Checking Istio ingress gateway ..."
kubectl get svc "$GATEWAY_NAME" -n "$ISTIO_NS" &>/dev/null \
  || die "Istio ingressgateway service not found in namespace $ISTIO_NS"

INGRESS_IP=$(kubectl -n "$ISTIO_NS" get svc "$GATEWAY_NAME" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
INGRESS_HOSTNAME=$(kubectl -n "$ISTIO_NS" get svc "$GATEWAY_NAME" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [[ -n "$INGRESS_IP" ]]; then
  ok "Istio gateway external IP: $INGRESS_IP"
elif [[ -n "$INGRESS_HOSTNAME" ]]; then
  ok "Istio gateway external hostname: $INGRESS_HOSTNAME"
else
  warn "Istio gateway has no external IP/hostname yet (LoadBalancer pending)"
fi

# ---------------------------------------------------------------------------
# 5. inferenceservice-config configmap
# ---------------------------------------------------------------------------
info "Checking inferenceservice-config ..."
kubectl get cm inferenceservice-config -n "$KSERVE_NS" &>/dev/null \
  || die "inferenceservice-config configmap not found in $KSERVE_NS"
ok "inferenceservice-config present"

DEPLOY_MODE=$(kubectl get cm inferenceservice-config -n "$KSERVE_NS" \
  -o jsonpath='{.data.deploy}' 2>/dev/null || echo "")
[[ "$DEPLOY_MODE" == *"RawDeployment"* ]] && ok "RawDeployment mode confirmed" \
  || warn "RawDeployment not set as default — verify inferenceservice-config deploy key"

# ---------------------------------------------------------------------------
# 6. imagePullSecret for docker.cc.com
# ---------------------------------------------------------------------------
info "Checking imagePullSecret ..."
SECRET_COUNT=$(kubectl get secrets -n "$KSERVE_NS" \
  --field-selector type=kubernetes.io/dockerconfigjson \
  -o name 2>/dev/null | wc -l | tr -d ' ')
if [[ "$SECRET_COUNT" -gt 0 ]]; then
  ok "Found $SECRET_COUNT docker registry secret(s) in $KSERVE_NS namespace:"
  kubectl get secrets -n "$KSERVE_NS" --field-selector type=kubernetes.io/dockerconfigjson -o name 2>/dev/null
else
  warn "No docker registry secrets found in $KSERVE_NS. You need one for docker.cc.com"
  warn "Create with: kubectl create secret docker-registry cloudsmith-registry-creds \\"
  warn "  --docker-server=docker.cc.com --docker-username=<user> --docker-password=<token> \\"
  warn "  -n $KSERVE_NS"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Pre-flight check complete. Next steps:"
info "  1. Train model     : ./scripts/train.sh"
info "  2. Build & push    : ./scripts/build-push.sh"
info "  3. Update secret   : edit imagePullSecrets name in k8s/kserve/iris-inferenceservice.yaml"
info "  4. Deploy          : kubectl apply -f k8s/kserve/iris-inferenceservice.yaml"
info "  5. Watch           : kubectl get inferenceservice iris -n kserve -w"
info "  6. Test            : ./scripts/test-inference.sh"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
