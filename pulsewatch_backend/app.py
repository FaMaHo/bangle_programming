from flask import Flask, request, jsonify
import os
from datetime import datetime
import csv
from io import StringIO

app = Flask(__name__)

# Where we will save the incoming medical data
UPLOAD_FOLDER = 'patient_data'
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

@app.route('/')
def home():
    return "PulseWatch AI Backend is Running!"

@app.route('/upload', methods=['POST'])
def upload_data():
    """
    Primary upload endpoint for Flutter App.
    Receives CSV data as raw body with Content-Type: text/csv

    Headers:
    - Content-Type: text/csv
    - X-Device-ID: Device identifier
    - X-Patient-ID: (optional) Patient identifier
    - X-Session-ID: (optional) Session identifier
    """
    try:
        # Get CSV data from request body
        csv_data = request.data.decode('utf-8')

        if not csv_data:
            return jsonify({'error': 'No data received'}), 400

        # Count records (excluding header)
        lines = csv_data.strip().split('\n')
        record_count = len(lines) - 1  # Subtract header

        # Get metadata from headers
        device_id = request.headers.get('X-Device-ID', 'unknown')
        patient_id = request.headers.get('X-Patient-ID', 'unknown')
        session_id = request.headers.get('X-Session-ID', datetime.now().strftime('%Y%m%d_%H%M%S'))

        # Create folder structure: patient_data/patient_id/session_id/
        save_path = os.path.join(UPLOAD_FOLDER, patient_id, session_id)
        os.makedirs(save_path, exist_ok=True)

        # Generate filename with timestamp
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        filename = f'pulsewatch_data_{timestamp}_{device_id}.csv'
        full_path = os.path.join(save_path, filename)

        # Save CSV file
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
    """
    Receives a CSV chunk from the Flutter App.
    Expected data: file, patient_id, session_id, chunk_index

    [LEGACY ENDPOINT - kept for backward compatibility]
    """
    if 'file' not in request.files:
        return jsonify({"error": "No file part"}), 400

    file = request.files['file']
    patient_id = request.form.get('patient_id', 'unknown')
    session_id = request.form.get('session_id', 'session_001')
    chunk_index = request.form.get('chunk_index', '0')

    if file.filename == '':
        return jsonify({"error": "No selected file"}), 400

    if file:
        # Create a folder for this specific patient/session
        save_path = os.path.join(UPLOAD_FOLDER, patient_id, session_id)
        os.makedirs(save_path, exist_ok=True)

        # Save the file (e.g., chunk_1.csv)
        filename = f"chunk_{chunk_index}.csv"
        full_path = os.path.join(save_path, filename)
        file.save(full_path)

        print(f"✅ Received Data: Patient {patient_id} - Chunk {chunk_index}")
        return jsonify({"message": "Chunk uploaded successfully", "path": full_path}), 200


@app.route('/upload_recorder_log', methods=['POST'])
def upload_recorder_log():
    """
    Receives Recorder CSV log from Bangle.js via Flutter App.
    
    Expected form data:
    - file: CSV file from Recorder app
    - patient_id: Patient identifier
    - session_id: Session identifier (e.g., "pilot_001")
    - timestamp: Upload timestamp (ISO format)
    
    Recorder CSV Format:
    Time,HR,HR Confidence,Accel X,Accel Y,Accel Z,BAT %,BAT Voltage
    1733234567,72,95,0.12,-0.05,0.98,87,4.15
    """
    
    if 'file' not in request.files:
        return jsonify({"error": "No file part"}), 400
    
    file = request.files['file']
    patient_id = request.form.get('patient_id', 'unknown')
    session_id = request.form.get('session_id', 'session_001')
    upload_timestamp = request.form.get('timestamp', datetime.now().isoformat())
    
    if file.filename == '':
        return jsonify({"error": "No selected file"}), 400

    try:
        # Create folder structure
        save_path = os.path.join(UPLOAD_FOLDER, patient_id, session_id)
        os.makedirs(save_path, exist_ok=True)
        
        # Generate unique filename with timestamp
        timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"recorder_{timestamp_str}.csv"
        full_path = os.path.join(save_path, filename)
        
        # Read and validate CSV
        csv_content = file.read().decode('utf-8')
        
        # Basic validation
        if len(csv_content.strip()) < 50:
            return jsonify({"error": "CSV file appears to be empty or invalid"}), 400
        
        # Parse CSV to count rows and validate format
        csv_reader = csv.reader(StringIO(csv_content))
        rows = list(csv_reader)
        
        if len(rows) < 2:  # Header + at least 1 data row
            return jsonify({"error": "CSV file has insufficient data"}), 400
        
        header = rows[0]
        data_rows = rows[1:]
        
        # Save original CSV
        with open(full_path, 'w', encoding='utf-8') as f:
            f.write(csv_content)
        
        # Create metadata file
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
        
        # Log success
        print(f"✅ Recorder Data Received:")
        print(f"   Patient: {patient_id}")
        print(f"   Session: {session_id}")
        print(f"   Rows: {len(data_rows)}")
        print(f"   Size: {len(csv_content)} bytes")
        print(f"   Saved: {full_path}")
        
        return jsonify({
            "message": "Recorder log uploaded successfully",
            "path": full_path,
            "row_count": len(data_rows),
            "file_size": len(csv_content),
            "metadata": metadata
        }), 200
        
    except Exception as e:
        print(f"❌ Error processing upload: {str(e)}")
        return jsonify({"error": f"Processing failed: {str(e)}"}), 500


@app.route('/patient/<patient_id>/sessions', methods=['GET'])
def get_patient_sessions(patient_id):
    """
    List all sessions for a given patient.
    Used by research team to see available data.
    """
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
    """
    Retrieve all CSV files for a specific session.
    Research team can download combined data for analysis.
    """
    session_path = os.path.join(UPLOAD_FOLDER, patient_id, session_id)
    
    if not os.path.exists(session_path):
        return jsonify({"error": "Session not found"}), 404
    
    csv_files = [f for f in os.listdir(session_path) if f.endswith('.csv')]
    
    # Combine all CSV files
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
    """
    Health check endpoint for monitoring.
    """
    return jsonify({
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "storage_path": UPLOAD_FOLDER,
        "patients": len(os.listdir(UPLOAD_FOLDER)) if os.path.exists(UPLOAD_FOLDER) else 0
    })


if __name__ == '__main__':
    # Runs on port 5000 inside container (mapped to 5001 on host via docker-compose)
    app.run(host='0.0.0.0', port=5000, debug=True)