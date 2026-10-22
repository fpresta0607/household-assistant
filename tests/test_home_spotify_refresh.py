"""Execute the household_home actions with Home Assistant's registry and Spotify mocked."""

from __future__ import annotations

import asyncio
import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest

ROOT = Path(__file__).resolve().parents[1]
ENTITY = "media_player.spotify_household"
TRACK = "spotify:track:5Q0Nhxo0l2bP3pNjpGJwV1"
PLAYLIST = "spotify:playlist:37i9dQZF1DX4sWumw6XAYa"


class SpotifyError(Exception):
    """spotifyaio's base error, which carries Spotify's raw answer as its text."""


def device(name: str) -> SimpleNamespace:
    return SimpleNamespace(name=name, device_id=f"id-{name}")


@pytest.fixture
def component(monkeypatch: pytest.MonkeyPatch) -> SimpleNamespace:
    modules = {
        name: ModuleType(name)
        for name in (
            "homeassistant",
            "homeassistant.auth",
            "homeassistant.auth.permissions",
            "homeassistant.auth.permissions.const",
            "homeassistant.config_entries",
            "homeassistant.core",
            "homeassistant.exceptions",
            "homeassistant.helpers",
            "homeassistant.helpers.entity_registry",
            "spotifyaio",
        )
    }
    for name, module in modules.items():
        monkeypatch.setitem(sys.modules, name, module)
    loaded = object()
    const = modules["homeassistant.auth.permissions.const"]
    monkeypatch.setattr(const, "POLICY_READ", "read", raising=False)
    monkeypatch.setattr(const, "POLICY_CONTROL", "control", raising=False)
    monkeypatch.setattr(
        modules["homeassistant.config_entries"],
        "ConfigEntryState",
        SimpleNamespace(LOADED=loaded),
        raising=False,
    )
    monkeypatch.setattr(
        modules["homeassistant.core"],
        "SupportsResponse",
        SimpleNamespace(ONLY="only"),
        raising=False,
    )
    monkeypatch.setattr(modules["spotifyaio"], "SpotifyError", SpotifyError, raising=False)
    errors = modules["homeassistant.exceptions"]
    monkeypatch.setattr(errors, "HomeAssistantError", RuntimeError, raising=False)
    monkeypatch.setattr(errors, "ServiceValidationError", ValueError, raising=False)
    monkeypatch.setattr(
        errors, "Unauthorized", lambda **kwargs: PermissionError("Not authorized"), raising=False
    )
    devices = SimpleNamespace(
        async_refresh=AsyncMock(), last_update_success=True, data=[device("Apple TV")]
    )
    client = SimpleNamespace(search=AsyncMock(), start_playback=AsyncMock())
    coordinator = SimpleNamespace(client=client, async_refresh=AsyncMock(), data=None)
    entry = SimpleNamespace(
        domain="spotify",
        state=loaded,
        runtime_data=SimpleNamespace(devices=devices, coordinator=coordinator),
    )
    entity = SimpleNamespace(platform="spotify", domain="media_player", config_entry_id="entry")
    registry = Mock()
    registry.async_get.side_effect = lambda entity_id: entity if entity_id == ENTITY else None
    monkeypatch.setattr(
        modules["homeassistant.helpers.entity_registry"],
        "async_get",
        lambda hass: registry,
        raising=False,
    )
    permissions = Mock()
    permissions.check_entity.return_value = True
    hass = SimpleNamespace(
        services=Mock(),
        config_entries=SimpleNamespace(async_get_entry=Mock(return_value=entry)),
        auth=SimpleNamespace(
            async_get_user=AsyncMock(return_value=SimpleNamespace(permissions=permissions))
        ),
    )
    path = ROOT / "deploy/homeassistant/custom_components/household_home/__init__.py"
    spec = importlib.util.spec_from_file_location("household_spotify_refresh", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "PLAY_CHECK_SECONDS", 0)
    assert asyncio.run(module.async_setup(hass, {})) is True
    registered = {
        found.args[1]: (found.args[2], found.kwargs)
        for found in hass.services.async_register.call_args_list
    }
    assert {found.args[0] for found in hass.services.async_register.call_args_list} == {
        "household_home"
    }
    assert set(registered) == {"refresh_spotify", "search_spotify", "play_spotify"}
    assert registered["search_spotify"][1] == {"supports_response": "only"}
    return SimpleNamespace(
        module=module,
        hass=hass,
        entity=entity,
        entry=entry,
        devices=devices,
        client=client,
        coordinator=coordinator,
        handlers={name: handler for name, (handler, _) in registered.items()},
        permissions=permissions,
    )


def call(data: dict[str, object] | None = None) -> SimpleNamespace:
    return SimpleNamespace(
        data={"entity_id": ENTITY} if data is None else data,
        context=SimpleNamespace(user_id="household-reader"),
    )


def run(component: SimpleNamespace, name: str, data: dict[str, object]) -> object:
    return asyncio.run(component.handlers[name](call({"entity_id": ENTITY, **data})))


# MARK: - Refreshing Spotify's devices


def test_refresh_updates_the_separate_device_cache_without_playback(
    component: SimpleNamespace,
) -> None:
    states: dict[str, list[str]] = {"source_list": []}

    async def discover() -> None:
        states["source_list"] = ["Apple TV"]

    component.devices.async_refresh.side_effect = discover

    asyncio.run(component.handlers["refresh_spotify"](call()))

    assert states["source_list"] == ["Apple TV"]
    component.permissions.check_entity.assert_called_once_with(ENTITY, "read")
    component.hass.services.async_call.assert_not_called()
    component.client.start_playback.assert_not_awaited()


@pytest.mark.parametrize(
    "data",
    [{}, {"entity_id": []}, {"entity_id": ENTITY, "play": True}, {"entity_id": "climate.kitchen"}],
)
def test_refresh_rejects_invalid_targets(
    component: SimpleNamespace, data: dict[str, object]
) -> None:
    with pytest.raises(ValueError, match="Spotify media player"):
        asyncio.run(component.handlers["refresh_spotify"](call(data)))
    component.devices.async_refresh.assert_not_awaited()


def test_refresh_rejects_another_integration(component: SimpleNamespace) -> None:
    component.entity.platform = "apple_tv"
    with pytest.raises(ValueError, match="Spotify media player"):
        asyncio.run(component.handlers["refresh_spotify"](call()))
    component.devices.async_refresh.assert_not_awaited()


@pytest.mark.parametrize("has_user", [True, False])
def test_refresh_checks_read_permission(component: SimpleNamespace, has_user: bool) -> None:
    component.permissions.check_entity.return_value = False
    if not has_user:
        component.hass.auth.async_get_user.return_value = None
    with pytest.raises(PermissionError):
        asyncio.run(component.handlers["refresh_spotify"](call()))
    component.devices.async_refresh.assert_not_awaited()


def test_refresh_rejects_an_unloaded_integration(component: SimpleNamespace) -> None:
    component.entry.state = "not-loaded"
    with pytest.raises(ValueError, match="not loaded"):
        asyncio.run(component.handlers["refresh_spotify"](call()))
    component.devices.async_refresh.assert_not_awaited()


def test_refresh_reports_a_failed_discovery_instead_of_using_the_old_cache(
    component: SimpleNamespace,
) -> None:
    component.devices.last_update_success = False
    with pytest.raises(RuntimeError, match="discovery failed"):
        asyncio.run(component.handlers["refresh_spotify"](call()))


def test_refresh_has_a_bounded_wait(component: SimpleNamespace) -> None:
    async def slow_discovery() -> None:
        await asyncio.Event().wait()

    component.module.REFRESH_SECONDS = 0.01
    component.devices.async_refresh.side_effect = slow_discovery
    with pytest.raises(RuntimeError, match="discovery timed out"):
        asyncio.run(component.handlers["refresh_spotify"](call()))


# MARK: - Searching Spotify


def artist(name: str) -> SimpleNamespace:
    return SimpleNamespace(name=name)


@pytest.mark.parametrize(
    ("kind", "found", "by"),
    [
        (
            "track",
            SimpleNamespace(uri=TRACK, name="Shake It Off", artists=[artist("Taylor Swift")]),
            "Taylor Swift",
        ),
        (
            "album",
            SimpleNamespace(
                uri="spotify:album:5iT3F2EhjVQVrO4PKhsP8c",
                name="Abbey Road",
                artists=[artist("The Beatles")],
            ),
            "The Beatles",
        ),
        (
            "artist",
            SimpleNamespace(uri="spotify:artist:3YCKuqpv9nCsIhJ2v8SMix", name="Hillsong Worship"),
            "",
        ),
        (
            "playlist",
            SimpleNamespace(
                uri=PLAYLIST, name="Calm Piano", owner=SimpleNamespace(display_name="Someone")
            ),
            "Someone",
        ),
    ],
)
def test_search_answers_spotifys_first_result_of_the_kind(
    component: SimpleNamespace, kind: str, found: SimpleNamespace, by: str
) -> None:
    component.client.search.return_value = SimpleNamespace(**{f"{kind}s": [found]})

    answer = run(component, "search_spotify", {"query": " calm piano ", "kind": kind})

    assert answer == {"uri": found.uri, "name": found.name, "by": by}
    component.client.search.assert_awaited_once_with("calm piano", [kind], limit=10)
    component.permissions.check_entity.assert_called_once_with(ENTITY, "read")


def test_search_skips_results_spotify_leaves_empty(component: SimpleNamespace) -> None:
    found = SimpleNamespace(uri=PLAYLIST, name="Calm", owner=SimpleNamespace(display_name="A"))
    component.client.search.return_value = SimpleNamespace(playlists=[None, found])
    answer = run(component, "search_spotify", {"query": "calm piano", "kind": "playlist"})
    assert answer == {"uri": PLAYLIST, "name": "Calm", "by": "A"}


def test_search_with_no_result_answers_empty(component: SimpleNamespace) -> None:
    component.client.search.return_value = SimpleNamespace(tracks=[])
    assert run(component, "search_spotify", {"query": "zzqx", "kind": "track"}) == {}


@pytest.mark.parametrize(
    "data",
    [
        {"query": "Shake It Off", "kind": "song"},
        {"query": "   ", "kind": "track"},
        {"query": "x" * 201, "kind": "track"},
        {"query": "Shake It Off", "kind": "track", "limit": 50},
        {"kind": "track"},
    ],
)
def test_search_rejects_odd_requests(component: SimpleNamespace, data: dict[str, object]) -> None:
    with pytest.raises(ValueError, match="what to look for"):
        run(component, "search_spotify", data)
    component.client.search.assert_not_awaited()


def test_a_failed_search_says_so_in_spotifys_words(component: SimpleNamespace) -> None:
    refusal = {"error": {"status": 403, "message": "Insufficient client scope"}}
    component.client.search.side_effect = SpotifyError(json.dumps(refusal))
    with pytest.raises(RuntimeError, match=r"search failed\. Spotify said: Insufficient"):
        run(component, "search_spotify", {"query": "Abbey Road", "kind": "album"})


# MARK: - Playing on one named device


def playback(identifier: str, uri: str) -> SimpleNamespace:
    is_track = uri.startswith("spotify:track:")
    return SimpleNamespace(
        is_playing=True,
        device=SimpleNamespace(device_id=identifier),
        item=SimpleNamespace(uri=uri if is_track else "spotify:track:0000000000000000000001"),
        context=None if is_track else SimpleNamespace(uri=uri),
    )


def playing_on(
    component: SimpleNamespace, identifier: str, uri: str = TRACK, *, after: int = 0
) -> None:
    """Spotify's playback reports the device playing `uri` once `after` refreshes have not."""
    misses = iter(range(after))

    async def refresh() -> None:
        if next(misses, None) is None:
            component.coordinator.data = SimpleNamespace(current_playback=playback(identifier, uri))

    component.coordinator.async_refresh.side_effect = refresh


def play(component: SimpleNamespace, **changes: object) -> None:
    run(component, "play_spotify", {"device": "Apple TV", "uri": TRACK, **changes})


def test_a_track_plays_on_the_named_device_even_when_another_is_listed_first(
    component: SimpleNamespace,
) -> None:
    component.devices.data = [device("Franco's iPhone"), device("Apple TV")]
    playing_on(component, "id-Apple TV", after=2)

    play(component)

    component.devices.async_refresh.assert_awaited_once()
    component.client.start_playback.assert_awaited_once_with(device_id="id-Apple TV", uris=[TRACK])
    assert component.coordinator.async_refresh.await_count == 3
    component.permissions.check_entity.assert_called_once_with(ENTITY, "control")


def test_a_playlist_plays_as_its_context(component: SimpleNamespace) -> None:
    playing_on(component, "id-Apple TV", PLAYLIST)
    play(component, uri=PLAYLIST)
    component.client.start_playback.assert_awaited_once_with(
        device_id="id-Apple TV", context_uri=PLAYLIST
    )


def test_a_device_spotify_does_not_list_plays_nothing(component: SimpleNamespace) -> None:
    component.devices.data = [device("Franco's iPhone")]
    with pytest.raises(ValueError, match="does not list Apple TV"):
        play(component)
    component.client.start_playback.assert_not_awaited()


def test_a_play_spotify_never_starts_is_a_failure_not_a_success(
    component: SimpleNamespace,
) -> None:
    playing_on(component, "id-Franco's iPhone")
    with pytest.raises(RuntimeError, match="nothing started on Apple TV"):
        play(component)
    assert component.coordinator.async_refresh.await_count == component.module.PLAY_CHECKS


def test_the_song_already_playing_on_the_device_is_not_taken_for_the_new_one(
    component: SimpleNamespace,
) -> None:
    component.coordinator.data = SimpleNamespace(current_playback=playback("id-Apple TV", PLAYLIST))
    with pytest.raises(RuntimeError, match="nothing started on Apple TV"):
        play(component)


def test_spotifys_refusal_is_passed_on_in_its_words(component: SimpleNamespace) -> None:
    refusal = {"error": {"status": 403, "message": "Player command failed: Premium required"}}
    component.client.start_playback.side_effect = SpotifyError(json.dumps(refusal))
    with pytest.raises(RuntimeError, match=r"refused to play on Apple TV\. Spotify said: Player"):
        play(component)


def test_play_checks_control_permission(component: SimpleNamespace) -> None:
    component.permissions.check_entity.side_effect = lambda entity_id, policy: policy == "read"
    with pytest.raises(PermissionError):
        play(component)
    component.client.start_playback.assert_not_awaited()


@pytest.mark.parametrize(
    "changes",
    [
        {"uri": "spotify:user:someone"},
        {"uri": "https://open.spotify.com/track/5Q0Nhxo0l2bP3pNjpGJwV1"},
        {"max_volume": 70},
        {"device": ["Apple TV"]},
        {"position": 0},
    ],
)
def test_play_rejects_odd_requests(component: SimpleNamespace, changes: dict[str, object]) -> None:
    with pytest.raises(ValueError, match="a Spotify uri to play"):
        play(component, **changes)
    component.devices.async_refresh.assert_not_awaited()
    component.client.start_playback.assert_not_awaited()
