# PulseWatch AI - Windows Server Deployment Checklist

Quick checklist for deploying to your Windows 11 server via TeamViewer.

## 📋 Pre-Deployment Checklist

- [ ] Reserve server time in group chat (at least 1 day in advance)
- [ ] Have TeamViewer credentials ready (contact administrator for access)
- [ ] Ensure you have admin access to the server

---

## 🚀 Deployment Steps (Execute via TeamViewer)

### Phase 1: Install Prerequisites (30 minutes)

- [ ] **Install Docker Desktop for Windows**
  - Download from: https://www.docker.com/products/docker-desktop/
  - ✅ Select "Use WSL 2 instead of Hyper-V" during installation
  - Restart server if required

- [ ] **Enable WSL 2**
  ```powershell
  # Open PowerShell as Administrator
  wsl --install
  wsl --set-default-version 2
  ```

- [ ] **Configure Docker resource limits** (IMPORTANT for shared server)
  - Open Docker Desktop Settings → Resources → Advanced
  - Set CPUs: 32 (half of 64)
  - Set Memory: 32 GB (half of 64 GB)
  - Click "Apply & Restart"

- [ ] **Verify Docker installation**
  ```powershell
  docker --version
  docker-compose --version
  ```

### Phase 2: Deploy Backend (10 minutes)

- [ ] **Navigate to project directory**
  ```powershell
  cd C:\bangle_programming\pulsewatch_backend
  ```

- [ ] **Build Docker image**
  ```powershell
  docker build -t pulsewatch-backend:latest .
  ```

- [ ] **Start backend service**
  ```powershell
  docker-compose up -d
  ```

- [ ] **Verify container is running**
  ```powershell
  docker ps
  # Should show: pulsewatch_backend with status "Up"
  ```

- [ ] **Check logs for errors**
  ```powershell
  docker-compose logs
  # Should show: "Running on http://0.0.0.0:5000"
  ```

### Phase 3: Configure Network (5 minutes)

- [ ] **Configure Windows Firewall**
  ```powershell
  # Open PowerShell as Administrator
  New-NetFirewallRule -DisplayName "PulseWatch Backend" -Direction Inbound -Protocol TCP -LocalPort 5001 -Action Allow
  ```

- [ ] **Get server IP address**
  ```powershell
  ipconfig | findstr "IPv4"
  # Note down the IP (e.g., 192.168.1.100)
  ```

### Phase 4: Testing (10 minutes)

- [ ] **Test health endpoint locally**
  ```powershell
  curl http://localhost:5001/health
  # Should return: {"status":"healthy",...}
  ```

- [ ] **Test upload endpoint**
  ```powershell
  # Create test.csv with sample data
  echo "timestamp,bpm,confidence,accel_x,accel_y,accel_z,device_id" > test.csv
  echo "1736697600000,72,85,100,-50,980,test-device" >> test.csv

  # Upload test file
  curl -X POST http://localhost:5001/upload `
    -H "Content-Type: text/csv" `
    -H "X-Device-ID: test-device" `
    -H "X-Patient-ID: test-patient" `
    --data-binary "@test.csv"

  # Should return: {"success":true,"message":"Successfully uploaded 1 records",...}
  ```

- [ ] **Verify data was saved**
  ```powershell
  dir C:\bangle_programming\pulsewatch_backend\patient_data\test-patient
  # Should show CSV file with timestamp
  ```

### Phase 5: Configure Flutter App (5 minutes)

- [ ] **Open PulseWatch Flutter app on phone**
- [ ] **Go to Server tab** (cloud icon)
- [ ] **Enter server URL:** `http://SERVER_IP_HERE:5001`
- [ ] **Tap "Test Connection"** → Should show ✅ Connected
- [ ] **Tap "Upload Data to Server"** → Should upload successfully
- [ ] **Verify data arrived on server**
  ```powershell
  dir C:\bangle_programming\pulsewatch_backend\patient_data
  # Should show new patient folder with data
  ```

---

## 🔧 Post-Deployment Configuration

### Optional but Recommended:

- [ ] **Set up automated backups**
  - Create `C:\scripts\backup.ps1` (see full guide)
  - Schedule daily backup task at 3 AM

- [ ] **Configure auto-start on boot**
  - Docker Desktop Settings → General
  - ✅ Enable "Start Docker Desktop when you log in"

- [ ] **Set up domain name** (choose one):
  - Option A: Free DDNS (DuckDNS, No-IP)
  - Option B: Purchase real domain (recommended for production)
  - Option C: Use Cloudflare Tunnel (easiest SSL setup)

- [ ] **Enable HTTPS with SSL** (recommended)
  - Follow Cloudflare Tunnel setup in full guide
  - Or configure NGINX reverse proxy

---

## 📊 Monitoring Setup

- [ ] **Create monitoring script** `monitor.ps1`:
  ```powershell
  # Check if container is running
  $status = docker ps --filter "name=pulsewatch_backend" --format "{{.Status}}"
  if ($status -match "Up") {
    Write-Host "✅ Backend is running"
  } else {
    Write-Host "❌ Backend is down!"
  }

  # Check disk space
  $drive = Get-PSDrive C
  $freeGB = [math]::Round($drive.Free / 1GB, 2)
  Write-Host "💾 Free disk space: $freeGB GB"

  # Check patient data size
  $dataSize = (Get-ChildItem -Path "C:\bangle_programming\pulsewatch_backend\patient_data" -Recurse | Measure-Object -Property Length -Sum).Sum
  $dataSizeMB = [math]::Round($dataSize / 1MB, 2)
  Write-Host "📁 Patient data size: $dataSizeMB MB"
  ```

- [ ] **Schedule daily monitoring**
  ```powershell
  $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-File C:\scripts\monitor.ps1'
  $trigger = New-ScheduledTaskTrigger -Daily -At 9am
  Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "PulseWatch Monitor"
  ```

---

## 🐛 Troubleshooting Quick Fixes

### Backend not starting?

```powershell
# Check logs
docker logs pulsewatch_backend

# Restart container
docker-compose restart

# Rebuild if code changed
docker-compose up -d --build
```

### Can't connect from phone?

```powershell
# Verify firewall rule
Get-NetFirewallRule -DisplayName "PulseWatch Backend"

# Check server IP
ipconfig | findstr "IPv4"

# Test connection locally first
curl http://localhost:5001/health
```

### Port 5001 already in use?

```powershell
# Find process using port
netstat -ano | findstr :5001

# Kill process (replace PID)
taskkill /PID <PID> /F

# Restart backend
docker-compose restart
```

---

## 📞 Support Contacts

- **Server Access:** Contact administrator for TeamViewer credentials
- **Usage Scheduling:** Post in group chat 1 day in advance
- **GitHub Issues:** https://github.com/YOUR_USERNAME/bangle_programming/issues
- **Full Documentation:** See `docs/WINDOWS_SERVER_DEPLOYMENT.md`

---

## ✅ Success Criteria

Your deployment is successful when ALL of these work:

1. ✅ `docker ps` shows pulsewatch_backend container running
2. ✅ `curl http://localhost:5001/health` returns healthy status
3. ✅ Flutter app can connect to server
4. ✅ Flutter app can upload data successfully
5. ✅ CSV files appear in `patient_data` folder on server
6. ✅ Backend auto-starts when server boots

---

## ⏱️ Estimated Timeline

- **Phase 1 (Prerequisites):** 30 minutes
- **Phase 2 (Deploy):** 10 minutes
- **Phase 3 (Network):** 5 minutes
- **Phase 4 (Testing):** 10 minutes
- **Phase 5 (Flutter app):** 5 minutes

**Total:** ~1 hour for initial deployment

**Optional configuration:** +30 minutes (backups, domain, SSL)

---

## 🎯 Next Steps After Deployment

1. **Add patient management system to Flutter app**
   - Implement patient ID assignment
   - Create patient registration flow

2. **Set up automated data upload**
   - Background sync when on WiFi
   - Retry failed uploads

3. **Start pilot study**
   - Recruit initial patients
   - Test 48-hour recording sessions
   - Monitor data quality

---

## 📝 Deployment Log Template

Fill this out during deployment:

```
Deployment Date: _______________
Deployed By: _______________

Server Details:
- IP Address: _______________
- Docker Version: _______________
- Backend Version: _______________

Test Results:
- Health endpoint: [ ] Pass [ ] Fail
- Upload test: [ ] Pass [ ] Fail
- Flutter app connection: [ ] Pass [ ] Fail
- Flutter app upload: [ ] Pass [ ] Fail

Notes:
_________________________________
_________________________________
_________________________________

Deployment Status: [ ] Success [ ] Partial [ ] Failed
```

---

Good luck with your deployment! 🚀

If you encounter any issues not covered in this checklist, refer to the full documentation at `docs/WINDOWS_SERVER_DEPLOYMENT.md` or open an issue on GitHub.
