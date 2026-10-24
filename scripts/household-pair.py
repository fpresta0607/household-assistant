#!/usr/bin/env python3
"""A setup link for a person's first iPhone, from their assistant's gateway.

A person with a paired iPhone makes the link for another one in the app, on Account. A
household's first iPhone, or one whose person has none left, gets it from whoever runs the
box, with this:

    python3 scripts/household-pair.py marina      # a person, or their assistant

It prints the link, good once for ten minutes, and, when qrencode is installed, a code the
phone's camera opens. The link is on the household's tailnet, so the phone has to be signed
in to it first, in the Tailscale app. Open it on that person's phone only: whoever opens it
first is paired as that person.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from collections.abc import Sequence

from gateway_config import (
    GATEWAYS,
    Gateway,
    Runner,
    ask_gateway,
    first_json_object,
    load_household,
)


def gateway_named(name: str) -> Gateway | None:
    """The gateway of the person or assistant called `name`, by id or by name as shown."""
    wanted = " ".join(name.split()).casefold()
    member = next(
        (
            m
            for m in load_household().members
            if wanted in {m.person, m.assistant, m.name.casefold(), m.assistant_name.casefold()}
        ),
        None,
    )
    return next((g for g in GATEWAYS if member and g.persona == member.assistant), None)


def setup_link(gateway: Gateway, run: Runner) -> str:
    asked = ask_gateway(
        gateway, run, "gateway", "call", "household-app.pair", "--json", "--params", "{}"
    )
    answer = first_json_object(asked.stdout, "link")
    if asked.returncode != 0 or answer is None or not isinstance(answer.get("link"), str):
        detail = (asked.stderr or asked.stdout).strip()[-400:]
        raise RuntimeError(f"{gateway.container} gave no setup link: {detail}")
    link: str = answer["link"]
    return link


def main(argv: Sequence[str] | None = None, *, run: Runner = subprocess.run) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument(
        "who", help="the person, or their assistant, as the household file names them"
    )
    arguments = parser.parse_args(argv)
    gateway = gateway_named(arguments.who)
    if gateway is None:
        known = ", ".join(f"{g.person} ({g.persona})" for g in GATEWAYS)
        parser.error(f"nobody in the household file is called {arguments.who!r}; it names {known}")
    try:
        link = setup_link(gateway, run)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Open this on {gateway.person}'s iPhone within ten minutes, once:")
    print(f"  {link}")
    if shutil.which("qrencode"):
        print("or point its camera at this:")
        run(["qrencode", "-t", "ansiutf8", link], check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
