#!/usr/bin/env python3
"""Voicebox - the household assistant's local speech service.

Voicebox is the name this repository gives to the managed local text-to-speech
service that runs on the Mac. It is local by construction: it binds to loopback
unless it is explicitly told to bind to a private address, it refuses to bind to
every interface, and it never reaches a paid speech service, as a fallback or
otherwise. Which synthesis engine it drives is deliberately not decided here.
Run scripts/macos/voicebox-benchmark.sh on the actual Mac and set
VOICEBOX_ENGINE from what the measurements say.

Standard library only, on purpose: this runs under launchd on a machine whose
only job is to build and to speak, and a dependency tree is a thing that breaks
at three in the morning.

Subcommands:

    serve       run the HTTP service (this is what launchd starts)
    engines     print the engine table as JSON
    phrase      print the fixed preview phrase, so shell callers share one copy
    synth       synthesise one phrase to a file with one engine
    selfcheck   assert the things that would silently break; needs no macOS

Environment:

    VOICEBOX_HOST           default 127.0.0.1
    VOICEBOX_PORT           default 8787
    VOICEBOX_ENGINE         engine name; unset means "not chosen yet"
    VOICEBOX_ALLOW_PRIVATE  1 to permit binding a private (RFC 1918) address
    VOICEBOX_MAX_CHARS      default 2000

NOT YET RUN ON APPLE HARDWARE for anything that shells out to a speech engine.
The service, its health endpoint, its bind policy and its request validation are
covered by selfcheck, which does run on Windows and in continuous integration.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import TypedDict

VERSION = "0.1.0"


class Engine(TypedDict):
    """One engine's entry in the table."""

    argv: list[str]
    stdin: bool
    note: str


EngineTable = dict[str, Engine]

# The fixed preview phrase. Every document, script and benchmark uses this one
# so that two measurements are comparable. Do not reword it.
PREVIEW_PHRASE = (
    "Good morning. I have reviewed your schedule and you have about an hour "
    "free before your next appointment."
)

# Candidate engines.
#
# argv is a template. {text} is replaced with the phrase, {out} with the output
# path, and ${VAR} with an environment variable, which is how an engine that
# needs a model file finds it without a special case in this file.
# stdin means the engine reads the phrase from standard input instead of argv.
#
# An engine that takes the phrase in argv takes it as a whole element with a
# bare -- immediately before it. The phrase arrives from a request, so without
# that separator a sentence beginning with a dash is read by the engine as an
# option: `say --input-file=/etc/passwd` synthesises a file nobody asked for and
# returns it to the caller as audio. The self-check holds every row to it. That
# say honours -- is its documented option parsing and has NOT been run on Apple
# hardware.
#
# Nothing here is a recommendation. The argv of every engine other than say is
# written from its documented interface and has NOT been run on Apple hardware;
# check each one against the version you actually install, and correct the row
# here if it has moved.
DEFAULT_ENGINES: EngineTable = {
    "say": {
        "argv": ["say", "--data-format=LEI16@22050", "-o", "{out}", "--", "{text}"],
        "stdin": False,
        "note": "macOS built-in; always present, needs no install",
    },
    "piper": {
        "argv": ["piper", "--model", "${VOICEBOX_PIPER_MODEL}", "--output_file", "{out}"],
        "stdin": True,
        "note": "needs VOICEBOX_PIPER_MODEL pointing at a .onnx voice",
    },
    "espeak-ng": {
        "argv": ["espeak-ng", "-w", "{out}", "--stdin"],
        "stdin": True,
        "note": "formant synthesis; fast and small, and it sounds like it",
    },
}

_TEMPLATE_REF = re.compile(r"\$\{([A-Z0-9_]+)\}|\{text\}|\{out\}")


class VoiceboxError(Exception):
    """Anything a caller did wrong, or an engine that is not usable."""


def expand_argv(
    argv: list[str], text: str, out_path: str, environ: dict[str, str] | os._Environ[str]
) -> list[str]:
    """Fill {text}, {out} and ${ENV_VAR} in one engine's argv.

    One pass over each template item, so nothing substituted in is ever scanned
    again. The caller's text arrives over the network: a request whose text
    reads `my home is ${HOME}` or `write to {out}` has to reach the engine as
    those literal characters and not as a template this process fills in from
    its own environment.
    """

    def substitute(match: re.Match[str]) -> str:
        name = match.group(1)
        if name is None:
            return text if match.group(0) == "{text}" else out_path
        value = environ.get(name)
        if value is None:
            raise VoiceboxError(
                f"engine argument needs ${{{name}}} and it is not set in the environment"
            )
        return value

    return [_TEMPLATE_REF.sub(substitute, item) for item in argv]


def is_bindable_host(host: str, allow_private: bool) -> bool:
    """Loopback always, a private address only when asked, everything else never.

    A private address is architecture rather than permission. The Linux VPS is
    the caller that will matter: the design has it reaching Voicebox on the Mac
    across the private network, so a service that could only ever bind loopback
    would have to be reopened to make that work. Nothing in this repository sets
    that path up yet, and the task that does owns it; until then the default is
    loopback and it takes VOICEBOX_ALLOW_PRIVATE=1 to go further. The capability
    is here so the design is not blocked, not because anything uses it today.

    The refusal is the rest of the point. Voicebox speaks household conversation
    out loud, so a wildcard address and a public address are refused outright:
    binding every interface is how a household service reaches the internet by
    accident.
    """
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    if address.is_unspecified:  # 0.0.0.0 and ::
        return False
    if address.is_loopback:
        return True
    if address.is_private and not address.is_link_local:
        return allow_private
    return False


def synthesise(
    engine_name: str,
    text: str,
    out_path: str,
    engines: EngineTable,
    environ: dict[str, str] | os._Environ[str],
) -> None:
    """Run one engine once. Raises VoiceboxError with something a human can read."""
    spec = engines.get(engine_name)
    if spec is None:
        known = ", ".join(sorted(engines))
        raise VoiceboxError(f"unknown engine {engine_name!r}; known engines are {known}")
    argv = expand_argv(spec["argv"], text, out_path, environ)
    if shutil.which(argv[0]) is None:
        raise VoiceboxError(f"engine {engine_name!r} needs {argv[0]!r} on PATH and it is not there")
    stdin_text = text if spec["stdin"] else None
    completed = subprocess.run(
        argv,
        input=stdin_text,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip().splitlines()
        tail = detail[-1] if detail else "no output"
        raise VoiceboxError(f"engine {engine_name!r} exited {completed.returncode}: {tail}")
    if not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
        raise VoiceboxError(f"engine {engine_name!r} exited 0 but wrote no audio to {out_path}")


def engine_health(
    engine: str,
    engines: EngineTable,
    environ: dict[str, str] | os._Environ[str],
) -> tuple[HTTPStatus, str, str | None]:
    """Whether the chosen engine could speak, and why not when it could not.

    Expanding the argv is part of the question. An engine whose template needs a
    variable this service was not given is unusable however present its binary
    is, and calling that ok sends the owner away satisfied from a service where
    every request is going to fail.
    """
    if not engine:
        return HTTPStatus.SERVICE_UNAVAILABLE, "no-engine", None
    if engine not in engines:
        return HTTPStatus.SERVICE_UNAVAILABLE, "unknown-engine", None
    try:
        argv = expand_argv(engines[engine]["argv"], "", "", environ)
    except VoiceboxError as error:
        return HTTPStatus.SERVICE_UNAVAILABLE, "engine-misconfigured", str(error)
    if shutil.which(argv[0]) is None:
        return HTTPStatus.SERVICE_UNAVAILABLE, "engine-missing", f"{argv[0]} is not on PATH"
    return HTTPStatus.OK, "ok", None


class ServerState(TypedDict):
    """What a running service carries: where it listens and what it speaks with."""

    host: str
    port: int
    engine: str
    engines: EngineTable
    max_chars: int
    started: float


class VoiceboxServer(ThreadingHTTPServer):
    """A server that declares the state the handler reads off it."""

    daemon_threads = True
    allow_reuse_address = True
    voicebox: ServerState


class Handler(BaseHTTPRequestHandler):
    """The whole HTTP surface: GET /health and POST /speak. Nothing else."""

    server: VoiceboxServer
    server_version = f"voicebox/{VERSION}"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        # Household conversation passes through this process. The access log
        # records the shape of a request and never its content.
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        sys.stderr.write(f"{stamp} voicebox {self.address_string()} {fmt % args}\n")

    def _respond(
        self,
        status: HTTPStatus,
        payload: dict[str, object] | None = None,
        body: bytes | None = None,
        content_type: str = "application/json",
    ) -> None:
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
        body = body or b""
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path.split("?", 1)[0] != "/health":
            self._respond(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        state = self.server.voicebox
        status, health, detail = engine_health(state["engine"], state["engines"], os.environ)
        self._respond(
            status,
            {
                "status": health,
                "detail": detail,
                "version": VERSION,
                "engine": state["engine"] or None,
                "engines": sorted(state["engines"]),
                "host": state["host"],
                "port": state["port"],
                "pid": os.getpid(),
                "uptime_s": round(time.monotonic() - state["started"], 1),
            },
        )

    def do_POST(self) -> None:
        if self.path.split("?", 1)[0] != "/speak":
            self._respond(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        state = self.server.voicebox
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            # The announced body has not been read, so this connection can no
            # longer be trusted to start the next request at a request line.
            self.close_connection = True
            self._respond(HTTPStatus.BAD_REQUEST, {"error": "bad Content-Length"})
            return
        if length <= 0 or length > 64 * 1024:
            self.close_connection = True
            self._respond(HTTPStatus.BAD_REQUEST, {"error": "body must be 1 byte to 64 KiB"})
            return
        try:
            request = json.loads(self.rfile.read(length).decode("utf-8"))
            text = request["text"]
            if not isinstance(text, str):
                raise TypeError
        except (ValueError, KeyError, TypeError, UnicodeDecodeError):
            self._respond(
                HTTPStatus.BAD_REQUEST, {"error": "body must be an object with a text string"}
            )
            return
        text = text.strip()
        if not text:
            self._respond(HTTPStatus.BAD_REQUEST, {"error": "text is empty"})
            return
        max_chars = state["max_chars"]
        if len(text) > max_chars:
            self._respond(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                {"error": f"text is longer than {max_chars} characters"},
            )
            return
        if not state["engine"]:
            self._respond(
                HTTPStatus.SERVICE_UNAVAILABLE,
                {"error": "no engine chosen; run voicebox-benchmark.sh and set VOICEBOX_ENGINE"},
            )
            return
        directory = tempfile.mkdtemp(prefix="voicebox-")
        out_path = os.path.join(directory, "speech.wav")
        try:
            synthesise(state["engine"], text, out_path, state["engines"], os.environ)
            with open(out_path, "rb") as handle:
                audio = handle.read()
        except VoiceboxError as error:
            self._respond(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(error)})
            return
        finally:
            shutil.rmtree(directory, ignore_errors=True)
        self.log_message("spoke %d chars with %s", len(text), state["engine"])
        self._respond(HTTPStatus.OK, body=audio, content_type="audio/wav")


def make_server(
    host: str,
    port: int,
    engine: str,
    engines: EngineTable,
    max_chars: int,
    allow_private: bool,
) -> VoiceboxServer:
    """Bind the service, or refuse with a reason."""
    if not is_bindable_host(host, allow_private):
        raise VoiceboxError(
            f"refusing to bind {host!r}. Voicebox binds loopback, or a private address "
            "when VOICEBOX_ALLOW_PRIVATE=1, and never every interface."
        )
    family = socket.AF_INET6 if ":" in host else socket.AF_INET

    class Server(VoiceboxServer):
        address_family = family

    server = Server((host, port), Handler)
    server.voicebox = {
        "host": host,
        "port": server.server_address[1],
        "engine": engine,
        "engines": engines,
        "max_chars": max_chars,
        "started": time.monotonic(),
    }
    return server


def cmd_serve(args: argparse.Namespace) -> int:
    server = make_server(
        args.host,
        args.port,
        os.environ.get("VOICEBOX_ENGINE", "").strip(),
        DEFAULT_ENGINES,
        int(os.environ.get("VOICEBOX_MAX_CHARS", "2000")),
        os.environ.get("VOICEBOX_ALLOW_PRIVATE") == "1",
    )
    state = server.voicebox
    chosen = state["engine"] or "not chosen"
    sys.stderr.write(
        f"voicebox {VERSION} listening on {state['host']}:{state['port']} engine={chosen}\n"
    )
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def cmd_engines(args: argparse.Namespace) -> int:
    json.dump(DEFAULT_ENGINES, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def cmd_phrase(args: argparse.Namespace) -> int:
    print(PREVIEW_PHRASE)
    return 0


def cmd_synth(args: argparse.Namespace) -> int:
    """Synthesise once and report what it cost, one key=value per line.

    The timing is taken around the engine call inside this process rather than
    around this process from a shell, so that the number is the engine's and
    not the interpreter's startup.
    """
    binary = ""
    if args.engine in DEFAULT_ENGINES:
        argv = expand_argv(DEFAULT_ENGINES[args.engine]["argv"], "", "", os.environ)
        binary = shutil.which(argv[0]) or ""
    started = time.monotonic()
    synthesise(args.engine, args.text, args.out, DEFAULT_ENGINES, os.environ)
    elapsed = time.monotonic() - started
    print(f"seconds={elapsed:.3f}")
    print(f"bytes={os.path.getsize(args.out)}")
    print(f"binary={binary}")
    print(f"out={args.out}")
    return 0


def _check_bind_policy() -> None:
    for host in ("0.0.0.0", "::", "8.8.8.8", "not-an-address", ""):
        assert not is_bindable_host(host, allow_private=True), host
    for host in ("127.0.0.1", "::1"):
        assert is_bindable_host(host, allow_private=False), host
    assert not is_bindable_host("192.168.1.10", allow_private=False)
    assert is_bindable_host("192.168.1.10", allow_private=True)

    # Enforced at the point it matters, not only in the predicate.
    try:
        make_server("0.0.0.0", 0, "", DEFAULT_ENGINES, 2000, allow_private=True)
        raise AssertionError("0.0.0.0 must be refused")
    except VoiceboxError:
        pass


def _check_engine_table() -> None:
    argv = expand_argv(["say", "-o", "{out}", "{text}"], "hello", "/tmp/a.wav", {})
    assert argv == ["say", "-o", "/tmp/a.wav", "hello"], argv
    filled = expand_argv(["x", "${M}"], "t", "o", {"M": "/voices/en.onnx"})
    assert filled == ["x", "/voices/en.onnx"], filled
    try:
        expand_argv(["x", "${M}"], "t", "o", {})
        raise AssertionError("a missing model path must not pass silently")
    except VoiceboxError:
        pass

    # The caller's text is data and never a template. Everything a request
    # carries has to survive expansion exactly as it was sent, or a request can
    # read this process's environment back out of it as audio.
    spoken = expand_argv(
        ["say", "-o", "{out}", "{text}"],
        "my home is ${HOME}, write to {out}",
        "/tmp/a.wav",
        {"HOME": "/Users/someone"},
    )
    assert spoken == ["say", "-o", "/tmp/a.wav", "my home is ${HOME}, write to {out}"], spoken

    for name, spec in DEFAULT_ENGINES.items():
        argv = spec["argv"]
        assert argv, name
        assert any("{out}" in item for item in argv), f"{name} never writes its output"
        assert spec["stdin"] or any("{text}" in item for item in argv), name

        # The phrase comes from a request. An engine that takes it in argv has
        # to take it whole and after --, or an engine parses a sentence that
        # starts with a dash as an option.
        for position, item in enumerate(argv):
            if "{text}" not in item:
                continue
            assert item == "{text}", f"{name} buries the phrase inside {item!r}"
            assert position and argv[position - 1] == "--", (
                f"{name} passes the phrase as argv[{position}] with no -- before it"
            )

    try:
        synthesise("nope", "hi", "/tmp/x.wav", DEFAULT_ENGINES, {})
        raise AssertionError("an unknown engine must be refused")
    except VoiceboxError as error:
        assert "unknown engine" in str(error)


def _check_health_answers() -> None:
    needs_a_variable: EngineTable = {
        "needs-a-variable": {
            "argv": ["true", "--model", "${VOICEBOX_NO_SUCH_VARIABLE}", "{out}"],
            "stdin": True,
            "note": "selfcheck only",
        }
    }
    assert engine_health("", DEFAULT_ENGINES, {})[1] == "no-engine"
    assert engine_health("nope", DEFAULT_ENGINES, {})[1] == "unknown-engine"

    # An engine the job description cannot actually run must never read ok:
    # this is the one that used to, because only the unexpanded argv[0] was
    # looked up on PATH, and every request to it then failed with a 500.
    status, health, detail = engine_health("needs-a-variable", needs_a_variable, {})
    assert status == HTTPStatus.SERVICE_UNAVAILABLE, status
    assert health == "engine-misconfigured", health
    assert detail is not None and "VOICEBOX_NO_SUCH_VARIABLE" in detail, detail


def _check_caller_text_is_never_an_option() -> None:
    """A request whose text starts with a dash is spoken, not parsed.

    Through the real endpoint and a real subprocess, with an engine that parses
    its own command line the way a speech engine does: an option for the output
    path, then -- , then the phrase. What this proves is that caller text
    survives the whole path from request body to argv element without being
    read as an option by something downstream.

    It is not the guard on DEFAULT_ENGINES. This engine's own argv carries the
    separator literally, so removing -- from a shipped engine row leaves this
    check passing. The structural assertion in _check_engine_table is what
    fails in that case, and it is the one to keep if these ever diverge.
    """
    reader = (
        "import pathlib, sys\n"
        "args = sys.argv[1:]\n"
        "out = args[args.index('-o') + 1]\n"
        "phrase = ' '.join(args[args.index('--') + 1 :])\n"
        "pathlib.Path(out).write_bytes(phrase.encode())\n"
    )
    engines: EngineTable = {
        "reader": {
            "argv": [sys.executable, "-c", reader, "-o", "{out}", "--", "{text}"],
            "stdin": False,
            "note": "selfcheck only: writes back the phrase it was handed",
        }
    }
    server = make_server("127.0.0.1", 0, "reader", engines, 2000, allow_private=False)
    port = server.voicebox["port"]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for hostile in ("--input-file=/etc/passwd", "-o", "--output-file=/tmp/taken.plist"):
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/speak",
                data=json.dumps({"text": hostile}).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                spoken = response.read().decode("utf-8")
            assert spoken == hostile, spoken
    finally:
        server.shutdown()
        server.server_close()


def _check_live_server() -> None:
    server = make_server("127.0.0.1", 0, "", DEFAULT_ENGINES, 2000, allow_private=False)
    port = server.voicebox["port"]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base = f"http://127.0.0.1:{port}"
        try:
            urllib.request.urlopen(f"{base}/health", timeout=5)
            raise AssertionError("health must report 503 while no engine is chosen")
        except urllib.error.HTTPError as error:
            assert error.code == 503, error.code
            health = json.loads(error.read())
            assert health["status"] == "no-engine", health
            assert health["detail"] is None, health
            assert health["version"] == VERSION
            assert health["engine"] is None
            assert "say" in health["engines"]

        def post(body: bytes) -> int:
            request = urllib.request.Request(
                f"{base}/speak", data=body, headers={"Content-Type": "application/json"}
            )
            try:
                urllib.request.urlopen(request, timeout=5)
            except urllib.error.HTTPError as error:
                return error.code
            return 200

        assert post(b"not json") == 400
        assert post(b'{"text": ""}') == 400
        assert post(b'{"nottext": "x"}') == 400
        assert post(b'{"text": "' + b"x" * 3000 + b'"}') == 413
        # A well formed request with no engine chosen fails loudly, not quietly.
        assert post(b'{"text": "hello"}') == 503

        try:
            urllib.request.urlopen(f"{base}/anything-else", timeout=5)
            raise AssertionError("an unknown path must 404")
        except urllib.error.HTTPError as error:
            assert error.code == 404
    finally:
        server.shutdown()
        server.server_close()


def cmd_selfcheck(args: argparse.Namespace) -> int:
    """Assert the things whose failure would be silent. Runs anywhere."""
    # The preview phrase is fixed by the brief. If this fails, two benchmark
    # runs are no longer comparable with each other.
    assert PREVIEW_PHRASE == (
        "Good morning. I have reviewed your schedule and you have about an "
        "hour free before your next appointment."
    ), "the preview phrase changed"

    _check_bind_policy()
    _check_engine_table()
    _check_health_answers()
    _check_caller_text_is_never_an_option()
    _check_live_server()

    print("voicebox selfcheck passed")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="voicebox.py",
        description="Voicebox - the household assistant's local speech service.",
        allow_abbrev=False,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    serve = sub.add_parser("serve", help="run the HTTP service")
    serve.add_argument("--host", default=os.environ.get("VOICEBOX_HOST", "127.0.0.1"))
    serve.add_argument("--port", type=int, default=int(os.environ.get("VOICEBOX_PORT", "8787")))
    serve.set_defaults(func=cmd_serve)

    sub.add_parser("engines", help="print the engine table").set_defaults(func=cmd_engines)
    sub.add_parser("phrase", help="print the fixed preview phrase").set_defaults(func=cmd_phrase)
    sub.add_parser("selfcheck", help="assert the invariants").set_defaults(func=cmd_selfcheck)

    synth = sub.add_parser("synth", help="synthesise one phrase to a file")
    synth.add_argument("--engine", required=True)
    synth.add_argument("--out", required=True)
    synth.add_argument("--text", default=PREVIEW_PHRASE)
    synth.set_defaults(func=cmd_synth)

    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except VoiceboxError as error:
        sys.stderr.write(f"voicebox: {error}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
