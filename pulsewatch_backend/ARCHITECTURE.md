# Backend + Website — Architecture

Flask app, deployed on a DigitalOcean VPS at **pulsana.org**. One Python
process serves three logically separate things out of the same `app.py`:
the data-upload API the phone app talks to, the public marketing/consent
website, and a researcher web portal. No separate frontend framework or
build step — pages are server-rendered Jinja2 templates with plain CSS.

If you're here to work on the **website specifically**, you mostly want
`templates/` (the actual pages) and the `# ─── Website ───` /
`# ─── Researcher web portal ───` sections of `app.py` (the routes). You
shouldn't need to touch `auth.py` or the API routes for visual/UX changes.

## Files

```
pulsewatch_backend/
├── app.py              # All routes: API, website, researcher portal
├── auth.py             # Accounts, password hashing, enrollment codes (SQLite)
├── create_admin.py     # CLI to bootstrap a researcher account (not an API route)
├── templates/           # Jinja2 HTML — the actual website pages
│   ├── base.html         # Shared layout + all CSS
│   ├── index.html        # Landing page
│   ├── download.html     # Consent page → issues enrollment code → APK link
│   ├── researcher_login.html
│   ├── researcher_dashboard.html
│   └── researcher_patient.html
├── static/downloads/    # pulsewatch.apk lives here (not in git — see below)
├── users.db             # SQLite: accounts + enrollment codes (not in git)
├── patient_data/        # Uploaded CSVs, organized by patient/session (not in git)
└── requirements.txt
```

## Two separate auth systems — don't mix them up

| | Used by | Mechanism | Where checked |
|---|---|---|---|
| **JWT bearer tokens** | The Flutter app | `Authorization: Bearer <token>` header | `@jwt_required()` / `@researcher_required` decorators |
| **Session cookie** | The researcher website | Signed browser cookie (Flask `session`) | `@researcher_web_required` decorator |

They're deliberately independent — a browser can't easily attach a custom
`Authorization` header to a normal link click, so the web portal uses a
normal cookie-based login instead of asking a human to paste a JWT around.
Both share the same `SECRET_KEY` value but sign/verify completely separately
(JWT via `flask-jwt-extended`, sessions via Flask's built-in `itsdangerous`
signer) — reusing the value is fine, they're independent mechanisms.

## Routes

**API (JWT, used by the app):**

| Route | Method | Auth | What |
|---|---|---|---|
| `/auth/claim` | POST | none (rate-limited) | Turn an enrollment code into an account |
| `/auth/login` | POST | none (rate-limited) | Username/password → tokens |
| `/auth/refresh` | POST | refresh token | New access token |
| `/auth/enroll` | POST | researcher JWT | Generate a code (used by `create_admin.py`-created accounts, or programmatically) |
| `/upload`, `/upload_chunk`, `/upload_recorder_log` | POST | patient JWT | Receive CSV data. **`patient_id` always comes from the verified token**, never a client header — this closes an old hole where any client could claim to be any patient. |
| `/patient/<id>/sessions`, `/patient/<id>/session/<id>/data` | GET | JWT | Read data — patient can only read their own; researcher role can read any |
| `/health` | GET | none | Liveness check |

**Website (public, no auth):**

| Route | What |
|---|---|
| `/` | Landing page |
| `/download` | GET shows the consent form; POST (after checking "I agree") generates a one-time enrollment code and shows it + the APK link. Rate-limited to stop code-farming. |
| `/download-apk` | Serves the static APK file for direct download |

**Researcher portal (session cookie):**

| Route | What |
|---|---|
| `/researcher/login` | GET shows the form, POST checks credentials and sets the session |
| `/researcher/logout` | Clears the session |
| `/researcher/dashboard` | Lists all patient accounts; also has the "generate enrollment code" form |
| `/researcher/patient/<id>` | That patient's uploaded sessions, with download links |
| `/researcher/patient/<id>/session/<id>/download` | Streams the combined CSV for one session as a file download |

## Why enrollment codes exist at all

Without them, anyone could hit `/auth/claim` and self-register into the
study with junk data. A code is minted server-side (`auth.create_enrollment_code()`)
alongside a fresh, random `patient_id` — claiming a code is the only way to
create a patient account, and each code works once. Two ways codes get
issued:
1. **Researcher-initiated** — `/auth/enroll` (JWT) or the dashboard's
   "Generate enrollment code" button, for handing to someone in person.
2. **Public self-service** — `/download`'s consent flow, for the "visit the
   website, agree to the terms, get a code" path. This is intentionally
   open (rate-limited, not researcher-gated) — the consent checkbox is the
   gate here, not a human vetting each signup.

## Data storage

No external database — everything is local SQLite/filesystem, which is
fine at this project's scale:
- `users.db` — accounts + enrollment codes (`auth.py`)
- `patient_data/<patient_id>/<session_id>/*.csv` — uploaded data

Both are gitignored — `users.db` because it holds password hashes,
`patient_data/` because it's medical data.

## Running it locally

```bash
cd pulsewatch_backend
uv venv
# macOS/Linux: source .venv/bin/activate   |   Windows: .venv\Scripts\activate
uv pip install -r requirements.txt
python app.py
```

Open `http://localhost:5001`. For the JWT signing to be stable across
restarts (so tokens don't get invalidated every time you restart the dev
server), set a `SECRET_KEY` env var — otherwise a random one is generated
each run (fine for quick local testing, annoying if you're testing login
persistence).

Create a researcher account to test the portal:
```bash
python create_admin.py
```

Editing `templates/*.html` and `app.py` and just restarting `python app.py`
is enough to see changes — no build step, no bundler, no `npm install`.

## Deployment (production)

Runs on a DigitalOcean droplet at `188.166.228.82`, domain `pulsana.org`:

- **gunicorn** runs the Flask app as a **systemd service**
  (`pulsewatch-backend.service`), bound to `127.0.0.1:8000` only
- **nginx** reverse-proxies `pulsana.org` → gunicorn, and handles TLS
- **Let's Encrypt** (via `certbot`) provides the HTTPS certificate,
  auto-renewing
- `SECRET_KEY` is set via a systemd `EnvironmentFile` (`.env` in this
  folder on the server, not in git)

To deploy a change: push to GitHub, then on the server:
```bash
cd ~/app && git pull
cd pulsewatch_backend && source $HOME/.local/bin/env && uv pip install -r requirements.txt
sudo systemctl restart pulsewatch-backend
```

The APK at `static/downloads/pulsewatch.apk` isn't in git (too large, and
it's a build artifact) — if it changes, it has to be copied to the server
separately (`scp`), not picked up by `git pull`.

`docker-compose.yml`/`Dockerfile` also exist for a container-based
deployment path, but the current production setup runs gunicorn directly
under systemd instead — the Docker path isn't the one actually in use on
`pulsana.org`.
