#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-push.sh — Build the model OCI image and push to docker.cc.com
# ---------------------------------------------------------------------------
# Usage:
#   ./scripts/build-push.sh [tag]
#
# Examples:
#   ./scripts/build-push.sh          # tag defaults to v1
#   ./scripts/build-push.sh v2
#
# Prerequisites:
#   - Model trained: run ./scripts/train.sh first
#   - Docker logged in: docker login docker.cc.com
# ---------------------------------------------------------------------------

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

REGISTRY="docker.cc.com"
IMAGE_NAME="iris-onnx-model"
IMAGE_TAG="${1:-v1}"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

# ---------------------------------------------------------------------------
# Validate model exists
# ---------------------------------------------------------------------------
SOURCE_MODEL="models/iris_rf.onnx"
TARGET_MODEL="models/model.onnx"

[[ -f "$SOURCE_MODEL" ]] || die "Model not found at $SOURCE_MODEL. Run ./scripts/train.sh first."

# KServe ONNX runtime expects the file to be named model.onnx
info "Renaming $SOURCE_MODEL → $TARGET_MODEL for KServe compatibility ..."
cp "$SOURCE_MODEL" "$TARGET_MODEL"

# ---------------------------------------------------------------------------
# Build image
# ---------------------------------------------------------------------------
info "Building model image: $FULL_IMAGE ..."
docker build \
  -f Dockerfile.model \
  -t "$FULL_IMAGE" \
  --label "model=iris" \
  --label "format=onnx" \
  --label "version=${IMAGE_TAG}" \
  .

# ---------------------------------------------------------------------------
# Push image
# ---------------------------------------------------------------------------
info "Pushing $FULL_IMAGE ..."
docker push "$FULL_IMAGE"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Image pushed: ${FULL_IMAGE}"
info "Next step: kubectl apply -f k8s/kserve/iris-inferenceservice.yaml"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
