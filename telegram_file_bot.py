#!/usr/bin/env python3
"""Small Telegram file-drop bot for the MATINO X build pipeline.

It watches a Telegram chat, saves any document into ``BundledFiles/`` and
pushes a commit. GitHub Actions then rebuilds the IPA with those files inside
``Payload/MATINO X.app/``.

Setup:
    pip install requests
    set TELEGRAM_BOT_TOKEN=...
    set ALLOWED_CHAT_IDS=123456789
    python telegram_file_bot.py

Never hardcode the bot token. Store it in an environment variable.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("Install the dependency first:  pip install requests")

REPO = Path(__file__).resolve().parent
DROP_DIR = REPO / "BundledFiles"
ENV_FILE = REPO / ".env"

API = "https://api.telegram.org/bot{token}"


def load_env_file() -> None:
    """Load KEY=VALUE lines from .env into os.environ (no dependency)."""
    if not ENV_FILE.is_file():
        return
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


load_env_file()


def token() -> str:
    value = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    if not value:
        sys.exit("TELEGRAM_BOT_TOKEN is not set. Revoke any token posted in chat.")
    return value


def allowed_chats() -> set[int]:
    raw = os.environ.get("ALLOWED_CHAT_IDS", "").strip()
    if not raw:
        return set()
    result = set()
    for part in raw.split(","):
        part = part.strip()
        if part.isdigit() or (part.startswith("-") and part[1:].isdigit()):
            result.add(int(part))
    return result


def api(method: str, params: dict | None = None, files: dict | None = None):
    url = API.format(token=token()) + "/" + method
    response = requests.post(url, data=params, files=files, timeout=30)
    response.raise_for_status()
    return response.json()


def safe_name(name: str) -> str:
    name = Path(name.replace("\\", "/")).name
    name = re.sub(r"[^A-Za-z0-9._-]", "_", name).lstrip(".") or "file"
    return name[:120]


def send(chat_id: int, text: str) -> None:
    api("sendMessage", {"chat_id": chat_id, "text": text[:4000]})


def push_file(chat_id: int, document: dict) -> None:
    file_id = document["file_id"]
    name = safe_name(document.get("file_name", "file"))

    info = api("getFile", {"file_id": file_id})["result"]
    path = info["file_path"]
    url = "https://api.telegram.org/file/bot{token}/{path}".format(
        token=token(), path=path
    )
    payload = requests.get(url, timeout=60)
    payload.raise_for_status()

    DROP_DIR.mkdir(parents=True, exist_ok=True)
    target = DROP_DIR / name
    target.write_bytes(payload.content)

    subprocess.run(["git", "add", "--", f"BundledFiles/{name}"], cwd=REPO, check=True)
    change = subprocess.run(
        ["git", "diff", "--cached", "--quiet"], cwd=REPO
    ).returncode
    if change == 0:
        send(chat_id, f"{name}: no change, skipping rebuild.")
        return

    subprocess.run(
        ["git", "commit", "-m", f"Bundle file: {name}"], cwd=REPO, check=True
    )
    push = subprocess.run(["git", "push"], cwd=REPO, capture_output=True, text=True)
    if push.returncode != 0:
        send(chat_id, f"{name}: committed locally but push failed:\n{push.stderr[-1000:]}")
        return

    send(
        chat_id,
        f"✅ {name} added ({len(payload.content)} bytes). "
        "GitHub Actions is rebuilding the IPA.",
    )


def main() -> int:
    if not os.environ.get("TELEGRAM_BOT_TOKEN"):
        sys.exit("Set TELEGRAM_BOT_TOKEN first. Never paste tokens in chat.")
    allowed = allowed_chats()
    offset = 0

    me = api("getMe")["result"]
    print(f"Connected as @{me.get('username', 'bot')}. Waiting for files...")

    while True:
        try:
            updates = api(
                "getUpdates",
                {"offset": offset, "timeout": 30, "allowed_updates": ["message"]},
            )["result"]
        except requests.RequestException as exc:
            print(f"Polling error: {exc}", file=sys.stderr)
            time.sleep(5)
            continue

        for update in updates:
            offset = max(offset, update["update_id"] + 1)
            message = update.get("message") or {}
            chat_id = message.get("chat", {}).get("id")
            if chat_id is None:
                continue
            if allowed and chat_id not in allowed:
                send(chat_id, "Not authorized.")
                continue

            document = message.get("document")
            if document:
                try:
                    push_file(chat_id, document)
                except Exception as exc:  # keep the bot alive
                    send(chat_id, f"Failed: {exc}")
                    print(f"File error: {exc}", file=sys.stderr)
            elif message.get("text", "").startswith("/start"):
                send(chat_id, "Send me a file and I'll add it to the next IPA build.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
