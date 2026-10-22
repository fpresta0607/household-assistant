"""household-app-relay.py: the app's family room, carried between the two gateways.

Each gateway's household-app plugin keeps what its own person and assistant did in the
family room in household-app/outbox.json under its state. The relay reads both files on
the host and pipes what is new, with its attachments, into the other gateway's container,
where the plugin's relay-in.mjs writes it into that plugin's inbox. These tests replace
`docker exec` with a recorder and keep both gateways' state in a temporary directory.
"""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import stat
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import Any, Protocol

import pytest

from tests.capabilities import needs_getuid, needs_nofollow_open, needs_symlinks

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "household-app-relay.py"

pytestmark = needs_nofollow_open


class GatewayLike(Protocol):
    """gateway_config.Gateway, which the relay script loads from its own directory."""

    persona: str
    container: str
    state: Path
    person: str


def load(path: Path, name: str) -> ModuleType:
    if str(path.parent) not in sys.path:
        sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def relay() -> ModuleType:
    return load(SCRIPT, "household_app_relay")


class Docker:
    """Stands in for `docker exec`: records each delivery and answers as relay-in does."""

    def __init__(self, failing: set[str] | None = None) -> None:
        self.calls: list[tuple[list[str], dict[str, Any]]] = []
        self.failing = failing or set()

    def __call__(self, command: list[str], **options: object) -> subprocess.CompletedProcess[str]:
        payload = json.loads(str(options["input"]))
        self.calls.append((command, payload))
        container = next(part for part in command if part.startswith("openclaw-"))
        if container in self.failing:
            return subprocess.CompletedProcess(command, 1, "", "relay-in: container not running")
        answer = {
            "ok": True,
            "entries": len(payload["batch"]["entries"]),
            "media": len(payload["media"]),
        }
        return subprocess.CompletedProcess(command, 0, json.dumps(answer) + "\n", "")

    def delivered(self, container: str) -> list[dict[str, Any]]:
        return [payload for command, payload in self.calls if container in command]


def gateways(relay: ModuleType, root: Path) -> tuple[Any, Any]:
    corey = relay.Gateway("corey", "openclaw-gateway", root / "openclaw", "franco")
    denise = relay.Gateway("denise", "openclaw-denise", root / "openclaw-denise", "gia")
    for gateway in (corey, denise):
        (gateway.state / "household-app" / "media").mkdir(parents=True)
    return corey, denise


def write_outbox(
    gateway: GatewayLike,
    entries: list[dict[str, Any]],
    typing: dict[str, Any] | None = None,
    *,
    sign_ins: list[Any] | None = None,
    approvals: list[Any] | None = None,
    steps: dict[str, list[Any]] | None = None,
) -> None:
    outbox = {
        "entries": entries,
        "typing": typing or {},
        "identity": {
            "assistant": {"id": gateway.persona, "name": gateway.persona.title(), "emoji": "🦊"}
        },
        "signIns": sign_ins or [],
        "approvals": approvals or [],
        "cart": (steps or {}).get("cart", []),
        "notes": (steps or {}).get("notes", []),
    }
    (gateway.state / "household-app" / "outbox.json").write_text(
        json.dumps(outbox), encoding="utf-8"
    )


def message(rev: int, author: str, **extra: object) -> dict[str, Any]:
    return {
        "id": f"m-{rev:08d}",
        "rev": rev,
        "kind": "message",
        "conversation": "family",
        "author": author,
        "at": 1792540800000 + rev,
        "origin": "local",
        "text": f"said {rev}",
        "media": [],
        "replyTo": None,
        **extra,
    }


def put_media(gateway: GatewayLike, data: bytes) -> str:
    media_id = hashlib.sha256(data).hexdigest()
    (gateway.state / "household-app" / "media" / media_id).write_bytes(data)
    return media_id


def tick(relay: ModuleType, root: Path, docker: Callable[..., object]) -> object:
    corey, denise = gateways_of(relay, root)
    return relay.tick((corey, denise), root / "relay.json", docker)


def gateways_of(relay: ModuleType, root: Path) -> tuple[Any, Any]:
    return (
        relay.Gateway("corey", "openclaw-gateway", root / "openclaw", "franco"),
        relay.Gateway("denise", "openclaw-denise", root / "openclaw-denise", "gia"),
    )


def test_what_is_new_on_one_side_reaches_the_other_once(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [message(1, "franco"), message(2, "corey", runId="run-1")])
    docker = Docker()

    tick(relay, tmp_path, docker)
    tick(relay, tmp_path, docker)

    deliveries = docker.delivered("openclaw-denise")
    assert len(deliveries) == 1
    assert deliveries[0]["from"] == "corey"
    assert [entry["id"] for entry in deliveries[0]["batch"]["entries"]] == [
        "m-00000001",
        "m-00000002",
    ]
    assert deliveries[0]["batch"]["identity"] == {
        "assistant": {"id": "corey", "name": "Corey", "emoji": "🦊"}
    }
    assert docker.delivered("openclaw-gateway") == []


def test_the_delivery_runs_relay_in_as_the_gateways_own_user(
    relay: ModuleType, tmp_path: Path
) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [message(1, "franco")])
    docker = Docker()
    tick(relay, tmp_path, docker)
    command = docker.calls[0][0]
    assert command == [
        "docker",
        "exec",
        "-i",
        "-u",
        "node",
        "openclaw-denise",
        "node",
        "/opt/household-plugins/household-app/relay-in.mjs",
    ]


def test_a_later_entry_is_delivered_on_a_later_tick(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [message(1, "franco")])
    docker = Docker()
    tick(relay, tmp_path, docker)
    write_outbox(corey, [message(1, "franco"), message(5, "franco")])
    tick(relay, tmp_path, docker)
    assert [
        [entry["id"] for entry in payload["batch"]["entries"]]
        for payload in docker.delivered("openclaw-denise")
    ] == [
        ["m-00000001"],
        ["m-00000005"],
    ]


def test_a_failed_delivery_is_tried_again_next_tick(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [message(1, "franco")])
    tick(relay, tmp_path, Docker(failing={"openclaw-denise"}))
    docker = Docker()
    tick(relay, tmp_path, docker)
    assert [
        entry["id"] for entry in docker.delivered("openclaw-denise")[0]["batch"]["entries"]
    ] == ["m-00000001"]


def test_one_side_failing_does_not_hold_up_the_other(relay: ModuleType, tmp_path: Path) -> None:
    corey, denise = gateways(relay, tmp_path)
    write_outbox(corey, [message(1, "franco")])
    write_outbox(denise, [message(1, "gia")])
    docker = Docker(failing={"openclaw-denise"})
    tick(relay, tmp_path, docker)
    assert len(docker.delivered("openclaw-gateway")) == 1


def test_only_the_sources_own_person_and_assistant_in_the_family_room_travel(
    relay: ModuleType, tmp_path: Path
) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(
        corey,
        [
            message(1, "franco"),
            message(2, "gia"),
            message(3, "denise"),
            message(4, "franco", conversation="direct"),
            message(5, "corey"),
        ],
    )
    docker = Docker()
    tick(relay, tmp_path, docker)
    sent = docker.delivered("openclaw-denise")[0]["batch"]["entries"]
    assert [entry["id"] for entry in sent] == ["m-00000001", "m-00000005"]


def test_attachments_travel_with_the_message_that_names_them(
    relay: ModuleType, tmp_path: Path
) -> None:
    corey, _ = gateways(relay, tmp_path)
    data = os.urandom(4096)
    media_id = put_media(corey, data)
    attachment = {"id": media_id, "kind": "voice", "mime": "audio/mp4", "bytes": 4096}
    write_outbox(corey, [message(1, "franco", media=[attachment])])
    docker = Docker()
    tick(relay, tmp_path, docker)
    payload = docker.delivered("openclaw-denise")[0]
    assert payload["media"] == {media_id: base64.b64encode(data).decode("ascii")}


def test_a_face_travels_with_its_photo(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    data = os.urandom(2048)
    media_id = put_media(corey, data)
    face = {"id": media_id, "kind": "photo", "mime": "image/jpeg", "bytes": 2048}
    avatar = {
        "id": "avatar:corey",
        "rev": 1,
        "kind": "avatar",
        "conversation": "family",
        "author": "corey",
        "at": 1792540800000,
        "origin": "local",
        "media": [face],
    }
    write_outbox(corey, [avatar])
    docker = Docker()
    tick(relay, tmp_path, docker)
    payload = docker.delivered("openclaw-denise")[0]
    assert payload["batch"]["entries"] == [avatar]
    assert payload["media"] == {media_id: base64.b64encode(data).decode("ascii")}


@pytest.mark.parametrize(
    ("source", "target"), [("corey", "openclaw-denise"), ("denise", "openclaw-gateway")]
)
def test_the_family_rooms_own_photo_travels_from_either_side(
    relay: ModuleType, tmp_path: Path, source: str, target: str
) -> None:
    sides = dict(zip(("corey", "denise"), gateways(relay, tmp_path), strict=True))
    data = os.urandom(2048)
    media_id = put_media(sides[source], data)
    photo = {
        "id": "avatar:family",
        "rev": 7,
        "kind": "avatar",
        "conversation": "family",
        "author": "family",
        "at": 1792540800000,
        "origin": "local",
        "media": [{"id": media_id, "kind": "photo", "mime": "image/jpeg", "bytes": 2048}],
    }
    write_outbox(sides[source], [photo])
    docker = Docker()

    tick(relay, tmp_path, docker)

    payload = docker.delivered(target)[0]
    assert payload["batch"]["entries"] == [photo]
    assert payload["media"] == {media_id: base64.b64encode(data).decode("ascii")}


def test_only_a_photo_may_speak_for_the_family_room(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    page = {
        "id": "profile:family",
        "rev": 2,
        "kind": "profile",
        "conversation": "family",
        "author": "family",
        "at": 1792540800000,
        "origin": "local",
        "name": "Family",
    }
    write_outbox(corey, [message(1, "family"), page, message(3, "franco")])
    docker = Docker()

    tick(relay, tmp_path, docker)

    sent = docker.delivered("openclaw-denise")[0]["batch"]["entries"]
    assert [entry["id"] for entry in sent] == ["m-00000003"]


def look(rev: int, author: str, change: str = "color") -> dict[str, Any]:
    return {
        "id": f"look:{author}:{1792540800000 + rev}",
        "rev": rev,
        "kind": "look",
        "conversation": "family",
        "author": author,
        "at": 1792540800000 + rev,
        "origin": "local",
        "change": change,
        "ring": {"red": 1, "green": 1, "blue": 1},
    }


@pytest.mark.parametrize(
    ("source", "author", "target"),
    [("corey", "franco", "openclaw-denise"), ("denise", "gia", "openclaw-gateway")],
)
def test_a_persons_change_to_the_family_rooms_look_travels_from_either_side(
    relay: ModuleType, tmp_path: Path, source: str, author: str, target: str
) -> None:
    sides = dict(zip(("corey", "denise"), gateways(relay, tmp_path), strict=True))
    change = look(4, author)
    write_outbox(sides[source], [change])
    docker = Docker()

    tick(relay, tmp_path, docker)

    assert docker.delivered(target)[0]["batch"]["entries"] == [change]


def test_a_look_the_side_may_not_say_is_held_back(relay: ModuleType, tmp_path: Path) -> None:
    # The room and the other side's person are held back here; the receiving plugin also
    # refuses one written as an assistant, which only a person changes.
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [look(1, "family"), look(2, "gia"), look(3, "corey"), look(4, "franco")])
    docker = Docker()

    tick(relay, tmp_path, docker)

    sent = docker.delivered("openclaw-denise")[0]["batch"]["entries"]
    assert [entry["id"] for entry in sent] == [
        "look:corey:1792540800003",
        "look:franco:1792540800004",
    ]


def test_an_assistants_page_travels_like_a_face(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    page = {
        "id": "profile:corey",
        "rev": 1,
        "kind": "profile",
        "conversation": "family",
        "author": "corey",
        "at": 1792540800000,
        "origin": "local",
        "name": "Corey",
        "voice": "will",
        "voiceName": "Will",
        "modelName": "GLM 5.3 Flash",
    }
    write_outbox(corey, [page])
    docker = Docker()
    tick(relay, tmp_path, docker)
    assert docker.delivered("openclaw-denise")[0]["batch"]["entries"] == [page]


def test_a_live_maps_update_and_an_answer_to_a_place_travel_like_a_reaction(
    relay: ModuleType, tmp_path: Path
) -> None:
    corey, _ = gateways(relay, tmp_path)
    shared = message(1, "franco", text="", location={"latitudeE6": 1, "until": 1792544400000})
    marker = {"conversation": "family", "author": "franco", "origin": "local", "signature": "s"}
    update = {
        "id": "live:m-00000001",
        "rev": 2,
        "kind": "live",
        "at": 1792540900000,
        "messageId": "m-00000001",
        "position": None,
        **marker,
    }
    answer = {
        "id": "place:a-00000009:franco",
        "rev": 3,
        "kind": "place",
        "at": 1792540900000,
        "messageId": "a-00000009",
        "answer": "yes",
        **marker,
    }
    write_outbox(corey, [shared, update, answer])
    docker = Docker()
    tick(relay, tmp_path, docker)
    assert docker.delivered("openclaw-denise")[0]["batch"]["entries"] == [shared, update, answer]


def test_an_attachment_whose_bytes_do_not_match_its_name_is_not_carried(
    relay: ModuleType, tmp_path: Path
) -> None:
    corey, _ = gateways(relay, tmp_path)
    wrong = "a" * 64
    (corey.state / "household-app" / "media" / wrong).write_bytes(b"not what the name says")
    attachment = {"id": wrong, "kind": "photo", "mime": "image/jpeg", "bytes": 22}
    write_outbox(corey, [message(1, "franco", media=[attachment])])
    docker = Docker()
    tick(relay, tmp_path, docker)
    assert docker.delivered("openclaw-denise")[0]["media"] == {}


def test_a_batch_is_bounded_and_the_rest_follows_in_the_same_tick(
    relay: ModuleType, tmp_path: Path
) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [message(rev, "franco") for rev in range(1, relay.ENTRIES_PER_BATCH + 6)])
    docker = Docker()
    tick(relay, tmp_path, docker)
    sizes = [len(payload["batch"]["entries"]) for payload in docker.delivered("openclaw-denise")]
    assert sizes == [relay.ENTRIES_PER_BATCH, 5]


def test_typing_travels_when_it_changes_and_not_otherwise(
    relay: ModuleType, tmp_path: Path
) -> None:
    corey, _ = gateways(relay, tmp_path)
    typing = {"corey": {"conversation": "family", "until": 1792540830000}}
    write_outbox(corey, [], typing)
    docker = Docker()
    tick(relay, tmp_path, docker)
    tick(relay, tmp_path, docker)
    write_outbox(corey, [], {})
    tick(relay, tmp_path, docker)
    assert [payload["batch"]["typing"] for payload in docker.delivered("openclaw-denise")] == [
        typing,
        {},
    ]


def sign_in(request_id: str, person: str) -> dict[str, Any]:
    return {"id": request_id, "name": "A new iPhone", "at": 1792540800000, "person": person}


def approval(request_id: str, person: str) -> dict[str, Any]:
    return {"requestId": request_id, "person": person, "at": 1792540800000, "signature": "sig"}


def test_sign_ins_travel_when_they_change_and_not_otherwise(
    relay: ModuleType, tmp_path: Path
) -> None:
    _, denise = gateways(relay, tmp_path)
    write_outbox(denise, [], sign_ins=[sign_in("req-1", "gia")])
    docker = Docker()
    tick(relay, tmp_path, docker)
    tick(relay, tmp_path, docker)
    write_outbox(denise, [])
    tick(relay, tmp_path, docker)
    assert [
        (payload["batch"]["signIns"], payload["batch"]["approvals"])
        for payload in docker.delivered("openclaw-gateway")
    ] == [([sign_in("req-1", "gia")], []), ([], [])]


def test_only_the_sources_own_sign_ins_and_approvals_for_the_other_person_travel(
    relay: ModuleType, tmp_path: Path
) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(
        corey,
        [],
        sign_ins=[sign_in("req-1", "franco"), sign_in("req-2", "gia"), "not a sign-in"],
        approvals=[approval("req-3", "gia"), approval("req-4", "franco"), None],
    )
    docker = Docker()
    tick(relay, tmp_path, docker)
    batch = docker.delivered("openclaw-denise")[0]["batch"]
    assert batch["signIns"] == [sign_in("req-1", "franco")]
    assert batch["approvals"] == [approval("req-3", "gia")]


def cart_step(step_id: int, author: str) -> dict[str, Any]:
    return {
        "id": f"co-00000000-0000-4000-8000-{step_id:012d}",
        "at": 1792540800000 + step_id,
        "author": author,
        "kind": "remove",
        "item": "ci-0badc0de",
    }


def note_step(step_id: int, author: str) -> dict[str, Any]:
    return {
        "id": f"ns-00000000-0000-4000-8000-{step_id:012d}",
        "at": 1792540800000 + step_id,
        "author": author,
        "kind": "remove",
        "line": "hn-0badc0de",
    }


# The household cart's steps and the household note's, which travel the same way.
STEP_LOGS = pytest.mark.parametrize(("key", "step"), [("cart", cart_step), ("notes", note_step)])


@STEP_LOGS
def test_shared_steps_travel_when_they_change_and_not_otherwise(
    relay: ModuleType, tmp_path: Path, key: str, step: Callable[[int, str], dict[str, Any]]
) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [], steps={key: [step(1, "corey")]})
    docker = Docker()
    tick(relay, tmp_path, docker)
    tick(relay, tmp_path, docker)
    write_outbox(corey, [], steps={key: [step(1, "corey"), step(2, "corey")]})
    tick(relay, tmp_path, docker)
    assert [payload["batch"][key] for payload in docker.delivered("openclaw-denise")] == [
        [step(1, "corey")],
        [step(1, "corey"), step(2, "corey")],
    ]


@STEP_LOGS
def test_shared_steps_ride_along_with_every_delivery_so_a_gateway_that_lost_them_gets_them_back(
    relay: ModuleType, tmp_path: Path, key: str, step: Callable[[int, str], dict[str, Any]]
) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [], steps={key: [step(1, "corey")]})
    docker = Docker()
    tick(relay, tmp_path, docker)
    write_outbox(corey, [message(1, "franco")], steps={key: [step(1, "corey")]})
    tick(relay, tmp_path, docker)
    assert [payload["batch"][key] for payload in docker.delivered("openclaw-denise")] == [
        [step(1, "corey")],
        [step(1, "corey")],
    ]


@STEP_LOGS
def test_only_the_sources_own_assistants_shared_steps_travel(
    relay: ModuleType, tmp_path: Path, key: str, step: Callable[[int, str], dict[str, Any]]
) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(
        corey,
        [],
        steps={key: [step(1, "corey"), step(2, "denise"), step(3, "franco"), "not a step"]},
    )
    docker = Docker()
    tick(relay, tmp_path, docker)
    assert docker.delivered("openclaw-denise")[0]["batch"][key] == [step(1, "corey")]


def test_a_note_step_alone_is_a_delivery_beside_an_unchanged_cart(
    relay: ModuleType, tmp_path: Path
) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [], steps={"cart": [cart_step(1, "corey")]})
    docker = Docker()
    tick(relay, tmp_path, docker)
    write_outbox(
        corey, [], steps={"cart": [cart_step(1, "corey")], "notes": [note_step(1, "corey")]}
    )
    tick(relay, tmp_path, docker)
    batches = [payload["batch"] for payload in docker.delivered("openclaw-denise")]
    assert [(batch["cart"], batch["notes"]) for batch in batches] == [
        ([cart_step(1, "corey")], []),
        ([cart_step(1, "corey")], [note_step(1, "corey")]),
    ]


def test_a_side_with_no_outbox_yet_sends_nothing(relay: ModuleType, tmp_path: Path) -> None:
    gateways(relay, tmp_path)
    docker = Docker()
    tick(relay, tmp_path, docker)
    assert docker.calls == []


@needs_symlinks
def test_an_outbox_that_is_a_symlink_is_refused(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    elsewhere = tmp_path / "elsewhere.json"
    elsewhere.write_text(
        json.dumps({"entries": [message(1, "franco")], "typing": {}}), encoding="utf-8"
    )
    (corey.state / "household-app" / "outbox.json").symlink_to(elsewhere)
    docker = Docker()
    result = relay.tick(gateways_of(relay, tmp_path), tmp_path / "relay.json", docker)
    assert docker.calls == []
    assert any("corey" in problem for problem in result.problems)


@needs_symlinks
def test_a_plugin_directory_that_is_a_symlink_is_refused(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    real = tmp_path / "real-room"
    real.mkdir()
    (real / "outbox.json").write_text(
        json.dumps({"entries": [message(1, "franco")], "typing": {}}), encoding="utf-8"
    )
    plugin = corey.state / "household-app"
    for child in plugin.iterdir():
        child.rmdir()
    plugin.rmdir()
    plugin.symlink_to(real)
    docker = Docker()
    tick(relay, tmp_path, docker)
    assert docker.calls == []


def test_an_outbox_over_its_size_bound_is_refused(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    (corey.state / "household-app" / "outbox.json").write_bytes(b" " * (relay.MAX_OUTBOX_BYTES + 1))
    docker = Docker()
    result = relay.tick(gateways_of(relay, tmp_path), tmp_path / "relay.json", docker)
    assert docker.calls == []
    assert any("size" in problem for problem in result.problems)


def test_an_outbox_that_does_not_parse_sends_nothing(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    (corey.state / "household-app" / "outbox.json").write_text("{not json", encoding="utf-8")
    docker = Docker()
    tick(relay, tmp_path, docker)
    assert docker.calls == []


@needs_getuid
def test_the_relay_state_is_private(relay: ModuleType, tmp_path: Path) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [message(1, "franco")])
    tick(relay, tmp_path, Docker())
    mode = stat.S_IMODE((tmp_path / "relay.json").stat().st_mode)
    assert mode == 0o600


def test_nothing_any_message_said_is_printed(
    relay: ModuleType, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    corey, _ = gateways(relay, tmp_path)
    write_outbox(corey, [message(1, "franco", text="the secret family recipe")])
    tick(relay, tmp_path, Docker(failing={"openclaw-denise"}))
    captured = capsys.readouterr()
    assert "recipe" not in captured.out + captured.err
