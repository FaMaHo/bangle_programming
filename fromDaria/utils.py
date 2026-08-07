import pickle
import pandas as pd
from pathlib import Path


def load_model_artifacts(model_path):
    with open(model_path, "rb") as f:
        arts = pickle.load(f)
    if isinstance(arts, dict):
        return arts["model"], arts["scaler"], arts["feature_names"]
    elif isinstance(arts, (list, tuple)):
        return arts[0], arts[1], arts[2] if len(arts) > 2 else None
    else:
        return arts, None, None


def load_feature_medians(processed_dir):
    path = Path(processed_dir) / "feature_medians.csv"
    if path.exists():
        return pd.read_csv(path, index_col=0).squeeze()
    return pd.Series(dtype=float)


def validate_input_schema(df):
    required = ["hr_bpm", "rr_intervals_ms", "ppg_raw", "accel_x", "accel_y", "accel_z"]
    missing  = [c for c in required if c not in df.columns]
    if missing:
        raise ValueError(f"Missing columns in input CSV: {missing}")
    return True
