"""The family room between the gateways: each mounts only the other's share, read-only.

Each gateway's household-app plugin writes its half of the family room into
household-app/share in its own state (share.js), and the other gateway reads it from a
read-only mount (peer-link.js). Anything more of the other's state in a container, or a
share it could write to, would hand one assistant the other's private threads.
"""

from __future__ import annotations

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
COMPOSE = ROOT / "deploy" / "openclaw" / "docker-compose.yml"
STATES = {
    "openclaw-gateway": Path("/var/lib/household-assistant/openclaw"),
    "openclaw-denise": Path("/var/lib/household-assistant/openclaw-denise"),
}
PEER = {"openclaw-gateway": "openclaw-denise", "openclaw-denise": "openclaw-gateway"}


def volumes(service: str) -> list[tuple[Path, str, str]]:
    compose = yaml.safe_load(COMPOSE.read_text(encoding="utf-8"))
    mounts = []
    for volume in compose["services"][service].get("volumes", []):
        source, target, *mode = volume.split(":")
        mounts.append((Path(source), target, mode[0] if mode else "rw"))
    return mounts


def test_each_gateway_mounts_the_others_share_read_only_and_nothing_else_of_its_state() -> None:
    for service, peer in PEER.items():
        of_peer = [mount for mount in volumes(service) if mount[0].is_relative_to(STATES[peer])]
        assert of_peer == [(STATES[peer] / "household-app" / "share", "/opt/household-peer", "ro")]


def test_the_share_mount_point_is_the_one_the_plugin_reads() -> None:
    source = (ROOT / "deploy/openclaw/plugins/household-app/peer-link.js").read_text()
    assert 'export const PEER_SHARE = "/opt/household-peer";' in source


def test_the_installer_makes_each_share_as_the_gateways_user_before_compose_starts() -> None:
    script = (ROOT / "scripts" / "openclaw-install.sh").read_text(encoding="utf-8")
    made = script.index('share="${state}/household-app/share"')
    assert "setpriv --reuid=" in script[made : made + 400]
    assert made < script.index("compose up -d --wait")
