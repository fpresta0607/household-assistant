"""What Corey and Denise may do to the house, through Home Assistant and the Apple TV.

These are the real limits, since the Home Assistant user they act as can control every
entity: the thermostat only within 62 to 80 degrees, only in the mode it is already in,
and only after a yes, the TV's volume never set above 70% and raised above 40% only after
a yes, music only on the living room TV, found by Spotify's own search or from an
open.spotify.com link, and nothing else in the house at all. Every answer reads the house
back afterwards, so the assistant reports what the device says, not what was asked, and
every refusal says why in words the person can act on.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from typing import Any, Protocol

LOWEST = 62
HIGHEST = 80
# The ecobee keeps heat and cool at least this far apart on auto, and spreads a narrower
# range around its middle: asked for 70 to 73 on 17 October 2026 it held 69 to 74, and
# every range Home Assistant recorded from 15 October on was 5 or more apart.
SMALLEST_GAP = 5
# The modes the thermostat holds one temperature in. On auto, heat_cool, it holds a range.
ONE_TARGET_MODES = ("heat", "cool")
QUIET_VOLUME = 40
LOUDEST_VOLUME = 70
VOLUME_STEP = 10
# How long to wait for the Apple TV's Spotify app to show up as a place to play. It took
# 2 seconds from a sleeping TV on 17 October 2026.
LISTING_CHECKS = 15
LISTING_PAUSE_SECONDS = 2.0
PLAY_KINDS = ("track", "album", "artist", "playlist")
MAX_QUERY_CHARACTERS = 200
YOUTUBE_LINK = re.compile(
    r"^https://(?:(?:www|m|music)\.)?youtube\.com/(?:watch\?(?:[^#]*&)?v=|shorts/|live/)"
    r"([0-9A-Za-z_-]{11})(?:[?&#].*)?$"
    r"|^https://youtu\.be/([0-9A-Za-z_-]{11})(?:[?#].*)?$"
)
VIDEO_CONTROLS = ("pause", "resume", "next", "previous", "seek")
LONGEST_SEEK_SECONDS = 600
SPOTIFY_LINK = re.compile(
    r"^https://open\.spotify\.com/(?:intl-[a-z]{2}(?:-[a-z]{2})?/)?"
    r"(playlist|album|artist|track)/([0-9A-Za-z]{22})(?:[?#].*)?$"
)
MUSIC_ACTIONS = {
    "pause": "media_pause",
    "resume": "media_play",
    "next": "media_next_track",
    "previous": "media_previous_track",
}


class HomeError(Exception):
    """A refusal the assistant can explain, with a stable code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class HomeAssistant(Protocol):
    def state(self, entity_id: str) -> dict[str, Any]: ...

    def call(self, domain: str, service: str, data: dict[str, Any]) -> None: ...

    def ask(self, domain: str, service: str, data: dict[str, Any]) -> dict[str, Any]: ...


@dataclass(frozen=True)
class TVReading:
    # pyatv's power state in lower case: on, off or unknown.
    power: str
    # None while the TV offers the house no volume control, as when it sleeps.
    volume: int | None


class AppleTV(Protocol):
    def wake(self) -> None: ...

    def open_spotify(self) -> None: ...

    def sleep(self) -> None: ...

    def read(self) -> TVReading: ...

    def set_volume(self, level: int) -> int: ...

    def open_youtube(self, video: str) -> bool: ...

    def control(self, control: str, seconds: int) -> bool: ...


@dataclass(frozen=True)
class Entities:
    thermostat: str
    spotify: str
    # The name the Apple TV's Spotify app goes by among Spotify's places to play.
    tv_spotify_name: str


def _whole(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _degrees(values: dict[str, Any], names: Iterable[str]) -> str:
    """A setting as a person says it: 69 to 74, or 72."""
    return " to ".join(
        f"{values[name]:g}" if isinstance(values[name], int | float) else "nothing"
        for name in names
    )


class Home:
    def __init__(
        self,
        *,
        hass: HomeAssistant,
        tv: AppleTV,
        entities: Entities,
        wait: Callable[[float], None],
    ) -> None:
        self.hass = hass
        self.apple_tv = tv
        self.entities = entities
        self.wait = wait

    def _thermostat(self) -> dict[str, Any]:
        state = self.hass.state(self.entities.thermostat)
        attributes = state.get("attributes", {})
        return {
            "temperature": attributes.get("current_temperature"),
            "target": attributes.get("temperature"),
            "low": attributes.get("target_temp_low"),
            "high": attributes.get("target_temp_high"),
            "mode": state.get("state"),
            "doing": attributes.get("hvac_action"),
        }

    def _music(self) -> dict[str, Any]:
        state = self.hass.state(self.entities.spotify)
        attributes = state.get("attributes", {})
        # Spotify's volume is left out: on the Apple TV it is fixed, and the TV's own is the one.
        music: dict[str, Any] = {"state": state.get("state")}
        for key, name in (
            ("media_title", "title"),
            ("media_artist", "artist"),
            ("source", "playing_on"),
        ):
            if attributes.get(key):
                music[name] = attributes[key]
        return music

    def _music_on_tv(self) -> dict[str, Any]:
        """The music, when what Spotify is playing is on the living room TV."""
        music = self._music()
        where = music.get("playing_on")
        if music["state"] not in ("playing", "paused") or where is None:
            raise HomeError("nothing_playing", "Nothing is playing on the living room TV.")
        if where != self.entities.tv_spotify_name:
            raise HomeError(
                "playing_elsewhere",
                f"Spotify is playing on {where}, not the living room TV, "
                "so the house left it alone.",
            )
        return music

    def _tv(self) -> dict[str, Any]:
        try:
            reading = self.apple_tv.read()
        except HomeError as refused:
            return {"error": refused.message}
        return {"power": reading.power, "volume": reading.volume}

    def status(self) -> dict[str, Any]:
        devices = self._spotify_devices()
        return {
            "thermostat": self._thermostat(),
            "music": {
                **self._music(),
                "devices": devices,
                "tv_ready": self.entities.tv_spotify_name in devices,
            },
            "tv": self._tv(),
        }

    def thermostat(
        self,
        *,
        low: object = None,
        high: object = None,
        target: object = None,
        confirmed: bool,
    ) -> dict[str, Any]:
        """Set what the thermostat's own mode holds: one target on heat or cool, a range on auto.

        Home Assistant's ecobee integration sets a range only on auto and one temperature
        only on heat or cool, and takes no mode with either, so a setting for another mode
        would change nothing at all.
        """
        mode = self.hass.state(self.entities.thermostat).get("state")
        if mode == "heat_cool":
            bottom, top = _whole(low), _whole(high)
            if target is not None:
                raise HomeError(
                    "thermostat_mode",
                    "The thermostat is on auto, keeping the house between two temperatures, "
                    "so give low and high, not one target.",
                )
            if (
                bottom is None
                or top is None
                or bottom < LOWEST
                or top > HIGHEST
                or top - bottom < SMALLEST_GAP
            ):
                raise HomeError(
                    "out_of_range",
                    f"On auto the thermostat keeps the house between two whole degrees from "
                    f"{LOWEST} to {HIGHEST}, the high at least {SMALLEST_GAP} above the low, "
                    "since it holds them no closer.",
                )
            asked: dict[str, int] = {"low": bottom, "high": top}
            question = f"Set the thermostat to stay between {bottom} and {top} degrees?"
            setting: dict[str, int] = {"target_temp_low": bottom, "target_temp_high": top}
        elif mode in ONE_TARGET_MODES:
            degrees = _whole(target)
            if low is not None or high is not None:
                raise HomeError(
                    "thermostat_mode",
                    f"The thermostat is on {mode}, holding one temperature, so give one target, "
                    "not low and high.",
                )
            if degrees is None or not LOWEST <= degrees <= HIGHEST:
                raise HomeError(
                    "out_of_range",
                    f"On {mode} the thermostat holds one whole degree from {LOWEST} to {HIGHEST}.",
                )
            asked = {"target": degrees}
            question = f"{mode.capitalize()} the house to {degrees} degrees?"
            setting = {"temperature": degrees}
        elif mode == "off":
            raise HomeError(
                "thermostat_off",
                "The thermostat is off, and the house does not turn it on, so it was left alone.",
            )
        else:
            raise HomeError(
                "thermostat_unavailable",
                "The thermostat is not answering Home Assistant right now, so it was left alone. "
                "Try again in a few minutes.",
            )
        if not confirmed:
            return {"needs_yes": question}
        self.hass.call(
            "climate", "set_temperature", {"entity_id": self.entities.thermostat, **setting}
        )
        held = self._thermostat()
        if any(held[name] != value for name, value in asked.items()):
            raise HomeError(
                "thermostat_held_otherwise",
                f"The thermostat holds {_degrees(held, asked)} now, "
                f"not the {_degrees(asked, asked)} asked for.",
            )
        return {"thermostat": held}

    def volume(
        self, *, percent: object = None, step: object = None, confirmed: bool
    ) -> dict[str, Any]:
        if (percent is None) == (step is None) or step not in (None, "up", "down"):
            raise HomeError(
                "invalid_arguments", "Give the TV's volume as a percent, or as up or down."
            )
        level = _whole(percent)
        if percent is not None and (level is None or level < 0 or level > LOUDEST_VOLUME):
            raise HomeError("out_of_range", f"The TV's volume goes from 0 to {LOUDEST_VOLUME}%.")
        reading = self.apple_tv.read()
        if reading.power == "off":
            raise HomeError("tv_off", "The living room TV is off, so its volume was left alone.")
        current = reading.volume
        if current is None:
            raise HomeError(
                "no_volume",
                "The living room TV is not offering its volume to the house right now, "
                "so it was left alone. Try again in a moment.",
            )
        if level is None:
            if step == "up" and current >= LOUDEST_VOLUME:
                raise HomeError(
                    "out_of_range",
                    f"The TV is at {current}%, and the house turns it up no further "
                    f"than {LOUDEST_VOLUME}%.",
                )
            change = VOLUME_STEP if step == "up" else -VOLUME_STEP
            level = max(0, min(current + change, LOUDEST_VOLUME))
        # Turning it down never needs a yes, wherever it starts.
        if level > QUIET_VOLUME and level > current and not confirmed:
            return {"needs_yes": f"Turn the TV up to {level}%?"}
        return {"tv": {"power": reading.power, "volume": self.apple_tv.set_volume(level)}}

    def music(self, *, action: object) -> dict[str, Any]:
        service = MUSIC_ACTIONS.get(action) if isinstance(action, str) else None
        if service is None:
            raise HomeError("invalid_arguments", f"The music can {', '.join(MUSIC_ACTIONS)}.")
        self._music_on_tv()
        self.hass.call("media_player", service, {"entity_id": self.entities.spotify})
        return {"music": self._music()}

    def _spotify_devices(self) -> list[str]:
        """Spotify's places to play, refreshed first, since Home Assistant polls them slowly."""
        self.hass.call("household_home", "refresh_spotify", {"entity_id": self.entities.spotify})
        return self.hass.state(self.entities.spotify).get("attributes", {}).get("source_list") or []

    def _tv_is_listed(self) -> bool:
        return self.entities.tv_spotify_name in self._spotify_devices()

    def _open_spotify_on_tv(self) -> None:
        """Wake the TV, bring Spotify to the front, and wait until Spotify can play there."""
        self.apple_tv.open_spotify()
        for check in range(LISTING_CHECKS):
            if check:
                self.wait(LISTING_PAUSE_SECONDS)
            if self._tv_is_listed():
                return
        raise HomeError(
            "spotify_not_on_tv",
            "Spotify opened on the living room TV, but in half a minute it never showed up "
            "as a place to play. Spotify may be signed out on the TV, or signed in to a "
            "different account.",
        )

    def _find(
        self, *, link: object, query: object, kind: object
    ) -> tuple[str, dict[str, Any] | None]:
        """The Spotify uri to play, and what Spotify's search found when it was asked."""
        # A model may fill the fields it does not use with empty strings.
        link, query, kind = (None if value == "" else value for value in (link, query, kind))
        if link is not None:
            found = SPOTIFY_LINK.fullmatch(link) if isinstance(link, str) else None
            if found is None or query is not None or kind is not None:
                raise HomeError(
                    "not_spotify",
                    "Give a full open.spotify.com link to a playlist, album, artist or track.",
                )
            return f"spotify:{found.group(1)}:{found.group(2)}", None
        if (
            not isinstance(query, str)
            or not query.strip()
            or len(query) > MAX_QUERY_CHARACTERS
            or kind not in PLAY_KINDS
        ):
            raise HomeError(
                "invalid_arguments",
                "Say what to play and whether it is a track, album, artist or playlist.",
            )
        answer = self.hass.ask(
            "household_home",
            "search_spotify",
            {"entity_id": self.entities.spotify, "query": query.strip(), "kind": kind},
        )
        uri = answer.get("uri")
        if not isinstance(uri, str):
            raise HomeError("not_found", f'Spotify found no {kind} for "{query.strip()}".')
        return uri, {"name": answer.get("name"), "by": answer.get("by")}

    def play(
        self, *, link: object = None, query: object = None, kind: object = None
    ) -> dict[str, Any]:
        uri, found = self._find(link=link, query=query, kind=kind)
        self._open_spotify_on_tv()
        self.hass.call(
            "household_home",
            "play_spotify",
            {
                "entity_id": self.entities.spotify,
                "device": self.entities.tv_spotify_name,
                "uri": uri,
            },
        )
        answer: dict[str, Any] = {"music": self._music()}
        if found is not None:
            answer["found"] = found
        return answer

    def open_spotify(self) -> dict[str, Any]:
        self._open_spotify_on_tv()
        return {"tv": "on", "spotify": "open", "music": self._music()}

    def youtube(self, *, link: object) -> dict[str, Any]:
        found = YOUTUBE_LINK.fullmatch(link) if isinstance(link, str) else None
        if found is None:
            raise HomeError("not_youtube", "Give a youtube.com or youtu.be link to one video.")
        video = found.group(1) or found.group(2)
        if not self.apple_tv.open_youtube(video):
            raise HomeError(
                "youtube_not_playing",
                "YouTube opened on the living room TV, but the video has not started. It may "
                "be asking who is watching: pick that with the remote, then ask again.",
            )
        return {"youtube": {"video": video, "playing": True}}

    def video(self, *, control: object, seconds: object = None) -> dict[str, Any]:
        """Control what plays on the TV in YouTube, read back as playing or not."""
        amount = _whole(seconds)
        is_seek = control == "seek"
        if (
            control not in VIDEO_CONTROLS
            or (seconds is not None) != is_seek
            or (is_seek and (amount is None or amount == 0 or abs(amount) > LONGEST_SEEK_SECONDS))
        ):
            raise HomeError(
                "invalid_arguments",
                "A video can pause, resume, go to the next or previous one, or seek by a "
                f"number of seconds up to {LONGEST_SEEK_SECONDS}, negative to go back.",
            )
        is_playing = self.apple_tv.control(str(control), amount or 0)
        return {"video": {"playing": is_playing}}

    def tv_power(self, *, power: object) -> dict[str, Any]:
        if power == "on":
            self.apple_tv.wake()
        elif power == "off":
            self.apple_tv.sleep()
        else:
            raise HomeError("invalid_arguments", "The TV can be turned on or off.")
        return {"tv": power}
