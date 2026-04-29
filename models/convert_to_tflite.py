"""
convert_to_onnx.py
Output: tflite_output/model.onnx + tflite_output/feature_names.json
(Used in Flutter via the onnxruntime package — no TFLite conversion needed)
"""
import os, sys, json
import numpy as np
import joblib

# ── Step 1: Load pkl ─────────────────────────────────────────────────────────
print("\n[1/5] Loading cardiosclerosis_model_v1.pkl ...")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
artifacts  = joblib.load(os.path.join(SCRIPT_DIR, "cardiosclerosis_model_v1.pkl"))

model         = artifacts["model"]
scaler        = artifacts["scaler"]
feature_names = artifacts["feature_names"]
print(f"  Model    : {type(model).__name__}")
print(f"  Scaler   : {type(scaler).__name__}")
print(f"  Features : {len(feature_names)}")
print(f"  Val AUC  : {artifacts.get('val_auc','N/A')}")
assert len(feature_names) == 23

# ── Step 2: Build sklearn Pipeline for reference inference ───────────────────
print("\n[2/5] Building sklearn Pipeline (reference only) ...")
from sklearn.pipeline import Pipeline
pipeline = Pipeline([("scaler", scaler), ("classifier", model)])
print("  Done.")

# ── Step 3: Convert to ONNX (onnxmltools + scaler graph surgery) ─────────────
print("\n[3/5] Converting to ONNX ...")

OUTPUT_DIR = os.path.join(SCRIPT_DIR, "tflite_output")
os.makedirs(OUTPUT_DIR, exist_ok=True)
ONNX_PATH = os.path.join(OUTPUT_DIR, "model.onnx")

try:
    from onnxmltools.convert import convert_xgboost as ot_convert
    from onnxmltools.convert.common.data_types import FloatTensorType as OT_Float
    import onnx
    from onnx import numpy_helper, TensorProto, helper as oh

    print("  Converting XGBClassifier with onnxmltools ...")
    xgb_onnx = ot_convert(
        model,
        initial_types=[("float_input_scaled", OT_Float([None, 23]))],
        target_opset=15,
    )

    # Ensure standard ONNX opset "" is declared (needed for Sub/Div nodes)
    existing_domains = {imp.domain for imp in xgb_onnx.opset_import}
    if "" not in existing_domains:
        xgb_onnx.opset_import.append(oh.make_opsetid("", 15))

    # Prepend StandardScaler: Z = (X - mean) / scale
    mean_init  = numpy_helper.from_array(scaler.mean_.astype(np.float32),  name="scaler_mean")
    scale_init = numpy_helper.from_array(scaler.scale_.astype(np.float32), name="scaler_scale")
    sub_node   = oh.make_node("Sub", inputs=["float_input", "scaler_mean"],  outputs=["centered"])
    div_node   = oh.make_node("Div", inputs=["centered",   "scaler_scale"], outputs=["float_input_scaled"])

    xgb_onnx.graph.node.insert(0, div_node)
    xgb_onnx.graph.node.insert(0, sub_node)
    xgb_onnx.graph.initializer.append(mean_init)
    xgb_onnx.graph.initializer.append(scale_init)

    del xgb_onnx.graph.input[:]
    xgb_onnx.graph.input.append(
        oh.make_tensor_value_info("float_input", TensorProto.FLOAT, [None, 23])
    )

    onnx.checker.check_model(xgb_onnx)
    with open(ONNX_PATH, "wb") as f:
        f.write(xgb_onnx.SerializeToString())
    print(f"  ONNX saved -> {ONNX_PATH}")

except Exception as e:
    print(f"  [onnxmltools] Failed: {e}")
    try:
        print("  Falling back to skl2onnx with registered XGBoost converter ...")
        from skl2onnx import convert_sklearn, update_registered_converter
        from skl2onnx.common.data_types import FloatTensorType
        from skl2onnx.common.shape_calculator import calculate_linear_classifier_output_shapes
        from onnxmltools.convert.xgboost.operator_converters.XGBoost import convert_xgboost as skl_xgb
        from xgboost import XGBClassifier as _XGB

        update_registered_converter(
            _XGB, "XGBoostXGBClassifier",
            calculate_linear_classifier_output_shapes,
            skl_xgb,
            options={"nocl": [True, False], "zipmap": [True, False, "columns"]},
        )
        proto = convert_sklearn(
            pipeline,
            initial_types=[("float_input", FloatTensorType([None, 23]))],
            target_opset={"": 15, "ai.onnx.ml": 3},
            options={id(model): {"zipmap": False}},
        )
        with open(ONNX_PATH, "wb") as f:
            f.write(proto.SerializeToString())
        print(f"  [skl2onnx+register] ONNX saved -> {ONNX_PATH}")

    except Exception as e2:
        print(f"  [skl2onnx fallback] Also failed: {e2}")
        sys.exit(1)

# ── Step 4: Smoke-test ONNX ──────────────────────────────────────────────────
print("\n[4/5] Smoke-testing ONNX with onnxruntime ...")
import onnxruntime as ort

sess    = ort.InferenceSession(ONNX_PATH, providers=["CPUExecutionProvider"])
in_name = sess.get_inputs()[0].name
print(f"  Input    : {in_name} {sess.get_inputs()[0].shape}")
print(f"  Outputs  : {[(o.name, o.shape) for o in sess.get_outputs()]}")

TEST = np.array([[
    750.0, 45.0, 35.0, 12.0, 15.0,
    800.0, 600.0, 1.3, 2000.0, 0.8,
    1.5, 0.4, 0.6, 0.9, 0.85,
    -0.1, -0.05, 1.2, 0.3, 0.35,
    62.0, 8.0, 0.15,
]], dtype=np.float32)

onnx_outs = sess.run(None, {in_name: TEST})
prob_arr  = np.array(onnx_outs[1]).flatten()   # 'probabilities' is output index 1
onnx_risk = float(prob_arr[1])

pkl_risk  = float(pipeline.predict_proba(TEST)[0][1])
diff      = abs(pkl_risk - onnx_risk)

print(f"  PKL  -> P(cardiosclerosis) = {pkl_risk:.6f}")
print(f"  ONNX -> P(cardiosclerosis) = {onnx_risk:.6f}")
print(f"  Diff = {diff:.6f}  (tolerance 0.001)")

if diff > 0.001:
    print(f"ERROR: outputs differ by {diff:.6f} > 0.001")
    sys.exit(1)

# ── Step 5: Save feature_names.json ─────────────────────────────────────────
print("\n[5/5] Saving feature_names.json ...")
FEAT_JSON = os.path.join(OUTPUT_DIR, "feature_names.json")
with open(FEAT_JSON, "w") as f:
    json.dump(feature_names, f, indent=2)
print(f"  Saved -> {FEAT_JSON}")

size_kb = os.path.getsize(ONNX_PATH) / 1024
print(f"\n{'='*55}")
print(f"  Verification  : PASSED (diff={diff:.6f})")
print(f"  model.onnx    : {size_kb:.1f} KB")
print(f"  ONNX path     : {ONNX_PATH}")
print(f"  Features JSON : {FEAT_JSON}")
print(f"{'='*55}")
print("\nNext step: copy both files to pulsewatch_app/assets/models/")
