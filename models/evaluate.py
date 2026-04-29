

import yaml
import joblib
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
from pathlib import Path
from sklearn.metrics import (
    classification_report, confusion_matrix, roc_auc_score,
    roc_curve, precision_recall_curve, average_precision_score,
    accuracy_score, f1_score, brier_score_loss,
)
from sklearn.calibration import calibration_curve

ROOT = Path(__file__).resolve().parents[1]
with open(ROOT / "config.yaml") as f:
    CONFIG = yaml.safe_load(f)

PROCESSED_DIR = ROOT / CONFIG["paths"]["processed_data"]
MODELS_DIR = ROOT / CONFIG["paths"]["models"]
OUTPUT_DIR = ROOT / CONFIG["paths"]["output"]
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


def main():
    # ── Load model ────────────────────────────────────────────────────────────
    model_path = MODELS_DIR / "cardiosclerosis_model_v1.pkl"
    if not model_path.exists():
        print(f"❌ {model_path} not found. Run models/train.py first.")
        return
    print(f"📂 Loading model: {model_path}")
    artifacts = joblib.load(model_path)
    model = artifacts["model"]
    scaler = artifacts["scaler"]
    feature_names = artifacts["feature_names"]

    # ── Load test set ─────────────────────────────────────────────────────────
    test_path = PROCESSED_DIR / "test_balanced.csv"
    if not test_path.exists():
        print(f"❌ {test_path} not found.")
        return
    df_test = pd.read_csv(test_path)
    y_test = df_test["label"].astype(int)
    X_test = df_test.drop(columns=["label"])
    # dataset_source may be in X_test if saved there
    source_col = None
    if "dataset_source" in X_test.columns:
        sources = X_test["dataset_source"].copy()
        source_col = sources
        X_test = X_test.drop(columns=["dataset_source"])

    # Align columns
    for col in feature_names:
        if col not in X_test.columns:
            X_test[col] = 0.0
    X_test = X_test[feature_names]

    X_test_scaled = scaler.transform(X_test)
    y_proba = model.predict_proba(X_test_scaled)[:, 1]
    y_pred = (y_proba >= 0.5).astype(int)

    # ── Overall metrics ───────────────────────────────────────────────────────
    acc = accuracy_score(y_test, y_pred)
    auc = roc_auc_score(y_test, y_proba)
    f1 = f1_score(y_test, y_pred)
    ap = average_precision_score(y_test, y_proba)
    brier = brier_score_loss(y_test, y_proba)
    print("\n" + "=" * 50)
    print("📊 TEST SET EVALUATION")
    print("=" * 50)
    print(f"  Accuracy      : {acc:.4f}")
    print(f"  AUC-ROC       : {auc:.4f}")
    print(f"  F1 (Cardio)   : {f1:.4f}")
    print(f"  Avg Precision : {ap:.4f}")
    print(f"  Brier Score   : {brier:.4f}")
    print()
    print(classification_report(y_test, y_pred, target_names=["Healthy", "Cardiosclerosis"]))

    if auc >= 0.90:
        print("✅ AUC target achieved (≥0.90)!")
    else:
        print(f"⚠️  AUC {auc:.4f} below target 0.90")

    # ── Per-dataset breakdown ─────────────────────────────────────────────────
    if source_col is not None:
        print("\n📈 Per-Dataset Performance:")
        df_eval = pd.DataFrame({"y_true": y_test.values, "y_pred": y_pred,
                                 "y_proba": y_proba, "source": source_col.values})
        for src, grp in df_eval.groupby("source"):
            if len(grp["y_true"].unique()) < 2:
                continue
            src_auc = roc_auc_score(grp["y_true"], grp["y_proba"])
            src_acc = accuracy_score(grp["y_true"], grp["y_pred"])
            print(f"  {src:25s}  Acc={src_acc:.3f}  AUC={src_auc:.3f}  N={len(grp)}")

    # ── Plots ─────────────────────────────────────────────────────────────────
    fig = plt.figure(figsize=(16, 10))
    gs = gridspec.GridSpec(2, 3, figure=fig)

    # 1. Confusion Matrix
    ax1 = fig.add_subplot(gs[0, 0])
    cm = confusion_matrix(y_test, y_pred)
    im = ax1.imshow(cm, cmap="Blues")
    ax1.set_xticks([0, 1]); ax1.set_yticks([0, 1])
    ax1.set_xticklabels(["Healthy", "Cardio"]); ax1.set_yticklabels(["Healthy", "Cardio"])
    ax1.set_xlabel("Predicted"); ax1.set_ylabel("Actual")
    ax1.set_title("Confusion Matrix")
    for i in range(2):
        for j in range(2):
            ax1.text(j, i, cm[i, j], ha="center", va="center", fontsize=14,
                     color="white" if cm[i, j] > cm.max() / 2 else "black")

    # 2. ROC Curve
    ax2 = fig.add_subplot(gs[0, 1])
    fpr, tpr, _ = roc_curve(y_test, y_proba)
    ax2.plot(fpr, tpr, "b-", lw=2, label=f"AUC = {auc:.3f}")
    ax2.plot([0, 1], [0, 1], "k--", lw=1)
    ax2.set_xlabel("False Positive Rate"); ax2.set_ylabel("True Positive Rate")
    ax2.set_title("ROC Curve"); ax2.legend()

    # 3. Precision-Recall Curve
    ax3 = fig.add_subplot(gs[0, 2])
    precision, recall, _ = precision_recall_curve(y_test, y_proba)
    ax3.plot(recall, precision, "r-", lw=2, label=f"AP = {ap:.3f}")
    ax3.set_xlabel("Recall"); ax3.set_ylabel("Precision")
    ax3.set_title("Precision-Recall Curve"); ax3.legend()

    # 4. Calibration Plot
    ax4 = fig.add_subplot(gs[1, 0])
    prob_true, prob_pred = calibration_curve(y_test, y_proba, n_bins=10)
    ax4.plot(prob_pred, prob_true, "s-", color="blue", label="Model")
    ax4.plot([0, 1], [0, 1], "k--", label="Perfect")
    ax4.set_xlabel("Mean Predicted Probability"); ax4.set_ylabel("Fraction of Positives")
    ax4.set_title("Calibration Plot"); ax4.legend()

    # 5. Feature Importance (top 15)
    ax5 = fig.add_subplot(gs[1, 1:])
    importances = pd.Series(model.feature_importances_, index=feature_names).nlargest(15)
    importances.sort_values().plot(kind="barh", ax=ax5, color="steelblue")
    ax5.set_title("Top 15 Feature Importances (XGBoost)")
    ax5.set_xlabel("Importance Score")

    plt.suptitle("Heart Sclerosis Model — Test Set Evaluation", fontsize=14, fontweight="bold")
    plt.tight_layout()
    plot_path = OUTPUT_DIR / "evaluation_report.png"
    plt.savefig(plot_path, dpi=150, bbox_inches="tight")
    print(f"\n📊 Evaluation plots saved: {plot_path}")
    print("✅ Evaluation complete.")


if __name__ == "__main__":
    main()
