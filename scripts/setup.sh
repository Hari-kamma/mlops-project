#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — Install KServe + dependencies on Minikube (Mac/Linux)
# ---------------------------------------------------------------------------
# Order of operations (dependencies must be satisfied):
#   1. Minikube
#   2. Istio
#   3. cert-manager        (KNative dependency)
#   4. KNative Serving     (KServe dependency)
#   5. KServe
#   6. MinIO               (model storage)
#
# Usage:
#   chmod +x scripts/setup.sh
#   ./scripts/setup.sh
# ---------------------------------------------------------------------------

set -euo pipefail

# ---- Versions (pin these to avoid surprises) --------------------------------
MINIKUBE_CPUS=4
MINIKUBE_MEMORY=8g
MINIKUBE_DRIVER=docker          # change to 'hyperkit' on Mac if preferred

ISTIO_VERSION=1.21.2
CERT_MANAGER_VERSION=v1.14.5
KNATIVE_VERSION=v1.14.0
KSERVE_VERSION=v0.13.0

# ---- Colors -----------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- Helpers ----------------------------------------------------------------
wait_for_pods() {
  local ns=$1 label=${2:-""} timeout=${3:-300}
  info "Waiting for pods in namespace '$ns' (label: ${label:-all}) ..."
  if [[ -n "$label" ]]; then
    kubectl wait pod -n "$ns" -l "$label" \
      --for=condition=Ready --timeout="${timeout}s"
  else
    kubectl wait pod -n "$ns" --all \
      --for=condition=Ready --timeout="${timeout}s"
  fi
}

check_deps() {
  for cmd in minikube kubectl curl helm; do
    command -v "$cmd" &>/dev/null || die "'$cmd' not found. Please install it first."
  done
  command -v istioctl &>/dev/null || {
    warn "istioctl not found — will download Istio $ISTIO_VERSION"
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
    export PATH="$PWD/istio-${ISTIO_VERSION}/bin:$PATH"
  }
}

# =============================================================================
# STEP 1 — Minikube
# =============================================================================
step1_minikube() {
  info "=== STEP 1: Starting Minikube ==="
  if minikube status | grep -q "Running"; then
    warn "Minikube already running — skipping start"
  else
    minikube start \
      --cpus="$MINIKUBE_CPUS" \
      --memory="$MINIKUBE_MEMORY" \
      --driver="$MINIKUBE_DRIVER" \
      --addons=registry
  fi
  kubectl cluster-info
}

# =============================================================================
# STEP 2 — Istio
# =============================================================================
step2_istio() {
  info "=== STEP 2: Installing Istio $ISTIO_VERSION ==="
  istioctl install --set profile=demo -y
  kubectl label namespace default istio-injection=enabled --overwrite
  wait_for_pods istio-system "" 180
  info "Istio ready."
}

# =============================================================================
# STEP 3 — cert-manager
# =============================================================================
step3_certmanager() {
  info "=== STEP 3: Installing cert-manager $CERT_MANAGER_VERSION ==="
  kubectl apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  info "Waiting for cert-manager webhooks to be ready ..."
  kubectl wait pod -n cert-manager --all \
    --for=condition=Ready --timeout=180s
  info "cert-manager ready."
}

# =============================================================================
# STEP 4 — KNative Serving
# =============================================================================
step4_knative() {
  info "=== STEP 4: Installing KNative Serving $KNATIVE_VERSION ==="
  kubectl apply -f \
    "https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-crds.yaml"
  kubectl apply -f \
    "https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-core.yaml"

  # KNative + Istio integration
  kubectl apply -f \
    "https://github.com/knative/net-istio/releases/download/knative-${KNATIVE_VERSION}/net-istio.yaml"

  # Patch KNative to use the Minikube ingress IP rather than a real DNS
  kubectl patch configmap config-domain -n knative-serving \
    --type=merge \
    -p '{"data":{"example.com":""}}'

  wait_for_pods knative-serving "" 180
  info "KNative Serving ready."
}

# =============================================================================
# STEP 5 — KServe
# =============================================================================
step5_kserve() {
  info "=== STEP 5: Installing KServe $KSERVE_VERSION ==="
  kubectl apply -f \
    "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve.yaml"
  kubectl apply -f \
    "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve-cluster-resources.yaml"

  wait_for_pods kserve "" 300
  info "KServe ready."
}

# =============================================================================
# STEP 6 — MinIO (model storage)
# =============================================================================
step6_minio() {
  info "=== STEP 6: Installing MinIO (model storage) ==="
  kubectl create namespace minio-system 2>/dev/null || true

  helm repo add minio https://charts.min.io/ 2>/dev/null || true
  helm repo update

  helm upgrade --install minio minio/minio \
    --namespace minio-system \
    --set rootUser=minioadmin \
    --set rootPassword=minioadmin \
    --set mode=standalone \
    --set resources.requests.memory=512Mi \
    --set persistence.size=5Gi

  wait_for_pods minio-system "" 120

  # Create the bucket that the InferenceService references
  info "Creating 'mlops-models' bucket in MinIO ..."
  kubectl run mc-setup --restart=Never --rm -i \
    --image=minio/mc:latest \
    --env="MC_HOST_local=http://minioadmin:minioadmin@minio.minio-system.svc.cluster.local:9000" \
    -- sh -c "mc mb local/mlops-models --ignore-existing"

  info "MinIO ready. Access key: minioadmin / minioadmin"
}

# =============================================================================
# STEP 7 — Apply KServe manifests
# =============================================================================
step7_apply_manifests() {
  info "=== STEP 7: Applying KServe + Istio manifests ==="
  kubectl apply -f k8s/istio/gateway.yaml
  # InferenceService applied separately after uploading the model
  info "Gateway applied. Upload your ONNX model first, then run:"
  info "  kubectl apply -f k8s/kserve/iris-inferenceservice.yaml"
  info "  kubectl apply -f k8s/istio/virtual-service.yaml"
}

# =============================================================================
# Main
# =============================================================================
main() {
  check_deps
  step1_minikube
  step2_istio
  step3_certmanager
  step4_knative
  step5_kserve
  step6_minio
  step7_apply_manifests

  echo ""
  info "============================================================"
  info "  Setup complete! Next steps:"
  info "  1. In a NEW terminal: minikube tunnel"
  info "  2. Upload the ONNX model: ./scripts/upload-model.sh"
  info "  3. Apply the InferenceService:"
  info "     kubectl apply -f k8s/kserve/iris-inferenceservice.yaml"
  info "     kubectl apply -f k8s/istio/virtual-service.yaml"
  info "  4. Test inference: ./scripts/test-inference.sh"
  info "============================================================"
}

main "$@"
