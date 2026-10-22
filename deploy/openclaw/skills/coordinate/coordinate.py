#!/usr/bin/env python3
"""Say something to the other assistant, in front of both people.

`ask` writes a request into the gateway's own state directory and waits for the host
relay to answer it. The relay posts the text to the household group and only then
hands it to the other assistant, so there is no way to use this to say something the
people cannot read, and nothing here can send anywhere else.

Four results come back, and every one of them prints the `request_id`. There are
four because there are only ever four things to know about whether the family read
your words, and that is the only thing that decides what you do next:

* `relayed` - posted in the group and handed to the other assistant.
* `refused` - a guard said no and **the group never saw it**. `reason` says which:
  nobody has addressed an assistant in the group since the last stop; this assistant
  has already said its two things in the current turn; either person said "stop"; or
  the off switch is off. A refusal is the answer. Do not rephrase it and try again.
* `unsent` - **the group never saw it**, and we know that rather than assume it:
  nothing said no, the send did not happen, or we took the request back before
  anyone carried it. You are free to say it yourself in the group, in your own words.
* `unconfirmed` - **we cannot tell you whether the group saw it.** The relay may
  still be working, it may have posted and failed to hand them over, or the answer
  may have aged out. Never send the same text again. Look in the group before you say
  anything about it, and say only what you find there.

`reason` and `detail` say more than the status does, and they are worth reading, but
the status is the part to act on. It never claims more than the relay established.

`check` prints the relay's answer to an earlier `ask`, in the same four shapes.
Reading does not spend it: the same `request_id` gives the same answer every time,
while the relay still has it.

    coordinate.py check <request_id>

Only the standard library: the gateway image has no package manager and is never
rebuilt on the box.
"""

import argparse
import json
import os
import time
import uuid
from pathlib import Path

HOME = Path(os.environ.get("OPENCLAW_HOME", "/home/node"))
OUTBOX = HOME / ".openclaw/workspace/coordination-outbox"

# The relay ticks every fifteen seconds and the peer's turn is not waited on, so a
# minute is generous. Timing out here means the daemon is not running, not that the
# message was refused.
WAIT_SECONDS = 60
POLL_SECONDS = 2


def ask(text: str) -> int:
    request_id = uuid.uuid4().hex
    OUTBOX.mkdir(parents=True, exist_ok=True)
    result_path = OUTBOX / f"{request_id}.result.json"
    # Written beside the final name and moved into place, so the daemon never reads a
    # half-written request on a tick that lands mid-write.
    staging = OUTBOX / f"{request_id}.json.partial"
    staging.write_text(json.dumps({"text": text}), encoding="utf-8")
    request = OUTBOX / f"{request_id}.json"
    staging.rename(request)

    deadline = time.monotonic() + WAIT_SECONDS
    while True:
        result = _answer(result_path)
        if result is None and time.monotonic() >= deadline:
            result = _gave_up(request, result_path, request_id)
        if result is not None:
            return _report(result, request_id)
        time.sleep(POLL_SECONDS)


def check(request_id: str) -> int:
    """The relay's answer to an `ask` that gave up waiting for it."""
    result = _answer(OUTBOX / f"{request_id}.result.json") or _still_unknown(request_id)
    return _report(result, request_id)


def _report(result: dict[str, str], request_id: str) -> int:
    print(json.dumps({"request_id": request_id, **result}, indent=2))
    return 0 if result.get("status") == "relayed" else 1


def _answer(result_path: Path) -> dict[str, str] | None:
    """What the relay wrote back, if it has written anything yet.

    Reading it does not take it. An answer destroyed by being read once would turn a
    known outcome back into `unconfirmed` for anyone who asked twice, so nothing here
    ever removes one; the relay ages them out.

    The relay puts an answer in place with a rename, so a partial read should not be
    possible. Anything unreadable is still treated as not-yet rather than raised,
    because this is polled in a loop and one bad read is a reason to look again, not
    to hand the assistant a traceback where it expected a status.
    """
    try:
        raw = result_path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError):
        return None
    try:
        answer: dict[str, str] = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return answer


def _gave_up(request: Path, result_path: Path, request_id: str) -> dict[str, str]:
    """Nobody answered in time, so take the request back, or find out we cannot.

    Unlinking is atomic and the relay claims a request by unlinking it too, so exactly
    one of the two of us gets it. Winning it here means it was never carried and the
    group never saw the words. Losing it means the relay has them, and it claims before
    it posts, so they may be in the group already; the answer that says which is the
    one the relay writes, and it may have landed while we were racing for the unlink.
    """
    try:
        request.unlink()
    except FileNotFoundError:
        return _answer(result_path) or _still_unknown(request_id)
    withdrawn = {
        "status": "unsent",
        "reason": "the coordination relay did not answer",
        "detail": "the request was withdrawn, so the group never saw it. You are free "
        "to say it yourself in the group, in your own words.",
    }
    # Written down rather than only printed. The relay will never write an answer for
    # a request it did not get, so without this a later `check` would find nothing and
    # report `unconfirmed` - and an outcome the relay established would have decayed
    # into one it did not, which is the opposite instruction.
    result_path.write_text(json.dumps(withdrawn), encoding="utf-8")
    return withdrawn


def _still_unknown(request_id: str) -> dict[str, str]:
    """No answer on disk, which is not the same as knowing nothing happened.

    Reached when the relay holds the request and has not written back yet, and also
    when it wrote back and the answer has since aged out. Those are different stories
    and the skill cannot tell them apart from here, so it claims neither: the one
    thing true of both is that whether the group saw the words is unknown, and the
    behaviour that follows from it is the same either way.

    An earlier version called this `in_flight` and asserted the relay still had them,
    which quietly became false an hour later when the answer was pruned, turning a
    known outcome into the opposite instruction.
    """
    return {
        "status": "unconfirmed",
        "reason": "the coordination relay has not left an answer for this request",
        "detail": "it may still be carrying them, or it may have answered and the "
        "answer has since aged out. They may already be in the group. Do not send "
        f"them again. `coordinate.py check {request_id}` again shortly if the relay "
        "may still be working; otherwise look in the group and say only what you "
        "find there.",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    asking = subcommands.add_parser("ask", help="say this to the other assistant")
    asking.add_argument("text", help="exactly what to say, in full, as the group will see it")
    checking = subcommands.add_parser("check", help="how an earlier ask turned out")
    checking.add_argument("request_id", help="the request_id that ask printed")
    arguments = parser.parse_args(argv)
    if arguments.command == "check":
        return check(arguments.request_id)
    return ask(arguments.text)


if __name__ == "__main__":
    raise SystemExit(main())
