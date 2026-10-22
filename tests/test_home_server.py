"""The home key holder's interface: MCP over a Unix socket, bounded, one call at a time.

The house behind it is a fake, so nothing reaches Home Assistant or the TV.
"""

from __future__ import annotations

import asyncio
import json
import sys
from collections.abc import Coroutine
from pathlib import Path
from typing import Any

import pytest

from household.home.actions import HomeError
from household.home.server import (
    TOOL_NAMES,
    KeyHolder,
    Session,
    check_socket_directory,
    prepare_socket,
    serve,
)


class FakeHome:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []

    def status(self) -> dict[str, Any]:
        self.calls.append(("status", {}))
        return {"thermostat": {"temperature": 71.7}}

    def thermostat(
        self, *, low: int | None, high: int | None, target: int | None, confirmed: bool
    ) -> dict[str, Any]:
        given = {"low": low, "high": high, "target": target, "confirmed": confirmed}
        self.calls.append(("thermostat", given))
        if low is not None and low < 62:
            raise HomeError(
                "out_of_range", "The thermostat can be set only within 62 to 80 degrees."
            )
        return {"thermostat": {"low": low, "high": high}}

    def volume(self, *, percent: int | None, step: str | None, confirmed: bool) -> dict[str, Any]:
        self.calls.append(("volume", {"percent": percent, "step": step, "confirmed": confirmed}))
        return {"tv": {"power": "on", "volume": percent}}

    def music(self, *, action: str) -> dict[str, Any]:
        self.calls.append(("music", {"action": action}))
        return {"music": {"state": "paused"}}

    def play(self, *, link: str | None, query: str | None, kind: str | None) -> dict[str, Any]:
        self.calls.append(("play", {"link": link, "query": query, "kind": kind}))
        return {"music": {"state": "playing"}}

    def open_spotify(self) -> dict[str, Any]:
        self.calls.append(("open_spotify", {}))
        return {"tv": "on", "spotify": "open"}

    def youtube(self, *, link: str) -> dict[str, Any]:
        self.calls.append(("youtube", {"link": link}))
        return {"youtube": {"playing": True}}

    def video(self, *, control: str, seconds: int | None) -> dict[str, Any]:
        self.calls.append(("video", {"control": control, "seconds": seconds}))
        return {"video": {"playing": True}}

    def tv_power(self, *, power: str) -> dict[str, Any]:
        self.calls.append(("tv_power", {"power": power}))
        return {"tv": power}


def session(clock: list[float] | None = None) -> tuple[Session, FakeHome, list[str]]:
    home = FakeHome()
    log: list[str] = []
    now = clock or [1000.0]
    holder = KeyHolder(home=home, clock=lambda: now[0], log=log.append)  # type: ignore[arg-type]
    return Session(holder), home, log


def run(coroutine: Coroutine[object, object, dict[str, Any] | None]) -> dict[str, Any]:
    answer = asyncio.run(coroutine)
    assert answer is not None
    return answer


def initialized(sess: Session) -> None:
    answer = run(
        sess.handle(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-11-25"},
            }
        )
    )
    assert answer["result"]["protocolVersion"] == "2025-11-25"
    assert answer["result"]["capabilities"] == {"tools": {}}
    initialized_note = {"jsonrpc": "2.0", "method": "notifications/initialized"}
    assert asyncio.run(sess.handle(initialized_note)) is None


def call(
    sess: Session, name: str, arguments: dict[str, Any] | None = None, identifier: int = 2
) -> dict[str, Any]:
    answer = run(
        sess.handle(
            {
                "jsonrpc": "2.0",
                "id": identifier,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments or {}},
            }
        )
    )
    result: dict[str, Any] = answer["result"]
    return result


def test_the_tools_are_the_house_actions_and_nothing_else() -> None:
    sess, _, _ = session()
    initialized(sess)
    listed = run(sess.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}))["result"][
        "tools"
    ]
    assert (
        {tool["name"] for tool in listed}
        == TOOL_NAMES
        == {
            "home_status",
            "home_thermostat",
            "home_volume",
            "home_music",
            "home_play",
            "home_open_spotify",
            "home_youtube",
            "home_video",
            "home_tv",
        }
    )
    assert all(tool["inputSchema"]["additionalProperties"] is False for tool in listed)


def test_a_call_runs_the_action_and_answers_with_what_it_read_back() -> None:
    sess, home, log = session()
    initialized(sess)
    result = call(sess, "home_thermostat", {"low": 70, "high": 75, "confirmed": True})
    assert result["structuredContent"] == {"thermostat": {"low": 70, "high": 75}}
    assert home.calls == [
        ("thermostat", {"low": 70, "high": 75, "target": None, "confirmed": True})
    ]
    assert log == ["home_thermostat ok"]


def test_a_refusal_is_a_coded_tool_error() -> None:
    sess, _, log = session()
    initialized(sess)
    result = call(sess, "home_thermostat", {"low": 50, "high": 75, "confirmed": True})
    assert result["isError"] is True
    assert json.loads(result["content"][0]["text"]) == {
        "code": "out_of_range",
        "message": "The thermostat can be set only within 62 to 80 degrees.",
    }
    assert log == ["home_thermostat out_of_range"]


@pytest.mark.parametrize(
    ("name", "arguments", "action", "given"),
    [
        (
            "home_play",
            {"query": "Shake It Off Taylor Swift", "kind": "track"},
            "play",
            {"link": None, "query": "Shake It Off Taylor Swift", "kind": "track"},
        ),
        (
            "home_play",
            {"link": "https://open.spotify.com/track/5Q0Nhxo0l2bP3pNjpGJwV1"},
            "play",
            {
                "link": "https://open.spotify.com/track/5Q0Nhxo0l2bP3pNjpGJwV1",
                "query": None,
                "kind": None,
            },
        ),
        ("home_open_spotify", {}, "open_spotify", {}),
        (
            "home_thermostat",
            {"target": 73, "confirmed": False},
            "thermostat",
            {"low": None, "high": None, "target": 73, "confirmed": False},
        ),
        (
            "home_youtube",
            {"link": "https://youtu.be/n0FBb6hnwTo"},
            "youtube",
            {"link": "https://youtu.be/n0FBb6hnwTo"},
        ),
        ("home_video", {"control": "pause"}, "video", {"control": "pause", "seconds": None}),
        (
            "home_video",
            {"control": "seek", "seconds": -30},
            "video",
            {"control": "seek", "seconds": -30},
        ),
        (
            "home_volume",
            {"step": "down", "confirmed": False},
            "volume",
            {"percent": None, "step": "down", "confirmed": False},
        ),
    ],
)
def test_each_music_tool_reaches_its_action_with_only_what_was_given(
    name: str, arguments: dict[str, Any], action: str, given: dict[str, Any]
) -> None:
    sess, home, log = session()
    initialized(sess)
    assert "isError" not in call(sess, name, arguments)
    assert home.calls == [(action, given)]
    assert log == [f"{name} ok"]


@pytest.mark.parametrize(
    ("name", "arguments"),
    [
        ("home_volume", {"percent": 30, "louder": True}),
        ("home_play", {"query": "Shake It Off", "kind": "track", "volume": 70}),
        ("home_youtube", {}),
        ("home_video", {"seconds": 30}),
        ("home_open_spotify", {"play": True}),
        ("home_lock_front_door", {}),
        ("home_status", {"entity_id": "lock.front_door"}),
        ("home_thermostat", {"target": 73}),
        ("home_thermostat", {"target": 73, "hvac_mode": "heat_cool", "confirmed": True}),
    ],
)
def test_unknown_tools_and_arguments_are_refused_before_the_house(
    name: str, arguments: dict[str, Any]
) -> None:
    sess, home, _ = session()
    initialized(sess)
    result = call(sess, name, arguments)
    assert result["isError"] is True
    assert json.loads(result["content"][0]["text"])["code"] == "invalid_arguments"
    assert home.calls == []


def test_a_call_before_initialize_is_refused() -> None:
    sess, home, _ = session()
    answer = run(
        sess.handle(
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "home_status"}}
        )
    )
    assert answer["error"]["code"] == -32002
    assert home.calls == []


def test_changes_to_the_house_have_their_own_smaller_budget() -> None:
    clock = [1000.0]
    sess, home, _ = session(clock)
    initialized(sess)
    for identifier in range(10):
        assert "isError" not in call(
            sess, "home_volume", {"percent": 20, "confirmed": False}, identifier + 2
        )
    refused = call(sess, "home_volume", {"percent": 20, "confirmed": False}, 20)
    assert json.loads(refused["content"][0]["text"])["code"] == "rate_limited"
    assert "isError" not in call(sess, "home_status", {}, 21), "reading still works"
    clock[0] += 61
    assert "isError" not in call(sess, "home_volume", {"percent": 20, "confirmed": False}, 22)
    assert len([c for c in home.calls if c[0] == "volume"]) == 11


@pytest.mark.skipif(
    sys.platform == "win32", reason="asyncio has no Unix sockets on Windows; CI on Linux runs it"
)
def test_the_socket_answers_one_session(tmp_path: Path) -> None:
    home = FakeHome()
    holder = KeyHolder(home=home, clock=lambda: 1000.0, log=lambda _line: None)  # type: ignore[arg-type]
    directory = tmp_path / "home"
    directory.mkdir()
    directory.chmod(0o2750)
    path = directory / "home.sock"

    async def scenario() -> dict[str, Any]:
        server = asyncio.create_task(serve(holder, path))
        for _ in range(50):
            if path.exists():
                break
            await asyncio.sleep(0.02)
        reader, writer = await asyncio.open_unix_connection(str(path))
        for message in (
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-11-25"},
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "home_status", "arguments": {}},
            },
        ):
            writer.write((json.dumps(message) + "\n").encode())
        await writer.drain()
        await reader.readline()
        answer: dict[str, Any] = json.loads(await reader.readline())
        writer.close()
        server.cancel()
        return answer

    answer = run(scenario())
    assert answer["result"]["structuredContent"] == {"thermostat": {"temperature": 71.7}}
    assert path.stat().st_mode & 0o777 == 0o660


@pytest.mark.skipif(
    sys.platform == "win32", reason="POSIX ownership and modes; CI on Linux runs it"
)
def test_a_file_planted_at_the_socket_path_is_never_replaced(tmp_path: Path) -> None:
    planted = tmp_path / "home.sock"
    planted.write_text("not a socket")
    with pytest.raises(SystemExit):
        prepare_socket(planted)
    assert planted.read_text() == "not a socket"


@pytest.mark.skipif(
    sys.platform == "win32", reason="POSIX ownership and modes; CI on Linux runs it"
)
@pytest.mark.parametrize("planted", ["symlink", "open mode", "plain directory"])
def test_a_socket_directory_the_installer_did_not_make_is_refused(
    tmp_path: Path, planted: str
) -> None:
    real = tmp_path / "real"
    real.mkdir()
    real.chmod(0o2750)
    check_socket_directory(real)
    candidate = tmp_path / "candidate"
    if planted == "symlink":
        candidate.symlink_to(real, target_is_directory=True)
    else:
        candidate.mkdir()
        candidate.chmod(0o2777 if planted == "open mode" else 0o750)
    with pytest.raises(SystemExit):
        check_socket_directory(candidate)
