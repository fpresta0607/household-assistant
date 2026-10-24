#!/usr/bin/env python3
"""Exports SIQsermon's sermons and study plans for the household-scripture plugin, once.

SIQsermon is being retired, and the household's own preaching history is the one thing
in it that is not public data. This reads every sermon and study project through
SIQsermon's backend, the way the old scripture skill did, and writes them as two JSON
files the plugin keeps the next time it is used (household-scripture/import/ in the
gateway's state). Running it again keeps nothing twice.

It runs inside a gateway container, which is on SIQsermon's network and holds the
SIQSERMON_USERNAME and SIQSERMON_PASSWORD the old skill signed in with, as the gateway's
own user so the files are the gateway's:

    docker exec -i -u node openclaw-gateway python3 - \\
        --out /home/node/.openclaw/household-scripture/import < scripts/siqsermon-export.py

scripts/siqsermon-retire.sh does that, and copies the files to the other gateway.
Only the standard library: the gateway image has no package manager.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

BACKEND = os.environ.get("SIQSERMON_URL", "http://deploy-backend-1:8000")
COOKIE_NAME = "siqsermon_session"
TIMEOUT = 60
# Fields worth reading as prose, in the order a sermon or a plan is usually written.
PROSE_FIRST = ("summary", "outline", "manuscript", "content", "text", "body", "notes")

Call = Callable[[str, dict[str, str] | None, str | None], tuple[Any, list[str]]]


class ExportError(Exception):
    pass


def call(url: str, payload: dict[str, str] | None, cookie: str | None) -> tuple[Any, list[str]]:
    """The parsed JSON body and the Set-Cookie headers of one request to the backend."""
    headers = {"Accept": "application/json"}
    body = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload).encode()
    if cookie:
        # A bare header: the cookie is marked Secure, and a cookie jar would refuse to send
        # it back over the in-network http call.
        headers["Cookie"] = f"{COOKIE_NAME}={cookie}"
    request = urllib.request.Request(url, data=body, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response), response.headers.get_all("Set-Cookie") or []
    except urllib.error.HTTPError as error:
        raise ExportError(f"SIQsermon returned {error.code} for {url}") from error
    except urllib.error.URLError as error:
        raise ExportError(f"cannot reach SIQsermon at {url} ({error.reason})") from error


def session(fetch: Call, env: dict[str, str]) -> str:
    username, password = env.get("SIQSERMON_USERNAME"), env.get("SIQSERMON_PASSWORD")
    if not username or not password:
        raise ExportError("SIQSERMON_USERNAME and SIQSERMON_PASSWORD are not set here")
    _, cookies = fetch(f"{BACKEND}/login", {"username": username, "password": password}, None)
    for value in cookies:
        if value.startswith(f"{COOKIE_NAME}="):
            return value.split("=", 1)[1].split(";", 1)[0]
    raise ExportError("SIQsermon accepted the login but issued no session cookie")


def readable(record: dict[str, Any], skip: set[str]) -> str:
    """A sermon or plan as text: its prose fields first, then everything else as JSON."""
    parts: list[str] = []
    keys = [key for key in PROSE_FIRST if key in record] + sorted(
        key for key in record if key not in PROSE_FIRST
    )
    for key in keys:
        value = record[key]
        if key in skip or value in (None, "", [], {}):
            continue
        heading = key.replace("_", " ").capitalize()
        if isinstance(value, str):
            parts.append(f"## {heading}\n\n{value.strip()}")
        else:
            parts.append(f"## {heading}\n\n{json.dumps(value, indent=2, ensure_ascii=False)}")
    return "\n\n".join(parts) or json.dumps(record, indent=2, ensure_ascii=False)


def items(fetch: Call, cookie: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    sermons: list[dict[str, Any]] = []
    listing, _ = fetch(f"{BACKEND}/sermons", None, cookie)
    for entry in listing.get("sermons") or []:
        full, _ = fetch(f"{BACKEND}/sermons/{entry['id']}", None, cookie)
        record = full if isinstance(full, dict) else entry
        title = record.get("topic") or record.get("title") or f"Sermon {entry['id']}"
        detail = record.get("passage") or record.get("scripture") or record.get("series") or ""
        sermons.append(
            {
                "kind": "sermon",
                "title": str(title),
                "detail": str(detail),
                "body": readable(record, {"id", "topic", "title", "created_at"}),
                "createdAt": record.get("created_at") or entry.get("created_at"),
                "source": "siqsermon",
                "originId": str(entry["id"]),
            }
        )
    plans: list[dict[str, Any]] = []
    listing, _ = fetch(f"{BACKEND}/projects", None, cookie)
    for entry in listing.get("projects") or []:
        full, _ = fetch(f"{BACKEND}/projects/{entry['id']}", None, cookie)
        record = full if isinstance(full, dict) else entry
        plans.append(
            {
                "kind": "plan",
                "title": str(record.get("title") or f"Study plan {entry['id']}"),
                "detail": str(record.get("study_method") or ""),
                "body": readable(record, {"id", "title", "study_method", "created_at"}),
                "createdAt": record.get("created_at") or entry.get("created_at"),
                "source": "siqsermon",
                "originId": str(entry["id"]),
            }
        )
    return sermons, plans


def write(out: Path, name: str, records: list[dict[str, Any]]) -> Path:
    out.mkdir(parents=True, exist_ok=True)
    path = out / name
    temporary = out / f".{name}.part"
    temporary.write_text(json.dumps(records, ensure_ascii=False, indent=2))
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    return path


def main(argv: Sequence[str] | None = None, *, fetch: Call = call) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n", 1)[0])
    parser.add_argument("--out", type=Path, required=True, help="the plugin's import folder")
    arguments = parser.parse_args(argv)
    try:
        cookie = session(fetch, dict(os.environ))
        sermons, plans = items(fetch, cookie)
    except (ExportError, KeyError) as error:
        print(f"siqsermon-export: {error}", file=sys.stderr)
        return 1
    write(arguments.out, "siqsermon-sermons.json", sermons)
    write(arguments.out, "siqsermon-plans.json", plans)
    print(f"exported {len(sermons)} sermons and {len(plans)} study plans to {arguments.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
