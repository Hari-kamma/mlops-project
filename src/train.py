"""
train.py — Iris classifier training script.

Trains a Random Forest on the Iris dataset, evaluates it, exports to ONNX,
and logs everything (params, metrics, artifact) to MLflow.

Usage:
    python src/train.py [--n-estimators N] [--max-depth D] [--run-name NAME]
"""

import argparse
import os
import sys
import hashlib
import json
from pathlib import Path

import numpy as np
import mlflow
import mlflow.sklearn
from sklearn.datasets import load_iris
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score, f1_score, classification_report
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType
import onnxruntime as rt

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = ROOT / "models"
MODELS_DIR.mkdir(exist_ok=True)
ONNX_PATH = MODELS_DIR / "iris_rf.onnx"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def dataset_hash(X, y) -> str:
    """Deterministic hash of the dataset for reproducibility tracking."""
    combined = np.concatenate([X, y.reshape(-1, 1)], axis=1).tobytes()
    return hashlib.sha256(combined).hexdigest()[:12]


def verify_onnx_model(onnx_path: Path, X_test: np.ndarray, y_test: np.ndarray) -> float:
    """Run inference with onnxruntime to sanity-check the exported model."""
    sess = rt.InferenceSession(str(onnx_path))
    input_name = sess.get_inputs()[0].name
    label_name = sess.get_outputs()[0].name

    pred = sess.run([label_name], {input_name: X_test.astype(np.float32)})[0]
    acc = accuracy_score(y_test, pred)
    print(f"[ONNX verify] accuracy={acc:.4f}")
    return acc


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(description="Train Iris Random Forest and export to ONNX")
    parser.add_argument("--n-estimators", type=int, default=100)
    parser.add_argument("--max-depth", type=int, default=None)
    parser.add_argument("--test-size", type=float, default=0.2)
    parser.add_argument("--random-state", type=int, default=42)
    parser.add_argument("--run-name", type=str, default="iris-rf")
    parser.add_argument("--experiment", type=str, default="iris-classification")
    return parser.parse_args()


def main():
    args = parse_args()

    # ------------------------------------------------------------------
    # MLflow setup
    # ------------------------------------------------------------------
    mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI", "http://127.0.0.1:5001"))
    mlflow.set_experiment(args.experiment)

    with mlflow.start_run(run_name=args.run_name) as run:
        print(f"MLflow run id: {run.info.run_id}")

        # ------------------------------------------------------------------
        # Data
        # ------------------------------------------------------------------
        iris = load_iris()
        X, y = iris.data.astype(np.float32), iris.target

        X_train, X_test, y_train, y_test = train_test_split(
            X, y,
            test_size=args.test_size,
            random_state=args.random_state,
            stratify=y,
        )

        dset_hash = dataset_hash(X, y)
        print(f"Dataset hash: {dset_hash}  (samples={len(X)}, features={X.shape[1]})")

        # ------------------------------------------------------------------
        # Log params
        # ------------------------------------------------------------------
        mlflow.log_params({
            "n_estimators": args.n_estimators,
            "max_depth": str(args.max_depth),
            "test_size": args.test_size,
            "random_state": args.random_state,
            "dataset_hash": dset_hash,
            "n_classes": len(iris.target_names),
            "feature_names": json.dumps(list(iris.feature_names)),
            "class_names": json.dumps(list(iris.target_names)),
        })

        # ------------------------------------------------------------------
        # Train
        # ------------------------------------------------------------------
        clf = RandomForestClassifier(
            n_estimators=args.n_estimators,
            max_depth=args.max_depth,
            random_state=args.random_state,
            n_jobs=-1,
        )
        clf.fit(X_train, y_train)

        # ------------------------------------------------------------------
        # Evaluate
        # ------------------------------------------------------------------
        y_pred = clf.predict(X_test)
        acc = accuracy_score(y_test, y_pred)
        f1 = f1_score(y_test, y_pred, average="weighted")

        print(f"\nTest accuracy : {acc:.4f}")
        print(f"Test F1 (weighted): {f1:.4f}")
        print("\n" + classification_report(y_test, y_pred, target_names=iris.target_names))

        mlflow.log_metrics({"accuracy": acc, "f1_weighted": f1})

        # ------------------------------------------------------------------
        # Export to ONNX
        # ------------------------------------------------------------------
        initial_type = [("float_input", FloatTensorType([None, X.shape[1]]))]
        onnx_model = convert_sklearn(clf, initial_types=initial_type)

        with open(ONNX_PATH, "wb") as f:
            f.write(onnx_model.SerializeToString())

        print(f"\nONNX model saved → {ONNX_PATH}")

        # ------------------------------------------------------------------
        # Verify ONNX output matches sklearn output
        # ------------------------------------------------------------------
        onnx_acc = verify_onnx_model(ONNX_PATH, X_test, y_test)
        assert abs(onnx_acc - acc) < 1e-6, "ONNX accuracy does not match sklearn — export failed!"

        mlflow.log_metric("onnx_accuracy", onnx_acc)

        # ------------------------------------------------------------------
        # Log ONNX artifact + sklearn model
        # ------------------------------------------------------------------
        mlflow.log_artifact(str(ONNX_PATH), artifact_path="onnx")
        mlflow.sklearn.log_model(clf, artifact_path="sklearn_model")

        # Save a small metadata sidecar next to the ONNX file
        meta = {
            "run_id": run.info.run_id,
            "accuracy": acc,
            "f1_weighted": f1,
            "dataset_hash": dset_hash,
            "input_shape": [None, int(X.shape[1])],
            "input_dtype": "float32",
            "class_names": list(iris.target_names),
            "onnx_input_name": "float_input",
            "onnx_output_name": "output_label",
        }
        meta_path = MODELS_DIR / "iris_rf_meta.json"
        with open(meta_path, "w") as f:
            json.dump(meta, f, indent=2)
        mlflow.log_artifact(str(meta_path), artifact_path="onnx")

        print(f"\nRun complete. MLflow run_id={run.info.run_id}")
        print(f"Model artifacts logged under experiment '{args.experiment}'")

    return 0


if __name__ == "__main__":
    sys.exit(main())
