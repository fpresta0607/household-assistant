"""What a test needs from the machine running it, and the mark that skips it without.

The code under test runs on the Linux box, and CI on Linux runs every test. The gate
also runs the suite on a Windows machine, which lacks some of what these tests use,
so a test that needs one of these is skipped there with the reason, and never on
Linux. Each mark names a capability, not a platform, and goes on the narrowest scope:
a file only where every test in it needs the capability.
"""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path

import pytest


def _can_symlink() -> bool:
    with tempfile.TemporaryDirectory() as directory:
        try:
            os.symlink(directory, Path(directory) / "link")
        except OSError:
            return False
    return True


def _posix_bash() -> str | None:
    bash = shutil.which("bash")
    # Windows' own bash.exe, in System32 or WindowsApps, starts WSL, where a path in
    # this checkout means nothing. It is the one a gate started from cmd finds first.
    if bash is None or Path(bash).parent.name.lower() in {"system32", "windowsapps"}:
        return None
    return bash


POSIX_BASH = _posix_bash()

needs_nofollow_open = pytest.mark.skipif(
    not (hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY")),
    reason="needs os.O_NOFOLLOW and os.O_DIRECTORY, which the scripts open state with; "
    "CI on Linux runs it",
)
needs_getuid = pytest.mark.skipif(
    not hasattr(os, "getuid"),
    reason="needs os.getuid to tell files it owns from others'; CI on Linux runs it",
)
needs_symlinks = pytest.mark.skipif(
    not _can_symlink(),
    reason="needs to create symbolic links, which this account may not; CI on Linux runs it",
)
needs_posix_bash = pytest.mark.skipif(
    POSIX_BASH is None,
    reason="needs a POSIX bash to run the deployment scripts, and the only bash here "
    "starts WSL; CI on Linux runs it",
)
