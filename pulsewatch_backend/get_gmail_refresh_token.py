"""One-time LOCAL helper — run this on your own laptop, not the server.

It gets a Gmail OAuth refresh token for the contact form's email sending
(app.py's _send_contact_email), so the server can authenticate via OAuth
(XOAUTH2) instead of an App Password. Uses only the standard library —
nothing to install.

Setup (once), in Google Cloud Console (console.cloud.google.com):
  1. Create a new project (any name, e.g. "Pulsana").
  2. APIs & Services -> Enabled APIs & services -> Enable "Gmail API".
  3. APIs & Services -> OAuth consent screen -> User type "External" ->
     fill in an app name and your own email as contact. Under "Test
     users", add pulsana.org.dev@gmail.com. This keeps the app in
     "Testing" mode, which needs no Google review — test users can
     authorize it immediately.
  4. APIs & Services -> Credentials -> Create Credentials -> OAuth
     client ID -> Application type "Desktop app". Copy the Client ID
     and Client secret it gives you.

Then run this script:
    python get_gmail_refresh_token.py
Paste the Client ID and Client secret when asked. A browser window opens
— sign in as pulsana.org.dev@gmail.com and approve. The script prints
three values; put them in the server's .env (see ARCHITECTURE.md):
    GMAIL_OAUTH_CLIENT_ID=...
    GMAIL_OAUTH_CLIENT_SECRET=...
    GMAIL_OAUTH_REFRESH_TOKEN=...

You only need to run this again if the refresh token is ever revoked
(e.g. via https://myaccount.google.com/permissions).
"""
import base64
import hashlib
import http.server
import json
import secrets
import urllib.parse
import urllib.request
import webbrowser

AUTH_ENDPOINT = 'https://accounts.google.com/o/oauth2/v2/auth'
TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token'
SCOPE = 'https://www.googleapis.com/auth/gmail.send'
REDIRECT_PORT = 8734
REDIRECT_URI = f'http://localhost:{REDIRECT_PORT}/'


def main():
    client_id = input('Client ID: ').strip()
    client_secret = input('Client secret: ').strip()

    state = secrets.token_urlsafe(16)
    code_verifier = secrets.token_urlsafe(64)
    code_challenge = base64.urlsafe_b64encode(
        hashlib.sha256(code_verifier.encode()).digest()
    ).decode().rstrip('=')

    auth_url = AUTH_ENDPOINT + '?' + urllib.parse.urlencode({
        'client_id': client_id,
        'redirect_uri': REDIRECT_URI,
        'response_type': 'code',
        'scope': SCOPE,
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
        'code_challenge': code_challenge,
        'code_challenge_method': 'S256',
    })

    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            result['code'] = qs.get('code', [None])[0]
            result['state'] = qs.get('state', [None])[0]
            result['error'] = qs.get('error', [None])[0]
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'<p>Done \xe2\x80\x94 you can close this tab and go back to the terminal.</p>')

        def log_message(self, *args):
            pass

    print('\nOpening your browser \xe2\x80\x94 sign in as pulsana.org.dev@gmail.com and approve.')
    webbrowser.open(auth_url)

    server = http.server.HTTPServer(('localhost', REDIRECT_PORT), Handler)
    server.handle_request()  # blocks until the OAuth redirect lands
    server.server_close()

    if result.get('error'):
        print(f"Google returned an error: {result['error']}")
        return
    if result.get('state') != state:
        print('State mismatch on the redirect \xe2\x80\x94 aborting for safety. Try again.')
        return
    if not result.get('code'):
        print('No authorization code received. Try again.')
        return

    data = urllib.parse.urlencode({
        'code': result['code'],
        'client_id': client_id,
        'client_secret': client_secret,
        'redirect_uri': REDIRECT_URI,
        'grant_type': 'authorization_code',
        'code_verifier': code_verifier,
    }).encode()

    try:
        req = urllib.request.Request(TOKEN_ENDPOINT, data=data)
        with urllib.request.urlopen(req, timeout=10) as resp:
            tokens = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f'Token exchange failed: {e.read().decode()}')
        return

    if 'refresh_token' not in tokens:
        print(
            'No refresh token in the response \xe2\x80\x94 this usually means this '
            'app was already authorized before, so Google skipped issuing a '
            'new one. Revoke access at https://myaccount.google.com/permissions '
            '(look for your app name) and run this script again.'
        )
        return

    print('\nAdd these three lines to the server .env, then restart the service:\n')
    print(f'GMAIL_OAUTH_CLIENT_ID={client_id}')
    print(f'GMAIL_OAUTH_CLIENT_SECRET={client_secret}')
    print(f'GMAIL_OAUTH_REFRESH_TOKEN={tokens["refresh_token"]}')
    print(f'CONTACT_SMTP_USERNAME=pulsana.org.dev@gmail.com')


if __name__ == '__main__':
    main()
