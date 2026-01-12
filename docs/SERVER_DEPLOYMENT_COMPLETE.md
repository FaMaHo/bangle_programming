# PulseWatch Server - Complete Deployment Guide
## Production-Ready Setup for Medical Data Collection

---

## 🎯 Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    INTERNET (HTTPS)                         │
│              Port 443 - SSL/TLS Encrypted                   │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              NGINX (Ubuntu Host Machine)                     │
│  • SSL/TLS Termination (Let's Encrypt)                      │
│  • Reverse Proxy                                            │
│  • Rate Limiting (1000 req/hour per IP)                     │
│  • Request Logging                                          │
└────────────────────────┬────────────────────────────────────┘
                         │ Proxy to localhost:5000
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                   DOCKER COMPOSE                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Flask API Container (pulsewatch-api)                │  │
│  │  • Receives chunked data uploads                     │  │
│  │  • JWT authentication                                │  │
│  │  • Data validation                                   │  │
│  │  • CSV export for researchers                        │  │
│  │  Port: 5000 (internal only)                          │  │
│  └──────────────────────┬───────────────────────────────┘  │
│                         │                                   │
│                         ▼                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  PostgreSQL + TimescaleDB Container (pulsewatch-db)  │  │
│  │  • Time-series optimized storage                     │  │
│  │  • Patient data                                      │  │
│  │  • Heart rate readings                               │  │
│  │  • Accelerometer readings                            │  │
│  │  • Session management                                │  │
│  │  Port: 5432 (internal only)                          │  │
│  │  Volume: /var/lib/postgresql/data (persistent)      │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                         │
                         │ Export data
                         ▼
┌─────────────────────────────────────────────────────────────┐
│          Research Team in Romania                            │
│  • Web Dashboard (optional)                                  │
│  • CSV Data Export                                          │
│  • Analysis Tools                                           │
└─────────────────────────────────────────────────────────────┘
```

---

## 📋 Server Specifications (Confirmed)

- **CPU:** Quad-core 2.0 GHz (Intel Xeon E3 / AMD Ryzen 5)
- **RAM:** 8 GB DDR4
- **Storage:** 500 GB SSD
- **OS:** Ubuntu 22.04 LTS
- **Network:** Public IPv4, HTTPS (port 443)
- **Location:** China (primary) / Romania (backup)

---

## 🔑 Key Design Decisions

### 1. **Store-and-Forward Architecture (Not Real-Time)**
**Problem:** Great Firewall of China blocks/throttles real-time connections.
**Solution:** Phone collects data locally, uploads in 1-hour chunks via HTTPS.

### 2. **Chunked Upload Protocol**
- Data collected for 1 hour → Create chunk file
- Upload chunk to server via HTTPS POST
- Server responds "200 OK" → Phone deletes chunk
- If upload fails → Retry that specific chunk (not entire session)

### 3. **Docker for Portability**
- Build once in Romania → Deploy anywhere
- Easy migration if needed (Romania ↔ China)
- Consistent environment (no "works on my machine" issues)

### 4. **TimescaleDB for Time-Series Data**
- Built on PostgreSQL (familiar + stable)
- Optimized for sensor data queries
- 100x faster for time-range queries

---

## 🗄️ Database Schema (PostgreSQL + TimescaleDB)

```sql
-- Enable TimescaleDB extension
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Patients table
CREATE TABLE patients (
    id SERIAL PRIMARY KEY,
    patient_code VARCHAR(50) UNIQUE NOT NULL,  -- Anonymous code (e.g., "P001")
    device_id VARCHAR(100),                    -- Bangle.js MAC address
    age INTEGER,
    gender VARCHAR(10),
    study_group VARCHAR(50),                   -- Control vs Test
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_sync TIMESTAMP
);

-- Heart rate readings (time-series)
CREATE TABLE heart_rate (
    time TIMESTAMPTZ NOT NULL,                 -- Timestamp with timezone
    patient_id INTEGER REFERENCES patients(id),
    bpm INTEGER NOT NULL,
    confidence INTEGER,                        -- Optional: HRM confidence (0-100)
    device_id VARCHAR(100),
    CHECK (bpm > 0 AND bpm < 250)
);

-- Convert to TimescaleDB hypertable (time-series optimized)
SELECT create_hypertable('heart_rate', 'time');

-- Accelerometer readings (time-series)
CREATE TABLE accelerometer (
    time TIMESTAMPTZ NOT NULL,
    patient_id INTEGER REFERENCES patients(id),
    x FLOAT NOT NULL,
    y FLOAT NOT NULL,
    z FLOAT NOT NULL,
    device_id VARCHAR(100)
);

-- Convert to TimescaleDB hypertable
SELECT create_hypertable('accelerometer', 'time');

-- Recording sessions
CREATE TABLE sessions (
    id SERIAL PRIMARY KEY,
    patient_id INTEGER REFERENCES patients(id),
    session_code VARCHAR(100) UNIQUE NOT NULL, -- e.g., "P001_2024-12-03_001"
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ,
    duration_hours FLOAT,
    total_hr_readings INTEGER DEFAULT 0,
    total_accel_readings INTEGER DEFAULT 0,
    total_chunks INTEGER DEFAULT 0,            -- Number of 1-hour chunks
    chunks_received INTEGER DEFAULT 0,         -- Successfully uploaded chunks
    status VARCHAR(20) DEFAULT 'active',       -- active, completed, error
    notes TEXT
);

-- Data chunks tracking (for upload reliability)
CREATE TABLE data_chunks (
    id SERIAL PRIMARY KEY,
    session_id INTEGER REFERENCES sessions(id),
    chunk_index INTEGER NOT NULL,             -- 1, 2, 3, 4...
    chunk_time TIMESTAMPTZ NOT NULL,          -- Start time of this chunk
    hr_count INTEGER DEFAULT 0,               -- Heart rate readings in chunk
    accel_count INTEGER DEFAULT 0,            -- Accelerometer readings in chunk
    file_size_kb INTEGER,
    checksum VARCHAR(64),                     -- MD5/SHA256 for integrity
    uploaded_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(20) DEFAULT 'received',    -- received, verified, error
    UNIQUE(session_id, chunk_index)
);

-- Create indexes for fast queries
CREATE INDEX idx_hr_patient_time ON heart_rate(patient_id, time DESC);
CREATE INDEX idx_accel_patient_time ON accelerometer(patient_id, time DESC);
CREATE INDEX idx_sessions_patient ON sessions(patient_id);
CREATE INDEX idx_chunks_session ON data_chunks(session_id);
```

---

## 📁 Project File Structure

```
/opt/pulsewatch/
├── docker-compose.yml          # Docker orchestration
├── .env                        # Environment variables (SECRETS!)
├── .env.example                # Template for .env
├── README.md
│
├── backend/                    # Flask API
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── app.py                  # Main Flask app
│   ├── config.py               # Configuration
│   ├── wsgi.py                 # Gunicorn entry point
│   │
│   ├── routes/
│   │   ├── __init__.py
│   │   ├── patients.py         # Patient registration
│   │   ├── upload.py           # Data upload endpoints
│   │   ├── sessions.py         # Session management
│   │   ├── export.py           # CSV export for researchers
│   │   └── health.py           # Health check endpoint
│   │
│   ├── models/
│   │   ├── __init__.py
│   │   ├── patient.py
│   │   ├── heart_rate.py
│   │   ├── accelerometer.py
│   │   └── session.py
│   │
│   ├── utils/
│   │   ├── __init__.py
│   │   ├── auth.py             # JWT authentication
│   │   ├── validation.py       # Data validation
│   │   ├── chunking.py         # Chunk processing
│   │   └── database.py         # Database connection
│   │
│   └── tests/
│       ├── test_upload.py
│       ├── test_auth.py
│       └── test_export.py
│
├── database/
│   ├── init.sql                # Initial database schema
│   └── migrations/
│
├── nginx/
│   └── pulsewatch.conf         # NGINX configuration
│
└── scripts/
    ├── backup.sh               # Database backup script
    ├── deploy.sh               # Deployment script
    └── restore.sh              # Database restore script
```

---

## 🚀 Step-by-Step Deployment

### **PHASE 1: Server Preparation (Ubuntu 22.04)**

#### Step 1.1: Update System
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git vim htop net-tools
```

#### Step 1.2: Install Docker & Docker Compose
```bash
# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Add current user to docker group (no need for sudo)
sudo usermod -aG docker $USER
newgrp docker

# Verify Docker installation
docker --version

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Verify Docker Compose
docker-compose --version
```

#### Step 1.3: Install NGINX
```bash
sudo apt install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx

# Check NGINX status
sudo systemctl status nginx
```

#### Step 1.4: Setup Firewall
```bash
sudo ufw allow 22/tcp      # SSH
sudo ufw allow 80/tcp      # HTTP (for Let's Encrypt verification)
sudo ufw allow 443/tcp     # HTTPS
sudo ufw enable
sudo ufw status
```

---

### **PHASE 2: SSL Certificate Setup**

#### Step 2.1: Install Certbot
```bash
sudo apt install -y certbot python3-certbot-nginx
```

#### Step 2.2: Obtain SSL Certificate
**IMPORTANT:** You need a domain name first! (e.g., pulsewatch.youruniversity.edu)

```bash
# Replace with your actual domain
sudo certbot --nginx -d pulsewatch.youruniversity.edu

# Follow prompts:
# - Enter email address
# - Agree to terms
# - Choose to redirect HTTP to HTTPS (option 2)
```

#### Step 2.3: Test Auto-Renewal
```bash
sudo certbot renew --dry-run
```

SSL certificates auto-renew via cron job. No manual intervention needed!

---

### **PHASE 3: Create Project Directory**

```bash
# Create project directory
sudo mkdir -p /opt/pulsewatch
sudo chown $USER:$USER /opt/pulsewatch
cd /opt/pulsewatch

# Initialize git repository (optional but recommended)
git init
```

---

### **PHASE 4: Create Docker Configuration**

#### Step 4.1: Create `docker-compose.yml`
```yaml
version: '3.8'

services:
  # PostgreSQL + TimescaleDB Database
  database:
    image: timescale/timescaledb:latest-pg14
    container_name: pulsewatch-db
    restart: always
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db-data:/var/lib/postgresql/data
      - ./database/init.sql:/docker-entrypoint-initdb.d/init.sql
    ports:
      - "127.0.0.1:5432:5432"  # Only accessible from localhost
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Flask API
  api:
    build: ./backend
    container_name: pulsewatch-api
    restart: always
    environment:
      FLASK_ENV: production
      DATABASE_URL: postgresql://${DB_USER}:${DB_PASSWORD}@database:5432/${DB_NAME}
      JWT_SECRET_KEY: ${JWT_SECRET_KEY}
      API_RATE_LIMIT: ${API_RATE_LIMIT}
    depends_on:
      database:
        condition: service_healthy
    ports:
      - "127.0.0.1:5000:5000"  # Only accessible from localhost
    volumes:
      - ./backend:/app
      - api-logs:/app/logs
    command: gunicorn --workers 4 --bind 0.0.0.0:5000 --timeout 120 wsgi:app

volumes:
  db-data:      # Persistent database storage
  api-logs:     # Application logs
```

#### Step 4.2: Create `.env` File (IMPORTANT - Keep Secret!)
```bash
# Create .env file
cat > .env << 'EOF'
# Database Configuration
DB_NAME=pulsewatch_db
DB_USER=pulsewatch_user
DB_PASSWORD=CHANGE_THIS_SECURE_PASSWORD_123!

# Flask Configuration
JWT_SECRET_KEY=CHANGE_THIS_LONG_RANDOM_STRING_456!
API_RATE_LIMIT=1000

# Admin Credentials (for initial setup)
ADMIN_USERNAME=admin
ADMIN_PASSWORD=CHANGE_THIS_ADMIN_PASSWORD_789!
EOF

# Secure the .env file
chmod 600 .env
```

**CRITICAL:** Change all passwords before deployment!

#### Step 4.3: Create `.env.example` (Template for Others)
```bash
cat > .env.example << 'EOF'
# Database Configuration
DB_NAME=pulsewatch_db
DB_USER=pulsewatch_user
DB_PASSWORD=your_secure_password_here

# Flask Configuration
JWT_SECRET_KEY=your_jwt_secret_key_here
API_RATE_LIMIT=1000

# Admin Credentials
ADMIN_USERNAME=admin
ADMIN_PASSWORD=your_admin_password_here
EOF
```

---

### **PHASE 5: Create Backend Application**

#### Step 5.1: Create `backend/Dockerfile`
```dockerfile
FROM python:3.10-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create logs directory
RUN mkdir -p /app/logs

# Expose port
EXPOSE 5000

# Run with gunicorn
CMD ["gunicorn", "--workers", "4", "--bind", "0.0.0.0:5000", "--timeout", "120", "wsgi:app"]
```

#### Step 5.2: Create `backend/requirements.txt`
```txt
Flask==2.3.3
Flask-CORS==4.0.0
Flask-JWT-Extended==4.5.2
psycopg2-binary==2.9.7
gunicorn==21.2.0
python-dotenv==1.0.0
pandas==2.1.0
hashlib
```

#### Step 5.3: Create `backend/app.py` (Main Flask Application)
```python
from flask import Flask, jsonify
from flask_cors import CORS
from flask_jwt_extended import JWTManager
import os
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Initialize Flask app
app = Flask(__name__)
app.config['JWT_SECRET_KEY'] = os.getenv('JWT_SECRET_KEY')
app.config['JWT_ACCESS_TOKEN_EXPIRES'] = 86400  # 24 hours

# Enable CORS
CORS(app, resources={r"/api/*": {"origins": "*"}})

# Initialize JWT
jwt = JWTManager(app)

# Import routes
from routes import health, patients, upload, sessions, export

# Register blueprints
app.register_blueprint(health.bp)
app.register_blueprint(patients.bp, url_prefix='/api/v1/patients')
app.register_blueprint(upload.bp, url_prefix='/api/v1/upload')
app.register_blueprint(sessions.bp, url_prefix='/api/v1/sessions')
app.register_blueprint(export.bp, url_prefix='/api/v1/export')

# Error handlers
@app.errorhandler(404)
def not_found(error):
    return jsonify({"error": "Endpoint not found"}), 404

@app.errorhandler(500)
def internal_error(error):
    return jsonify({"error": "Internal server error"}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
```

#### Step 5.4: Create `backend/wsgi.py`
```python
from app import app

if __name__ == "__main__":
    app.run()
```

#### Step 5.5: Create Health Check Route `backend/routes/health.py`
```python
from flask import Blueprint, jsonify
import psycopg2
import os

bp = Blueprint('health', __name__)

@bp.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    try:
        # Test database connection
        conn = psycopg2.connect(os.getenv('DATABASE_URL'))
        conn.close()
        
        return jsonify({
            "status": "healthy",
            "database": "connected",
            "version": "1.0.0"
        }), 200
    except Exception as e:
        return jsonify({
            "status": "unhealthy",
            "error": str(e)
        }), 500
```

---

### **PHASE 6: Create Database Schema**

#### Step 6.1: Create `database/init.sql`
```sql
-- Enable TimescaleDB extension
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Patients table
CREATE TABLE patients (
    id SERIAL PRIMARY KEY,
    patient_code VARCHAR(50) UNIQUE NOT NULL,
    device_id VARCHAR(100),
    age INTEGER,
    gender VARCHAR(10),
    study_group VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_sync TIMESTAMP
);

-- Heart rate readings (time-series)
CREATE TABLE heart_rate (
    time TIMESTAMPTZ NOT NULL,
    patient_id INTEGER REFERENCES patients(id),
    bpm INTEGER NOT NULL,
    confidence INTEGER,
    device_id VARCHAR(100),
    CHECK (bpm > 0 AND bpm < 250)
);

-- Convert to TimescaleDB hypertable
SELECT create_hypertable('heart_rate', 'time');

-- Accelerometer readings (time-series)
CREATE TABLE accelerometer (
    time TIMESTAMPTZ NOT NULL,
    patient_id INTEGER REFERENCES patients(id),
    x FLOAT NOT NULL,
    y FLOAT NOT NULL,
    z FLOAT NOT NULL,
    device_id VARCHAR(100)
);

-- Convert to TimescaleDB hypertable
SELECT create_hypertable('accelerometer', 'time');

-- Sessions table
CREATE TABLE sessions (
    id SERIAL PRIMARY KEY,
    patient_id INTEGER REFERENCES patients(id),
    session_code VARCHAR(100) UNIQUE NOT NULL,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ,
    duration_hours FLOAT,
    total_hr_readings INTEGER DEFAULT 0,
    total_accel_readings INTEGER DEFAULT 0,
    total_chunks INTEGER DEFAULT 0,
    chunks_received INTEGER DEFAULT 0,
    status VARCHAR(20) DEFAULT 'active',
    notes TEXT
);

-- Data chunks tracking
CREATE TABLE data_chunks (
    id SERIAL PRIMARY KEY,
    session_id INTEGER REFERENCES sessions(id),
    chunk_index INTEGER NOT NULL,
    chunk_time TIMESTAMPTZ NOT NULL,
    hr_count INTEGER DEFAULT 0,
    accel_count INTEGER DEFAULT 0,
    file_size_kb INTEGER,
    checksum VARCHAR(64),
    uploaded_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(20) DEFAULT 'received',
    UNIQUE(session_id, chunk_index)
);

-- Create indexes
CREATE INDEX idx_hr_patient_time ON heart_rate(patient_id, time DESC);
CREATE INDEX idx_accel_patient_time ON accelerometer(patient_id, time DESC);
CREATE INDEX idx_sessions_patient ON sessions(patient_id);
CREATE INDEX idx_chunks_session ON data_chunks(session_id);

-- Insert test patient
INSERT INTO patients (patient_code, device_id, age, gender, study_group) 
VALUES ('P001-TEST', 'test_device_123', 30, 'F', 'pilot');
```

---

### **PHASE 7: Configure NGINX**

#### Step 7.1: Create NGINX Config `nginx/pulsewatch.conf`
```nginx
# Rate limiting zone
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=100r/m;

# Upstream to Flask API
upstream flask_api {
    server 127.0.0.1:5000;
}

# HTTP to HTTPS redirect
server {
    listen 80;
    server_name pulsewatch.youruniversity.edu;
    return 301 https://$server_name$request_uri;
}

# HTTPS Server
server {
    listen 443 ssl http2;
    server_name pulsewatch.youruniversity.edu;

    # SSL certificates (managed by Certbot)
    ssl_certificate /etc/letsencrypt/live/pulsewatch.youruniversity.edu/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/pulsewatch.youruniversity.edu/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Logging
    access_log /var/log/nginx/pulsewatch_access.log;
    error_log /var/log/nginx/pulsewatch_error.log;

    # Client body size (for file uploads)
    client_max_body_size 10M;

    # API endpoints
    location /api/ {
        # Rate limiting
        limit_req zone=api_limit burst=20 nodelay;
        
        proxy_pass http://flask_api;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Timeout settings
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Health check endpoint (no rate limit)
    location /health {
        proxy_pass http://flask_api;
        proxy_set_header Host $host;
    }
}
```

#### Step 7.2: Deploy NGINX Config
```bash
# Copy config to NGINX
sudo cp nginx/pulsewatch.conf /etc/nginx/sites-available/pulsewatch

# Create symbolic link
sudo ln -s /etc/nginx/sites-available/pulsewatch /etc/nginx/sites-enabled/

# Test configuration
sudo nginx -t

# Reload NGINX
sudo systemctl reload nginx
```

---

### **PHASE 8: Deploy & Start Services**

#### Step 8.1: Build and Start Docker Containers
```bash
cd /opt/pulsewatch

# Build images
docker-compose build

# Start services
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f
```

#### Step 8.2: Verify Deployment
```bash
# Test health endpoint
curl https://pulsewatch.youruniversity.edu/health

# Expected response:
# {"status":"healthy","database":"connected","version":"1.0.0"}

# Check Docker containers
docker ps

# Check database
docker exec -it pulsewatch-db psql -U pulsewatch_user -d pulsewatch_db -c "\dt"
```

---

### **PHASE 9: Backup & Maintenance**

#### Step 9.1: Create Backup Script `scripts/backup.sh`
```bash
#!/bin/bash

BACKUP_DIR="/opt/pulsewatch/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$BACKUP_DIR/pulsewatch_backup_$TIMESTAMP.sql"

# Create backup directory
mkdir -p $BACKUP_DIR

# Backup database
docker exec pulsewatch-db pg_dump -U pulsewatch_user pulsewatch_db > $BACKUP_FILE

# Compress backup
gzip $BACKUP_FILE

# Keep only last 30 days of backups
find $BACKUP_DIR -name "*.sql.gz" -mtime +30 -delete

echo "Backup completed: ${BACKUP_FILE}.gz"
```

#### Step 9.2: Setup Automated Daily Backups
```bash
# Make script executable
chmod +x scripts/backup.sh

# Add to crontab (runs daily at 2 AM)
(crontab -l 2>/dev/null; echo "0 2 * * * /opt/pulsewatch/scripts/backup.sh >> /opt/pulsewatch/logs/backup.log 2>&1") | crontab -
```

#### Step 9.3: Monitor Disk Usage
```bash
# Check disk space
df -h

# Check Docker volumes
docker system df

# Clean unused Docker resources (careful!)
docker system prune -a
```

---

## 📊 API Endpoints Summary

### 1. **Health Check**
```
GET /health
Response: {"status": "healthy", "database": "connected"}
```

### 2. **Patient Registration**
```
POST /api/v1/patients/register
Body: {
  "patient_code": "P001",
  "device_id": "bangle_abc123",
  "age": 45,
  "gender": "F"
}
Response: {
  "patient_id": 1,
  "token": "jwt_token_here"
}
```

### 3. **Start Session**
```
POST /api/v1/sessions/start
Headers: Authorization: Bearer <token>
Body: {
  "patient_id": 1
}
Response: {
  "session_id": 1,
  "session_code": "P001_2024-12-03_001",
  "start_time": "2024-12-03T10:00:00Z"
}
```

### 4. **Upload Data Chunk**
```
POST /api/v1/upload/chunk
Headers: Authorization: Bearer <token>
Body: {
  "session_id": 1,
  "chunk_index": 1,
  "chunk_time": "2024-12-03T10:00:00Z",
  "heart_rate_data": [
    {"timestamp": 1701601200000, "bpm": 75},
    {"timestamp": 1701601201000, "bpm": 76},
    ...
  ],
  "accelerometer_data": [
    {"timestamp": 1701601200000, "x": 0.1, "y": -0.5, "z": 0.8},
    ...
  ],
  "checksum": "abc123def456"
}
Response: {
  "status": "success",
  "chunk_id": 1,
  "hr_inserted": 3600,
  "accel_inserted": 45000
}
```

### 5. **End Session**
```
POST /api/v1/sessions/end
Headers: Authorization: Bearer <token>
Body: {
  "session_id": 1
}
Response: {
  "session_id": 1,
  "duration_hours": 48.2,
  "total_chunks": 48,
  "chunks_received": 48,
  "total_hr_readings": 173000,
  "total_accel_readings": 2160000
}
```

### 6. **Export Patient Data (CSV)**
```
GET /api/v1/export/patient/1?format=csv&days=7
Headers: Authorization: Bearer <admin_token>
Response: CSV file download
```

---

## 🔒 Security Checklist

- [ ] Changed all default passwords in `.env`
- [ ] SSL certificate installed and auto-renewing
- [ ] Firewall configured (only 22, 80, 443 open)
- [ ] Database only accessible from localhost
- [ ] API only accessible from localhost (proxied via NGINX)
- [ ] Rate limiting enabled (100 req/min)
- [ ] JWT tokens expire after 24 hours
- [ ] Automated backups running daily
- [ ] Log rotation configured
- [ ] `.env` file secured (chmod 600)
- [ ] `.env` file added to `.gitignore`

---

## 🚨 Troubleshooting

### Docker containers won't start
```bash
# Check logs
docker-compose logs

# Rebuild containers
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

### Database connection errors
```bash
# Check database container
docker exec -it pulsewatch-db psql -U pulsewatch_user -d pulsewatch_db

# Check environment variables
docker exec pulsewatch-api env | grep DATABASE
```

### NGINX errors
```bash
# Check NGINX logs
sudo tail -f /var/log/nginx/error.log

# Test configuration
sudo nginx -t

# Reload NGINX
sudo systemctl reload nginx
```

### SSL certificate issues
```bash
# Test SSL
curl https://pulsewatch.youruniversity.edu/health

# Renew certificate manually
sudo certbot renew

# Check certificate expiry
sudo certbot certificates
```

---

## 📈 Monitoring & Analytics

### Check API Performance
```bash
# API response time
curl -w "@curl-format.txt" -o /dev/null -s https://pulsewatch.youruniversity.edu/health

# Active connections
netstat -ant | grep :443 | wc -l

# Database connections
docker exec pulsewatch-db psql -U pulsewatch_user -d pulsewatch_db -c "SELECT count(*) FROM pg_stat_activity;"
```

### Database Statistics
```bash
# Total patients
docker exec pulsewatch-db psql -U pulsewatch_user -d pulsewatch_db -c "SELECT COUNT(*) FROM patients;"

# Total heart rate readings
docker exec pulsewatch-db psql -U pulsewatch_user -d pulsewatch_db -c "SELECT COUNT(*) FROM heart_rate;"

# Database size
docker exec pulsewatch-db psql -U pulsewatch_user -d pulsewatch_db -c "SELECT pg_size_pretty(pg_database_size('pulsewatch_db'));"
```

---

## 🎓 Next Steps After Deployment

1. **Test with dummy data** - Upload test chunks from Flutter app
2. **Verify data integrity** - Check database for correct data storage
3. **Test chunk recovery** - Simulate failed uploads and retries
4. **Load testing** - Simulate 20-30 patients uploading simultaneously
5. **Setup monitoring** - Consider Grafana + Prometheus (optional)
6. **Train research team** - CSV export and data analysis

---

## 📝 Important Notes

- **Portability:** Entire setup can be copied to USB and deployed in China
- **Scalability:** Can handle 100+ patients with current specs
- **Backup:** Daily automated backups to `/opt/pulsewatch/backups`
- **SSL:** Auto-renews every 90 days via certbot
- **Updates:** `docker-compose pull && docker-compose up -d` to update

---

## ✅ Pre-Deployment Checklist

- [ ] Domain name registered and DNS configured
- [ ] Server has public IPv4 address
- [ ] Ubuntu 22.04 LTS installed
- [ ] Docker & Docker Compose installed
- [ ] NGINX installed
- [ ] SSL certificate obtained
- [ ] `.env` file created with secure passwords
- [ ] Firewall configured
- [ ] Project files uploaded to `/opt/pulsewatch`
- [ ] Docker containers built and running
- [ ] Health check endpoint returns "healthy"
- [ ] Database accessible and schema created
- [ ] Backup script tested
- [ ] API endpoints tested with Postman/curl

---

**🎉 Server is ready for pilot study!**
