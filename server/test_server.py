#!/usr/bin/env python3
"""
PulseWatch AI - Test Server for CSV Data Upload
Run this on your MacBook to receive data from the Flutter app
"""

from flask import Flask, request, jsonify
from datetime import datetime
import os

app = Flask(__name__)

# Create uploads directory if it doesn't exist
UPLOAD_DIR = 'uploads'
os.makedirs(UPLOAD_DIR, exist_ok=True)

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint for testing connection"""
    return jsonify({
        'status': 'ok',
        'service': 'PulseWatch AI Server',
        'timestamp': datetime.now().isoformat()
    }), 200

@app.route('/upload', methods=['POST'])
def upload_data():
    """Receive CSV data from Flutter app"""
    try:
        # Get CSV data from request body
        csv_data = request.data.decode('utf-8')

        if not csv_data:
            return jsonify({'error': 'No data received'}), 400

        # Count records (excluding header)
        lines = csv_data.strip().split('\n')
        record_count = len(lines) - 1  # Subtract header

        # Get device ID from headers
        device_id = request.headers.get('X-Device-ID', 'unknown')

        # Generate filename with timestamp
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        filename = f'pulsewatch_data_{timestamp}_{device_id}.csv'
        filepath = os.path.join(UPLOAD_DIR, filename)

        # Save CSV file
        with open(filepath, 'w') as f:
            f.write(csv_data)

        print(f"\n✅ Received upload from {device_id}")
        print(f"   Records: {record_count}")
        print(f"   Saved to: {filepath}")
        print(f"   Size: {len(csv_data)} bytes\n")

        return jsonify({
            'success': True,
            'message': f'Successfully uploaded {record_count} records',
            'filename': filename,
            'records': record_count
        }), 200

    except Exception as e:
        print(f"❌ Error: {str(e)}")
        return jsonify({'error': str(e)}), 500

@app.route('/stats', methods=['GET'])
def get_stats():
    """Get statistics about uploaded files"""
    try:
        files = os.listdir(UPLOAD_DIR)
        csv_files = [f for f in files if f.endswith('.csv')]

        total_size = sum(
            os.path.getsize(os.path.join(UPLOAD_DIR, f))
            for f in csv_files
        )

        return jsonify({
            'total_files': len(csv_files),
            'total_size_bytes': total_size,
            'files': csv_files
        }), 200

    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    print("=" * 60)
    print("🏥 PulseWatch AI - Test Server")
    print("=" * 60)
    print(f"\n📁 Upload directory: {os.path.abspath(UPLOAD_DIR)}")
    print(f"\n🌐 Server starting on http://0.0.0.0:5000")
    print(f"\n📱 Configure Flutter app with your MacBook's IP:")
    print(f"   Example: http://192.168.1.XXX:5000")
    print(f"\n💡 To find your MacBook IP address:")
    print(f"   macOS: System Settings → Network → Wi-Fi → Details")
    print(f"   or run: ifconfig | grep 'inet ' | grep -v 127.0.0.1")
    print(f"\n⏹️  Press Ctrl+C to stop the server\n")
    print("=" * 60 + "\n")

    # Run server on all interfaces so it's accessible from phone
    app.run(host='0.0.0.0', port=5000, debug=True)
