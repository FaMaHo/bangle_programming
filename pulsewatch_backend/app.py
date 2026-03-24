from flask import Flask, request, jsonify, Response
import os
import socket
import io
import base64
from datetime import datetime
import csv
from io import StringIO

app = Flask(__name__)

UPLOAD_FOLDER = 'patient_data'
os.makedirs(UPLOAD_FOLDER, exist_ok=True)


def _get_local_ip():
    """Read host IP from environment variable set at docker-compose time."""
    ip = os.environ.get('HOST_IP', '')
    if ip:
        return ip
    # fallback
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return '127.0.0.1'


# ─── QR Code ──────────────────────────────────────────────────────────────────

@app.route('/qr')
def qr_code_page():
    """
    Serves an HTML page with a scannable QR code.
    The QR encodes this server's base URL (http://LAN_IP:5001).
    Researcher opens this in a browser and shows it to the patient to scan.
    """
    try:
        import qrcode
        from qrcode.image.pure import PyPNGImage

        ip = _get_local_ip()
        server_url = f'http://{ip}:5001'

        qr = qrcode.QRCode(
            version=None,
            error_correction=qrcode.constants.ERROR_CORRECT_M,
            box_size=10,
            border=4,
        )
        qr.add_data(server_url)
        qr.make(fit=True)

        # Generate PNG in memory and encode as base64
        try:
            from PIL import Image as PILImage
            img = qr.make_image(fill_color='black', back_color='white')
            buf = io.BytesIO()
            img.save(buf, format='PNG')
            img_b64 = base64.b64encode(buf.getvalue()).decode('utf-8')
            img_tag = f'<img src="data:image/png;base64,{img_b64}" width="280" height="280" alt="QR Code">'
        except ImportError:
            # Pillow not available — fall back to pure PNG
            img = qr.make_image(image_factory=PyPNGImage)
            buf = io.BytesIO()
            img.save(buf)
            img_b64 = base64.b64encode(buf.getvalue()).decode('utf-8')
            img_tag = f'<img src="data:image/png;base64,{img_b64}" width="280" height="280" alt="QR Code">'

        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>PulseWatch AI – Connect</title>
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #faf8f5;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 32px 20px;
    }}
    .card {{
      background: #fff;
      border-radius: 20px;
      padding: 40px 36px;
      max-width: 380px;
      width: 100%;
      box-shadow: 0 4px 24px rgba(0,0,0,0.08);
      text-align: center;
    }}
    .logo {{
      width: 48px; height: 48px;
      background: rgba(124,182,134,0.12);
      border-radius: 14px;
      display: flex; align-items: center; justify-content: center;
      margin: 0 auto 20px;
      font-size: 24px;
    }}
    h1 {{ font-size: 20px; font-weight: 700; color: #2d3142; margin-bottom: 6px; }}
    .subtitle {{ font-size: 13px; color: #6b7280; margin-bottom: 28px; line-height: 1.5; }}
    .qr-wrapper {{
      background: #fff;
      border: 2px solid #e5e7eb;
      border-radius: 16px;
      padding: 16px;
      display: inline-block;
      margin-bottom: 24px;
    }}
    .url-box {{
      background: #f3f4f6;
      border-radius: 10px;
      padding: 10px 16px;
      font-family: monospace;
      font-size: 14px;
      color: #2d3142;
      word-break: break-all;
      margin-bottom: 16px;
    }}
    .hint {{ font-size: 12px; color: #9ca3af; line-height: 1.5; }}
    .dot {{ display: inline-block; width: 8px; height: 8px;
            background: #7cb686; border-radius: 50; margin-right: 6px; }}
  </style>
</head>
<body>
  <div class="card">
    <div class="logo">❤️</div>
    <h1>PulseWatch AI</h1>
    <p class="subtitle">Scan this QR code with the PulseWatch app<br>to connect to the research server.</p>
    <div class="qr-wrapper">
      {img_tag}
    </div>
    <div class="url-box">
      <span class="dot"></span>{server_url}
    </div>
    <p class="hint">Make sure your phone and this computer<br>are on the same Wi-Fi network.</p>
  </div>
</body>
</html>"""

        return Response(html, mimetype='text/html')

    except ImportError:
        return jsonify({
            'error': 'qrcode library not installed. Run: pip install qrcode[pil]'
        }), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ─── Existing routes ───────────────────────────────────────────────────────────

@app.route('/')
def home():
    return "PulseWatch AI Backend is Running!"


@app.route('/upload', methods=['POST'])
def upload_data():
    try:
        csv_data = request.data.decode('utf-8')

        if not csv_data:
            return jsonify({'error': 'No data received'}), 400

        lines = csv_data.strip().split('\n')
        record_count = len(lines) - 1

        device_id = request.headers.get('X-Device-ID', 'unknown')
        patient_id = request.headers.get('X-Patient-ID', 'unknown')
        session_id = request.headers.get('X-Session-ID', datetime.now().strftime('%Y%m%d_%H%M%S'))

        save_path = os.path.join(UPLOAD_FOLDER, patient_id, session_id)
        os.makedirs(save_path, exist_ok=True)

        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        filename = f'pulsewatch_data_{timestamp}_{device_id}.csv'
        full_path = os.path.join(save_path, filename)

        with open(full_path, 'w', encoding='utf-8') as f:
            f.write(csv_data)

        print(f"\n✅ Received upload from {device_id}")
        print(f"   Patient: {patient_id}")
        print(f"   Session: {session_id}")
        print(f"   Records: {record_count}")
        print(f"   Saved to: {full_path}")
        print(f"   Size: {len(csv_data)} bytes\n")

        return jsonify({
            'success': True,
            'message': f'Successfully uploaded {record_count} records',
            'filename': filename,
            'records': record_count,
            'path': full_path
        }), 200

    except Exception as e:
        print(f"❌ Error in /upload: {str(e)}")
        return jsonify({'error': str(e)}), 500


@app.route('/upload_chunk', methods=['POST'])
def upload_chunk():
    if 'file' not in request.files:
        return jsonify({"error": "No file part"}), 400

    file = request.files['file']
    patient_id = request.form.get('patient_id', 'unknown')
    session_id = request.form.get('session_id', 'session_001')
    chunk_index = request.form.get('chunk_index', '0')

    if file.filename == '':
        return jsonify({"error": "No selected file"}), 400

    if file:
        save_path = os.path.join(UPLOAD_FOLDER, patient_id, session_id)
        os.makedirs(save_path, exist_ok=True)
        filename = f"chunk_{chunk_index}.csv"
        full_path = os.path.join(save_path, filename)
        file.save(full_path)
        print(f"✅ Received Data: Patient {patient_id} - Chunk {chunk_index}")
        return jsonify({"message": "Chunk uploaded successfully", "path": full_path}), 200


@app.route('/upload_recorder_log', methods=['POST'])
def upload_recorder_log():
    if 'file' not in request.files:
        return jsonify({"error": "No file part"}), 400

    file = request.files['file']
    patient_id = request.form.get('patient_id', 'unknown')
    session_id = request.form.get('session_id', 'session_001')
    upload_timestamp = request.form.get('timestamp', datetime.now().isoformat())

    if file.filename == '':
        return jsonify({"error": "No selected file"}), 400

    try:
        save_path = os.path.join(UPLOAD_FOLDER, patient_id, session_id)
        os.makedirs(save_path, exist_ok=True)

        timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"recorder_{timestamp_str}.csv"
        full_path = os.path.join(save_path, filename)

        csv_content = file.read().decode('utf-8')

        if len(csv_content.strip()) < 50:
            return jsonify({"error": "CSV file appears to be empty or invalid"}), 400

        csv_reader = csv.reader(StringIO(csv_content))
        rows = list(csv_reader)

        if len(rows) < 2:
            return jsonify({"error": "CSV file has insufficient data"}), 400

        header = rows[0]
        data_rows = rows[1:]

        with open(full_path, 'w', encoding='utf-8') as f:
            f.write(csv_content)

        metadata_path = os.path.join(save_path, f"metadata_{timestamp_str}.json")
        metadata = {
            "patient_id": patient_id,
            "session_id": session_id,
            "upload_timestamp": upload_timestamp,
            "server_timestamp": datetime.now().isoformat(),
            "filename": filename,
            "row_count": len(data_rows),
            "columns": header,
            "file_size_bytes": len(csv_content),
        }

        import json
        with open(metadata_path, 'w') as f:
            json.dump(metadata, f, indent=2)

        return jsonify({
            "message": "Recorder log uploaded successfully",
            "path": full_path,
            "row_count": len(data_rows),
            "file_size": len(csv_content),
            "metadata": metadata
        }), 200

    except Exception as e:
        return jsonify({"error": f"Processing failed: {str(e)}"}), 500


@app.route('/patient/<patient_id>/sessions', methods=['GET'])
def get_patient_sessions(patient_id):
    patient_path = os.path.join(UPLOAD_FOLDER, patient_id)

    if not os.path.exists(patient_path):
        return jsonify({"error": "Patient not found"}), 404

    sessions = []
    for session_id in os.listdir(patient_path):
        session_path = os.path.join(patient_path, session_id)
        if os.path.isdir(session_path):
            files = os.listdir(session_path)
            csv_files = [f for f in files if f.endswith('.csv')]
            sessions.append({
                "session_id": session_id,
                "file_count": len(csv_files),
                "files": csv_files
            })

    return jsonify({
        "patient_id": patient_id,
        "sessions": sessions,
        "total_sessions": len(sessions)
    })


@app.route('/patient/<patient_id>/session/<session_id>/data', methods=['GET'])
def get_session_data(patient_id, session_id):
    session_path = os.path.join(UPLOAD_FOLDER, patient_id, session_id)

    if not os.path.exists(session_path):
        return jsonify({"error": "Session not found"}), 404

    csv_files = [f for f in os.listdir(session_path) if f.endswith('.csv')]

    combined_data = []
    for csv_file in sorted(csv_files):
        file_path = os.path.join(session_path, csv_file)
        with open(file_path, 'r') as f:
            combined_data.append(f.read())

    return jsonify({
        "patient_id": patient_id,
        "session_id": session_id,
        "file_count": len(csv_files),
        "files": csv_files,
        "combined_csv": "\n".join(combined_data)
    })


@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "storage_path": UPLOAD_FOLDER,
        "patients": len(os.listdir(UPLOAD_FOLDER)) if os.path.exists(UPLOAD_FOLDER) else 0
    })


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)