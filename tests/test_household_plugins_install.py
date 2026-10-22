"""scripts/install-household-plugins.sh: the household plugins into the read-only mount.

openclaw-install.sh used to empty the whole mount and refill it from the repository.
The mount also holds pocket-piggies-corey and pocket-piggies-denise, which
pocket-piggies-install.py puts there under those names, so running the install would
have deleted both and left a pocket-piggies directory no gateway loads. Each case runs
the real script against directories in a temporary root.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.capabilities import needs_getuid, needs_posix_bash

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "install-household-plugins.sh"
INSTALL = ROOT / "scripts" / "openclaw-install.sh"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


@pytest.fixture
def tree(tmp_path: Path) -> tuple[Path, Path]:
    source = tmp_path / "source"
    write(source / "household-speech" / "index.js", "speech v2")
    write(source / "household-memory" / "index.js", "memory v1")
    write(source / "pocket-piggies" / "index.mjs", "pocket piggies source")
    mount = tmp_path / "mount"
    write(mount / "household-speech" / "index.js", "speech v1")
    write(mount / "household-speech" / "removed.js", "a file v2 no longer ships")
    write(mount / "pocket-piggies-corey" / "index.mjs", "corey's installed copy")
    write(mount / "pocket-piggies-denise" / "index.mjs", "denise's installed copy")
    return source, mount


def install(source: Path, mount: Path) -> subprocess.CompletedProcess[str]:
    bash = shutil.which("bash")
    assert bash is not None, "the deployment scripts are bash, and CI has to have it"
    return subprocess.run(
        [bash, SCRIPT.as_posix(), source.as_posix(), mount.as_posix()],
        env={**os.environ, "PLUGIN_OWNER": f"{os.getuid()}:{os.getgid()}"},
        capture_output=True,
        text=True,
        check=False,
    )


@needs_getuid
@needs_posix_bash
def test_the_pocketpiggies_copies_its_own_installer_made_are_left_alone(
    tree: tuple[Path, Path],
) -> None:
    source, mount = tree

    result = install(source, mount)

    assert result.returncode == 0, result.stderr
    assert (mount / "pocket-piggies-corey" / "index.mjs").read_text() == "corey's installed copy"
    assert (mount / "pocket-piggies-denise" / "index.mjs").read_text() == "denise's installed copy"
    assert not (mount / "pocket-piggies").exists()


@needs_getuid
@needs_posix_bash
def test_each_household_plugin_is_replaced_whole(tree: tuple[Path, Path]) -> None:
    source, mount = tree

    assert install(source, mount).returncode == 0

    assert (mount / "household-speech" / "index.js").read_text() == "speech v2"
    assert not (mount / "household-speech" / "removed.js").exists()
    assert (mount / "household-memory" / "index.js").read_text() == "memory v1"


def test_the_install_no_longer_empties_the_mount() -> None:
    text = INSTALL.read_text(encoding="utf-8")
    assert 'find "${PLUGIN_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf' not in text
    assert 'install-household-plugins.sh" "${plugins_src}" "${PLUGIN_DIR}"' in text
