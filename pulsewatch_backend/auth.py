"""User accounts, password hashing, and enrollment codes for PulseWatch.

Storage is a small local SQLite file (users.db) — no external DB service
required. Patients never self-register: a researcher generates a one-time
enrollment code (which also mints a fresh, unguessable patient_id), the
patient claims it once from the app to set their own password, and logs
in with username/password after that.
"""
import secrets
import sqlite3
import string
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

from werkzeug.security import check_password_hash, generate_password_hash

DB_PATH = Path(__file__).parent / 'users.db'

ROLES = ('patient', 'researcher')


def _now():
    return datetime.now(timezone.utc)


@contextmanager
def _connect():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA foreign_keys = ON')
    try:
        yield db
        db.commit()
    finally:
        db.close()


def init_db():
    with _connect() as db:
        db.execute('''
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                role TEXT NOT NULL CHECK(role IN ('patient', 'researcher')),
                patient_id TEXT UNIQUE,
                created_at TEXT NOT NULL
            )
        ''')
        db.execute('''
            CREATE TABLE IF NOT EXISTS enrollment_codes (
                code TEXT PRIMARY KEY,
                patient_id TEXT UNIQUE NOT NULL,
                created_at TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                used_by_user_id INTEGER,
                FOREIGN KEY(used_by_user_id) REFERENCES users(id)
            )
        ''')


def generate_patient_id():
    # 32 bits of randomness — a label, not a credential, but no longer
    # guessable from name+birth-year like the old client-side hash was.
    return 'P-' + secrets.token_hex(4).upper()


def _generate_code(length=8):
    # Avoid ambiguous characters (0/O, 1/I) since a researcher may read
    # this aloud or a patient may type it in by hand.
    alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    return ''.join(secrets.choice(alphabet) for _ in range(length))


def create_enrollment_code(ttl_hours=72):
    """Researcher-side: mint a one-time code + a fresh patient_id for a new participant."""
    patient_id = generate_patient_id()
    code = _generate_code()
    now = _now()
    expires = now + timedelta(hours=ttl_hours)
    with _connect() as db:
        db.execute(
            'INSERT INTO enrollment_codes (code, patient_id, created_at, expires_at) '
            'VALUES (?, ?, ?, ?)',
            (code, patient_id, now.isoformat(), expires.isoformat()),
        )
    return code, patient_id


def claim_enrollment_code(code, username, password):
    """Patient-side: turn a valid, unused code into a real account.

    Returns (user_dict, None) on success, or (None, error_message) on failure.
    """
    code = (code or '').strip().upper()
    username = (username or '').strip()

    with _connect() as db:
        row = db.execute(
            'SELECT * FROM enrollment_codes WHERE code = ?', (code,)
        ).fetchone()

        if row is None:
            return None, 'Invalid enrollment code'
        if row['used_by_user_id'] is not None:
            return None, 'This code has already been used'
        if datetime.fromisoformat(row['expires_at']) < _now():
            return None, 'This code has expired — ask your researcher for a new one'

        existing = db.execute(
            'SELECT id FROM users WHERE username = ?', (username,)
        ).fetchone()
        if existing is not None:
            return None, 'That username is already taken'

        # The checks above aren't atomic with the writes below, so two
        # concurrent claims (e.g. of the same code) can both pass them.
        # Guard the writes themselves rather than trusting the checks:
        # patient_id/username collisions surface as IntegrityError, and the
        # UPDATE below only "wins" the code for one of the two INSERTs.
        password_hash = generate_password_hash(password)
        try:
            cursor = db.execute(
                'INSERT INTO users (username, password_hash, role, patient_id, created_at) '
                'VALUES (?, ?, ?, ?, ?)',
                (username, password_hash, 'patient', row['patient_id'], _now().isoformat()),
            )
        except sqlite3.IntegrityError as e:
            if 'users.username' in str(e):
                return None, 'That username is already taken'
            return None, 'This code has already been used'

        claimed = db.execute(
            'UPDATE enrollment_codes SET used_by_user_id = ? '
            'WHERE code = ? AND used_by_user_id IS NULL',
            (cursor.lastrowid, code),
        )
        if claimed.rowcount == 0:
            # Someone else claimed this code in the window between our
            # check and this write — undo the user row we just created.
            db.execute('DELETE FROM users WHERE id = ?', (cursor.lastrowid,))
            return None, 'This code has already been used'

        user = db.execute(
            'SELECT * FROM users WHERE id = ?', (cursor.lastrowid,)
        ).fetchone()
        return dict(user), None


def create_researcher(username, password):
    """Bootstrap-only: researcher/admin accounts are never self-registered
    from the app. Run via the create_admin.py CLI script on the server."""
    username = (username or '').strip()
    with _connect() as db:
        existing = db.execute(
            'SELECT id FROM users WHERE username = ?', (username,)
        ).fetchone()
        if existing is not None:
            raise ValueError('That username is already taken')
        password_hash = generate_password_hash(password)
        db.execute(
            'INSERT INTO users (username, password_hash, role, patient_id, created_at) '
            'VALUES (?, ?, ?, NULL, ?)',
            (username, password_hash, 'researcher', _now().isoformat()),
        )


def verify_login(username, password):
    username = (username or '').strip()
    with _connect() as db:
        row = db.execute(
            'SELECT * FROM users WHERE username = ?', (username,)
        ).fetchone()
        if row is None or not check_password_hash(row['password_hash'], password):
            return None
        return dict(row)


def list_patients():
    """Researcher-side: every enrolled patient account, newest first."""
    with _connect() as db:
        rows = db.execute(
            "SELECT username, patient_id, created_at FROM users "
            "WHERE role = 'patient' ORDER BY created_at DESC"
        ).fetchall()
        return [dict(row) for row in rows]


def get_patient_by_id(patient_id):
    with _connect() as db:
        row = db.execute(
            'SELECT username, patient_id, created_at FROM users WHERE patient_id = ?',
            (patient_id,),
        ).fetchone()
        return dict(row) if row else None
