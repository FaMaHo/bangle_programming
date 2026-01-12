# PulseWatch AI - Windows Server Deployment Guide

This guide explains how to deploy the PulseWatch AI backend on your Windows 11 server.

## Server Specifications

- **CPU:** AMD Ryzen Threadripper 7980X (64-core, 3.2 GHz)
- **GPU:** AMD Radeon RX 550
- **RAM:** 64 GB
- **Storage:** 4 TB SSD
- **OS:** Windows 11
- **Remote Access:** TeamViewer ID: 1010587657 (Password: HanLab608)

## Deployment Overview

We'll deploy the backend using **Docker Desktop for Windows**, which allows running Linux containers on Windows seamlessly.

---

## Step 1: Install Prerequisites on Windows Server

### 1.1 Install Docker Desktop for Windows

1. **Download Docker Desktop:**
   - Visit: https://www.docker.com/products/docker-desktop/
   - Download the Windows installer

2. **Install Docker Desktop:**
   ```powershell
   # Run the installer
   # During installation, ensure "Use WSL 2 instead of Hyper-V" is selected
   ```

3. **Enable WSL 2 (Windows Subsystem for Linux):**
   ```powershell
   # Open PowerShell as Administrator
   wsl --install
   wsl --set-default-version 2
   ```

4. **Start Docker Desktop:**
   - Launch Docker Desktop from Start Menu
   - Wait for Docker Engine to start (whale icon in system tray)
   - Verify installation:
     ```powershell
     docker --version
     docker-compose --version
     ```

### 1.2 Install Git for Windows (if not already installed)

```powershell
# Download from: https://git-scm.com/download/win
# Or use winget:
winget install Git.Git
```

---

## Step 2: Clone Repository (if not already done)

```powershell
# Open PowerShell or Git Bash
cd C:\
git clone https://github.com/YOUR_USERNAME/bangle_programming.git
cd bangle_programming
```

---

## Step 3: Configure Docker Resource Limits

**IMPORTANT:** Since the server is shared, configure Docker to use limited resources.

1. **Open Docker Desktop Settings:**
   - Right-click Docker Desktop system tray icon
   - Select "Settings"

2. **Configure Resource Limits:**
   - Go to: Resources → Advanced
   - **CPUs:** Set to 32 cores (half of 64)
   - **Memory:** Set to 32 GB (half of 64 GB)
   - **Disk image size:** 200 GB (enough for patient data)
   - Click "Apply & Restart"

This ensures other users can still use the server while your backend runs.

---

## Step 4: Build and Deploy the Backend

### 4.1 Navigate to Backend Directory

```powershell
cd C:\bangle_programming\pulsewatch_backend
```

### 4.2 Build Docker Image

```powershell
# Build the Docker image
docker build -t pulsewatch-backend:latest .

# Verify the image was created
docker images | findstr pulsewatch
```

### 4.3 Start the Backend Service

```powershell
# Start the backend using docker-compose
docker-compose up -d

# Verify the container is running
docker ps
```

Expected output:
```
CONTAINER ID   IMAGE                         STATUS          PORTS
abc123...      pulsewatch-backend:latest     Up 2 seconds    0.0.0.0:5001->5000/tcp
```

### 4.4 Check Logs

```powershell
# View real-time logs
docker-compose logs -f

# Or view specific container logs
docker logs pulsewatch_backend
```

---

## Step 5: Configure Windows Firewall

Allow incoming connections on port 5001:

```powershell
# Open PowerShell as Administrator

# Add firewall rule for port 5001
New-NetFirewallRule -DisplayName "PulseWatch Backend" -Direction Inbound -Protocol TCP -LocalPort 5001 -Action Allow

# Verify the rule was created
Get-NetFirewallRule -DisplayName "PulseWatch Backend"
```

---

## Step 6: Find Server IP Address

### 6.1 Get Local Network IP

```powershell
# Get IPv4 address
ipconfig | findstr "IPv4"
```

Example output: `192.168.1.100`

### 6.2 Get Public IP (if accessing from outside local network)

```powershell
# Get public IP address
curl ifconfig.me
```

---

## Step 7: Test the Backend

### 7.1 Test Locally on Server

```powershell
# Test health endpoint
curl http://localhost:5001/health

# Expected response:
# {"status":"healthy","timestamp":"2025-01-12T10:30:00.123456","storage_path":"patient_data","patients":0}
```

### 7.2 Test from Another Computer on Same Network

```powershell
# Replace 192.168.1.100 with your server's IP
curl http://192.168.1.100:5001/health
```

### 7.3 Test CSV Upload

Create a test file `test.csv`:
```csv
timestamp,bpm,confidence,accel_x,accel_y,accel_z,device_id
1736697600000,72,85,100,-50,980,test-device
1736697601000,73,87,105,-48,982,test-device
```

Upload it:
```powershell
curl -X POST http://localhost:5001/upload `
  -H "Content-Type: text/csv" `
  -H "X-Device-ID: test-device" `
  -H "X-Patient-ID: test-patient" `
  --data-binary "@test.csv"
```

Expected response:
```json
{
  "success": true,
  "message": "Successfully uploaded 2 records",
  "filename": "pulsewatch_data_20250112_103000_test-device.csv",
  "records": 2
}
```

---

## Step 8: Configure Flutter App

1. **Open PulseWatch Flutter App**
2. **Go to Server Tab** (cloud icon)
3. **Enter Server URL:**
   - **Local network:** `http://192.168.1.100:5001`
   - **Public internet:** `http://YOUR_PUBLIC_IP:5001` (requires port forwarding)
4. **Tap "Test Connection"** - Should show "✅ Connected"
5. **Tap "Upload Data to Server"** - Should upload successfully

---

## Step 9: Set Up Domain Name (Optional but Recommended)

### Option A: Use Dynamic DNS (Free)

If you don't have a static public IP, use a Dynamic DNS service:

1. **Register with a DDNS provider:**
   - No-IP: https://www.noip.com/ (Free)
   - DuckDNS: https://www.duckdns.org/ (Free)
   - Dynu: https://www.dynu.com/ (Free)

2. **Example with DuckDNS:**
   ```powershell
   # Visit duckdns.org and create account
   # Choose a subdomain: pulsewatch.duckdns.org
   # Install DuckDNS Windows client to auto-update IP
   ```

3. **Update Flutter app with domain:**
   ```
   http://pulsewatch.duckdns.org:5001
   ```

### Option B: Purchase a Real Domain (Recommended for Production)

1. **Purchase domain** (e.g., from Namecheap, GoDaddy)
2. **Add A record** pointing to your public IP
3. **Configure SSL** (see Step 10)

---

## Step 10: Enable HTTPS with SSL (Recommended for Production)

### Option A: Use Cloudflare Tunnel (Easiest, Free SSL)

Cloudflare Tunnel creates a secure tunnel without port forwarding:

1. **Create Cloudflare account:** https://cloudflare.com
2. **Install Cloudflared:**
   ```powershell
   # Download from: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
   ```

3. **Create tunnel:**
   ```powershell
   cloudflared tunnel login
   cloudflared tunnel create pulsewatch
   cloudflared tunnel route dns pulsewatch api.your-domain.com
   ```

4. **Configure tunnel:**
   Create `config.yml`:
   ```yaml
   tunnel: <tunnel-id>
   credentials-file: C:\Users\YourUser\.cloudflared\<tunnel-id>.json

   ingress:
     - hostname: api.your-domain.com
       service: http://localhost:5001
     - service: http_status:404
   ```

5. **Run tunnel:**
   ```powershell
   cloudflared tunnel run pulsewatch
   ```

6. **Update Flutter app:**
   ```
   https://api.your-domain.com
   ```

### Option B: Use NGINX Reverse Proxy with Let's Encrypt

This requires more setup but gives you full control. See `docs/SERVER_DEPLOYMENT_COMPLETE.md` for detailed NGINX configuration.

---

## Step 11: Port Forwarding (If Accessing from Internet)

If you need to access the server from outside your local network:

### 11.1 Configure Router Port Forwarding

1. **Access your router admin panel** (usually http://192.168.1.1)
2. **Find Port Forwarding section** (varies by router)
3. **Add port forwarding rule:**
   - **External Port:** 5001
   - **Internal IP:** 192.168.1.100 (your server IP)
   - **Internal Port:** 5001
   - **Protocol:** TCP

### 11.2 Security Warning

⚠️ **Opening ports to the internet is risky!** Consider these security measures:

1. **Use a firewall** to limit connections
2. **Implement authentication** (JWT tokens)
3. **Use HTTPS** with SSL certificates
4. **Rate limiting** to prevent abuse
5. **Regular security updates**

**For pilot study, we recommend:**
- Use Cloudflare Tunnel (no port forwarding needed)
- Or keep server on local network and use VPN

---

## Step 12: Auto-Start on Server Boot

### Option A: Docker Desktop Auto-Start (Recommended)

1. **Open Docker Desktop Settings**
2. **General tab:**
   - ✅ Enable "Start Docker Desktop when you log in"
3. **Docker Compose with restart policy:**
   ```yaml
   # Already configured in docker-compose.yml:
   restart: always
   ```

### Option B: Windows Task Scheduler

If you need more control, create a scheduled task:

```powershell
# Create task to start Docker service on boot
$action = New-ScheduledTaskAction -Execute 'docker-compose' -Argument 'up -d' -WorkingDirectory 'C:\bangle_programming\pulsewatch_backend'
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -TaskName "PulseWatch Backend" -Description "Start PulseWatch backend on boot"
```

---

## Management Commands

### View Logs

```powershell
# Real-time logs
docker-compose logs -f

# Last 100 lines
docker-compose logs --tail=100

# Logs for specific service
docker logs pulsewatch_backend
```

### Stop Backend

```powershell
# Stop containers
docker-compose down

# Stop and remove volumes (CAUTION: deletes data!)
docker-compose down -v
```

### Restart Backend

```powershell
# Restart without rebuilding
docker-compose restart

# Rebuild and restart (after code changes)
docker-compose up -d --build
```

### Check Resource Usage

```powershell
# View container resource usage
docker stats pulsewatch_backend

# View all containers
docker stats
```

### Backup Patient Data

```powershell
# Patient data is stored in: C:\bangle_programming\pulsewatch_backend\patient_data

# Create backup
$date = Get-Date -Format "yyyyMMdd_HHmmss"
Compress-Archive -Path "C:\bangle_programming\pulsewatch_backend\patient_data" -DestinationPath "C:\backups\patient_data_$date.zip"
```

### Update Backend Code

```powershell
# Pull latest code
cd C:\bangle_programming
git pull origin main

# Rebuild and restart
cd pulsewatch_backend
docker-compose down
docker-compose up -d --build
```

---

## Monitoring and Maintenance

### 1. Check Server Health Daily

```powershell
# Check if container is running
docker ps | findstr pulsewatch

# Check health endpoint
curl http://localhost:5001/health
```

### 2. Monitor Disk Space

```powershell
# Check disk usage
Get-PSDrive C

# Check patient data folder size
Get-ChildItem -Path "C:\bangle_programming\pulsewatch_backend\patient_data" -Recurse | Measure-Object -Property Length -Sum
```

### 3. Set Up Automated Backups

Create a PowerShell script `backup.ps1`:

```powershell
# backup.ps1
$date = Get-Date -Format "yyyyMMdd_HHmmss"
$source = "C:\bangle_programming\pulsewatch_backend\patient_data"
$destination = "C:\backups\patient_data_$date.zip"

# Create backup
Compress-Archive -Path $source -DestinationPath $destination

# Keep only last 30 days of backups
Get-ChildItem -Path "C:\backups" -Filter "patient_data_*.zip" |
  Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-30) } |
  Remove-Item

Write-Host "Backup completed: $destination"
```

Schedule it daily:
```powershell
$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-File C:\scripts\backup.ps1'
$trigger = New-ScheduledTaskTrigger -Daily -At 3am
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "PulseWatch Backup" -Description "Daily backup of patient data"
```

---

## Troubleshooting

### Problem: Docker Desktop won't start

**Solution:**
```powershell
# Restart Docker Desktop
Stop-Process -Name "Docker Desktop" -Force
Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"

# Or restart Docker service
Restart-Service docker
```

### Problem: Port 5001 already in use

**Solution:**
```powershell
# Find process using port 5001
netstat -ano | findstr :5001

# Kill the process (replace PID with actual process ID)
taskkill /PID <PID> /F
```

### Problem: Cannot connect from phone

**Solution:**
1. Check Windows Firewall is allowing port 5001
2. Verify server and phone are on same Wi-Fi network
3. Check server IP address hasn't changed
4. Try pinging server from phone

### Problem: Docker container exits immediately

**Solution:**
```powershell
# Check container logs for errors
docker logs pulsewatch_backend

# Common issues:
# - Port already in use
# - Syntax error in app.py
# - Missing dependencies in requirements.txt
```

### Problem: "permission denied" errors

**Solution:**
```powershell
# Ensure patient_data directory has write permissions
icacls "C:\bangle_programming\pulsewatch_backend\patient_data" /grant Users:F
```

---

## Security Best Practices

### 1. Regular Windows Updates

```powershell
# Check for updates
Get-WindowsUpdate

# Install updates
Install-WindowsUpdate
```

### 2. Use Strong Passwords

- Change default TeamViewer password
- Use strong Windows login password
- Enable Two-Factor Authentication where possible

### 3. Limit Network Exposure

- Keep server on local network only (no port forwarding)
- Or use VPN for remote access
- Or use Cloudflare Tunnel for secure external access

### 4. Regular Backups

- Daily automated backups
- Store backups on separate drive or cloud storage
- Test restore process monthly

### 5. Monitor Logs

- Check Docker logs daily for errors
- Look for suspicious upload patterns
- Monitor disk space usage

---

## Performance Optimization

### 1. Docker Resource Allocation

Current settings (32 cores, 32GB RAM) are more than sufficient for the pilot study.

Expected resource usage:
- **CPU:** <1% (idle), 5-10% (during uploads)
- **RAM:** 200-500 MB
- **Disk:** Grows with patient data (~10 MB per patient per day)

### 2. Database Optimization (Future)

When adding PostgreSQL/TimescaleDB:
- Configure connection pooling
- Set appropriate cache sizes
- Enable query optimization

---

## Next Steps After Deployment

1. ✅ **Test end-to-end data flow:**
   - Bangle.js → Flutter App → Server
   - Verify CSV files are saved correctly

2. ✅ **Add patient management system:**
   - Implement patient ID assignment in Flutter app
   - Add patient registration flow

3. ✅ **Set up automated backups:**
   - Daily backups of patient_data folder
   - Test restore process

4. ✅ **Configure domain and SSL:**
   - Register domain or use DDNS
   - Set up SSL certificate
   - Update Flutter app with HTTPS URL

5. ✅ **Start pilot study:**
   - Recruit initial patients
   - Test 48-hour recording sessions
   - Monitor data quality and completeness

---

## Contact and Support

- **GitHub Issues:** https://github.com/YOUR_USERNAME/bangle_programming/issues
- **Server Access:** TeamViewer ID 1010587657
- **Usage Scheduling:** Post in group chat at least 1 day in advance

---

## Appendix: Alternative Deployment Methods

### Method 1: Docker Desktop (Recommended) ✅

**Pros:**
- Easy to set up and manage
- Consistent with Linux deployment
- Isolated environment
- Easy updates and rollbacks

**Cons:**
- Requires Docker Desktop license for commercial use (free for education)
- Uses WSL2 which requires virtualization

### Method 2: Native Python on Windows

**Pros:**
- No Docker required
- Direct Windows integration
- Slightly better performance

**Cons:**
- Different environment than production Linux
- More manual configuration
- Harder to replicate

If you prefer native Python deployment:

```powershell
# Install Python 3.11
winget install Python.Python.3.11

# Install dependencies
cd C:\bangle_programming\pulsewatch_backend
pip install -r requirements.txt

# Run directly
python app.py
```

### Method 3: Windows Subsystem for Linux (WSL2)

Run full Linux inside Windows:

```powershell
# Install Ubuntu in WSL2
wsl --install -d Ubuntu-22.04

# Access Linux environment
wsl

# Follow Linux deployment guide
```

---

## Summary

Your Windows server deployment is now:
- ✅ Running Docker Desktop with resource limits
- ✅ Backend container running on port 5001
- ✅ Windows Firewall configured
- ✅ Ready to receive data from Flutter app
- ✅ Auto-starts on server boot
- ✅ Daily automated backups configured

**Server URL for Flutter app:**
- Local network: `http://YOUR_SERVER_IP:5001`
- With domain/DDNS: `http://pulsewatch.your-domain.com:5001`
- With SSL: `https://pulsewatch.your-domain.com`

You're ready to start the pilot study! 🎉
