# ---------------------------------------------------------------------------
# Stage 1: training job image
# ---------------------------------------------------------------------------
# This image is used to run the training script (src/train.py).
# It is NOT the inference server image — KServe manages that itself via
# its built-in ONNX Runtime server container.
#
# Build:
#   docker build -t iris-trainer:latest .
#
# Run (with MLflow server already up on host):
#   docker run --rm \
#     -e MLFLOW_TRACKING_URI=http://host.docker.internal:5000 \
#     -v $(pwd)/models:/app/models \
#     iris-trainer:latest
# ---------------------------------------------------------------------------

FROM python:3.11-slim AS base

# Security: run as non-root
RUN groupadd -r mluser && useradd -r -g mluser mluser

WORKDIR /app

# Install deps first for better layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source
COPY src/ ./src/

# Owned by non-root user
RUN mkdir -p models && chown -R mluser:mluser /app

USER mluser

# Default: run the training script
CMD ["python", "src/train.py"]
