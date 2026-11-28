#!/usr/bin/env python3
"""MATINO X secure console.

Three tools behind ONE strong login:
  1. SERVER KEY  - manage license keys in Firestore (create / edit / disable / delete)
  2. SERVER FILE - upload / rename / delete .3105 packages in the GitHub repo
  3. WINDOWS     - free-form notes ("enter anything") stored in the repo

Hardening:
  - password from SITE_PASSWORD (plain or werkzeug hash), constant-time compare
  - rate limiting + per-IP lockout after repeated failures
  - CSRF token on every state-changing request
  - regenerated sessions, HttpOnly / SameSite / secure-cookie options
  - security headers, strict filename/path validation, no debug mode
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import struct
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

from flask import (
    Flask, abort, flash, redirect, render_template, request, session, url_for,
)
from werkzeug.security import check_password_hash

SITE = Path(__file__).resolve().parent

# ---------------------------------------------------------------- config
REPO_SLUG = os.environ.get("REPO_SLUG", "gminegg150-cell/matino-x")
BRANCH = os.environ.get("REPO_BRANCH", "main")
GH_TOKEN = os.environ.get("GH_TOKEN", "").strip()
GH_API = f"https://api.github.com/repos/{REPO_SLUG}"

FB_PROJECT = os.environ.get("FIREBASE_PROJECT_ID", "baypass-x-dbabb").strip()
FB_KEY = os.environ.get(
    "FIREBASE_API_KEY", "AIzaSyDDk-5RZaPuOtCd86aFhgXpMUNGaTtx5EQ"
).strip()
FB_BASE = (
    f"https://firestore.googleapis.com/v1/projects/{FB_PROJECT}"
    "/databases/(default)/documents"
)

app = Flask(__name__)
app.secret_key = os.environ.get("SITE_SECRET") or secrets.token_hex(32)
TOTP_SECRET = re.sub(r"\s+", "", os.environ.get("SITE_TOTP_SECRET", "")).upper()
TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
TG_CHATS = [c.strip() for c in os.environ.get("ALLOWED_CHAT_IDS", "").split(",") if c.strip()]
AUDIT_LOG = SITE / "audit.log"

app.config.update(
    MAX_CONTENT_LENGTH=32 * 1024 * 1024,
    PERMANENT_SESSION_LIFETIME=timedelta(hours=2),
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=os.environ.get("SITE_COOKIE_SECURE", "").lower() == "true",
)

# login throttle (in-memory, per process)
_lock = threading.Lock()
_attempts: dict[str, dict] = {}
MAX_FAILS = 5
LOCK_SECONDS = 15 * 60
ALLOWED_IPS = {
    ip.strip() for ip in os.environ.get("SITE_ALLOWED_IPS", "").split(",") if ip.strip()
}


# ---------------------------------------------------------------- helpers
def _ip() -> str:
    return request.remote_addr or "unknown"


def password_ok(candidate: str) -> bool:
    stored = os.environ.get("SITE_PASSWORD", "").strip()
    if not stored:
        return False
    if stored.startswith(("pbkdf2:", "scrypt:", "argon2")):
        try:
            return check_password_hash(stored, candidate)
        except Exception:
            return False
    return hmac.compare_digest(candidate, stored)


def ip_allowed() -> bool:
    return not ALLOWED_IPS or _ip() in ALLOWED_IPS


def logged_in() -> bool:
    return session.get("auth") == "ok" and ip_allowed()


def fingerprint_valid() -> bool:
    """Bind the session to the original IP + browser (stops cookie theft)."""
    expected = session.get("fingerprint")
    if not expected:
        return True
    current = hashlib.sha256(
        f"{_ip()}|{request.headers.get('User-Agent', '')}".encode()
    ).hexdigest()
    return hmac.compare_digest(expected, current)


def notify(text: str) -> None:
    """Best-effort Telegram alert to the owner (never blocks a request long)."""
    if not TG_TOKEN or not TG_CHATS:
        return
    for chat in TG_CHATS:
        try:
            url = f"https://api.telegram.org/bot{TG_TOKEN}/sendMessage"
            body = json.dumps({"chat_id": chat, "text": text[:900]}).encode()
            req = urllib.request.Request(url, data=body,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=4):
                pass
        except Exception:
            pass


def audit(action: str, detail: str = "", alert: bool = False) -> None:
    line = f"{datetime.now().isoformat(timespec='seconds')} {_ip()} {action} {detail}\n"
    try:
        with AUDIT_LOG.open("a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass
    if alert:
        notify(f"🔐 MATINO console: {action} — {detail} (IP {_ip()})")


def totp_ok(code: str) -> bool:
    """TOTP (RFC 6238, SHA1, 6 digits, 30s) with ±1 step tolerance."""
    if not TOTP_SECRET or not code or not re.fullmatch(r"\d{6}", code):
        return False
    try:
        padded = TOTP_SECRET + "=" * ((8 - len(TOTP_SECRET) % 8) % 8)
        key = base64.b32decode(padded, casefold=True)
    except Exception:
        return False
    counter = int(time.time()) // 30
    for offset in (-1, 0, 1):
        msg = struct.pack(">Q", counter + offset)
        digest = hmac.new(key, msg, hashlib.sha1).digest()
        pos = digest[-1] & 0x0F
        value = struct.unpack(">I", digest[pos:pos + 4])[0] & 0x7FFFFFFF
        if hmac.compare_digest(code, f"{value % 1_000_000:06d}"):
            return True
    return False


def csrf_token() -> str:
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(32)
    return session["csrf"]


def csrf_ok() -> bool:
    sent = request.form.get("csrf", "")
    return bool(sent) and hmac.compare_digest(sent, session.get("csrf", ""))


def throttled() -> bool:
    with _lock:
        entry = _attempts.get(_ip())
        return bool(entry and entry.get("until", 0) > time.time())


def record_fail() -> None:
    with _lock:
        entry = _attempts.setdefault(_ip(), {"fails": 0, "until": 0})
        entry["fails"] += 1
        if entry["fails"] >= MAX_FAILS:
            entry["until"] = time.time() + LOCK_SECONDS
            entry["fails"] = 0


def record_success() -> None:
    with _lock:
        _attempts.pop(_ip(), None)


def friendly_error(code: int, message: str):
    return (
        "<!doctype html><meta charset='utf-8'><title>MATINO X Console</title>"
        "<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#050505;"
        "color:#eee;font-family:system-ui,sans-serif}.b{max-width:440px;background:#0d0d0d;"
        "border:1px solid #ffffff20;border-radius:18px;padding:28px;text-align:center}"
        "h1{font-size:22px}p{color:#999;font-size:13px}a{display:inline-block;margin-top:12px;"
        "padding:10px 16px;border:1px solid #ffffff40;border-radius:10px;color:#fff;"
        "text-decoration:none;font-weight:700}</style>"
        "<div class='b'><h1>" + str(code) + "</h1><p>" + message + "</p>"
        "<a href='/' >BACK TO CONSOLE</a></div>"
    )


@app.errorhandler(400)
def handle_400(e):
    return friendly_error(400, "The request could not be understood. Please go back and retry."), 400


@app.errorhandler(403)
def handle_403(e):
    return friendly_error(403, "Access denied. Your session or IP is not allowed."), 403


@app.errorhandler(404)
def handle_404(e):
    return friendly_error(404, "Page not found."), 404


@app.before_request
def guard():
    if not ip_allowed():
        return friendly_error(403, "Access denied. Your IP is not allowed."), 403
    if logged_in() and not fingerprint_valid():
        session.clear()
        audit("session_fingerprint_mismatch", "session cleared", alert=True)
        flash("Session expired for your security. Please log in again.")
        return redirect(url_for("index"))
    if request.method == "POST" and logged_in() and not csrf_ok():
        session.pop("csrf", None)
        flash("Session expired. Please go back and try again.")
        return redirect(url_for("index"))


@app.after_request
def security_headers(resp):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Referrer-Policy"] = "no-referrer"
    resp.headers["Cache-Control"] = "no-store"
    resp.headers["Content-Security-Policy"] = (
        "default-src 'self'; style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data:; form-action 'self'; frame-ancestors 'none'"
    )
    return resp


@app.context_processor
def inject_csrf():
    return {"csrf_token": csrf_token}


# ---------------------------------------------------------------- GitHub
def gh_headers() -> dict:
    h = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "matino-x-console",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if GH_TOKEN:
        h["Authorization"] = f"Bearer {GH_TOKEN}"
    return h


def gh_request(url: str, method: str = "GET", payload: dict | None = None) -> dict | list | None:
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=gh_headers(), method=method)
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if e.code != 404:  # a missing file is a normal case (not an error)
            app.logger.error("GitHub %s %s -> %s: %s", method, url, e.code, e.read()[:200])
        return None
    except Exception as e:  # network
        app.logger.error("GitHub %s failed: %s", url, e)
        return None


def gh_get_file(path: str) -> tuple[bytes, str | None]:
    # Cache-buster: the Contents API response can be held by a CDN, so a
    # second save would read stale bytes + a stale SHA and overwrite the
    # change that was just written. A changing query forces fresh data.
    url = (f"{GH_API}/contents/{urllib.parse.quote(path)}"
           f"?ref={BRANCH}&t={int(time.time() * 1000)}")
    data = gh_request(url)
    if not isinstance(data, dict):
        return b"", None
    return base64.b64decode(data.get("content", "")), data.get("sha")


def gh_put_file(path: str, content: bytes, message: str) -> bool:
    _, sha = gh_get_file(path)
    payload = {"message": message, "content": base64.b64encode(content).decode(),
               "branch": BRANCH}
    if sha:
        payload["sha"] = sha
    return gh_request(f"{GH_API}/contents/{urllib.parse.quote(path)}", "PUT", payload) is not None


def gh_delete_file(path: str, message: str) -> bool:
    _, sha = gh_get_file(path)
    if not sha:
        return True
    payload = {"message": message, "sha": sha, "branch": BRANCH}
    return gh_request(f"{GH_API}/contents/{urllib.parse.quote(path)}", "DELETE", payload) is not None


def gh_list_dir(path: str) -> list[dict]:
    data = gh_request(f"{GH_API}/contents/{urllib.parse.quote(path)}"
                      f"?ref={BRANCH}&t={int(time.time() * 1000)}")
    return data if isinstance(data, list) else []


def load_json(path: str) -> dict:
    raw, _ = gh_get_file(path)
    if not raw:
        return {}
    try:
        obj = json.loads(raw.decode())
        return obj if isinstance(obj, dict) else {}
    except Exception:
        return {}


def normalize_windows(obj) -> list[dict]:
    """windows.json as a list of notes, newest first.

    Current format : [{"title": …, "content": …, "ts": …}, …]
    Legacy format  : {"TITLE": "content"}  (converted, keeps old notes visible)
    """
    out: list[dict] = []
    if isinstance(obj, list):
        for w in obj:
            if not isinstance(w, dict):
                continue
            title = str(w.get("title", "")).strip()[:120]
            if not title:
                continue
            try:
                ts = float(w.get("ts") or 0)
            except (TypeError, ValueError):
                ts = 0.0
            out.append({
                "title": title,
                "content": str(w.get("content", ""))[:8000],
                "ts": ts,
            })
    elif isinstance(obj, dict):
        for title, content in obj.items():
            out.append({"title": str(title)[:120],
                        "content": str(content)[:8000], "ts": 0.0})
    out.sort(key=lambda w: w["ts"], reverse=True)
    return out


def load_windows() -> list[dict]:
    return normalize_windows(load_json("BundledFiles/windows.json"))


def save_json(path: str, obj, message: str) -> bool:
    # Re-read the current SHA immediately before writing so a save that
    # follows another one never overwrites with a stale blob.
    _, sha = gh_get_file(path)
    payload = {
        "message": message + " [skip ci]",
        "content": base64.b64encode(
            json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
        ).decode("ascii"),
        "branch": BRANCH,
    }
    if sha:
        payload["sha"] = sha
    return gh_request(f"{GH_API}/contents/{urllib.parse.quote(path)}", "PUT", payload) is not None


def latest_build_id() -> str:
    """Build id of the newest IPA, written by the build workflow."""
    raw, _ = gh_get_file("latest_build.txt")
    return raw.decode("utf-8", "replace").strip() if raw else ""


def safe_name(name: str) -> str:
    name = Path(name.replace("\\", "/")).name
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- ")
    cleaned = "".join(c if c in allowed else "_" for c in name).strip().lstrip(".")
    return cleaned[:100] or "file"


# ---------------------------------------------------------------- Firestore
def fs_value(v: dict):
    for k in ("stringValue", "timestampValue", "booleanValue", "integerValue", "doubleValue"):
        if k in v:
            return v[k]
    if "nullValue" in v:
        return None
    return None


def fs_fields_to_dict(fields: dict) -> dict:
    return {k: fs_value(v) for k, v in fields.items() if isinstance(v, dict)}


def fs_request(url: str, method: str = "GET", payload: dict | None = None):
    """Firestore uses the API key in the query, NOT a GitHub Bearer header."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Accept": "application/json", "Content-Type": "application/json",
                 "User-Agent": "matino-x-console"},
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if e.code != 404:
            app.logger.error("Firestore %s -> %s: %s", url, e.code, e.read()[:200])
        return None
    except Exception as e:
        app.logger.error("Firestore request failed: %s", e)
        return None


def fs_list() -> list[dict]:
    url = f"{FB_BASE}/licenses?key={urllib.parse.quote(FB_KEY)}&pageSize=200"
    data = fs_request(url)
    docs = data.get("documents", []) if isinstance(data, dict) else []
    out = []
    for d in docs:
        out.append({
            "name": d.get("name", "").rsplit("/", 1)[-1],
            "fields": fs_fields_to_dict(d.get("fields", {})),
        })
    return out


def fs_to_firestore_value(value: str):
    v = value.strip()
    if not v:
        return {"nullValue": None}
    if v.lower() in ("true", "false"):
        return {"booleanValue": v.lower() == "true"}
    if re.fullmatch(r"-?\d+", v):
        return {"integerValue": v}
    return {"stringValue": v}


def fs_write(doc_id: str, fields: dict[str, str]) -> bool:
    """Create or update a license. Only submitted fields change, so the
    device binding and original start date are never wiped on an edit."""
    doc_id = re.sub(r"[^A-Za-z0-9_-]", "_", doc_id)[:100] or secrets.token_hex(6)
    url = f"{FB_BASE}/licenses/{urllib.parse.quote(doc_id)}?key={urllib.parse.quote(FB_KEY)}"
    existing = fs_request(url)
    body_fields = {k: fs_to_firestore_value(v) for k, v in fields.items() if v.strip()}
    if not isinstance(existing, dict):  # new key: stamp the start date
        body_fields["createdAt"] = {
            "timestampValue": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        }
        body_fields.setdefault("role", {"stringValue": "user"})
    mask = "&".join("updateMask.fieldPaths=" + urllib.parse.quote(k) for k in body_fields)
    if mask:
        url += "&" + mask
    return fs_request(url, "PATCH", {"fields": body_fields}) is not None


def fs_delete(doc_id: str) -> bool:
    doc_id = re.sub(r"[^A-Za-z0-9_-]", "_", doc_id)[:100]
    return fs_request(f"{FB_BASE}/licenses/{urllib.parse.quote(doc_id)}?key={urllib.parse.quote(FB_KEY)}",
                      "DELETE") is not None


# ---------------------------------------------------------------- routes
@app.route("/", methods=["GET", "POST"])
def index():
    if request.method == "POST" and "login" in request.form:
        if throttled():
            flash("Too many attempts. Try again in 15 minutes.")
            audit("login_blocked", "rate limited", alert=True)
        elif not password_ok(request.form.get("password", "")):
            record_fail()
            audit("login_failed", "wrong password", alert=True)
            flash("Wrong password.")
        elif TOTP_SECRET and not totp_ok(request.form.get("totp", "")):
            record_fail()
            audit("login_failed", "wrong 2FA code", alert=True)
            flash("Wrong 2FA code.")
        else:
            session.clear()
            session["auth"] = "ok"
            session["fingerprint"] = hashlib.sha256(
                f"{_ip()}|{request.headers.get('User-Agent', '')}".encode()
            ).hexdigest()
            session.permanent = True
            record_success()
            audit("login_success", "")
            flash("Authenticated.")
        return redirect(url_for("index"))

    if not logged_in():
        return render_template("login.html",
                               configured=bool(os.environ.get("SITE_PASSWORD", "").strip()),
                               locked=throttled(),
                               totp_required=bool(TOTP_SECRET))

    tab = request.args.get("tab", "files")
    files = []
    if tab == "files":
        files = sorted(
            (i["name"] for i in gh_list_dir("BundledFiles")
             if i.get("type") == "file" and i["name"].lower().endswith(".3105"))
        )
    keys = fs_list() if tab == "keys" else []
    windows = load_windows() if tab == "windows" else []
    control = load_json("BundledFiles/app_control.json") if tab == "control" else {}
    comments = load_json("BundledFiles/comments.json") if tab == "files" else {}
    names = load_json("BundledFiles/names.json") if tab == "files" else {}

    return render_template("index.html", tab=tab, files=files, keys=keys,
                           windows=windows, control=control,
                           comments=comments, names=names)


@app.route("/file/upload", methods=["POST"])
def file_upload():
    if not logged_in():
        return redirect(url_for("index"))
    incoming = request.files.get("file")
    if not incoming or not incoming.filename:
        flash("No file selected.")
        return redirect(url_for("index"))
    name = safe_name(incoming.filename)
    category = request.form.get("category", "").strip().upper()
    variant = request.form.get("variant", "").strip().upper()
    category = category if category in {"AIM", "HOLOGRAM", "SKIN", "MISC"} else ""
    variant = variant if variant in {"NORMAL", "MAX"} else "NORMAL"
    clean = re.sub(r"^(AIM|HOLOGRAM|SKIN|MISC)_+", "", name, flags=re.I)
    clean = re.sub(r"^(MAX|NORMAL)_+", "", clean, flags=re.I) or "file"
    parts = ([category] if category else []) + [variant, clean]
    name = safe_name("_".join(parts))
    ok = gh_put_file(f"BundledFiles/{name}", incoming.read(), f"Bundle file: {name}")
    audit("file_upload", name, alert=True)
    flash(f"{name} uploaded." if ok else f"{name}: upload failed (check GH_TOKEN).")
    return redirect(url_for("index", tab="files"))


@app.route("/file/delete", methods=["POST"])
def file_delete():
    if not logged_in():
        return redirect(url_for("index"))
    name = safe_name(request.form.get("name", ""))
    if name in {"names.json", "comments.json", "windows.json"}:
        flash("This file cannot be deleted.")
    else:
        ok = gh_delete_file(f"BundledFiles/{name}", f"Remove bundled file: {name}")
        audit("file_delete", name, alert=True)
        flash(f"{name} deleted." if ok else f"{name}: deletion failed.")
    return redirect(url_for("index", tab="files"))


@app.route("/file/meta", methods=["POST"])
def file_meta():
    """Save the comment + display name shown under a package in the app."""
    if not logged_in():
        return redirect(url_for("index"))
    name = safe_name(request.form.get("name", ""))
    if not name.lower().endswith(".3105"):
        flash("Invalid file name.")
        return redirect(url_for("index", tab="files"))

    comment = request.form.get("comment", "").strip()[:300]
    display = request.form.get("display_name", "").strip()[:100]

    comments = load_json("BundledFiles/comments.json")
    names = load_json("BundledFiles/names.json")
    # Keep both key forms in sync so lookup works with or without extension.
    stem = name.rsplit(".", 1)[0]
    for key in (name, stem):
        comments.pop(key, None)
        names.pop(key, None)
    if comment:
        comments[name] = comment
    if display:
        names[name] = display
    ok_c = save_json("BundledFiles/comments.json", comments, "Update comments")
    ok_n = save_json("BundledFiles/names.json", names, "Update display names")
    audit("file_meta", f"{name} comment={bool(comment)} name={bool(display)}", alert=True)
    flash("Saved." if (ok_c and ok_n) else "Save failed (check GH_TOKEN).")
    return redirect(url_for("index", tab="files"))


@app.route("/key/save", methods=["POST"])
def key_save():
    if not logged_in():
        return redirect(url_for("index"))
    key = request.form.get("key", "").strip()
    if not key or len(key) > 120:
        flash("A key value is required (max 120 chars).")
        return redirect(url_for("index", tab="keys"))
    doc_id = re.sub(r"[^A-Za-z0-9_-]", "_", key)
    fields = {
        "key": key,
        "package": request.form.get("package", "").strip() or "MATINO X",
        "duration": request.form.get("duration", "Lifetime"),
        "status": request.form.get("status", "Active"),
    }
    ok = fs_write(doc_id, fields)
    audit("key_save", doc_id, alert=True)
    flash(f"Key {key} saved." if ok else "Firestore write failed (check API key/rules).")
    return redirect(url_for("index", tab="keys"))


@app.route("/key/status", methods=["POST"])
def key_status():
    """One-click enable / disable for a license."""
    if not logged_in():
        return redirect(url_for("index"))
    doc_id = re.sub(r"[^A-Za-z0-9_-]", "_", request.form.get("doc_id", ""))
    status = "Active" if request.form.get("status") == "Active" else "Disabled"
    ok = fs_write(doc_id, {"status": status})
    audit("key_status", f"{doc_id} -> {status}", alert=True)
    flash(f"Status set to {status}." if ok else "Update failed.")
    return redirect(url_for("index", tab="keys"))


@app.route("/key/delete", methods=["POST"])
def key_delete():
    if not logged_in():
        return redirect(url_for("index"))
    doc_id = request.form.get("doc_id", "").strip()
    ok = fs_delete(doc_id)
    audit("key_delete", doc_id, alert=True)
    flash("Key deleted." if ok else "Deletion failed.")
    return redirect(url_for("index", tab="keys"))


@app.route("/window/save", methods=["POST"])
def window_save():
    """Create or update a note shown behind the green bell in the app."""
    if not logged_in():
        return redirect(url_for("index"))
    title = request.form.get("title", "").strip()[:120]
    content = request.form.get("content", "")[:8000]
    if not title:
        flash("Give the window a title.")
        return redirect(url_for("index", tab="windows"))
    windows = load_windows()
    now = time.time()
    for w in windows:
        if w["title"].lower() == title.lower():
            w["content"] = content
            w["ts"] = now
            break
    else:
        windows.insert(0, {"title": title, "content": content, "ts": now})
    windows = windows[:60]
    ok = save_json("BundledFiles/windows.json", windows, "Update windows")
    audit("window_save", title)
    flash(f"“{title}” saved." if ok else "Save failed (check GH_TOKEN).")
    return redirect(url_for("index", tab="windows"))


@app.route("/window/delete", methods=["POST"])
def window_delete():
    if not logged_in():
        return redirect(url_for("index"))
    title = request.form.get("title", "").strip()
    windows = [w for w in load_windows() if w["title"] != title]
    save_json("BundledFiles/windows.json", windows, "Update windows")
    audit("window_delete", title)
    flash("Window deleted.")
    return redirect(url_for("index", tab="windows"))


@app.route("/control/save", methods=["POST"])
def control_save():
    if not logged_in():
        return redirect(url_for("index"))
    message = request.form.get("message", "").strip()[:2000]
    sound = request.form.get("sound", "none")
    if sound not in ("none", "tap", "applied", "restored"):
        sound = "none"
    disabled = request.form.get("disabled") == "1"
    payload = {
        "activeBuildID": latest_build_id(),
        "targetBuildID": latest_build_id(),
        "message": message,
        "updateMessage": request.form.get("update_message", "").strip()[:1000],
        "messageID": secrets.token_hex(8),
        "sound": sound,
        "disabled": disabled,
    }
    ok = save_json("BundledFiles/app_control.json", payload, "Update app control")
    audit("app_control", f"msg={bool(message)} sound={sound} disabled={disabled}", alert=True)
    flash("App control saved." if ok else "Save failed (check GH_TOKEN).")
    return redirect(url_for("index", tab="control"))


@app.route("/logout", methods=["POST"])
def logout():
    audit("logout", "")
    session.clear()
    return redirect(url_for("index"))


@app.route("/audit")
def audit_view():
    if not logged_in():
        return redirect(url_for("index"))
    lines = []
    try:
        lines = AUDIT_LOG.read_text(encoding="utf-8").splitlines()[-200:]
    except Exception:
        pass
    return render_template("audit.html", lines=list(reversed(lines)))


if __name__ == "__main__":
    if not os.environ.get("SITE_PASSWORD", "").strip():
        print("WARNING: set SITE_PASSWORD before starting.")
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "7860")), debug=False)
