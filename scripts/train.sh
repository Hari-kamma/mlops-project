#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# train.sh — Create venv, install deps, and run the training script
# ---------------------------------------------------------------------------
# Usage:
#   ./scripts/train.sh [train.py args...]
#
# Examples:
#   ./scripts/train.sh
#   ./scripts/train.sh --n-estimators 200 --max-depth 5
# ---------------------------------------------------------------------------

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv"

# ---------------------------------------------------------------------------
# Create venv if it doesn't exist
# ---------------------------------------------------------------------------
if [[ ! -d "$VENV" ]]; then
  echo "[setup] Creating venv at $VENV ..."
  python3 -m venv "$VENV"
fi

PIP="$VENV/bin/pip"
PYTHON="$VENV/bin/python"

# ---------------------------------------------------------------------------
# Install / sync dependencies
# ---------------------------------------------------------------------------
echo "[setup] Installing dependencies from requirements.txt ..."
"$PIP" install --upgrade pip --quiet
"$PIP" install -r "$ROOT/requirements.txt" --quiet

# ---------------------------------------------------------------------------
# Run training
# ---------------------------------------------------------------------------
echo ""
echo "[train] Starting training run ..."
cd "$ROOT"
"$PYTHON" src/train.py "$@"
