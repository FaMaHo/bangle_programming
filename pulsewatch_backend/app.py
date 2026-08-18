from flask import (
    Flask,
    request,
    jsonify,
    Response,
    render_template,
    render_template_string,
    session,
    redirect,
    url_for,
    send_from_directory,
)
import os
import re
import secrets
import shutil
import sys
import io
import base64
import hashlib
import json
import urllib.error
import urllib.parse
import urllib.request
import warnings
from email.message import EmailMessage

# Windows' console defaults to cp1252, which can't encode the emoji used in
# status prints below and crashes the request instead of just logging it.
if sys.stdout.encoding and sys.stdout.encoding.lower() != 'utf-8':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
from datetime import datetime, timedelta
from functools import wraps
import csv
from io import StringIO

from flask_jwt_extended import (
    JWTManager,
    create_access_token,
    create_refresh_token,
    get_jwt,
    get_jwt_identity,
    jwt_required,
)
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from werkzeug.middleware.proxy_fix import ProxyFix

import auth as accounts

app = Flask(__name__)

# Production runs behind nginx (see ARCHITECTURE.md), which sets
# X-Forwarded-For/-Proto/-Host. Without ProxyFix, request.remote_addr (and
# therefore every IP-based rate limit below) resolves to nginx's own
# loopback address for every visitor, collapsing all clients into one
# shared limiter bucket instead of one bucket per real client.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

UPLOAD_FOLDER = 'patient_data'
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

# Public base URL patients connect to. Defaults to the production domain;
# override with PUBLIC_SERVER_URL for local/dev testing (e.g. via the LAN IP).
PUBLIC_SERVER_URL = os.environ.get('PUBLIC_SERVER_URL', 'https://pulsana.org')

# Contact form → email relay, sent via the Gmail REST API over HTTPS rather
# than raw SMTP — cloud VPS providers (DigitalOcean included) commonly block
# outbound SMTP ports (25/465/587) for anti-spam reasons, but not 443, and
# the Gmail API needs nothing SMTP doesn't already need: same OAuth token,
# same gmail.send scope, just a different transport for the last mile.
# Credentials come from environment variables (systemd EnvironmentFile in
# production, never in git — see ARCHITECTURE.md), same pattern as
# SECRET_KEY below. The refresh token is minted once via the researcher
# portal's /gmail-oauth/start flow — see ARCHITECTURE.md for setup.
CONTACT_SMTP_USERNAME = os.environ.get('CONTACT_SMTP_USERNAME')
CONTACT_EMAIL_TO = os.environ.get('CONTACT_EMAIL_TO', CONTACT_SMTP_USERNAME)
GMAIL_OAUTH_CLIENT_ID = os.environ.get('GMAIL_OAUTH_CLIENT_ID')
GMAIL_OAUTH_CLIENT_SECRET = os.environ.get('GMAIL_OAUTH_CLIENT_SECRET')
GMAIL_OAUTH_REFRESH_TOKEN = os.environ.get('GMAIL_OAUTH_REFRESH_TOKEN')
GMAIL_TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token'
GMAIL_SEND_ENDPOINT = 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send'
_EMAIL_RE = re.compile(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')

# ─── Auth setup ──────────────────────────────────────────────────────────────

_secret_key = os.environ.get('SECRET_KEY')
if not _secret_key:
    warnings.warn(
        'SECRET_KEY is not set — using a random key that changes every '
        'restart (all existing sessions will be invalidated). This is fine '
        'for local development only; production must set SECRET_KEY.'
    )
    _secret_key = secrets.token_hex(32)

app.config['JWT_SECRET_KEY'] = _secret_key
app.config['JWT_ACCESS_TOKEN_EXPIRES'] = timedelta(hours=1)
app.config['JWT_REFRESH_TOKEN_EXPIRES'] = timedelta(days=30)
jwt = JWTManager(app)

# Separate from JWT — the researcher web portal uses a normal signed
# session cookie (browser-friendly), while the mobile app and API use
# bearer tokens. Same secret value, independent signing mechanisms.
app.secret_key = _secret_key
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'

accounts.init_db()

limiter = Limiter(get_remote_address, app=app, default_limits=[])

APK_DIR = os.path.join(os.path.dirname(__file__), 'static', 'downloads')
os.makedirs(APK_DIR, exist_ok=True)
APK_FILENAME = 'pulsewatch.apk'


def _tokens_for(user):
    extra_claims = {'role': user['role'], 'patient_id': user['patient_id']}
    return {
        'access_token': create_access_token(identity=user['username'], additional_claims=extra_claims),
        'refresh_token': create_refresh_token(identity=user['username'], additional_claims=extra_claims),
        'patient_id': user['patient_id'],
        'role': user['role'],
        # The app already knows its own username after /auth/login or
        # /auth/claim (it just typed it into the form), but /auth/reset-password
        # logs a patient in without them typing a username anywhere — this
        # is the only way that flow can learn it, to store locally same as
        # the other two.
        'username': user['username'],
    }


def researcher_required(fn):
    @wraps(fn)
    @jwt_required()
    def wrapper(*args, **kwargs):
        if get_jwt().get('role') != 'researcher':
            return jsonify({'error': 'Researcher access required'}), 403
        return fn(*args, **kwargs)
    return wrapper


def _safe_patient_session_path(patient_id, session_id):
    """Resolve patient_data/<patient_id>/<session_id>, refusing to return a
    path outside that patient's folder — session_id/patient_id land here
    from URL segments and form fields, so a '../' can't be trusted blindly."""
    patient_root = os.path.abspath(os.path.join(UPLOAD_FOLDER, patient_id))
    session_path = os.path.abspath(os.path.join(patient_root, session_id))
    if os.path.commonpath([patient_root, session_path]) != patient_root:
        return None
    return session_path


def _session_upload_date(session_path):
    """Earliest file mtime in a session folder, as the date a researcher
    would recognize as 'when this was uploaded'."""
    try:
        entries = [os.path.join(session_path, f) for f in os.listdir(session_path)]
        mtimes = [os.path.getmtime(p) for p in entries] or [os.path.getmtime(session_path)]
        return datetime.fromtimestamp(min(mtimes)).strftime('%Y-%m-%d %H:%M')
    except OSError:
        return None


def _get_gmail_access_token():
    """Exchange the long-lived OAuth refresh token for a short-lived access
    token. Plain stdlib HTTP call — no google-auth dependency needed just
    for this. Returns None if unconfigured or the exchange fails."""
    if not (GMAIL_OAUTH_CLIENT_ID and GMAIL_OAUTH_CLIENT_SECRET and GMAIL_OAUTH_REFRESH_TOKEN):
        return None

    data = urllib.parse.urlencode({
        'client_id': GMAIL_OAUTH_CLIENT_ID,
        'client_secret': GMAIL_OAUTH_CLIENT_SECRET,
        'refresh_token': GMAIL_OAUTH_REFRESH_TOKEN,
        'grant_type': 'refresh_token',
    }).encode()

    try:
        req = urllib.request.Request(GMAIL_TOKEN_ENDPOINT, data=data)
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())['access_token']
    except (urllib.error.URLError, KeyError, ValueError) as e:
        print(f'[contact] token refresh failed: {e}')
        return None


def _send_contact_email(name, sender_email, message_body):
    """Relay a contact-form submission to the research team's inbox via the
    Gmail API over HTTPS — not raw SMTP, which is commonly blocked outbound
    on cloud VPS providers. Returns True on success, False on any
    config/delivery failure (caller falls back to telling the visitor to
    email/WhatsApp directly)."""
    if not CONTACT_SMTP_USERNAME or not CONTACT_EMAIL_TO:
        return False

    access_token = _get_gmail_access_token()
    if not access_token:
        return False

    email_msg = EmailMessage()
    email_msg['Subject'] = f'Pulsana contact form — {name}'
    email_msg['From'] = CONTACT_SMTP_USERNAME
    email_msg['To'] = CONTACT_EMAIL_TO
    email_msg['Reply-To'] = sender_email
    email_msg.set_content(f'From: {name} <{sender_email}>\n\n{message_body}')

    raw = base64.urlsafe_b64encode(email_msg.as_bytes()).decode()
    payload = json.dumps({'raw': raw}).encode()

    try:
        req = urllib.request.Request(
            GMAIL_SEND_ENDPOINT,
            data=payload,
            headers={
                'Authorization': f'Bearer {access_token}',
                'Content-Type': 'application/json',
            },
            method='POST',
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        return True
    except urllib.error.HTTPError as e:
        print(f'[contact] Gmail API rejected the send: {e.code} {e.read().decode()}')
        return False
    except (urllib.error.URLError, OSError) as e:
        print(f'[contact] failed to send: {e}')
        return False


def _patient_activity_summary(patient_id):
    """Cheap upload-activity signal for the dashboard list: session count
    plus the earliest/latest file mtime across all of a patient's sessions.
    No CSV parsing, so this can run for every patient on every dashboard
    load without being slow.

    'complete' means the span between first and last upload is at least
    48 hours — a proxy for "still enrolled and uploading across the full
    window", not a guarantee the recording itself has no gaps."""
    patient_path = os.path.join(UPLOAD_FOLDER, patient_id)
    session_count = 0
    mtimes = []

    if os.path.isdir(patient_path):
        for session_id in os.listdir(patient_path):
            session_path = os.path.join(patient_path, session_id)
            if not os.path.isdir(session_path):
                continue
            session_count += 1
            try:
                for f in os.listdir(session_path):
                    mtimes.append(os.path.getmtime(os.path.join(session_path, f)))
            except OSError:
                continue

    if not mtimes:
        return {
            'session_count': session_count,
            'last_upload': None,
            'status': 'no_data' if session_count == 0 else 'in_progress',
        }

    first_upload = datetime.fromtimestamp(min(mtimes))
    last_upload = datetime.fromtimestamp(max(mtimes))
    span_hours = (last_upload - first_upload).total_seconds() / 3600
    return {
        'session_count': session_count,
        'last_upload': last_upload,
        'status': 'complete' if span_hours >= 48 else 'in_progress',
    }


def researcher_web_required(fn):
    """Session-cookie auth for the browser-based researcher portal —
    separate from the JWT bearer-token auth used by the mobile app/API."""
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if session.get('role') != 'researcher':
            return redirect(url_for('researcher_login'))
        return fn(*args, **kwargs)
    return wrapper


# ─── QR Code ──────────────────────────────────────────────────────────────────

@app.route('/qr')
def qr_code_page():
    """
    Serves an HTML page with a scannable QR code.
    The QR encodes this server's public base URL. Researcher opens this in
    a browser and shows it to the patient to scan.
    """
    try:
        import qrcode
        from qrcode.image.pure import PyPNGImage

        server_url = PUBLIC_SERVER_URL

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
    <p class="hint">Works over any internet connection —<br>no need to be on the same Wi-Fi network.</p>
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


# ─── Auth routes ─────────────────────────────────────────────────────────────

@app.route('/auth/enroll', methods=['POST'])
@researcher_required
def auth_enroll():
    """Researcher generates a one-time code + fresh patient_id for a new participant."""
    code, patient_id = accounts.create_enrollment_code()
    return jsonify({'code': code, 'patient_id': patient_id, 'expires_in_hours': 72}), 201


@app.route('/auth/claim', methods=['POST'])
@limiter.limit('10/minute')
def auth_claim():
    """Patient turns a researcher-issued enrollment code into a real account."""
    data = request.get_json(silent=True) or {}
    code = data.get('code', '')
    username = data.get('username', '')
    password = data.get('password', '')

    if not code or not username or not password:
        return jsonify({'error': 'code, username, and password are required'}), 400
    if len(password) < 8:
        return jsonify({'error': 'Password must be at least 8 characters'}), 400

    user, error = accounts.claim_enrollment_code(code, username, password)
    if error:
        return jsonify({'error': error}), 400

    return jsonify(_tokens_for(user)), 201


@app.route('/auth/login', methods=['POST'])
@limiter.limit('10/minute')
def auth_login():
    data = request.get_json(silent=True) or {}
    user = accounts.verify_login(data.get('username', ''), data.get('password', ''))
    if not user:
        return jsonify({'error': 'Invalid username or password'}), 401

    return jsonify(_tokens_for(user)), 200


@app.route('/auth/refresh', methods=['POST'])
@jwt_required(refresh=True)
def auth_refresh():
    claims = get_jwt()
    extra_claims = {'role': claims.get('role'), 'patient_id': claims.get('patient_id')}
    access_token = create_access_token(identity=get_jwt_identity(), additional_claims=extra_claims)
    return jsonify({'access_token': access_token}), 200


@app.route('/auth/change-password', methods=['POST'])
@jwt_required()
@limiter.limit('10/minute')
def auth_change_password():
    """Self-service — the app already has a valid session; this just
    proves the caller still knows the current password before changing it."""
    data = request.get_json(silent=True) or {}
    current_password = data.get('current_password', '')
    new_password = data.get('new_password', '')

    if not current_password or not new_password:
        return jsonify({'error': 'current_password and new_password are required'}), 400
    if len(new_password) < 8:
        return jsonify({'error': 'Password must be at least 8 characters'}), 400

    ok, error = accounts.change_password(get_jwt_identity(), current_password, new_password)
    if not ok:
        return jsonify({'error': error}), 400
    return jsonify({'success': True}), 200


@app.route('/auth/reset-password', methods=['POST'])
@limiter.limit('10/minute')
def auth_reset_password():
    """Redeems a researcher-issued reset code (see
    /researcher/patient/<patient_id>/generate-reset-code) — the forgot-
    password path for a patient who's locked out and can't prove identity
    with a current password. Logs them straight back in on success, same
    as /auth/claim does for a brand-new account."""
    data = request.get_json(silent=True) or {}
    code = data.get('code', '')
    new_password = data.get('new_password', '')

    if not code or not new_password:
        return jsonify({'error': 'code and new_password are required'}), 400
    if len(new_password) < 8:
        return jsonify({'error': 'Password must be at least 8 characters'}), 400

    user, error = accounts.claim_reset_code(code, new_password)
    if error:
        return jsonify({'error': error}), 400

    return jsonify(_tokens_for(user)), 200


# ─── Website ─────────────────────────────────────────────────────────────────

@app.route('/')
def home():
    return render_template('index.html', active_nav='home')


@app.route('/instructions')
def instructions_page():
    return render_template('instructions.html', active_nav='instructions')


@app.route('/faq')
def faq_page():
    return render_template('faq.html', active_nav='faq')


@app.route('/contact', methods=['GET', 'POST'])
@limiter.limit('5/hour')
def contact_page():
    if request.method == 'POST':
        if request.form.get('company'):
            # Honeypot — real visitors never see or fill this field, only bots.
            return render_template('contact.html', active_nav='contact', contact_sent=True)

        name = request.form.get('name', '').strip()
        sender_email = request.form.get('email', '').strip()
        message_body = request.form.get('message', '').strip()

        if not name or not sender_email or not message_body:
            return render_template('contact.html', active_nav='contact', contact_error='Please fill in every field before sending.')
        if not _EMAIL_RE.match(sender_email):
            return render_template('contact.html', active_nav='contact', contact_error='That email address doesn\'t look right — please double-check it.')
        if len(message_body) > 5000:
            return render_template('contact.html', active_nav='contact', contact_error='That message is a bit long — please keep it under 5000 characters.')

        if not _send_contact_email(name, sender_email, message_body):
            return render_template(
                'contact.html',
                active_nav='contact',
                contact_error="Something went wrong sending that — please email us directly instead.",
            )

        return render_template('contact.html', active_nav='contact', contact_sent=True)

    return render_template('contact.html', active_nav='contact')


@app.route('/join', methods=['GET', 'POST'])
@limiter.limit('10/hour')
def join_page():
    """Patient-facing: agree to the consent/terms, then get a one-time
    enrollment code plus the app download link — self-service, replacing
    a researcher having to hand out codes individually."""
    if request.method == 'POST':
        agreed = request.form.get('agree') == 'on'
        if not agreed:
            return render_template('join.html', active_nav='join', error='Please confirm you agree before continuing.')

        code, patient_id = accounts.create_enrollment_code()
        return render_template('join.html', active_nav='join', code=code, patient_id=patient_id)

    return render_template('join.html', active_nav='join')


@app.route('/download')
def download_page_redirect():
    """Old address for the join flow — kept so existing links/bookmarks/QR
    codes still resolve."""
    return redirect(url_for('join_page'), code=301)


@app.route('/download-apk')
def download_apk():
    apk_path = os.path.join(APK_DIR, APK_FILENAME)
    if not os.path.exists(apk_path):
        return jsonify({'error': 'App download is not available yet.'}), 404
    return send_from_directory(APK_DIR, APK_FILENAME, as_attachment=True)


# ─── Researcher web portal ─────────────────────────────────────────────────────

@app.route('/researcher/login', methods=['GET', 'POST'])
@limiter.limit('10/minute')
def researcher_login():
    if session.get('role') == 'researcher':
        return redirect(url_for('researcher_dashboard'))

    if request.method == 'POST':
        user = accounts.verify_login(request.form.get('username', ''), request.form.get('password', ''))
        if not user or user['role'] != 'researcher':
            return render_template('researcher_login.html', error='Invalid username or password.')

        session['role'] = 'researcher'
        session['username'] = user['username']
        return redirect(url_for('researcher_dashboard'))

    return render_template('researcher_login.html')


@app.route('/researcher/logout')
def researcher_logout():
    session.clear()
    return redirect(url_for('researcher_login'))


# ─── Gmail OAuth one-time setup ─────────────────────────────────────────────
# Mints the refresh token _send_contact_email() needs, entirely on this
# server — the human-approval step Google requires happens in the
# researcher's own browser, redirected back to this same domain, rather
# than via a script run on a local machine. Gated behind researcher login
# since it's only ever used once (or again if the token is revoked).

@app.route('/researcher/gmail-oauth/start')
@researcher_web_required
def gmail_oauth_start():
    if not (GMAIL_OAUTH_CLIENT_ID and GMAIL_OAUTH_CLIENT_SECRET):
        return (
            'Set GMAIL_OAUTH_CLIENT_ID and GMAIL_OAUTH_CLIENT_SECRET in .env '
            '(from the "Web application" OAuth client in Google Cloud '
            'Console — see ARCHITECTURE.md), restart the service, then '
            'reload this page.',
            400,
        )

    state = secrets.token_urlsafe(16)
    code_verifier = secrets.token_urlsafe(64)
    code_challenge = base64.urlsafe_b64encode(
        hashlib.sha256(code_verifier.encode()).digest()
    ).decode().rstrip('=')
    session['gmail_oauth_state'] = state
    session['gmail_oauth_code_verifier'] = code_verifier

    auth_url = 'https://accounts.google.com/o/oauth2/v2/auth?' + urllib.parse.urlencode({
        'client_id': GMAIL_OAUTH_CLIENT_ID,
        'redirect_uri': url_for('gmail_oauth_callback', _external=True),
        'response_type': 'code',
        'scope': 'https://www.googleapis.com/auth/gmail.send',
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
        'code_challenge': code_challenge,
        'code_challenge_method': 'S256',
    })
    return redirect(auth_url)


@app.route('/researcher/gmail-oauth/callback')
@researcher_web_required
def gmail_oauth_callback():
    error = request.args.get('error')
    if error:
        return f'Google returned an error: {error}', 400

    code = request.args.get('code')
    state = request.args.get('state')
    if not code or not state or state != session.get('gmail_oauth_state'):
        return (
            'Missing code, or the state didn\'t match (session may have '
            'expired) — start over from /researcher/gmail-oauth/start.',
            400,
        )

    code_verifier = session.pop('gmail_oauth_code_verifier', None)
    session.pop('gmail_oauth_state', None)

    data = urllib.parse.urlencode({
        'code': code,
        'client_id': GMAIL_OAUTH_CLIENT_ID,
        'client_secret': GMAIL_OAUTH_CLIENT_SECRET,
        'redirect_uri': url_for('gmail_oauth_callback', _external=True),
        'grant_type': 'authorization_code',
        'code_verifier': code_verifier,
    }).encode()

    try:
        req = urllib.request.Request(GMAIL_TOKEN_ENDPOINT, data=data)
        with urllib.request.urlopen(req, timeout=10) as resp:
            tokens = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return f'Token exchange failed: {e.read().decode()}', 400

    refresh_token = tokens.get('refresh_token')
    if not refresh_token:
        return (
            'No refresh token in the response — this usually means this '
            'Gmail account already authorized this app before, so Google '
            'skipped issuing a new one. Revoke access at '
            'https://myaccount.google.com/permissions (find the app name), '
            'then visit /researcher/gmail-oauth/start again.',
            400,
        )

    return render_template_string(
        '<pre style="font-family:monospace; white-space:pre-wrap; padding:24px; '
        'max-width:640px; margin:40px auto; border:1px solid #ccc; border-radius:8px;">'
        'Add this line to the server .env, then restart the service:\n\n'
        'GMAIL_OAUTH_REFRESH_TOKEN={{ token }}\n\n'
        '(GMAIL_OAUTH_CLIENT_ID and GMAIL_OAUTH_CLIENT_SECRET are already set '
        'from getting here — leave them as they are.)</pre>',
        token=refresh_token,
    )


def _patients_with_stats():
    patients = accounts.list_patients()
    for p in patients:
        p.update(_patient_activity_summary(p['patient_id']))
    stats = {
        'total': len(patients),
        'complete': sum(1 for p in patients if p['status'] == 'complete'),
        'in_progress': sum(1 for p in patients if p['status'] == 'in_progress'),
        'no_data': sum(1 for p in patients if p['status'] == 'no_data'),
    }
    return patients, stats


@app.route('/researcher/dashboard')
@researcher_web_required
def researcher_dashboard():
    patients, stats = _patients_with_stats()
    return render_template('researcher_dashboard.html', patients=patients, stats=stats)


@app.route('/researcher/generate-code', methods=['POST'])
@researcher_web_required
def researcher_generate_code():
    code, patient_id = accounts.create_enrollment_code()
    patients, stats = _patients_with_stats()
    return render_template(
        'researcher_dashboard.html',
        patients=patients,
        stats=stats,
        new_code=code,
        new_patient_id=patient_id,
    )


@app.route('/researcher/patient/<patient_id>')
@researcher_web_required
def researcher_patient_detail(patient_id):
    patient = accounts.get_patient_by_id(patient_id)
    patient_path = os.path.join(UPLOAD_FOLDER, patient_id)

    sessions = []
    if os.path.exists(patient_path):
        for session_id in sorted(os.listdir(patient_path)):
            session_path = os.path.join(patient_path, session_id)
            if os.path.isdir(session_path):
                csv_files = [f for f in os.listdir(session_path) if f.endswith('.csv')]
                sessions.append({
                    'session_id': session_id,
                    'file_count': len(csv_files),
                    'date': _session_upload_date(session_path),
                })

    deleted_count = request.args.get('deleted_count')
    if deleted_count == 'all':
        deleted_message = 'All uploaded data for this patient has been deleted.'
    elif deleted_count:
        deleted_message = f'{deleted_count} session(s) deleted.'
    elif request.args.get('deleted'):
        deleted_message = f"Session {request.args.get('deleted')} deleted."
    else:
        deleted_message = None

    return render_template(
        'researcher_patient.html',
        patient_id=patient_id,
        patient=patient,
        sessions=sessions,
        deleted_message=deleted_message,
        reset_code=request.args.get('reset_code'),
        reset_error=request.args.get('reset_error'),
        reset_code_history=accounts.get_reset_code_history(patient_id),
    )


@app.route('/researcher/patient/<patient_id>/generate-reset-code', methods=['POST'])
@researcher_web_required
def researcher_generate_reset_code(patient_id):
    code, error = accounts.create_reset_code(patient_id, generated_by=session.get('username'))
    if error:
        return redirect(url_for('researcher_patient_detail', patient_id=patient_id, reset_error=error))
    return redirect(url_for('researcher_patient_detail', patient_id=patient_id, reset_code=code))


@app.route('/researcher/patient/<patient_id>/session/<session_id>/delete', methods=['POST'])
@researcher_web_required
def researcher_delete_session(patient_id, session_id):
    session_path = _safe_patient_session_path(patient_id, session_id)
    if session_path and os.path.isdir(session_path):
        shutil.rmtree(session_path)
    return redirect(url_for('researcher_patient_detail', patient_id=patient_id, deleted=session_id))


@app.route('/researcher/patient/<patient_id>/sessions/delete', methods=['POST'])
@researcher_web_required
def researcher_delete_sessions(patient_id):
    session_ids = request.form.getlist('session_ids')
    deleted = 0
    for session_id in session_ids:
        session_path = _safe_patient_session_path(patient_id, session_id)
        if session_path and os.path.isdir(session_path):
            shutil.rmtree(session_path)
            deleted += 1
    return redirect(url_for('researcher_patient_detail', patient_id=patient_id, deleted_count=deleted))


@app.route('/researcher/patient/<patient_id>/delete-all', methods=['POST'])
@researcher_web_required
def researcher_delete_all_data(patient_id):
    patient_path = _safe_patient_session_path(patient_id, '.')
    if patient_path and os.path.isdir(patient_path):
        shutil.rmtree(patient_path)
    return redirect(url_for('researcher_patient_detail', patient_id=patient_id, deleted_count='all'))


@app.route('/researcher/patient/<patient_id>/session/<session_id>/download')
@researcher_web_required
def researcher_download_session(patient_id, session_id):
    session_path = os.path.join(UPLOAD_FOLDER, patient_id, session_id)
    if not os.path.exists(session_path):
        return jsonify({'error': 'Session not found'}), 404

    csv_files = sorted(f for f in os.listdir(session_path) if f.endswith('.csv'))
    combined = []
    for csv_file in csv_files:
        with open(os.path.join(session_path, csv_file), 'r', encoding='utf-8') as f:
            combined.append(f.read())

    body = '\n'.join(combined)
    filename = f'{patient_id}_{session_id}.csv'
    return Response(
        body,
        mimetype='text/csv',
        headers={'Content-Disposition': f'attachment; filename={filename}'},
    )


# ─── Existing routes ───────────────────────────────────────────────────────────


@app.route('/upload', methods=['POST'])
@jwt_required()
def upload_data():
    try:
        csv_data = request.data.decode('utf-8')

        if not csv_data:
            return jsonify({'error': 'No data received'}), 400

        lines = csv_data.strip().split('\n')
        record_count = len(lines) - 1

        # patient_id comes from the verified token, never from a client
        # header — a client can no longer claim to be a different patient.
        patient_id = get_jwt().get('patient_id')
        if not patient_id:
            return jsonify({'error': 'This account is not associated with a patient_id'}), 403
        device_id = request.headers.get('X-Device-ID', 'unknown')
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
@jwt_required()
def upload_chunk():
    if 'file' not in request.files:
        return jsonify({"error": "No file part"}), 400

    file = request.files['file']
    patient_id = get_jwt().get('patient_id')
    if not patient_id:
        return jsonify({'error': 'This account is not associated with a patient_id'}), 403
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
@jwt_required()
def upload_recorder_log():
    if 'file' not in request.files:
        return jsonify({"error": "No file part"}), 400

    file = request.files['file']
    patient_id = get_jwt().get('patient_id')
    if not patient_id:
        return jsonify({'error': 'This account is not associated with a patient_id'}), 403
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
@jwt_required()
def get_patient_sessions(patient_id):
    claims = get_jwt()
    if claims.get('role') != 'researcher' and claims.get('patient_id') != patient_id:
        return jsonify({'error': 'Forbidden'}), 403

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
@jwt_required()
def get_session_data(patient_id, session_id):
    claims = get_jwt()
    if claims.get('role') != 'researcher' and claims.get('patient_id') != patient_id:
        return jsonify({'error': 'Forbidden'}), 403

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
    debug_mode = os.environ.get('FLASK_DEBUG', '0') == '1'
    app.run(host='0.0.0.0', port=5001, debug=debug_mode)