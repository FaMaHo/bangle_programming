# Security Guidelines for PulseWatch AI

## 🔐 Handling Sensitive Information

This document outlines security best practices for the PulseWatch AI project.

---

## Critical: Never Commit These to Git

### 1. **Credentials and Passwords**
- TeamViewer IDs and passwords
- Server login credentials
- Database passwords
- Admin passwords
- API keys and tokens

### 2. **Patient Data**
- CSV files containing medical data
- Patient identifiers
- Session recordings
- Any exported data files

### 3. **Configuration Files with Secrets**
- `.env` files with real values
- `credentials.json`
- `secrets.yml`
- SSL certificates and private keys

---

## ✅ What's Safe to Commit

- Example configurations (`.env.example`)
- Documentation with placeholder values
- Code without hardcoded secrets
- Public IP examples (192.168.x.x)
- Generic database schemas

---

## 🛡️ Security Best Practices

### 1. Environment Variables

**Create `.env` file for local development:**
```bash
# Copy the example file
cp .env.example .env

# Edit with your actual credentials
# NEVER commit this file!
```

### 2. Patient Data Protection

**Medical data is highly sensitive and regulated:**
- All patient data is automatically excluded from git (see `.gitignore`)
- Store patient data only on secure servers
- Use encrypted backups
- Follow HIPAA/GDPR guidelines (if applicable)
- Implement proper access controls

### 3. Server Access

**TeamViewer and Remote Access:**
- Store credentials in password manager (1Password, LastPass, etc.)
- Share credentials securely (encrypted messaging, password sharing features)
- Never post credentials in:
  - GitHub issues
  - Pull requests
  - Documentation
  - Chat logs
  - Email

**Recommended:** Use a shared password manager for the team.

### 4. Database Security

**When deploying PostgreSQL:**
```bash
# Generate strong passwords
openssl rand -base64 32

# Store in .env file, not in code
DB_PASSWORD=your_generated_password_here
```

### 5. API Keys and Tokens

**For JWT authentication:**
```bash
# Generate secure JWT secret
python3 -c "import secrets; print(secrets.token_urlsafe(64))"

# Store in .env
JWT_SECRET_KEY=your_generated_token_here
```

### 6. SSL/TLS Certificates

**Private keys must never be committed:**
```bash
# Store certificates outside git repo or use .gitignore
/path/to/secure/location/cert.pem
/path/to/secure/location/key.pem
```

---

## 🚨 What to Do If Secrets Are Exposed

### If you accidentally committed secrets:

**1. Immediately invalidate the exposed credentials**
- Change passwords
- Regenerate API keys
- Revoke access tokens

**2. Remove from git history (if just committed):**
```bash
# If not yet pushed
git reset HEAD~1
git add .
git commit -m "Recommit without secrets"

# If already pushed (requires force push - be careful!)
# Better option: use git filter-repo or BFG Repo-Cleaner
```

**3. Use git-secrets or similar tools:**
```bash
# Install git-secrets to prevent committing secrets
brew install git-secrets  # macOS
# or
sudo apt-get install git-secrets  # Linux

# Configure
git secrets --install
git secrets --register-aws
```

**4. Notify the team**
- Alert all team members
- Document the incident
- Update affected systems

---

## 📋 Pre-Commit Checklist

Before committing code, verify:

- [ ] No hardcoded passwords or API keys
- [ ] `.env` file is not staged (should be in `.gitignore`)
- [ ] No patient data files included
- [ ] No TeamViewer credentials
- [ ] No database connection strings with real passwords
- [ ] No SSL private keys
- [ ] No access tokens or session tokens

**Use this command to check staged files:**
```bash
git diff --cached | grep -E "(password|secret|key|token|credentials)" -i
```

---

## 🔍 Regular Security Audits

### Monthly Checks:

1. **Review access logs**
   - Who accessed the server?
   - Any suspicious upload patterns?

2. **Update dependencies**
   ```bash
   # Python
   pip list --outdated

   # Flutter
   flutter pub outdated
   ```

3. **Check for exposed secrets**
   ```bash
   # Use truffleHog or gitleaks
   docker run --rm -v $(pwd):/repo trufflesecurity/trufflehog:latest filesystem /repo
   ```

4. **Review user access**
   - Remove inactive users
   - Audit permissions

---

## 🏥 Medical Data Compliance

### HIPAA Considerations (if applicable in USA):

- **Encryption:** Patient data must be encrypted at rest and in transit
- **Access Control:** Implement role-based access
- **Audit Logs:** Track all data access
- **Data Retention:** Define retention and deletion policies
- **Breach Notification:** Have incident response plan

### GDPR Considerations (if applicable in EU):

- **Consent:** Obtain explicit patient consent
- **Right to Erasure:** Implement data deletion on request
- **Data Portability:** Allow patients to export their data
- **Privacy by Design:** Build security into system design

### China Specific Regulations:

- Comply with Personal Information Protection Law (PIPL)
- Data localization requirements (store Chinese patient data in China)
- Implement appropriate security measures

---

## 📞 Reporting Security Issues

If you discover a security vulnerability:

1. **DO NOT** open a public GitHub issue
2. **Contact the project maintainer directly:**
   - Email: [Provide secure contact method]
   - Encrypted message preferred
3. **Provide details:**
   - Description of vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

---

## 🔒 Secure Development Workflow

### For Team Members:

1. **Use SSH keys for Git:**
   ```bash
   ssh-keygen -t ed25519 -C "your_email@example.com"
   # Add to GitHub: Settings → SSH Keys
   ```

2. **Enable 2FA on GitHub:**
   - Settings → Password and authentication → Two-factor authentication

3. **Use signed commits:**
   ```bash
   git config --global user.signingkey YOUR_GPG_KEY
   git config --global commit.gpgsign true
   ```

4. **Keep local development secure:**
   - Use encrypted disk
   - Lock computer when away
   - Don't store credentials in browser

---

## 📚 Additional Resources

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [GitHub Security Best Practices](https://docs.github.com/en/code-security)
- [HIPAA Security Rule](https://www.hhs.gov/hipaa/for-professionals/security/)
- [GDPR Guidelines](https://gdpr.eu/)
- [China PIPL Overview](https://www.china-briefing.com/news/china-personal-information-protection-law-pipl-faqs/)

---

## ✅ Security Checklist for Deployment

Before deploying to production:

- [ ] All default passwords changed
- [ ] `.env` file created with secure credentials
- [ ] Firewall configured properly
- [ ] SSL/TLS enabled (HTTPS)
- [ ] Database access restricted to authorized IPs
- [ ] Regular backup system configured
- [ ] Monitoring and alerting set up
- [ ] Incident response plan documented
- [ ] Team trained on security practices
- [ ] Patient consent forms prepared (if applicable)
- [ ] Privacy policy published
- [ ] Data retention policy defined

---

## 🎯 Summary

**Key Principles:**
1. Never commit secrets to git
2. Use environment variables for configuration
3. Protect patient data rigorously
4. Follow medical data regulations
5. Use strong, unique passwords
6. Enable 2FA everywhere possible
7. Regular security audits
8. Report issues responsibly

**Remember:** Security is everyone's responsibility. When in doubt, ask!

---

Last Updated: 2025-01-12
Version: 1.0
