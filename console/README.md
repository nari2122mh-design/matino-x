# MATINO X Secure Console

One protected web console with three tools:

| Tab | What it does |
|---|---|
| **SERVER FILE** | Upload / delete `.3105` packages in `BundledFiles` on GitHub |
| **SERVER KEY** | Create / edit / disable / delete licenses in Firestore `licenses` |
| **WINDOWS** | Free-form notes ("enter anything") stored in `BundledFiles/windows.json` |

## Hardening
- Single password login (`SITE_PASSWORD`), constant-time compare, supports a
  Werkzeug hash (`pbkdf2:...`)
- 5 failed logins => 15-minute per-IP lockout
- CSRF token required on every POST; session regenerated on login
- `HttpOnly` + `SameSite` cookies, optional `SITE_COOKIE_SECURE=true` for HTTPS
- Security headers (CSP, `X-Frame-Options: DENY`, `nosniff`, `no-referrer`)
- Optional `SITE_TOTP_SECRET` (base32) enables 2FA in the login form
- Session bound to IP + User-Agent (stolen cookies are rejected)
- Failed logins and all edits trigger a Telegram alert via
  `TELEGRAM_BOT_TOKEN` + `ALLOWED_CHAT_IDS`
- Every event is written to `audit.log` and viewable at `/audit`
- Optional `SITE_ALLOWED_IPS=ip1,ip2` allowlist
- No debug mode, uploads capped at 32 MB, filenames sanitized

## Environment
```
SITE_PASSWORD=<strong password>        # required
SITE_SECRET=<random 64-hex>            # recommended (else random per restart)
GH_TOKEN=<github token with repo write>
REPO_SLUG=gminegg150-cell/matino-x
FIREBASE_API_KEY=AIzaSy...             # optional, has a default
FIREBASE_PROJECT_ID=baypass-x-dbabb    # optional
SITE_ALLOWED_IPS=1.2.3.4               # optional
SITE_TOTP_SECRET=JBSWY3DPEHPK3PXP      # optional 2FA (base32)
TELEGRAM_BOT_TOKEN=123:ABC             # optional security alerts
ALLOWED_CHAT_IDS=123456789             # comma-separated
SITE_COOKIE_SECURE=true                # when served over HTTPS
PORT=7860
```

## Run locally
```bash
pip install -r requirements.txt
set SITE_PASSWORD=your-strong-password
python app.py
```
Open `http://127.0.0.1:7860`.

## Run with gunicorn
```bash
gunicorn -b 0.0.0.0:7860 app:app
```
