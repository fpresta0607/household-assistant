"""MCP over a Unix socket: the home key holder's only interface.

Messages are newline-delimited JSON-RPC, the framing MCP uses over stdio, so the gateway
plugin is an ordinary MCP client. Anything running as a gateway's user can connect,
including an assistant's shell in its owner's own thread, so this offers only the typed
house actions in actions.py, each with its own limits, and bounds every connection: its
message size, how many there are, how long one stays, and a budget of calls a minute,
with a smaller one for anything that changes the house. One call runs at a time. A call
is logged by its tool and outcome only.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import stat
import sys
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .actions import Home, HomeError

PROTOCOLS = ("2025-03-26", "2025-06-18", "2025-11-25")
MAX_MESSAGE_BYTES = 16 * 1024
MAX_CONNECTIONS = 8
# Longer than the slowest call: a search, waking the TV, opening Spotify, waiting half a
# minute for Spotify to list it, and the play Home Assistant checks for up to 8 seconds.
CONNECTION_SECONDS = 150
MESSAGE_IDLE_SECONDS = 15
CALLS_PER_MINUTE = 30
CHANGES_PER_MINUTE = 10

_BOOLEAN = {
    "type": "boolean",
    "description": "True only after the person said yes to this exact change.",
}
TOOLS: list[dict[str, Any]] = [
    {
        "name": "home_status",
        "description": (
            "The thermostat, the music, and the living room TV's power and volume, as the house "
            "has them now."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "home_thermostat",
        "description": (
            "Hold the house at one whole degree on heat or cool, or between two at least 5 "
            "apart on auto, from 62 to 80, as the thermostat's own mode has it."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "low": {"type": "integer", "minimum": 62, "maximum": 75},
                "high": {"type": "integer", "minimum": 67, "maximum": 80},
                "target": {"type": "integer", "minimum": 62, "maximum": 80},
                "confirmed": _BOOLEAN,
            },
            "required": ["confirmed"],
            "additionalProperties": False,
        },
    },
    {
        "name": "home_volume",
        "description": (
            "Set the living room TV's volume to a percent, 0 to 70, or step it up or down by 10."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "percent": {"type": "integer", "minimum": 0, "maximum": 70},
                "step": {"type": "string", "enum": ["up", "down"]},
                "confirmed": _BOOLEAN,
            },
            "required": ["confirmed"],
            "additionalProperties": False,
        },
    },
    {
        "name": "home_music",
        "description": "Pause, resume, skip or go back in the living room TV's music.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["pause", "resume", "next", "previous"]}
            },
            "required": ["action"],
            "additionalProperties": False,
        },
    },
    {
        "name": "home_play",
        "description": (
            "Play a track, album, artist or playlist on the living room TV, found by Spotify's "
            "search from a query and its kind, or from an open.spotify.com link. Wakes the TV "
            "and opens Spotify first."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "maxLength": 200},
                "kind": {"type": "string", "enum": ["track", "album", "artist", "playlist"]},
                "link": {"type": "string", "maxLength": 300},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "home_open_spotify",
        "description": "Wake the living room TV and open its Spotify app.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "home_youtube",
        "description": "Wake the living room TV and play a YouTube video from its link.",
        "inputSchema": {
            "type": "object",
            "properties": {"link": {"type": "string", "maxLength": 300}},
            "required": ["link"],
            "additionalProperties": False,
        },
    },
    {
        "name": "home_video",
        "description": (
            "Pause, resume, go to the next or previous video, or seek by seconds, in what "
            "plays on the living room TV."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "control": {
                    "type": "string",
                    "enum": ["pause", "resume", "next", "previous", "seek"],
                },
                "seconds": {"type": "integer", "minimum": -600, "maximum": 600},
            },
            "required": ["control"],
            "additionalProperties": False,
        },
    },
    {
        "name": "home_tv",
        "description": "Turn the living room TV on or off.",
        "inputSchema": {
            "type": "object",
            "properties": {"power": {"type": "string", "enum": ["on", "off"]}},
            "required": ["power"],
            "additionalProperties": False,
        },
    },
]
TOOL_NAMES = {tool["name"] for tool in TOOLS}
CHANGES = TOOL_NAMES - {"home_status"}
ARGUMENTS = {tool["name"]: set(tool["inputSchema"]["properties"]) for tool in TOOLS}
REQUIRED = {tool["name"]: set(tool["inputSchema"].get("required", [])) for tool in TOOLS}


@dataclass(slots=True)
class RateLimit:
    """At most ``limit`` events in any trailing ``window`` seconds."""

    limit: int
    window: float
    events: deque[float] = field(default_factory=deque)

    def admit(self, now: float) -> bool:
        while self.events and now - self.events[0] >= self.window:
            self.events.popleft()
        if len(self.events) >= self.limit:
            return False
        self.events.append(now)
        return True


def _result(value: dict[str, Any], *, is_error: bool = False) -> dict[str, Any]:
    result: dict[str, Any] = {
        "content": [{"type": "text", "text": json.dumps(value, separators=(",", ":"))}]
    }
    if is_error:
        result["isError"] = True
    else:
        result["structuredContent"] = value
    return result


def _rpc_error(identifier: object, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": identifier, "error": {"code": code, "message": message}}


class KeyHolder:
    def __init__(
        self,
        *,
        home: Home,
        clock: Callable[[], float] = time.monotonic,
        log: Callable[[str], None] = lambda line: print(line, file=sys.stderr, flush=True),
    ) -> None:
        self.home = home
        self.clock = clock
        self.log = log
        self._lock = asyncio.Lock()
        self._calls = RateLimit(CALLS_PER_MINUTE, 60)
        self._changes = RateLimit(CHANGES_PER_MINUTE, 60)

    def _run(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "home_status":
            return self.home.status()
        if name == "home_thermostat":
            return self.home.thermostat(
                low=arguments.get("low"),
                high=arguments.get("high"),
                target=arguments.get("target"),
                confirmed=arguments["confirmed"] is True,
            )
        if name == "home_volume":
            return self.home.volume(
                percent=arguments.get("percent"),
                step=arguments.get("step"),
                confirmed=arguments["confirmed"] is True,
            )
        if name == "home_music":
            return self.home.music(action=arguments["action"])
        if name == "home_play":
            return self.home.play(
                link=arguments.get("link"), query=arguments.get("query"), kind=arguments.get("kind")
            )
        if name == "home_open_spotify":
            return self.home.open_spotify()
        if name == "home_youtube":
            return self.home.youtube(link=arguments["link"])
        if name == "home_video":
            return self.home.video(control=arguments["control"], seconds=arguments.get("seconds"))
        return self.home.tv_power(power=arguments["power"])

    async def call(self, name: object, arguments: object) -> dict[str, Any]:
        tool = name if isinstance(name, str) and name in TOOL_NAMES else None
        try:
            if tool is None:
                raise HomeError("invalid_arguments", "There is no such home tool.")
            given = arguments if isinstance(arguments, dict) else {}
            if (
                not isinstance(arguments, dict | None)
                or set(given) - ARGUMENTS[tool]
                or REQUIRED[tool] - set(given)
            ):
                raise HomeError(
                    "invalid_arguments",
                    "Use only the tool's own arguments, all of the required ones.",
                )
            now = self.clock()
            if not self._calls.admit(now) or (tool in CHANGES and not self._changes.admit(now)):
                raise HomeError(
                    "rate_limited",
                    "Too many requests to the house just now. Try again in a minute.",
                )
            async with self._lock:
                value = await asyncio.to_thread(self._run, tool, given)
        except HomeError as refused:
            self.log(f"{tool or 'unknown'} {refused.code}")
            return _result({"code": refused.code, "message": refused.message}, is_error=True)
        self.log(f"{tool} ok")
        return _result(value)


class Session:
    def __init__(self, holder: KeyHolder) -> None:
        self.holder = holder
        self.ready = False

    async def handle(self, message: object) -> dict[str, Any] | None:
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            return _rpc_error(None, -32600, "Not a JSON-RPC 2.0 message.")
        method, identifier = message.get("method"), message.get("id")
        given = message.get("params")
        params: dict[str, Any] = given if isinstance(given, dict) else {}
        if identifier is None:
            if method == "notifications/initialized":
                self.ready = True
            return None
        if method == "initialize":
            asked = params.get("protocolVersion")
            return {
                "jsonrpc": "2.0",
                "id": identifier,
                "result": {
                    "protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[-1],
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "household-home", "version": "1.0.0"},
                },
            }
        if not self.ready:
            return _rpc_error(identifier, -32002, "Initialize first.")
        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": identifier, "result": {"tools": TOOLS}}
        if method == "tools/call":
            return {
                "jsonrpc": "2.0",
                "id": identifier,
                "result": await self.holder.call(params.get("name"), params.get("arguments")),
            }
        return _rpc_error(identifier, -32601, "No such method.")


async def _serve_connection(
    holder: KeyHolder, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> None:
    session = Session(holder)
    while True:
        line = await asyncio.wait_for(reader.readline(), MESSAGE_IDLE_SECONDS)
        if not line:
            return
        try:
            message = json.loads(line)
        except ValueError:
            message = None
        answer = await session.handle(message)
        if answer is not None:
            writer.write((json.dumps(answer, separators=(",", ":")) + "\n").encode("utf-8"))
            await writer.drain()


def check_socket_directory(directory: Path) -> None:
    """The bound directory must be the one the installer made for this service.

    Its source sits in the gateway's own state, so the gateway could swap it for a
    symlink or a directory of its own before the bind; either is refused here.
    """
    try:
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as error:
        raise SystemExit(f"refusing {directory}: {error.strerror}") from error
    try:
        metadata = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o2750:
        raise SystemExit(f"refusing {directory}: not this service's setgid 2750 directory")


def prepare_socket(path: Path) -> None:
    """Remove only a stale socket this uid left; refuse anything else at the path."""
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.geteuid():
        raise SystemExit(f"refusing to replace {path}: not a socket this service owns")
    os.unlink(path)


async def serve(holder: KeyHolder, path: Path) -> None:
    open_connections = 0

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        nonlocal open_connections
        if open_connections >= MAX_CONNECTIONS:
            writer.close()
            return
        open_connections += 1
        try:
            await asyncio.wait_for(_serve_connection(holder, reader, writer), CONNECTION_SECONDS)
        except (TimeoutError, asyncio.LimitOverrunError, ValueError, ConnectionError):
            pass
        finally:
            open_connections -= 1
            writer.close()
            with contextlib.suppress(ConnectionError):
                await writer.wait_closed()

    check_socket_directory(path.parent)
    prepare_socket(path)
    previous = os.umask(0o117)
    try:
        server = await asyncio.start_unix_server(handle, path=str(path), limit=MAX_MESSAGE_BYTES)
    finally:
        os.umask(previous)
    # The umask makes the socket 0660 and the setgid directory gives it the gateway's
    # group, so the gateway can connect and nobody else can.
    async with server:
        await server.serve_forever()
