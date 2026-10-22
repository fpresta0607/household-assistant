"""Spotify for the home key holders: discovery, search, and playing on one named device.

The Spotify integration's credential never leaves Home Assistant. Home Assistant's own
play_media sends a song to whichever device Spotify lists first when nothing is playing,
so the living room TV is played on by name here instead. Its volume is not Spotify's to
set: Spotify lists the Apple TV as a device without volume control.
"""

from __future__ import annotations

import asyncio
import json
import re
from typing import TYPE_CHECKING

from homeassistant.auth.permissions.const import POLICY_CONTROL, POLICY_READ
from homeassistant.config_entries import ConfigEntryState
from homeassistant.core import SupportsResponse
from homeassistant.exceptions import HomeAssistantError, ServiceValidationError, Unauthorized
from homeassistant.helpers import entity_registry
from spotifyaio import SpotifyError

if TYPE_CHECKING:
    from homeassistant.components.spotify.coordinator import SpotifyDeviceCoordinator
    from homeassistant.config_entries import ConfigEntry
    from homeassistant.core import HomeAssistant, ServiceCall, ServiceResponse
    from homeassistant.helpers.typing import ConfigType
    from spotifyaio.models import PlaybackState

DOMAIN = "household_home"
REFRESH_SECONDS = 15
SPOTIFY_SECONDS = 15
# Spotify answers an app in development mode at most ten results, and drops the
# playlists Spotify itself owns from them.
SEARCH_LIMIT = 10
SEARCH_KINDS = ("track", "album", "artist", "playlist")
MAX_QUERY_CHARACTERS = 200
PLAY_CHECKS = 8
PLAY_CHECK_SECONDS = 1.0
URI = re.compile(r"^spotify:(track|album|artist|playlist):[0-9A-Za-z]{22}$")


async def _spotify_entry(hass: HomeAssistant, call: ServiceCall, policy: str) -> ConfigEntry:
    entity_id = call.data.get("entity_id")
    entity = (
        entity_registry.async_get(hass).async_get(entity_id) if isinstance(entity_id, str) else None
    )
    if entity is None or entity.platform != "spotify" or entity.domain != "media_player":
        raise ServiceValidationError("Name one Spotify media player.")
    if call.context.user_id is not None:
        user = await hass.auth.async_get_user(call.context.user_id)
        if user is None or not user.permissions.check_entity(entity_id, policy):
            raise Unauthorized(entity_id=entity_id)
    entry = hass.config_entries.async_get_entry(entity.config_entry_id)
    if entry is None or entry.domain != "spotify" or entry.state is not ConfigEntryState.LOADED:
        raise ServiceValidationError("The Spotify integration is not loaded.")
    return entry


async def _refresh_devices(devices: SpotifyDeviceCoordinator) -> None:
    # update_entity refreshes playback only. The separate device cache polls every five minutes.
    try:
        async with asyncio.timeout(REFRESH_SECONDS):
            await devices.async_refresh()
    except TimeoutError:
        raise HomeAssistantError("Spotify device discovery timed out.") from None
    if not devices.last_update_success:
        raise HomeAssistantError("Spotify device discovery failed.")


def _plays(playback: PlaybackState | None, device_id: str, uri: str) -> bool:
    """Whether Spotify reports this device playing this uri, not what it played before."""
    if playback is None or not playback.is_playing or playback.device.device_id != device_id:
        return False
    if uri.startswith("spotify:track:"):
        return playback.item is not None and playback.item.uri == uri
    return playback.context is not None and playback.context.uri == uri


def _reason(error: SpotifyError) -> str:
    """Spotify's own words for a refusal, which spotifyaio carries as the raw answer."""
    try:
        answer = json.loads(str(error))
    except ValueError:
        return ""
    message = answer.get("error", {}).get("message") if isinstance(answer, dict) else None
    return f" Spotify said: {message}" if isinstance(message, str) else ""


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    async def refresh_spotify(call: ServiceCall) -> None:
        if set(call.data) != {"entity_id"}:
            raise ServiceValidationError("Name one Spotify media player.")
        entry = await _spotify_entry(hass, call, POLICY_READ)
        await _refresh_devices(entry.runtime_data.devices)

    async def search_spotify(call: ServiceCall) -> ServiceResponse:
        query, kind = call.data.get("query"), call.data.get("kind")
        if (
            set(call.data) != {"entity_id", "query", "kind"}
            or not isinstance(query, str)
            or not query.strip()
            or len(query) > MAX_QUERY_CHARACTERS
            or kind not in SEARCH_KINDS
        ):
            raise ServiceValidationError(
                "Name one Spotify media player, what to look for, "
                "and whether it is a track, album, artist or playlist."
            )
        entry = await _spotify_entry(hass, call, POLICY_READ)
        try:
            async with asyncio.timeout(SPOTIFY_SECONDS):
                result = await entry.runtime_data.coordinator.client.search(
                    query.strip(), [kind], limit=SEARCH_LIMIT
                )
        except TimeoutError:
            raise HomeAssistantError("Spotify search did not answer.") from None
        except SpotifyError as error:
            raise HomeAssistantError(f"Spotify search failed.{_reason(error)}") from error
        found = next((item for item in getattr(result, f"{kind}s") or [] if item), None)
        if found is None:
            return {}
        if kind == "playlist":
            by = found.owner.display_name
        elif kind == "artist":
            by = ""
        else:
            by = ", ".join(artist.name for artist in found.artists)
        return {"uri": found.uri, "name": found.name, "by": by}

    async def play_spotify(call: ServiceCall) -> None:
        device, uri = call.data.get("device"), call.data.get("uri")
        if (
            set(call.data) != {"entity_id", "device", "uri"}
            or not isinstance(device, str)
            or not isinstance(uri, str)
            or not URI.fullmatch(uri)
        ):
            raise ServiceValidationError(
                "Name one Spotify media player, the device, and a Spotify uri to play."
            )
        entry = await _spotify_entry(hass, call, POLICY_CONTROL)
        devices, coordinator = entry.runtime_data.devices, entry.runtime_data.coordinator
        await _refresh_devices(devices)
        target = next(
            (found for found in devices.data if found.name == device and found.device_id), None
        )
        if target is None:
            raise ServiceValidationError(f"Spotify does not list {device} as a place to play.")
        client = coordinator.client
        try:
            async with asyncio.timeout(SPOTIFY_SECONDS):
                if uri.startswith("spotify:track:"):
                    await client.start_playback(device_id=target.device_id, uris=[uri])
                else:
                    await client.start_playback(device_id=target.device_id, context_uri=uri)
        except TimeoutError:
            raise HomeAssistantError("Spotify did not answer.") from None
        except SpotifyError as error:
            raise HomeAssistantError(
                f"Spotify refused to play on {device}.{_reason(error)}"
            ) from error
        # spotifyaio passes most of Spotify's refusals back as a plain answer, so a play
        # counts only once Spotify's own playback says the device is playing.
        for _ in range(PLAY_CHECKS):
            await asyncio.sleep(PLAY_CHECK_SECONDS)
            await coordinator.async_refresh()
            playback = coordinator.data.current_playback if coordinator.data else None
            if _plays(playback, target.device_id, uri):
                return
        raise HomeAssistantError(f"Spotify took the request but nothing started on {device}.")

    hass.services.async_register(DOMAIN, "refresh_spotify", refresh_spotify)
    hass.services.async_register(
        DOMAIN, "search_spotify", search_spotify, supports_response=SupportsResponse.ONLY
    )
    hass.services.async_register(DOMAIN, "play_spotify", play_spotify)
    return True
