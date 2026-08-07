"""
inference/generate_report_html.py
==================================
Main inference script. Drop your bracelet CSV into readings/ then run:
    python inference/generate_report_html.py

Outputs a self-contained HTML report to output/ and prints a file:// link.
No Flask. No server. Just open the file in a browser.
"""

import os, sys, pickle, json, datetime, types
import numpy as np
import pandas as pd
from pathlib import Path

ROOT      = Path(__file__).resolve().parents[1]
READINGS  = ROOT / "readings"
MODEL_PKL = ROOT / "models" / "cardiosclerosis_model_v1.pkl"
MEDIANS   = ROOT / "data" / "processed" / "feature_medians.csv"
OUT_DIR   = ROOT / "output"
OUT_DIR.mkdir(exist_ok=True)

sys.path.insert(0, str(ROOT))
from inference.feature_extractor import extract_features_from_csv

# ── Load model (fixes XGBoost pickle version mismatch) ───────────────────────
def load_model():
    import xgboost as xgb_module
    fake = types.ModuleType("XGBClassifier")
    fake.XGBClassifier = xgb_module.XGBClassifier
    sys.modules["XGBClassifier"] = fake

    with open(MODEL_PKL, "rb") as f:
        arts = pickle.load(f)

    if isinstance(arts, dict):
        return arts["model"], arts.get("scaler"), arts.get("feature_names")
    elif isinstance(arts, (list, tuple)):
        return arts[0], arts[1] if len(arts)>1 else None, arts[2] if len(arts)>2 else None
    return arts, None, None

# ── Feature importance descriptions for the report ───────────────────────────
FEAT_INFO = {
    "lf_power":               ("LF Power",              "ms²",  "Low-frequency HRV band — reflects sympathetic nervous system activity. Elevated in cardiac fibrosis."),
    "tri_index":              ("Triangular Index",       "",     "How peaked the RR histogram is. Low = rigid, fibrotic heartbeat pattern."),
    "pulse_amplitude":        ("Pulse Amplitude",        "ADC",  "Strength of the PPG pulse wave. Reduced in arterial stiffness."),
    "diastolic_decay":        ("Diastolic Decay",        "",     "Rate of pressure drop after systolic peak. Changes with vascular compliance."),
    "systolic_upslope":       ("Systolic Upslope",       "",     "Speed of pressure rise during heartbeat. Slows with myocardial stiffening."),
    "pnn50":                  ("pNN50",                  "%",    "Fraction of consecutive beats differing by >50ms. Low = reduced parasympathetic tone."),
    "mean_rr":                ("Mean RR",                "ms",   "Average time between heartbeats. Shorter = higher resting heart rate."),
    "rmssd":                  ("RMSSD",                  "ms",   "Root mean square of successive RR differences. The most direct HRV marker."),
    "sleep_fragmentation_index": ("Sleep Fragmentation","",     "How often HR changes sharply during sleep. Elevated in cardiac autonomic dysfunction."),
    "lf_hf_ratio":            ("LF/HF Ratio",            "",     "Sympathetic vs parasympathetic balance. High ratio = sympathetic dominance."),
    "hf_power":               ("HF Power",               "ms²",  "High-frequency HRV band — reflects parasympathetic (vagal) activity."),
    "nocturnal_hr_mean":      ("Nocturnal HR Mean",      "bpm",  "Average heart rate during sleep. Elevated in early cardiac fibrosis."),
    "sdnn":                   ("SDNN",                   "ms",   "Standard deviation of all RR intervals. Overall HRV measure."),
    "recovery_slope_1min":    ("Recovery Slope 1min",    "bpm/s","How fast HR drops in first minute after activity peak."),
    "total_power":            ("Total HRV Power",        "ms²",  "Total variance in RR intervals across all frequency bands."),
    "ai_index":               ("Augmentation Index",     "",     "Ratio of augmented pressure to pulse pressure. Arterial stiffness marker."),
    "sedentary_time_ratio":   ("Sedentary Time",         "%",    "Fraction of time with minimal wrist movement."),
    "accel_entropy":          ("Accel. Entropy",         "",     "Randomness of movement patterns. Low = very sedentary lifestyle."),
    "hr_step_ratio":          ("HR/Step Ratio",          "",     "Heart rate relative to movement. Elevated = inefficient cardiac response."),
    "chronotropic_index":     ("Chronotropic Index",     "",     "Correlation of HR with activity. Low = reduced ability to raise HR on demand."),
    "hrv_circadian_amplitude":("Circadian HRV Amplitude","ms",   "Day-night difference in HRV. Blunted in autonomic dysfunction."),
    "movement_variability":   ("Movement Variability",   "",     "Variation in accelerometer signal across the session."),
    "recovery_slope_3min":    ("Recovery Slope 3min",    "bpm/s","Heart rate drop over 3 minutes after peak activity."),
}

# ── HTML template ─────────────────────────────────────────────────────────────
HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Heart Sclerosis Risk Report — {filename}</title>
<style>
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ font-family: 'Segoe UI', Arial, sans-serif; background: #F0F4F0; color: #1B2D23; }}
  .header {{ background: #1A3A2A; color: white; padding: 28px 40px; }}
  .header h1 {{ font-size: 22px; font-weight: 700; letter-spacing: 0.3px; }}
  .header p  {{ font-size: 13px; color: #95D5B2; margin-top: 6px; }}
  .container {{ max-width: 900px; margin: 32px auto; padding: 0 24px; }}
  .gauge-section {{ background: white; border-radius: 12px; padding: 36px; text-align: center;
                    box-shadow: 0 2px 12px rgba(0,0,0,0.08); margin-bottom: 24px; }}
  .score-number {{ font-size: 72px; font-weight: 800; line-height: 1; color: {score_color}; }}
  .score-label  {{ font-size: 18px; font-weight: 600; color: {score_color}; margin-top: 6px; text-transform: uppercase; letter-spacing: 1px; }}
  .risk-badge   {{ display: inline-block; background: {score_color}; color: white; border-radius: 20px;
                   padding: 6px 20px; font-size: 14px; font-weight: 700; margin-top: 14px; }}
  .gauge-bar    {{ width: 80%; max-width: 500px; height: 18px; background: #E8F0EC; border-radius: 9px;
                   margin: 20px auto 8px; overflow: hidden; }}
  .gauge-fill   {{ height: 100%; width: {score_pct}%; background: linear-gradient(90deg, #40916C, {score_color}); border-radius: 9px; }}
  .gauge-labels {{ display: flex; justify-content: space-between; width: 80%; max-width: 500px; margin: 0 auto;
                   font-size: 11px; color: #8A9E94; }}
  .assessment   {{ background: #F7FAF8; border-left: 4px solid {score_color}; border-radius: 0 8px 8px 0;
                   padding: 14px 18px; margin-top: 20px; text-align: left; font-size: 14px; line-height: 1.6; }}
  .section      {{ background: white; border-radius: 12px; padding: 28px; box-shadow: 0 2px 12px rgba(0,0,0,0.08);
                   margin-bottom: 24px; }}
  .section h2   {{ font-size: 16px; font-weight: 700; color: #1A3A2A; margin-bottom: 18px;
                   padding-bottom: 10px; border-bottom: 2px solid #D8F3DC; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 13px; }}
  th {{ background: #1A3A2A; color: white; padding: 10px 14px; text-align: left; font-weight: 600; }}
  td {{ padding: 10px 14px; border-bottom: 1px solid #E8F0EC; }}
  tr:nth-child(even) td {{ background: #F7FAF8; }}
  .imp-bar {{ height: 10px; background: #40916C; border-radius: 5px; }}
  .meta-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }}
  .meta-item {{ background: #F7FAF8; border-radius: 8px; padding: 12px 16px; }}
  .meta-item .label {{ font-size: 11px; color: #8A9E94; text-transform: uppercase; letter-spacing: 0.5px; }}
  .meta-item .value {{ font-size: 16px; font-weight: 700; color: #1A3A2A; margin-top: 2px; }}
  .disclaimer {{ background: #FFF8E3; border: 1px solid #E9963A; border-radius: 8px; padding: 14px 18px;
                 font-size: 12px; color: #7A5C1A; line-height: 1.6; margin-bottom: 24px; }}
  .footer {{ text-align: center; font-size: 11px; color: #8A9E94; padding: 20px; }}
</style>
</head>
<body>
<div class="header">
  <h1>Heart Sclerosis Risk Report</h1>
  <p>AI Bracelet System &nbsp;·&nbsp; NUST Politehnica Bucharest &nbsp;·&nbsp; {generated}</p>
</div>
<div class="container">

  <div class="disclaimer">
    ⚠ <strong>This is a research prototype, not a medical device.</strong>
    This report is designed to support — not replace — clinical evaluation.
    A score above 25% should prompt a cardiologist referral.
    All analysis runs locally on your device. No data is sent anywhere.
  </div>

  <div class="gauge-section">
    <div class="score-number">{score_display}%</div>
    <div class="score-label">Cardiac Risk Score</div>
    <div class="risk-badge">{risk_level} RISK</div>
    <div class="gauge-bar"><div class="gauge-fill"></div></div>
    <div class="gauge-labels"><span>0% — Healthy</span><span>50%</span><span>100% — High Risk</span></div>
    <div class="assessment">{assessment_text}</div>
  </div>

  <div class="section">
    <h2>Session Overview</h2>
    <div class="meta-grid">
      <div class="meta-item"><div class="label">File</div><div class="value">{filename}</div></div>
      <div class="meta-item"><div class="label">Windows analysed</div><div class="value">{n_windows}</div></div>
      <div class="meta-item"><div class="label">Data rows</div><div class="value">{n_rows:,}</div></div>
      <div class="meta-item"><div class="label">Session duration</div><div class="value">~{duration_h:.1f} hours</div></div>
      <div class="meta-item"><div class="label">Mean HR</div><div class="value">{mean_hr:.0f} bpm</div></div>
      <div class="meta-item"><div class="label">Mean RMSSD</div><div class="value">{mean_rmssd:.1f} ms</div></div>
    </div>
  </div>

  <div class="section">
    <h2>Top Influential Features</h2>
    <table>
      <tr><th>#</th><th>Feature</th><th>Value</th><th>Unit</th><th>Importance</th><th>Clinical meaning</th></tr>
      {feature_rows}
    </table>
  </div>

  <div class="footer">
    Generated by AI Bracelet for Early Detection of Heart Sclerosis &nbsp;·&nbsp;
    Model: XGBoost (AUC 0.990, Accuracy 95.3%) &nbsp;·&nbsp;
    Daria Gladkykh · FatemehSadat MahmoudzadehHosseini · Prof. Dr. Ing. Nicolae Goga
  </div>
</div>
</body>
</html>"""

# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    csvs = list(READINGS.glob("*.csv"))
    if not csvs:
        print(f"ERROR: No CSV files found in {READINGS}")
        print("Drop your bracelet recording CSV into the readings/ folder and run again.")
        sys.exit(1)

    print(f"Found {len(csvs)} file(s) in readings/")
    model, scaler, feature_names = load_model()

    # Load feature medians for fillna
    if MEDIANS.exists():
        medians = pd.read_csv(MEDIANS, index_col=0).squeeze()
    else:
        medians = pd.Series(dtype=float)

    # Get feature importances from model
    try:
        importances = model.feature_importances_
        imp_dict = dict(zip(feature_names or [], importances))
    except:
        imp_dict = {}

    for csv_path in csvs:
        print(f"\nProcessing: {csv_path.name} ...")
        df = pd.read_csv(csv_path)

        # Fill missing columns
        for col in ["hr_bpm","rr_intervals_ms","accel_x","accel_y","accel_z","ppg_raw"]:
            if col not in df.columns:
                df[col] = 0.0

        # Extract features per window and collect per-window probs
        step = 150   # 5-min window, 50% overlap at 1Hz
        window_probs = []
        window_feats_list = []

        for start in range(0, len(df) - 300, step):
            chunk = df.iloc[start:start+300]
            feats = extract_features_from_csv(chunk, window_s=300, overlap=0.0)
            feat_df = pd.DataFrame([feats])

            if feature_names:
                for fn in feature_names:
                    if fn not in feat_df.columns:
                        feat_df[fn] = medians.get(fn, 0.0)
                feat_df = feat_df[feature_names]

            feat_df = feat_df.fillna(feat_df.median()).fillna(0)

            if scaler:
                X = scaler.transform(feat_df.values)
            else:
                X = feat_df.values

            prob = float(model.predict_proba(X)[0, 1])
            window_probs.append(prob)
            window_feats_list.append(feats)

        if not window_probs:
            print("  Not enough data for windowing — using whole file")
            feats = extract_features_from_csv(df)
            feat_df = pd.DataFrame([feats])
            if feature_names:
                for fn in feature_names:
                    if fn not in feat_df.columns:
                        feat_df[fn] = medians.get(fn, 0.0)
                feat_df = feat_df[feature_names]
            feat_df = feat_df.fillna(0)
            X = scaler.transform(feat_df.values) if scaler else feat_df.values
            window_probs = [float(model.predict_proba(X)[0, 1])]
            window_feats_list = [feats]

        session_score = float(np.mean(window_probs))
        score_pct     = round(session_score * 100, 1)
        n_windows     = len(window_probs)

        # Aggregate features across windows
        agg_feats = {}
        for k in window_feats_list[0]:
            vals = [f.get(k, np.nan) for f in window_feats_list]
            vals = [v for v in vals if v is not None and not np.isnan(v)]
            agg_feats[k] = float(np.mean(vals)) if vals else 0.0

        # Risk level
        if session_score < 0.20:
            risk_level = "LOW";    score_color = "#40916C"
            assessment = "No significant cardiosclerosis markers detected. Readings are consistent with a healthy cardiovascular profile. Maintain regular activity and monitoring."
        elif session_score < 0.50:
            risk_level = "MEDIUM"; score_color = "#E9963A"
            assessment = "Some autonomic markers associated with early cardiac stress detected. This score warrants clinical follow-up. Please consult a cardiologist for further evaluation."
        else:
            risk_level = "HIGH";   score_color = "#E63946"
            assessment = "Multiple markers consistent with significant cardiac autonomic dysfunction detected. Prompt clinical evaluation is strongly recommended."

        # Top features
        top_feats = sorted(imp_dict.items(), key=lambda x: x[1], reverse=True)[:8]
        max_imp   = max([v for _,v in top_feats], default=1)
        feat_rows = ""
        for i, (fname, fimp) in enumerate(top_feats, 1):
            info  = FEAT_INFO.get(fname, (fname, "", ""))
            val   = agg_feats.get(fname, 0.0)
            bar_w = int(fimp / max_imp * 100)
            feat_rows += f"""<tr>
              <td>{i}</td>
              <td><strong>{info[0]}</strong></td>
              <td>{val:.3f}</td>
              <td>{info[1]}</td>
              <td><div class="imp-bar" style="width:{bar_w}%"></div></td>
              <td style="color:#556B5E;font-size:12px">{info[2]}</td>
            </tr>"""

        # Session stats
        hr_vals = df["hr_bpm"].replace(0, np.nan).dropna().values
        rr_vals = df["rr_intervals_ms"].replace(0, np.nan).dropna().values
        mean_hr    = float(hr_vals.mean()) if len(hr_vals) > 0 else 0.0
        mean_rmssd = float(agg_feats.get("rmssd", 0.0))
        duration_h = len(df) / 3600

        html = HTML_TEMPLATE.format(
            filename      = csv_path.name,
            generated     = datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
            score_display = f"{score_pct:.1f}",
            score_pct     = score_pct,
            score_color   = score_color,
            risk_level    = risk_level,
            assessment_text = assessment,
            n_windows     = n_windows,
            n_rows        = len(df),
            duration_h    = duration_h,
            mean_hr       = mean_hr,
            mean_rmssd    = mean_rmssd,
            feature_rows  = feat_rows,
        )

        stem    = csv_path.stem
        ts      = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        out_path= OUT_DIR / f"report_{stem}_{ts}.html"
        out_path.write_text(html, encoding="utf-8")

        print(f"  Score: {score_pct:.1f}%  |  Risk: {risk_level}")
        print(f"  Windows: {n_windows}  |  Rows: {len(df):,}")
        print(f"\n  ✅ Report saved:")
        print(f"  file:///{out_path.as_posix()}")

if __name__ == "__main__":
    main()
