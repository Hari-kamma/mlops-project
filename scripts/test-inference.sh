#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-inference.sh — Send a prediction request to the Iris InferenceService
# ---------------------------------------------------------------------------
# Target: AKS + KServe v0.16 RawDeployment + Istio ingress
#
# Usage:
#   ./scripts/test-inference.sh [sepal_l] [sepal_w] [petal_l] [petal_w]
#
# Examples:
#   ./scripts/test-inference.sh                    # Setosa (default)
#   ./scripts/test-inference.sh 5.1 3.5 1.4 0.2   # Setosa
#   ./scripts/test-inference.sh 6.3 3.3 4.7 1.6   # Versicolor
#   ./scripts/test-inference.sh 6.7 3.0 5.2 2.3   # Virginica
#
# Prerequisites:
#   kubectl get inferenceservice iris -n kserve   # must show Ready=True
# ---------------------------------------------------------------------------

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Input features (defaults = classic Setosa sample)
# ---------------------------------------------------------------------------
F1="${1:-5.1}"   # sepal length
F2="${2:-3.5}"   # sepal width
F3="${3:-1.4}"   # petal length
F4="${4:-0.2}"   # petal width

CLASS_NAMES=("Setosa" "Versicolor" "Virginica")

MODEL_NAME="iris"
NAMESPACE="kserve"

# ---------------------------------------------------------------------------
# Resolve Istio ingress gateway external IP/hostname (AKS LoadBalancer)
# ---------------------------------------------------------------------------
info "Resolving Istio ingress gateway address ..."
INGRESS_HOST=$(kubectl -n istio-gateway get service ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [[ -z "$INGRESS_HOST" ]]; then
  # Try hostname (AKS sometimes returns hostname instead of IP)
  INGRESS_HOST=$(kubectl -n istio-gateway get service ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
fi

if [[ -z "$INGRESS_HOST" ]]; then
  die "Could not resolve Istio ingress gateway IP/hostname. Is the LoadBalancer provisioned?"
fi

# KServe domain template: {{ .Name }}.{{ .IngressDomain }} = iris.azure.cc.com
HOST_HEADER="${MODEL_NAME}.azure.cc.com"
ENDPOINT="http://${INGRESS_HOST}/v2/models/${MODEL_NAME}/infer"

# ---------------------------------------------------------------------------
# Verify InferenceService is ready
# ---------------------------------------------------------------------------
IS_READY=$(kubectl get inferenceservice "$MODEL_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

if [[ "$IS_READY" != "True" ]]; then
  warn "InferenceService '${MODEL_NAME}' is not Ready yet:"
  kubectl get inferenceservice "$MODEL_NAME" -n "$NAMESPACE" 2>/dev/null || true
  die "Deploy first: kubectl apply -f k8s/kserve/iris-inferenceservice.yaml"
fi

# ---------------------------------------------------------------------------
# Build and send request (KServe V2 inference protocol)
# ---------------------------------------------------------------------------
PAYLOAD=$(cat <<EOF
{
  "id": "iris-test-$(date +%s)",
  "inputs": [
    {
      "name": "float_input",
      "shape": [1, 4],
      "datatype": "FP32",
      "data": [$F1, $F2, $F3, $F4]
    }
  ]
}
EOF
)

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Iris KServe Inference Test — AKS${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Gateway   : ${INGRESS_HOST}"
info "Host      : ${HOST_HEADER}"
info "Endpoint  : ${ENDPOINT}"
info "Features  : sepal_length=$F1  sepal_width=$F2  petal_length=$F3  petal_width=$F4"
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$ENDPOINT" \
  -H "Host: $HOST_HEADER" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [[ "$HTTP_CODE" != "200" ]]; then
  echo -e "${RED}Request failed (HTTP $HTTP_CODE):${NC}"
  echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse and display result
# ---------------------------------------------------------------------------
echo -e "${GREEN}Response (HTTP $HTTP_CODE):${NC}"
echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"

CLASS_IDX=$(echo "$BODY" | python3 -c "
import sys, json
resp = json.load(sys.stdin)
outputs = resp.get('outputs', [])
for o in outputs:
    if o.get('name') == 'output_label':
        print(o['data'][0])
        break
" 2>/dev/null || echo "")

if [[ -n "$CLASS_IDX" && "$CLASS_IDX" =~ ^[0-9]+$ ]]; then
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  Predicted class: ${GREEN}${CLASS_NAMES[$CLASS_IDX]} (index $CLASS_IDX)${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi

# ---------------------------------------------------------------------------
# Model metadata
# ---------------------------------------------------------------------------
echo ""
info "Model metadata:"
curl -s -H "Host: $HOST_HEADER" \
  "http://${INGRESS_HOST}/v2/models/${MODEL_NAME}" \
  | python3 -m json.tool 2>/dev/null || true
