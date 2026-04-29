"""
models/save_model.py
--------------------
Utility to serialize / inspect saved model artifacts.

Usage:
  python models/save_model.py --inspect          # Print artifact metadata
  python models/save_model.py --export-onnx      # Export to ONNX (optional)
"""

import argparse
import joblib
import json
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
with open(ROOT / "config.yaml") as f:
    CONFIG = yaml.safe_load(f)

MODELS_DIR = ROOT / CONFIG["paths"]["models"]


def save_model(model, scaler, feature_names: list, path: str):
    """
    Serialize model pipeline to a .pkl file.
    This is called automatically by train.py; expose here for manual use.
    """
    artifacts = {
        "model": model,
        "scaler": scaler,
        "feature_names": feature_names,
    }
    joblib.dump(artifacts, path)
    print(f"✅ Model artifacts saved to: {path}")


def inspect_model(path: Path):
    """Print metadata about a saved model artifact."""
    if not path.exists():
        print(f"❌ File not found: {path}")
        return
    artifacts = joblib.load(path)
    print(f"\n🔍 Model Artifact: {path.name}")
    print(f"   Keys: {list(artifacts.keys())}")
    model = artifacts.get("model")
    if model is not None:
        print(f"   Model type: {type(model).__name__}")
        print(f"   Best iteration: {getattr(model, 'best_iteration', 'N/A')}")
        print(f"   n_features: {model.n_features_in_}")
    feature_names = artifacts.get("feature_names", [])
    print(f"   Features ({len(feature_names)}): {feature_names}")
    val_auc = artifacts.get("val_auc")
    val_acc = artifacts.get("val_accuracy")
    if val_auc:
        print(f"   Validation AUC: {val_auc:.4f}")
    if val_acc:
        print(f"   Validation Accuracy: {val_acc:.4f}")


def export_onnx(path: Path):
    """Export XGBoost model to ONNX format for edge deployment."""
    try:
        from skl2onnx import convert_sklearn
        from skl2onnx.common.data_types import FloatTensorType
        from sklearn.pipeline import Pipeline
    except ImportError:
        print("❌ Install skl2onnx: pip install skl2onnx onnxruntime")
        return

    artifacts = joblib.load(path)
    model = artifacts["model"]
    scaler = artifacts["scaler"]
    feature_names = artifacts["feature_names"]

    pipeline = Pipeline([("scaler", scaler), ("model", model)])
    n_features = len(feature_names)
    initial_type = [("float_input", FloatTensorType([None, n_features]))]
    onnx_model = convert_sklearn(pipeline, initial_types=initial_type)
    onnx_path = path.with_suffix(".onnx")
    with open(onnx_path, "wb") as f:
        f.write(onnx_model.SerializeToString())
    print(f"✅ ONNX model exported: {onnx_path}")


def main():
    parser = argparse.ArgumentParser(description="Inspect or export heart sclerosis model")
    parser.add_argument("--model", default="models/cardiosclerosis_model_v1.pkl")
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--export-onnx", action="store_true")
    args = parser.parse_args()

    model_path = ROOT / args.model
    if args.inspect:
        inspect_model(model_path)
    if args.export_onnx:
        export_onnx(model_path)
    if not args.inspect and not args.export_onnx:
        inspect_model(model_path)


if __name__ == "__main__":
    main()
