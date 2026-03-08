#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# upload-model.sh — Upload the trained ONNX model to MinIO inside Minikube
# ---------------------------------------------------------------------------
# Prerequisites:
#   - MinIO running (installed by setup.sh)
#   - models/iris_rf.onnx exists (run src/train.py first)
#
# Usage:
#   ./scripts/upload-model.sh
# ---------------------------------------------------------------------------

set -euo pipefail

ONNX_SRC="models/iris_rf.onnx"
BUCKET="mlops-models"
DEST_PREFIX="iris"            # s3://mlops-models/iris/model.onnx

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }

[[ -f "$ONNX_SRC" ]] || { echo "ERROR: $ONNX_SRC not found. Run 'python src/train.py' first."; exit 1; }

# Copy the ONNX file as model.onnx (KServe looks for this exact name)
TMP_MODEL="$(mktemp -d)/model.onnx"
cp "$ONNX_SRC" "$TMP_MODEL"

info "Uploading $ONNX_SRC → s3://${BUCKET}/${DEST_PREFIX}/model.onnx ..."

# Use a temporary mc pod inside the cluster to push to MinIO
kubectl run mc-upload --restart=Never --rm -i \
  --image=minio/mc:latest \
  --overrides="{
    \"spec\": {
      \"containers\": [{
        \"name\": \"mc\",
        \"image\": \"minio/mc:latest\",
        \"command\": [\"sh\",\"-c\",\"mc alias set local http://minio.minio-system.svc.cluster.local:9000 minioadmin minioadmin && mc cp /tmp/model.onnx local/${BUCKET}/${DEST_PREFIX}/model.onnx && echo DONE\"],
        \"volumeMounts\": [{\"name\": \"model\", \"mountPath\": \"/tmp/model.onnx\", \"subPath\": \"model.onnx\"}]
      }],
      \"volumes\": [{\"name\": \"model\", \"configMap\": {\"name\": \"iris-model-cm\"}}]
    }
  }" -- true 2>/dev/null || true

# Simpler approach: port-forward MinIO and use local mc if available
if command -v mc &>/dev/null; then
  info "Using local mc CLI via port-forward ..."
  kubectl port-forward svc/minio -n minio-system 9000:9000 &
  PF_PID=$!
  sleep 3

  mc alias set minikube-minio http://127.0.0.1:9000 minioadmin minioadmin --insecure
  mc mb "minikube-minio/${BUCKET}" --ignore-existing
  mc cp "$TMP_MODEL" "minikube-minio/${BUCKET}/${DEST_PREFIX}/model.onnx"

  kill $PF_PID 2>/dev/null || true
  info "Upload complete: s3://${BUCKET}/${DEST_PREFIX}/model.onnx"
else
  info "Tip: Install the MinIO client (mc) for easier uploads:"
  info "  brew install minio/stable/mc   # macOS"
  info "  Then re-run this script."
fi
