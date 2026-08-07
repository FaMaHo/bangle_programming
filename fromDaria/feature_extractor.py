"""
Extracts the same 20 features used during training from a bracelet CSV.
Called by generate_report_html.py during inference.
"""

import numpy as np
import pandas as pd


def lomb_scargle_power(rr_ms, lo=0.04, hi=0.4):
    try:
        from scipy.signal import lombscargle
        rr = np.asarray(rr_ms, dtype=float)
        t  = np.cumsum(rr) / 1000.0; t -= t[0]
        freqs = np.linspace(lo, hi, 300)
        pgram = lombscargle(t, rr - rr.mean(), freqs * 2 * np.pi, normalize=True)
        lf = float(pgram[(freqs>=0.04)&(freqs<0.15)].mean())
        hf = float(pgram[(freqs>=0.15)&(freqs<=0.40)].mean())
        return lf, hf, float(pgram.sum())
    except:
        return np.nan, np.nan, np.nan


def extract_features_from_window(df):
    feats = {}
    rr  = df["rr_intervals_ms"].dropna().values.astype(float)
    rr  = rr[(rr > 300) & (rr < 2000)]
    hr  = df["hr_bpm"].dropna().values.astype(float)
    ax  = df["accel_x"].values.astype(float)
    ay  = df["accel_y"].values.astype(float)
    az  = df["accel_z"].values.astype(float)
    ppg = df["ppg_raw"].values.astype(float)

    # HRV time-domain
    if len(rr) >= 4:
        diff_rr = np.diff(rr)
        feats["rmssd"]    = float(np.sqrt(np.mean(diff_rr**2)))
        feats["sdnn"]     = float(np.std(rr))
        feats["mean_rr"]  = float(np.mean(rr))
        feats["pnn50"]    = float(np.mean(np.abs(diff_rr) > 50))
        hist, _           = np.histogram(rr, bins=max(4, len(rr)//8))
        feats["tri_index"]= float(len(rr) / (hist.max() + 1e-9))
    else:
        for k in ["rmssd","sdnn","mean_rr","pnn50","tri_index"]: feats[k] = np.nan

    # HRV frequency
    if len(rr) >= 8:
        lf, hf, total = lomb_scargle_power(rr)
        feats.update({"lf_power":lf,"hf_power":hf,"total_power":total,"lf_hf_ratio":lf/(hf+1e-9)})
    else:
        feats.update({"lf_power":np.nan,"hf_power":np.nan,"total_power":np.nan,"lf_hf_ratio":np.nan})

    # PPG morphology
    if len(ppg) >= 10 and ppg.std() > 0:
        mid = len(ppg)//2
        feats["pulse_amplitude"]  = float(ppg.max()-ppg.min())
        feats["systolic_upslope"] = float(np.diff(ppg[:mid]).mean()) if mid>1 else np.nan
        feats["ai_index"]         = float((ppg.max()-ppg[mid])/(ppg.max()-ppg.min()+1e-9))
    else:
        feats["pulse_amplitude"] = feats["systolic_upslope"] = feats["ai_index"] = np.nan

    # Activity
    accel_mag = np.sqrt(ax**2+ay**2+az**2)
    steps_est = float(np.sum(np.abs(np.diff(accel_mag))>0.1))
    feats["sedentary_time_ratio"] = float(np.mean(accel_mag<0.05))
    feats["accel_entropy"]        = float(-np.sum([p*np.log(p+1e-9) for p in np.histogram(accel_mag,bins=10,density=True)[0]/10]))
    feats["movement_variability"] = float(accel_mag.std())
    feats["hr_step_ratio"]        = float(hr.mean()/(steps_est+1)) if len(hr)>0 else np.nan
    feats["chronotropic_index"]   = float(np.corrcoef(hr,accel_mag)[0,1]) if len(hr)>4 and accel_mag.std()>0 else np.nan

    if len(hr) > 10:
        peak_idx = int(np.argmax(hr))
        idx1 = min(peak_idx+60,  len(hr)-1)
        idx3 = min(peak_idx+180, len(hr)-1)
        feats["recovery_slope_1min"] = float(hr[peak_idx]-hr[idx1])/60
        feats["recovery_slope_3min"] = float(hr[peak_idx]-hr[idx3])/180
    else:
        feats["recovery_slope_1min"] = feats["recovery_slope_3min"] = np.nan

    # Nocturnal
    feats["nocturnal_hr_mean"]         = float(hr[hr<hr.mean()].mean()) if len(hr)>4 else np.nan
    feats["hrv_circadian_amplitude"]   = float(rr.max()-rr.min()) if len(rr)>4 else np.nan
    feats["sleep_fragmentation_index"] = float(np.mean(np.abs(np.diff(hr))>5)) if len(hr)>4 else 0.0

    return feats


def extract_features_from_csv(df, window_s=300, overlap=0.5):
    step = int(window_s*(1-overlap))
    all_feats = []
    for start in range(0, len(df)-window_s, step):
        chunk = df.iloc[start:start+window_s]
        all_feats.append(extract_features_from_window(chunk))
    if not all_feats:
        return extract_features_from_window(df)
    # average across windows
    agg = {}
    for k in all_feats[0]:
        vals = [f[k] for f in all_feats if not (isinstance(f[k],float) and np.isnan(f[k]))]
        agg[k] = float(np.mean(vals)) if vals else np.nan
    return agg
