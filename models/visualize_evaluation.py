"""
visualize_evaluation.py
=======================
Generates a full visual evaluation report for the trained model.

Saves to output/:
  eval_confusion_matrix.png
  eval_roc_curve.png
  eval_calibration_curve.png
  eval_probability_distribution.png
  eval_threshold_analysis.png
  eval_summary.png   ← all 5 panels in one image

Usage:
  python models/visualize_evaluation.py
"""

import sys
import yaml
import joblib
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
from matplotlib.patches import FancyBboxPatch
from pathlib import Path

from sklearn.metrics import (
    confusion_matrix, roc_curve, auc,
    precision_recall_curve, average_precision_score,
    accuracy_score, f1_score, roc_auc_score, brier_score_loss,
)
from sklearn.calibration import calibration_curve

ROOT = Path(__file__).resolve().parents[1]
with open(ROOT / "config.yaml") as f:
    CONFIG = yaml.safe_load(f)

PROCESSED_DIR = ROOT / CONFIG["paths"]["processed_data"]
MODELS_DIR    = ROOT / CONFIG["paths"]["models"]
OUTPUT_DIR    = ROOT / CONFIG["paths"]["output"]
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# ── Colour palette ─────────────────────────────────────────────────────────────
C_HEALTHY  = "#4CAF50"   # green
C_CARDIO   = "#F44336"   # red
C_NEUTRAL  = "#2196F3"   # blue
C_WARN     = "#FF9800"   # orange
C_BG       = "#FAFAFA"
C_GRID     = "#E0E0E0"
FONT_MAIN  = "DejaVu Sans"

plt.rcParams.update({
    "font.family":       FONT_MAIN,
    "axes.facecolor":    C_BG,
    "figure.facecolor":  "white",
    "axes.grid":         True,
    "grid.color":        C_GRID,
    "grid.linewidth":    0.8,
    "axes.spines.top":   False,
    "axes.spines.right": False,
})


def load_artifacts():
    path = MODELS_DIR / "cardiosclerosis_model_v1.pkl"
    if not path.exists():
        print(f"❌ Model not found: {path}\n   Run: python models/train.py first.")
        sys.exit(1)
    art = joblib.load(path)
    return art["model"], art["scaler"], art["feature_names"]


def load_test_set(feature_names):
    path = PROCESSED_DIR / "test_balanced.csv"
    if not path.exists():
        print(f"❌ Test set not found: {path}\n   Run the data pipeline first.")
        sys.exit(1)
    df = pd.read_csv(path)
    y  = df["label"].astype(int).values
    X  = df.drop(columns=["label"])
    if "dataset_source" in X.columns:
        X = X.drop(columns=["dataset_source"])
    for col in feature_names:
        if col not in X.columns:
            X[col] = 0.0
    X = X[feature_names].fillna(0.0)
    return X, y


# ── 1. Confusion Matrix ────────────────────────────────────────────────────────
def plot_confusion_matrix(ax, y_true, y_pred):
    cm = confusion_matrix(y_true, y_pred)
    tn, fp, fn, tp = cm.ravel()
    labels = [["True Negative\n(Correctly\nidentified healthy)", "False Positive\n(Healthy flagged\nas cardiac)"],
              ["False Negative\n(Cardiac missed)", "True Positive\n(Correctly\nidentified cardiac)"]]
    colors = [[C_HEALTHY, C_WARN], [C_WARN, C_CARDIO]]
    alphas = [[0.7, 0.4], [0.4, 0.7]]
    vals   = [[tn, fp], [fn, tp]]

    for i in range(2):
        for j in range(2):
            ax.add_patch(FancyBboxPatch((j+0.05, 1-i+0.05), 0.9, 0.9,
                boxstyle="round,pad=0.02",
                facecolor=colors[i][j], alpha=alphas[i][j], linewidth=0))
            ax.text(j+0.5, 1-i+0.65, str(vals[i][j]),
                    ha="center", va="center", fontsize=22, fontweight="bold", color="white")
            ax.text(j+0.5, 1-i+0.3, labels[i][j],
                    ha="center", va="center", fontsize=7.5, color="white", alpha=0.95)

    ax.set_xlim(0, 2); ax.set_ylim(0, 2)
    ax.set_xticks([0.5, 1.5]); ax.set_xticklabels(["Predicted\nHealthy", "Predicted\nCardiac"], fontsize=10)
    ax.set_yticks([0.5, 1.5]); ax.set_yticklabels(["Cardiac\n(Actual)", "Healthy\n(Actual)"], fontsize=10)
    acc = accuracy_score(y_true, y_pred)
    ax.set_title(f"Confusion Matrix   (Accuracy {acc:.1%})", fontsize=12, fontweight="bold", pad=12)
    ax.grid(False)


# ── 2. ROC Curve ──────────────────────────────────────────────────────────────
def plot_roc(ax, y_true, y_proba):
    fpr, tpr, thresholds = roc_curve(y_true, y_proba)
    roc_auc = auc(fpr, tpr)
    ax.plot(fpr, tpr, color=C_CARDIO, lw=2.5, label=f"Model  (AUC = {roc_auc:.3f})")
    ax.fill_between(fpr, tpr, alpha=0.08, color=C_CARDIO)
    ax.plot([0,1],[0,1], "k--", lw=1.2, label="Random classifier")
    # Mark optimal threshold (closest to top-left)
    dist = np.sqrt(fpr**2 + (1-tpr)**2)
    opt_idx = np.argmin(dist)
    ax.scatter(fpr[opt_idx], tpr[opt_idx], s=80, color=C_CARDIO, zorder=5,
               label=f"Optimal threshold = {thresholds[opt_idx]:.2f}")
    ax.set_xlabel("False Positive Rate", fontsize=10)
    ax.set_ylabel("True Positive Rate", fontsize=10)
    ax.set_title("ROC Curve", fontsize=12, fontweight="bold", pad=12)
    ax.legend(fontsize=9, loc="lower right")
    ax.set_xlim(-0.02, 1.02); ax.set_ylim(-0.02, 1.02)


# ── 3. Calibration Curve ──────────────────────────────────────────────────────
def plot_calibration(ax, y_true, y_proba):
    prob_true, prob_pred = calibration_curve(y_true, y_proba, n_bins=10)
    brier = brier_score_loss(y_true, y_proba)
    ax.plot(prob_pred, prob_true, "s-", color=C_NEUTRAL, lw=2, ms=7, label=f"Model  (Brier = {brier:.3f})")
    ax.plot([0,1],[0,1], "k--", lw=1.2, label="Perfect calibration")
    ax.fill_between(prob_pred, prob_true, prob_pred,
                    where=(prob_true > prob_pred), alpha=0.15, color=C_CARDIO, label="Over-confident")
    ax.fill_between(prob_pred, prob_true, prob_pred,
                    where=(prob_true < prob_pred), alpha=0.15, color=C_HEALTHY, label="Under-confident")
    ax.set_xlabel("Mean Predicted Probability", fontsize=10)
    ax.set_ylabel("Fraction of Positives", fontsize=10)
    ax.set_title("Probability Calibration Curve", fontsize=12, fontweight="bold", pad=12)
    ax.legend(fontsize=9)
    ax.set_xlim(-0.02, 1.02); ax.set_ylim(-0.02, 1.02)


# ── 4. Probability Distribution ───────────────────────────────────────────────
def plot_prob_dist(ax, y_true, y_proba):
    healthy = y_proba[y_true == 0]
    cardiac = y_proba[y_true == 1]
    bins = np.linspace(0, 1, 35)
    ax.hist(healthy, bins=bins, alpha=0.65, color=C_HEALTHY, label=f"Healthy  (n={len(healthy):,})", density=True)
    ax.hist(cardiac, bins=bins, alpha=0.65, color=C_CARDIO,  label=f"Cardiac  (n={len(cardiac):,})", density=True)
    ax.axvline(0.5, color="black", lw=1.5, ls="--", label="Decision threshold (0.5)")
    ax.set_xlabel("Predicted Cardiosclerosis Probability", fontsize=10)
    ax.set_ylabel("Density", fontsize=10)
    ax.set_title("Prediction Probability Distribution", fontsize=12, fontweight="bold", pad=12)
    ax.legend(fontsize=9)
    overlap = np.sum((healthy > 0.5)) / len(healthy) + np.sum((cardiac < 0.5)) / len(cardiac)
    ax.text(0.97, 0.97, f"Separation score:\n{1-overlap/2:.1%}", transform=ax.transAxes,
            ha="right", va="top", fontsize=9, bbox=dict(boxstyle="round", fc="white", alpha=0.8))


# ── 5. Threshold Analysis ─────────────────────────────────────────────────────
def plot_threshold_analysis(ax, y_true, y_proba):
    thresholds = np.linspace(0.01, 0.99, 200)
    precisions, recalls, f1s, accs = [], [], [], []
    for t in thresholds:
        pred = (y_proba >= t).astype(int)
        tp = np.sum((pred == 1) & (y_true == 1))
        fp = np.sum((pred == 1) & (y_true == 0))
        fn = np.sum((pred == 0) & (y_true == 1))
        tn = np.sum((pred == 0) & (y_true == 0))
        prec = tp / (tp + fp) if (tp + fp) > 0 else 0
        rec  = tp / (tp + fn) if (tp + fn) > 0 else 0
        f1   = 2*prec*rec/(prec+rec) if (prec+rec) > 0 else 0
        acc  = (tp + tn) / len(y_true)
        precisions.append(prec); recalls.append(rec)
        f1s.append(f1);          accs.append(acc)

    ax.plot(thresholds, precisions, color=C_NEUTRAL,  lw=2,   label="Precision")
    ax.plot(thresholds, recalls,    color=C_CARDIO,   lw=2,   label="Recall (Sensitivity)")
    ax.plot(thresholds, f1s,        color=C_WARN,     lw=2.5, label="F1 Score")
    ax.plot(thresholds, accs,       color=C_HEALTHY,  lw=2,   label="Accuracy", ls="--")
    best_f1_idx = np.argmax(f1s)
    ax.axvline(thresholds[best_f1_idx], color=C_WARN, lw=1.5, ls=":",
               label=f"Best F1 threshold = {thresholds[best_f1_idx]:.2f}")
    ax.axvline(0.5, color="black", lw=1.2, ls="--", alpha=0.5, label="Default threshold (0.5)")
    ax.set_xlabel("Decision Threshold", fontsize=10)
    ax.set_ylabel("Score", fontsize=10)
    ax.set_title("Threshold Analysis: Precision–Recall Trade-off", fontsize=12, fontweight="bold", pad=12)
    ax.legend(fontsize=9, loc="lower left")
    ax.set_xlim(0, 1); ax.set_ylim(0, 1.05)


# ── Summary panel ─────────────────────────────────────────────────────────────
def plot_metrics_summary(ax, y_true, y_pred, y_proba):
    ax.axis("off")
    acc  = accuracy_score(y_true, y_pred)
    auc_ = roc_auc_score(y_true, y_proba)
    f1   = f1_score(y_true, y_pred)
    ap   = average_precision_score(y_true, y_proba)
    brier= brier_score_loss(y_true, y_proba)
    cm   = confusion_matrix(y_true, y_pred)
    tn, fp, fn, tp = cm.ravel()
    sens = tp / (tp + fn)
    spec = tn / (tn + fp)

    metrics = [
        ("Accuracy",          f"{acc:.1%}",  acc  >= 0.85),
        ("AUC-ROC",           f"{auc_:.3f}", auc_ >= 0.90),
        ("F1 Score",          f"{f1:.3f}",   f1   >= 0.80),
        ("Avg Precision",     f"{ap:.3f}",   ap   >= 0.85),
        ("Sensitivity",       f"{sens:.1%}", sens >= 0.80),
        ("Specificity",       f"{spec:.1%}", spec >= 0.80),
        ("Brier Score",       f"{brier:.3f}",brier<= 0.15),
    ]

    ax.set_title("Model Performance Summary", fontsize=12, fontweight="bold", pad=12)
    for i, (name, val, passed) in enumerate(metrics):
        y_pos = 0.88 - i * 0.13
        color = C_HEALTHY if passed else C_WARN
        icon  = "✅" if passed else "⚠️"
        ax.text(0.05, y_pos, f"{icon}  {name}", transform=ax.transAxes,
                fontsize=11, va="center", color="#333")
        ax.add_patch(FancyBboxPatch((0.62, y_pos-0.045), 0.33, 0.09,
                transform=ax.transAxes, boxstyle="round,pad=0.01",
                facecolor=color, alpha=0.25, linewidth=0))
        ax.text(0.785, y_pos, val, transform=ax.transAxes,
                fontsize=12, va="center", ha="center", fontweight="bold", color=color)


# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    print("📂 Loading model and test set...")
    model, scaler, feature_names = load_artifacts()
    X_test, y_test = load_test_set(feature_names)
    X_scaled = scaler.transform(X_test)
    y_proba  = model.predict_proba(X_scaled)[:, 1]
    y_pred   = (y_proba >= 0.5).astype(int)

    acc  = accuracy_score(y_test, y_pred)
    auc_ = roc_auc_score(y_test, y_proba)
    print(f"   Test accuracy: {acc:.1%}  |  AUC: {auc_:.3f}")

    # ── Individual plots ───────────────────────────────────────────────────
    plots = [
        ("eval_confusion_matrix.png",        "Confusion Matrix",                    (6, 5),  lambda ax: plot_confusion_matrix(ax, y_test, y_pred)),
        ("eval_roc_curve.png",               "ROC Curve",                           (6, 5),  lambda ax: plot_roc(ax, y_test, y_proba)),
        ("eval_calibration_curve.png",       "Calibration Curve",                   (6, 5),  lambda ax: plot_calibration(ax, y_test, y_proba)),
        ("eval_probability_distribution.png","Probability Distribution",            (6, 5),  lambda ax: plot_prob_dist(ax, y_test, y_proba)),
        ("eval_threshold_analysis.png",      "Threshold Analysis",                  (6, 5),  lambda ax: plot_threshold_analysis(ax, y_test, y_proba)),
    ]

    for fname, title, figsize, plot_fn in plots:
        fig, ax = plt.subplots(figsize=figsize)
        plot_fn(ax)
        plt.tight_layout()
        out = OUTPUT_DIR / fname
        fig.savefig(out, dpi=150, bbox_inches="tight")
        plt.close(fig)
        print(f"   💾 {fname}")

    # ── Summary: all 5 in one image ────────────────────────────────────────
    print("\n📊 Generating combined summary image...")
    fig = plt.figure(figsize=(20, 12))
    fig.suptitle("Heart Sclerosis Model — Full Evaluation Report",
                 fontsize=16, fontweight="bold", y=0.98)
    gs = gridspec.GridSpec(2, 3, figure=fig, hspace=0.42, wspace=0.32)

    axes = [
        fig.add_subplot(gs[0, 0]),
        fig.add_subplot(gs[0, 1]),
        fig.add_subplot(gs[0, 2]),
        fig.add_subplot(gs[1, 0]),
        fig.add_subplot(gs[1, 1]),
        fig.add_subplot(gs[1, 2]),
    ]

    plot_confusion_matrix(axes[0], y_test, y_pred)
    plot_roc(axes[1], y_test, y_proba)
    plot_calibration(axes[2], y_test, y_proba)
    plot_prob_dist(axes[3], y_test, y_proba)
    plot_threshold_analysis(axes[4], y_test, y_proba)
    plot_metrics_summary(axes[5], y_test, y_pred, y_proba)

    out_summary = OUTPUT_DIR / "eval_summary.png"
    fig.savefig(out_summary, dpi=150, bbox_inches="tight")
    plt.close(fig)

    print(f"\n{'='*55}")
    print(f"✅ All plots saved to {OUTPUT_DIR}")
    print(f"   • eval_confusion_matrix.png")
    print(f"   • eval_roc_curve.png")
    print(f"   • eval_calibration_curve.png")
    print(f"   • eval_probability_distribution.png")
    print(f"   • eval_threshold_analysis.png")
    print(f"   • eval_summary.png  ← all in one")
    print(f"{'='*55}")


if __name__ == "__main__":
    main()