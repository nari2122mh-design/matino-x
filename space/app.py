#!/usr/bin/env python3
"""MATINO X file-drop site - cloud-native (Hugging Face Space / Render / any host).

Uploads go straight into the GitHub repo via the Contents API, so no local git
repository is needed. GitHub Actions then rebuilds the IPA automatically.
Protected by SITE_PASSWORD (env var / HF Space secret).
"""
from __future__ import annotations

import base64
import json
import os
import re
import secrets
import time
import urllib.error
import urllib.request
from pathlib import Path

from flask import Flask, flash, redirect, render_template, request, session, url_for

SITE = Path(__file__).resolve().parent
REPO_SLUG = os.environ.get("REPO_SLUG", "gminegg150-cell/matino-x")
BRANCH = os.environ.get("REPO_BRANCH", "main")
API = f"https://api.github.com/repos/{REPO_SLUG}"
GH_TOKEN = os.environ.get("GH_TOKEN", "").strip()

app = Flask(__name__)
app.secret_key = os.environ.get("SITE_SECRET") or secrets.token_hex(32)
app.config["MAX_CONTENT_LENGTH"] = 64 * 1024 * 1024  # 64 MB


# ---------- GitHub Contents API helpers (stdlib only) ----------
def _headers() -> dict:
    h = {"Accept": "application/vnd.github+json", "User-Agent": "matino-x-file-site",
         "X-GitHub-Api-Version": "2022-11-28"}
    if GH_TOKEN:
        h["Authorization"] = f"Bearer {GH_TOKEN}"
    return h


def gh_get_file(path: str) -> tuple[bytes, str | None]:
    """Return (content_bytes, sha). Empty bytes + None if missing."""
    url = f"{API}/contents/{path}?ref={BRANCH}"
    req = urllib.request.Request(url, headers=_headers())
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.load(r)
        raw = base64.b64decode(data.get("content", ""))
        return raw, data.get("sha")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return b"", None
        raise


def gh_put_file(path: str, data: bytes, message: str) -> bool:
    """Create or update a file in the GitHub repo. Returns True on success."""
    _, sha = gh_get_file(path)
    payload = {
        "message": message,
        "content": base64.b64encode(data).decode("ascii"),
        "branch": BRANCH,
    }
    if sha:
        payload["sha"] = sha
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(f"{API}/contents/{path}", data=body,
                                 headers=_headers(), method="PUT")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return 200 <= r.status < 300
    except urllib.error.HTTPError as e:
        app.logger.error("gh_put_file %s failed: %s %s", path, e.code, e.read()[:300])
        return False


def gh_delete_file(path: str, message: str) -> bool:
    _, sha = gh_get_file(path)
    if not sha:
        return True  # already gone
    body = json.dumps({"message": message, "sha": sha, "branch": BRANCH}).encode("utf-8")
    req = urllib.request.Request(f"{API}/contents/{path}", data=body,
                                 headers=_headers(), method="DELETE")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return 200 <= r.status < 300
    except urllib.error.HTTPError as e:
        app.logger.error("gh_delete_file %s failed: %s %s", path, e.code, e.read()[:300])
        return False


# ---------- metadata JSON (comments / names), stored in GitHub ----------
def _load_json_remote(path: str) -> dict:
    try:
        raw, _ = gh_get_file(path)
        if not raw:
            return {}
        data = json.loads(raw.decode("utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def load_names() -> dict:
    return _load_json_remote("BundledFiles/names.json")


def save_names(names: dict) -> None:
    gh_put_file("BundledFiles/names.json",
                json.dumps(names, ensure_ascii=False, indent=2).encode("utf-8"),
                "Update display names [skip ci]")


def load_comments() -> dict:
    return _load_json_remote("BundledFiles/comments.json")


def save_comments(comments: dict) -> None:
    gh_put_file("BundledFiles/comments.json",
                json.dumps(comments, ensure_ascii=False, indent=2).encode("utf-8"),
                "Update comments [skip ci]")


def safe_name(name: str) -> str:
    name = Path(name.replace("\\", "/")).name
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    name = "".join(c if c in allowed else "_" for c in name).lstrip(".") or "file"
    return name[:120]


def password() -> str:
    return os.environ.get("SITE_PASSWORD", "").strip()


def logged_in() -> bool:
    return session.get("auth") == "ok" and bool(password())


def latest_release() -> dict | None:
    try:
        req = urllib.request.Request(
            f"{API}/releases/latest",
            headers={"User-Agent": "matino-x-file-site", **({"Authorization": f"Bearer {GH_TOKEN}"} if GH_TOKEN else {})},
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.load(r)
        assets = [a for a in data.get("assets", []) if a.get("name", "").lower().endswith(".ipa")]
        if not assets:
            return None
        return {"tag": data.get("tag_name", ""), "url": assets[0]["browser_download_url"]}
    except Exception:
        return None


def list_remote_files() -> list[str]:
    """List .3105 files in BundledFiles from GitHub."""
    try:
        req = urllib.request.Request(f"{API}/contents/BundledFiles?ref={BRANCH}", headers=_headers())
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.load(r)
        return sorted(
            i["name"] for i in data
            if i.get("type") == "file"
            and i["name"].lower().endswith(".3105")
        )
    except Exception:
        return []


# ---------- Routes ----------
@app.route("/", methods=["GET", "POST"])
def index():
    if request.method == "POST" and "login" in request.form:
        if secrets.compare_digest(request.form.get("password", ""), password()):
            session["auth"] = "ok"
            flash("Authenticated.")
        else:
            flash("Wrong password.")
        return redirect(url_for("index"))

    if not logged_in():
        return render_template("login.html", configured=bool(password()), release=latest_release())

    return render_template(
        "index.html", files=list_remote_files(), comments=load_comments(),
        names=load_names(), release=latest_release()
    )


@app.route("/upload", methods=["POST"])
def upload():
    if not logged_in():
        return redirect(url_for("index"))
    incoming = request.files.get("file")
    if incoming is None or not incoming.filename:
        flash("No file selected.")
        return redirect(url_for("index"))

    name = safe_name(incoming.filename)
    category = request.form.get("category", "").strip().upper()
    variant = request.form.get("variant", "").strip().upper()
    valid_category = category if category in {"AIM", "HOLOGRAM", "SKIN", "MISC"} else None
    valid_variant = variant if variant in {"NORMAL", "MAX"} else None

    clean = re.sub(r"^(AIM|HOLOGRAM|SKIN|MISC)_+", "", name, flags=re.IGNORECASE)
    clean = re.sub(r"^MAX_+", "", clean, flags=re.IGNORECASE)
    clean = re.sub(r"^NORMAL_+", "", clean, flags=re.IGNORECASE)
    clean = clean or "file"
    tokens = []
    if valid_category:
        tokens.append(valid_category)
    tokens.append(valid_variant or "NORMAL")
    tokens.append(clean)
    name = safe_name("_".join(tokens))

    ok = gh_put_file(f"BundledFiles/{name}", incoming.read(), f"Bundle file: {name} [skip ci]")

    comment = request.form.get("comment", "").strip()
    comments = load_comments()
    stem = name.rsplit(".", 1)[0]
    comments.pop(name, None)
    comments.pop(stem, None)
    if comment:
        comments[name] = comment
    save_comments(comments)

    display = request.form.get("display_name", "").strip()
    names = load_names()
    names.pop(name, None)
    names.pop(stem, None)
    if display:
        names[name] = display
    save_names(names)

    if ok:
        flash(f"{name} uploaded. It will appear in the app within ~2 seconds.")
    else:
        flash(f"{name}: GitHub upload failed. Check GH_TOKEN.")
    return redirect(url_for("index"))


@app.route("/delete", methods=["POST"])
def delete():
    if not logged_in():
        return redirect(url_for("index"))
    name = safe_name(request.form.get("name", ""))
    if name in {".gitkeep", "comments.json", "names.json"}:
        flash("This file cannot be deleted.")
        return redirect(url_for("index"))

    ok = gh_delete_file(f"BundledFiles/{name}", f"Remove bundled file: {name} [skip ci]")
    comments = load_comments()
    comments.pop(name, None)
    comments.pop(name.rsplit(".", 1)[0], None)
    save_comments(comments)
    names = load_names()
    names.pop(name, None)
    names.pop(name.rsplit(".", 1)[0], None)
    save_names(names)

    flash(f"{name} deleted." if ok else f"{name}: deletion failed. Check GH_TOKEN.")
    return redirect(url_for("index"))


@app.route("/rename", methods=["POST"])
def rename():
    if not logged_in():
        return redirect(url_for("index"))
    old = safe_name(request.form.get("old_name", ""))
    raw_new = request.form.get("new_name", "").strip()
    if old in {".gitkeep", "comments.json", "names.json"}:
        flash("This file cannot be renamed.")
        return redirect(url_for("index"))

    raw, _ = gh_get_file(f"BundledFiles/{old}")
    if not raw:
        flash(f"{old}: not found.")
        return redirect(url_for("index"))

    new = safe_name(raw_new) or "file"
    if not new.lower().endswith(".3105"):
        new += ".3105"
    if new == old:
        flash("Name unchanged.")
        return redirect(url_for("index"))

    ok = gh_put_file(f"BundledFiles/{new}", raw, f"Rename {old} -> {new} [skip ci]")
    if ok:
        gh_delete_file(f"BundledFiles/{old}", f"Rename {old} -> {new} [skip ci]")

    comments = load_comments()
    comment = comments.pop(old, None)
    comments.pop(old.rsplit(".", 1)[0], None)
    if comment:
        comments[new] = comment
    save_comments(comments)
    names = load_names()
    display = names.pop(old, None)
    names.pop(old.rsplit(".", 1)[0], None)
    if display:
        names[new] = display
    save_names(names)

    flash(f"Renamed to {new}." if ok else f"Rename failed. Check GH_TOKEN.")
    return redirect(url_for("index"))


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("index"))


if __name__ == "__main__":
    if not password():
        print("Set SITE_PASSWORD env var before starting.")
    port = int(os.environ.get("PORT", "7860"))
    app.run(host="0.0.0.0", port=port, debug=False)
