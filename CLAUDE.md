# MLOps on Minikube: End-to-End Guide for a DevOps Engineer

## 🎯 Use Case & Model

**Use Case: Iris Flower Classification**

- **Input:** 4 numbers (sepal/petal dimensions)
- **Output:** Flower species (Setosa, Versicolor, Virginica)
- **Why:** Tiny dataset, fast training, well-documented, easy to verify predictions

**Model:** Scikit-learn Random Forest → exported to **ONNX format**

ONNX is the "container image" of ML models — framework-agnostic, portable, and natively supported by most inference servers.

---

## 🏗️ The Stack

| Layer | Tool | Why |
|---|---|---|
| **Training** | Python + Scikit-learn | Simple, fast, great for beginners |
| **Experiment Tracking** | MLflow | Logs metrics, params, artifacts locally |
| **Model Format** | ONNX | Portable, framework-agnostic |
| **Model Registry** | MLflow Model Registry | Version and stage your models |
| **Inference Server** | KServe (on Minikube) | Kubernetes-native, Istio-aware, production-grade |
| **Service Mesh** | Istio | Traffic management, canary deployments |
| **Local Cluster** | Minikube | Local target environment |
| **Container Registry** | Local registry or GHCR | Store model server images |

---

## 🗺️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Your Laptop                          │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │   Training   │    │    MLflow    │    │  ONNX Model  │  │
│  │   Script     │───▶│   Tracking  │───▶│   Artifact   │  │
│  │ (sklearn)    │    │   Server    │    │  (.onnx file) │  │
│  └──────────────┘    └──────────────┘    └──────┬───────┘  │
│                                                 │           │
└─────────────────────────────────────────────────┼───────────┘
                                                  │
                    kubectl apply                  │ model artifact
                         ▼                        ▼
┌─────────────────────────────────────────────────────────────┐
│                     Minikube Cluster                        │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   Istio Gateway                     │   │
│  │         (InferenceService routes here)              │   │
│  └─────────────────────┬───────────────────────────────┘   │
│                        │                                    │
│  ┌─────────────────────▼───────────────────────────────┐   │
│  │              KServe InferenceService                │   │
│  │                                                     │   │
│  │   ┌──────────────┐      ┌──────────────────────┐   │   │
│  │   │  Predictor   │      │  Transformer (opt.)  │   │   │
│  │   │  (ONNX RT)   │      │  pre/post-process    │   │   │
│  │   └──────────────┘      └──────────────────────┘   │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                        │
              curl/Python client
              POST /v2/models/iris/infer
```

---

## 📁 Project Structure

```
project/
├── data/               # raw + processed data
├── notebooks/          # exploration only, never production
├── src/
│   ├── train.py        # training script
│   ├── evaluate.py     # metrics
│   └── export.py       # save to ONNX
├── models/             # saved artifacts
├── k8s/
│   ├── inference-service.yaml
│   ├── gateway.yaml
│   └── virtual-service.yaml
├── Dockerfile
└── requirements.txt
```

---

## 📋 Best Practices: Training Phase

### 1. Always Version Everything
- Training code → **Git**
- Dataset → store a hash/checksum at minimum
- Hyperparameters → `mlflow.log_param()`
- Metrics → `mlflow.log_metric()`
- Model artifact → `mlflow.log_artifact()`

### 2. Log Everything with MLflow
```python
import mlflow

with mlflow.start_run():
    mlflow.log_param("n_estimators", 100)
    mlflow.log_param("max_depth", 5)
    mlflow.log_metric("accuracy", 0.97)
    mlflow.log_metric("f1_score", 0.96)
    mlflow.log_artifact("model.onnx")
```

### 3. Export to ONNX (Not .pkl)
Never deploy a raw `.pkl` scikit-learn file in production — it's tied to library versions and Python versions. ONNX is version-stable.

```python
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType

initial_type = [("float_input", FloatTensorType([None, 4]))]
onnx_model = convert_sklearn(clf, initial_types=initial_type)

with open("models/iris.onnx", "wb") as f:
    f.write(onnx_model.SerializeToString())
```

### 4. Validate ONNX Before Deploying
```python
import onnxruntime as rt
import numpy as np

sess = rt.InferenceSession("models/iris.onnx")
input_name = sess.get_inputs()[0].name
pred = sess.run(None, {input_name: np.array([[5.1, 3.5, 1.4, 0.2]], dtype=np.float32)})
print(pred)  # Should output class label
```

### 5. Separate Notebooks from Production Code
- Use notebooks **only** for exploration and visualization
- All training logic goes into `src/train.py` as a proper script
- Training scripts should be runnable via CLI: `python src/train.py --n-estimators 100`

---

## 📋 Best Practices: Deployment Phase

### 1. Use KServe's `InferenceService` CRD
Don't write your own Flask/FastAPI inference server. KServe gives you:
- Automatic scaling (including scale-to-zero)
- Canary deployments (traffic splits between model versions)
- A standardized `/v2` inference API
- Native Istio VirtualService integration

### 2. Use the V2 Inference Protocol
```bash
POST /v2/models/{model-name}/infer

{
  "inputs": [{
    "name": "float_input",
    "shape": [1, 4],
    "datatype": "FP32",
    "data": [5.1, 3.5, 1.4, 0.2]
  }]
}
```

### 3. Always Set Resource Requests/Limits
```yaml
resources:
  requests:
    cpu: "100m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"
```

### 4. Use Istio for Traffic Management
KServe + Istio work natively together. Your `InferenceService` automatically creates a `VirtualService`. Route via the Istio Gateway — don't hack ingress manually.

### 5. Start with PERMISSIVE mTLS
Istio's `PeerAuthentication` mTLS settings can block KServe internal traffic. Start with `PERMISSIVE` mode in the `kserve` namespace, then tighten later.

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: kserve
spec:
  mtls:
    mode: PERMISSIVE
```

---

## 🛤️ Step-by-Step Roadmap

### Phase 1 — Train & Track (Local, no K8s yet)
1. Write training script with scikit-learn
2. Export model to ONNX
3. Track experiments with MLflow locally (`mlflow ui`)
4. Verify ONNX model works with `onnxruntime`

### Phase 2 — Package
1. Write a `Dockerfile` for your training job (good habit even if running locally)
2. Decide model storage: start with a local PVC or MinIO on Minikube

### Phase 3 — Deploy on Minikube
1. Start Minikube with enough resources:
   ```bash
   minikube start --cpus=4 --memory=8g --driver=docker
   ```
2. Install Istio:
   ```bash
   istioctl install --set profile=demo -y
   ```
3. Install dependencies in order:
   ```
   cert-manager → KNative Serving → KServe
   ```
4. Apply your `InferenceService` YAML
5. Watch KServe provision the predictor pod:
   ```bash
   kubectl get inferenceservice -n kserve-test -w
   ```

### Phase 4 — Access via Istio Gateway
1. Run `minikube tunnel` (keep it running in a separate terminal)
2. Get the Istio ingress gateway IP:
   ```bash
   export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   ```
3. Send a prediction:
   ```bash
   curl -X POST http://${INGRESS_HOST}/v2/models/iris/infer \
     -H "Host: iris.kserve-test.example.com" \
     -H "Content-Type: application/json" \
     -d '{
       "inputs": [{
         "name": "float_input",
         "shape": [1, 4],
         "datatype": "FP32",
         "data": [5.1, 3.5, 1.4, 0.2]
       }]
     }'
   ```

---

## ⚙️ Key Kubernetes Manifests

### InferenceService
```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: iris
  namespace: kserve-test
spec:
  predictor:
    model:
      modelFormat:
        name: onnx
      storageUri: "pvc://iris-models-pvc/iris.onnx"
      resources:
        requests:
          cpu: "100m"
          memory: "256Mi"
        limits:
          cpu: "500m"
          memory: "512Mi"
```

### Istio Gateway
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: kserve-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*.kserve-test.example.com"
```

---

## ⚡ Common Pitfalls

| Problem | Cause | Fix |
|---|---|---|
| KServe pods CrashLoop | cert-manager not ready | Wait for all cert-manager pods to be `Running` first |
| InferenceService stuck `Not Ready` | KNative not installed | Install KNative Serving before KServe |
| 404 on inference endpoint | Wrong `Host` header | Match the host to your `InferenceService` name + namespace |
| Internal traffic blocked | Istio mTLS STRICT mode | Set `PERMISSIVE` in kserve namespace |
| Istio LB has no IP | `minikube tunnel` not running | Run `minikube tunnel` in a separate terminal |
| ONNX shape mismatch | Wrong input shape in request | Validate with `onnxruntime` locally first |

---

## 📦 Requirements

```txt
# Training
scikit-learn==1.3.2
skl2onnx==1.16.0
onnxruntime==1.17.0
numpy==1.26.4
pandas==2.2.0

# Experiment Tracking
mlflow==2.10.0

# Dev
jupyter==1.0.0
matplotlib==3.8.2
```

---

## 🔗 Reference Links

- [KServe Docs](https://kserve.github.io/website/)
- [MLflow Docs](https://mlflow.org/docs/latest/index.html)
- [ONNX Runtime](https://onnxruntime.ai/)
- [Istio Getting Started](https://istio.io/latest/docs/setup/getting-started/)
- [KNative Install](https://knative.dev/docs/install/)
- [skl2onnx Docs](https://onnx.ai/sklearn-onnx/)
