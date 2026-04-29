

import argparse
import yaml
import numpy as np
import pandas as pd
import joblib
import os
from pathlib import Path
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import roc_auc_score, accuracy_score
import xgboost as xgb

ROOT = Path(__file__).resolve().parents[1]
with open(ROOT / "config.yaml") as f:
    CONFIG = yaml.safe_load(f)

PROCESSED_DIR = ROOT / CONFIG["paths"]["processed_data"]
MODELS_DIR = ROOT / CONFIG["paths"]["models"]
MODELS_DIR.mkdir(parents=True, exist_ok=True)

MODEL_CFG = CONFIG["model"]["params"]


def load_split(filename: str):
    path = PROCESSED_DIR / filename
    if not path.exists():
        raise FileNotFoundError(f"❌ {path} not found. Run data pipeline first.")
    df = pd.read_csv(path)
    y = df["label"].astype(int)
    X = df.drop(columns=["label"])
    return X, y


def main():
    parser = argparse.ArgumentParser(description="Train XGBoost heart sclerosis model")
    parser.add_argument("--config", default="config.yaml")
    args = parser.parse_args()

    print("📂 Loading training and validation data...")
    X_train, y_train = load_split("train_balanced.csv")
    X_val, y_val = load_split("val_balanced.csv")

    feature_names = list(X_train.columns)
    print(f"   Features: {len(feature_names)}")
    print(f"   Train: {len(X_train):,} | Val: {len(X_val):,}")
    print(f"   Train labels: {y_train.value_counts().to_dict()}")

    # ── Feature scaling ───────────────────────────────────────────────────────
    print("\n⚙️  Fitting StandardScaler on training data...")
    scaler = StandardScaler()
    X_train_scaled = scaler.fit_transform(X_train)
    X_val_scaled = scaler.transform(X_val)

    # ── Model definition ──────────────────────────────────────────────────────
    print("\n🚀 Training XGBoost classifier...")
    model = xgb.XGBClassifier(
        n_estimators=MODEL_CFG["n_estimators"],
        max_depth=MODEL_CFG["max_depth"],
        learning_rate=MODEL_CFG["learning_rate"],
        subsample=MODEL_CFG["subsample"],
        colsample_bytree=MODEL_CFG["colsample_bytree"],
        eval_metric=MODEL_CFG["eval_metric"],
        early_stopping_rounds=MODEL_CFG["early_stopping_rounds"],
        random_state=MODEL_CFG["random_state"],
        use_label_encoder=False,
        verbosity=1,
    )

    model.fit(
        X_train_scaled, y_train,
        eval_set=[(X_val_scaled, y_val)],
        verbose=20,
    )

    # ── Quick validation metrics ──────────────────────────────────────────────
    val_proba = model.predict_proba(X_val_scaled)[:, 1]
    val_pred = (val_proba >= 0.5).astype(int)
    val_acc = accuracy_score(y_val, val_pred)
    val_auc = roc_auc_score(y_val, val_proba)
    print(f"\n📊 Validation — Accuracy: {val_acc:.4f} | AUC: {val_auc:.4f}")
    if val_auc < 0.90:
        print("  ⚠️  AUC below target (0.90). Consider tuning hyperparameters or adding features.")
    else:
        print("  ✅ AUC target achieved (≥0.90).")

    # ── Save artifacts ────────────────────────────────────────────────────────
    artifacts = {
        "model": model,
        "scaler": scaler,
        "feature_names": feature_names,
        "val_accuracy": val_acc,
        "val_auc": val_auc,
        "best_iteration": model.best_iteration,
    }
    model_path = MODELS_DIR / "cardiosclerosis_model_v1.pkl"
    joblib.dump(artifacts, model_path)
    print(f"\n✅ Model saved: {model_path}")
    print("   Next step: python models/evaluate.py")


if __name__ == "__main__":
    main()
