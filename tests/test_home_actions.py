"""The home key holder's actions: what Corey and Denise may do to the house, and where it stops.

Home Assistant and the Apple TV are fakes here, so nothing reaches the house.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import pytest

from household.home.actions import (
    LISTING_CHECKS,
    LISTING_PAUSE_SECONDS,
    Entities,
    Home,
    HomeError,
    TVReading,
)

THERMOSTAT = "climate.thermostat"
SPOTIFY = "media_player.spotify_household"
TV_NAME = "Living Room"
PLAYLIST = "https://open.spotify.com/playlist/37i9dQZF1DX4xuWVBs4FgJ?si=abc123"
FOUND = {
    "uri": "spotify:track:5Q0Nhxo0l2bP3pNjpGJwV1",
    "name": "Shake It Off",
    "by": "Taylor Swift",
}


class FakeHass:
    def __init__(self) -> None:
        self.states: dict[str, dict[str, Any]] = {
            THERMOSTAT: {
                "state": "heat_cool",
                "attributes": {
                    "current_temperature": 71.7,
                    "target_temp_low": 66.5,
                    "target_temp_high": 71.5,
                    "hvac_action": "idle",
                    "hvac_modes": ["heat_cool", "heat", "cool", "off"],
                },
            },
            SPOTIFY: {
                "state": "idle",
                "attributes": {"volume_level": 0.25, "source_list": ["Franco's iPhone"]},
            },
        }
        self.calls: list[tuple[str, str, dict[str, Any]]] = []
        self.refusal: str | None = None
        self.on_device_refresh: Callable[[], None] = lambda: None
        self.search_answer: dict[str, Any] = dict(FOUND)
        # What the thermostat holds after a set, when it is not what was asked for.
        self.held: dict[str, Any] = {}

    def state(self, entity_id: str) -> dict[str, Any]:
        return self.states[entity_id]

    def ask(self, domain: str, service: str, data: dict[str, Any]) -> dict[str, Any]:
        self.calls.append((domain, service, data))
        return self.search_answer

    def call(self, domain: str, service: str, data: dict[str, Any]) -> None:
        self.calls.append((domain, service, data))
        if self.refusal and domain != "homeassistant":
            raise HomeError("home_assistant_refused", self.refusal)
        if (domain, service) == ("household_home", "refresh_spotify"):
            self.on_device_refresh()
        if (domain, service) == ("household_home", "play_spotify"):
            self.states[SPOTIFY]["state"] = "playing"
            self.states[SPOTIFY]["attributes"].update(source=data["device"], media_title="Song")
        if (domain, service) == ("climate", "set_temperature"):
            # As Home Assistant's ecobee integration does: a range only on auto, one
            # temperature only on heat or cool, and any mode passed with them ignored.
            thermostat = self.states[THERMOSTAT]
            setting = {
                key: value for key, value in data.items() if key not in ("entity_id", "hvac_mode")
            }
            takes = (
                {"temperature"}
                if thermostat["state"] in ("heat", "cool")
                else {"target_temp_low", "target_temp_high"}
            )
            if set(setting) == takes:
                thermostat["attributes"].update(setting, **self.held)


class FakeTV:
    def __init__(self, *, volume: int | None = 20, power: str = "on") -> None:
        self.steps: list[str] = []
        self.waits: list[float] = []
        self.refusal: HomeError | None = None
        self.reading = TVReading(power=power, volume=volume)
        self.is_youtube_playing = True

    def read(self) -> TVReading:
        if self.refusal:
            raise self.refusal
        return self.reading

    def set_volume(self, level: int) -> int:
        self.steps.append(f"volume {level}")
        self.reading = TVReading(power=self.reading.power, volume=level)
        return level

    def open_youtube(self, video: str) -> bool:
        self.steps.append(f"youtube {video}")
        return self.is_youtube_playing

    def control(self, control: str, seconds: int) -> bool:
        self.steps.append(f"{control} {seconds}")
        return control != "pause"

    def wake(self) -> None:
        self.steps.append("wake")

    def open_spotify(self) -> None:
        if self.refusal:
            raise self.refusal
        self.steps.append("open spotify")

    def sleep(self) -> None:
        self.steps.append("sleep")


def home(hass: FakeHass | None = None, tv: FakeTV | None = None) -> tuple[Home, FakeHass, FakeTV]:
    hass = hass or FakeHass()
    tv = tv or FakeTV()
    entities = Entities(thermostat=THERMOSTAT, spotify=SPOTIFY, tv_spotify_name=TV_NAME)
    return Home(hass=hass, tv=tv, entities=entities, wait=tv.waits.append), hass, tv


def changes(hass: FakeHass) -> list[tuple[str, str]]:
    """What the house was asked to do, leaving out reads of Spotify's devices and search."""
    return [
        (domain, service)
        for domain, service, _ in hass.calls
        if service not in ("refresh_spotify", "search_spotify")
    ]


def on_tv(hass: FakeHass, *, state: str = "playing") -> FakeHass:
    hass.states[SPOTIFY]["state"] = state
    hass.states[SPOTIFY]["attributes"]["source"] = TV_NAME
    return hass


def listed(hass: FakeHass, after: int = 0) -> FakeHass:
    """The TV shows up among Spotify's devices once `after` refreshes have missed it."""
    misses = iter(range(after))

    def update() -> None:
        if next(misses, None) is None:
            hass.states[SPOTIFY]["attributes"]["source_list"] = ["Franco's iPhone", TV_NAME]

    hass.on_device_refresh = update
    return hass


# MARK: - Reading the house


def test_status_is_the_thermostat_and_the_music_as_home_assistant_has_them() -> None:
    house, _, _ = home()
    assert house.status() == {
        "thermostat": {
            "temperature": 71.7,
            "target": None,
            "low": 66.5,
            "high": 71.5,
            "mode": "heat_cool",
            "doing": "idle",
        },
        "music": {"state": "idle", "devices": ["Franco's iPhone"], "tv_ready": False},
        "tv": {"power": "on", "volume": 20},
    }


def test_status_reads_the_one_temperature_the_thermostat_holds_on_heat() -> None:
    house, _, _ = home(on_mode(FakeHass(), "heat"))
    assert house.status()["thermostat"] == {
        "temperature": 70.1,
        "target": 73.0,
        "low": None,
        "high": None,
        "mode": "heat",
        "doing": "heating",
    }


def test_status_still_reads_the_house_when_the_tv_does_not_answer() -> None:
    tv = FakeTV()
    tv.refusal = HomeError("tv_unreachable", "The living room TV did not answer.")
    house, _, _ = home(tv=tv)
    answer = house.status()
    assert answer["tv"] == {"error": "The living room TV did not answer."}
    assert answer["thermostat"]["temperature"] == 71.7


def test_status_refreshes_readiness_without_waking_the_tv_or_changing_music() -> None:
    house, hass, tv = home()

    def refresh_devices() -> None:
        hass.states[SPOTIFY]["attributes"]["source_list"] = [TV_NAME]

    hass.on_device_refresh = refresh_devices

    answer = house.status()

    assert answer["music"]["tv_ready"] is True
    assert answer["music"]["devices"] == [TV_NAME]
    assert answer["music"]["state"] == "idle"
    assert changes(hass) == []
    assert tv.steps == []


# MARK: - The thermostat


def on_mode(hass: FakeHass, mode: str) -> FakeHass:
    """The thermostat as it read on 17 October 2026 after someone put it on heat at 73."""
    hass.states[THERMOSTAT] = {
        "state": mode,
        "attributes": {
            "current_temperature": 70.1,
            "temperature": 73.0 if mode in ("heat", "cool") else None,
            "target_temp_low": None,
            "target_temp_high": None,
            "hvac_action": "heating" if mode == "heat" else "idle",
        },
    }
    return hass


def test_a_range_asks_for_a_yes_first_and_changes_nothing() -> None:
    house, hass, _ = home()
    assert house.thermostat(low=70, high=75, confirmed=False) == {
        "needs_yes": "Set the thermostat to stay between 70 and 75 degrees?",
    }
    assert changes(hass) == []


def test_a_confirmed_range_on_auto_is_set_as_it_is_and_read_back() -> None:
    house, hass, _ = home()
    answer = house.thermostat(low=70, high=75, confirmed=True)
    assert hass.calls == [
        (
            "climate",
            "set_temperature",
            {"entity_id": THERMOSTAT, "target_temp_low": 70, "target_temp_high": 75},
        )
    ]
    assert answer["thermostat"]["low"] == 70
    assert answer["thermostat"]["high"] == 75


@pytest.mark.parametrize(("mode", "question"), [("heat", "Heat"), ("cool", "Cool")])
def test_one_temperature_on_heat_or_cool_asks_then_is_set_and_read_back(
    mode: str, question: str
) -> None:
    house, hass, _ = home(on_mode(FakeHass(), mode))
    assert house.thermostat(target=72, confirmed=False) == {
        "needs_yes": f"{question} the house to 72 degrees?",
    }
    assert changes(hass) == []

    answer = house.thermostat(target=72, confirmed=True)

    assert hass.calls == [
        ("climate", "set_temperature", {"entity_id": THERMOSTAT, "temperature": 72})
    ]
    assert answer["thermostat"]["target"] == 72
    assert answer["thermostat"]["mode"] == mode


def test_the_temperature_it_already_holds_is_set_again_and_reads_the_same() -> None:
    house, _, _ = home(on_mode(FakeHass(), "heat"))
    before = house.status()["thermostat"]
    assert house.thermostat(target=73, confirmed=True) == {"thermostat": before}


@pytest.mark.parametrize(
    ("mode", "given"),
    [
        ("heat_cool", {"target": 72}),
        ("heat_cool", {"low": 70, "high": 75, "target": 72}),
        ("heat", {"low": 70, "high": 75}),
        ("cool", {"high": 75}),
        ("heat", {"low": 70, "target": 72}),
    ],
)
def test_a_setting_for_another_mode_is_refused_unasked(mode: str, given: dict[str, int]) -> None:
    house, hass, _ = home(on_mode(FakeHass(), mode))
    with pytest.raises(HomeError) as refused:
        house.thermostat(**given, confirmed=True)
    assert refused.value.code == "thermostat_mode"
    assert changes(hass) == []


@pytest.mark.parametrize(
    ("low", "high"),
    [
        (61, 70),
        (70, 81),
        (74, 70),
        (70, 71),
        # The ecobee holds heat and cool 5 apart and would spread this to 69 to 74.
        (70, 73),
        (70, 74),
        (70.5, 75),
        ("70", 75),
        (True, 75),
        (None, 75),
    ],
)
def test_a_range_outside_what_the_house_holds_is_refused_unasked(low: object, high: object) -> None:
    house, hass, _ = home()
    with pytest.raises(HomeError) as refused:
        house.thermostat(low=low, high=high, confirmed=True)
    assert refused.value.code == "out_of_range"
    assert "at least 5 above the low" in refused.value.message
    assert changes(hass) == []


@pytest.mark.parametrize("target", [61, 81, 72.5, "72", True, None])
def test_one_temperature_outside_what_the_house_allows_is_refused_unasked(target: object) -> None:
    house, hass, _ = home(on_mode(FakeHass(), "heat"))
    with pytest.raises(HomeError) as refused:
        house.thermostat(target=target, confirmed=True)
    assert refused.value.code == "out_of_range"
    assert changes(hass) == []


@pytest.mark.parametrize(
    ("mode", "code"), [("off", "thermostat_off"), ("unavailable", "thermostat_unavailable")]
)
def test_a_thermostat_that_is_off_or_not_answering_is_left_alone(mode: str, code: str) -> None:
    house, hass, _ = home(on_mode(FakeHass(), mode))
    with pytest.raises(HomeError) as refused:
        house.thermostat(target=72, confirmed=True)
    assert refused.value.code == code
    assert changes(hass) == []


def test_a_thermostat_that_holds_something_else_says_what_it_holds() -> None:
    hass = FakeHass()
    hass.held = {"target_temp_low": 69.0, "target_temp_high": 75.0}
    house, _, _ = home(hass)
    with pytest.raises(HomeError) as refused:
        house.thermostat(low=70, high=75, confirmed=True)
    assert refused.value.code == "thermostat_held_otherwise"
    assert refused.value.message == "The thermostat holds 69 to 75 now, not the 70 to 75 asked for."


def test_what_home_assistant_refuses_comes_back_as_its_answer() -> None:
    hass = FakeHass()
    hass.refusal = "Unable to set the hold"
    house, _, _ = home(hass)
    with pytest.raises(HomeError) as refused:
        house.thermostat(low=70, high=75, confirmed=True)
    assert refused.value.code == "home_assistant_refused"
    assert refused.value.message == "Unable to set the hold"


# MARK: - The TV's volume


def test_volume_up_to_forty_needs_no_yes() -> None:
    house, _, tv = home(tv=FakeTV(volume=20))
    assert house.volume(percent=40, confirmed=False) == {"tv": {"power": "on", "volume": 40}}
    assert tv.steps == ["volume 40"]


def test_volume_over_forty_asks_and_seventy_is_the_ceiling() -> None:
    house, _, tv = home(tv=FakeTV(volume=25))
    assert house.volume(percent=60, confirmed=False) == {"needs_yes": "Turn the TV up to 60%?"}
    assert tv.steps == []
    assert house.volume(percent=60, confirmed=True)["tv"]["volume"] == 60
    for percent in (71, 100, -1, 50.5, "40"):
        with pytest.raises(HomeError) as refused:
            house.volume(percent=percent, confirmed=True)
        assert refused.value.code == "out_of_range"


def test_turning_it_down_needs_no_yes_even_above_forty() -> None:
    house, _, tv = home(tv=FakeTV(volume=65))
    assert house.volume(percent=50, confirmed=False)["tv"]["volume"] == 50
    assert tv.steps == ["volume 50"]


@pytest.mark.parametrize(
    ("current", "step", "level"),
    [(30, "up", 40), (60, "up", 70), (65, "up", 70), (60, "down", 50), (5, "down", 0)],
)
def test_volume_steps_ten_up_or_down_within_the_ceiling(
    current: int, step: str, level: int
) -> None:
    house, _, tv = home(tv=FakeTV(volume=current))
    assert house.volume(step=step, confirmed=True)["tv"]["volume"] == level
    assert tv.steps == [f"volume {level}"]


def test_a_step_up_past_forty_asks_first() -> None:
    house, _, tv = home(tv=FakeTV(volume=40))
    assert house.volume(step="up", confirmed=False) == {"needs_yes": "Turn the TV up to 50%?"}
    assert tv.steps == []


def test_down_from_above_the_ceiling_comes_to_the_ceiling_unasked() -> None:
    house, _, tv = home(tv=FakeTV(volume=90))
    assert house.volume(step="down", confirmed=False)["tv"]["volume"] == 70
    assert tv.steps == ["volume 70"]


def test_up_at_the_ceiling_says_it_goes_no_louder() -> None:
    house, _, tv = home(tv=FakeTV(volume=70))
    with pytest.raises(HomeError) as refused:
        house.volume(step="up", confirmed=True)
    assert refused.value.code == "out_of_range"
    assert "70%" in refused.value.message
    assert tv.steps == []


def test_a_tv_offering_no_volume_keeps_it() -> None:
    tv = FakeTV()
    tv.reading = TVReading(power="on", volume=None)
    house, _, _ = home(tv=tv)
    with pytest.raises(HomeError) as refused:
        house.volume(step="down", confirmed=True)
    assert refused.value.code == "no_volume"
    assert tv.steps == []


def test_a_sleeping_tv_keeps_its_volume() -> None:
    house, hass, tv = home(tv=FakeTV(power="off"))
    with pytest.raises(HomeError) as refused:
        house.volume(percent=20, confirmed=True)
    assert refused.value.code == "tv_off"
    assert tv.steps == []
    assert changes(hass) == []


@pytest.mark.parametrize(
    "arguments",
    [{}, {"percent": 30, "step": "up"}, {"step": "louder"}, {"step": 10}],
)
def test_volume_takes_a_percent_or_a_step(arguments: dict[str, Any]) -> None:
    house, _, tv = home()
    with pytest.raises(HomeError) as refused:
        house.volume(**arguments, confirmed=True)
    assert refused.value.code == "invalid_arguments"
    assert tv.steps == []


# MARK: - Music


@pytest.mark.parametrize(
    ("action", "service"),
    [
        ("pause", "media_pause"),
        ("resume", "media_play"),
        ("next", "media_next_track"),
        ("previous", "media_previous_track"),
    ],
)
def test_the_music_controls_are_the_media_player_actions(action: str, service: str) -> None:
    house, hass, _ = home(on_tv(FakeHass(), state="paused" if action == "resume" else "playing"))
    house.music(action=action)
    assert hass.calls == [("media_player", service, {"entity_id": SPOTIFY})]


def test_controls_leave_music_playing_somewhere_else_alone() -> None:
    hass = FakeHass()
    hass.states[SPOTIFY]["state"] = "playing"
    hass.states[SPOTIFY]["attributes"]["source"] = "Tesla Media Player"
    house, _, _ = home(hass)
    with pytest.raises(HomeError) as refused:
        house.music(action="pause")
    assert refused.value.code == "playing_elsewhere"
    assert "Tesla Media Player" in refused.value.message
    assert changes(hass) == []


def test_controls_with_nothing_playing_say_so() -> None:
    house, hass, _ = home()
    with pytest.raises(HomeError) as refused:
        house.music(action="next")
    assert refused.value.code == "nothing_playing"
    assert refused.value.message == "Nothing is playing on the living room TV."
    assert changes(hass) == []


# MARK: - Playing on the TV


def play_data(uri: str) -> dict[str, Any]:
    return {"entity_id": SPOTIFY, "device": TV_NAME, "uri": uri}


def test_a_named_song_is_found_by_spotify_and_played_on_the_tv() -> None:
    house, hass, tv = home(listed(FakeHass()))

    answer = house.play(query=" Shake It Off Taylor Swift ", kind="track")

    assert hass.calls[0] == (
        "household_home",
        "search_spotify",
        {"entity_id": SPOTIFY, "query": "Shake It Off Taylor Swift", "kind": "track"},
    )
    assert tv.steps == ["open spotify"]
    assert hass.calls[-1] == ("household_home", "play_spotify", play_data(FOUND["uri"]))
    assert answer["found"] == {"name": "Shake It Off", "by": "Taylor Swift"}
    assert answer["music"]["state"] == "playing"
    assert answer["music"]["playing_on"] == TV_NAME


def test_play_wakes_the_tv_opens_spotify_and_waits_until_spotify_lists_it() -> None:
    house, hass, tv = home(listed(FakeHass(), after=2))

    house.play(link=PLAYLIST)

    assert tv.steps == ["open spotify"]
    assert tv.waits == [LISTING_PAUSE_SECONDS, LISTING_PAUSE_SECONDS]
    assert changes(hass) == [("household_home", "play_spotify")]
    assert hass.calls[-1][2] == play_data("spotify:playlist:37i9dQZF1DX4xuWVBs4FgJ")


def test_a_tv_already_listed_still_brings_spotify_forward_and_plays_at_once() -> None:
    hass = FakeHass()
    hass.states[SPOTIFY]["attributes"]["source_list"] = [TV_NAME]
    house, _, tv = home(hass)

    house.play(link=PLAYLIST)

    assert tv.steps == ["open spotify"]
    assert tv.waits == []


def test_changing_the_song_while_one_plays_plays_the_new_one_on_the_tv() -> None:
    house, hass, tv = home(listed(on_tv(FakeHass())))
    house.play(query="Bohemian Rhapsody Queen", kind="track")
    assert changes(hass) == [("household_home", "play_spotify")]
    assert tv.steps == ["open spotify"]


def test_a_tv_spotify_never_lists_says_why_and_nothing_plays() -> None:
    house, hass, tv = home()
    with pytest.raises(HomeError) as refused:
        house.play(link=PLAYLIST)
    assert refused.value.code == "spotify_not_on_tv"
    assert "signed out" in refused.value.message
    assert "not ready" not in refused.value.message
    assert tv.waits == [LISTING_PAUSE_SECONDS] * (LISTING_CHECKS - 1)
    assert changes(hass) == []


def test_a_tv_that_will_not_wake_says_so_and_nothing_plays() -> None:
    tv = FakeTV()
    tv.refusal = HomeError("tv_asleep", "The living room TV is off and did not wake up when asked.")
    house, hass, _ = home(tv=tv)
    with pytest.raises(HomeError) as refused:
        house.play(query="Abbey Road", kind="album")
    assert refused.value.code == "tv_asleep"
    assert changes(hass) == []


def test_nothing_found_is_said_and_the_tv_is_left_alone() -> None:
    hass = FakeHass()
    hass.search_answer = {}
    house, _, tv = home(hass)
    with pytest.raises(HomeError) as refused:
        house.play(query="zzqx no such song", kind="track")
    assert refused.value.code == "not_found"
    assert refused.value.message == 'Spotify found no track for "zzqx no such song".'
    assert tv.steps == []
    assert changes(hass) == []


def test_what_spotify_refuses_comes_back_in_its_words() -> None:
    hass = listed(FakeHass())
    house, _, _ = home(hass)
    hass.refusal = "Spotify refused to play on Living Room. Spotify said: Premium required"
    with pytest.raises(HomeError) as refused:
        house.play(link=PLAYLIST)
    assert refused.value.code == "home_assistant_refused"
    assert "Premium required" in refused.value.message


@pytest.mark.parametrize(
    "arguments",
    [
        {},
        {"query": "Shake It Off"},
        {"query": "Shake It Off", "kind": "song"},
        {"query": "   ", "kind": "track"},
        {"query": "x" * 201, "kind": "track"},
        {"query": ["Shake It Off"], "kind": "track"},
    ],
)
def test_a_query_needs_words_and_its_kind(arguments: dict[str, Any]) -> None:
    house, hass, tv = home()
    with pytest.raises(HomeError) as refused:
        house.play(**arguments)
    assert refused.value.code == "invalid_arguments"
    assert tv.steps == []
    assert hass.calls == []


@pytest.mark.parametrize(
    "link",
    [
        "https://evil.example/playlist/37i9dQZF1DX4xuWVBs4FgJ",
        "https://open.spotify.com.evil.example/playlist/37i9dQZF1DX4xuWVBs4FgJ",
        "http://open.spotify.com/playlist/37i9dQZF1DX4xuWVBs4FgJ",
        "https://open.spotify.com/user/someone",
        "https://open.spotify.com/playlist/short",
        "spotify:playlist:37i9dQZF1DX4xuWVBs4FgJ",
        "easy dinner jazz",
    ],
)
def test_only_an_open_spotify_link_plays(link: str) -> None:
    house, hass, tv = home()
    with pytest.raises(HomeError) as refused:
        house.play(link=link)
    assert refused.value.code == "not_spotify"
    assert tv.steps == []
    assert hass.calls == []


def test_empty_fields_beside_a_query_are_left_out() -> None:
    house, hass, _ = home(listed(FakeHass()))
    house.play(link="", query="Shake It Off Taylor Swift", kind="track")
    assert hass.calls[-1] == ("household_home", "play_spotify", play_data(FOUND["uri"]))


def test_a_link_and_a_query_together_are_refused() -> None:
    house, hass, _ = home()
    with pytest.raises(HomeError) as refused:
        house.play(link=PLAYLIST, query="Shake It Off", kind="track")
    assert refused.value.code == "not_spotify"
    assert hass.calls == []


@pytest.mark.parametrize(
    ("kind", "path"), [("album", "album"), ("artist", "artist"), ("track", "track")]
)
def test_albums_artists_and_tracks_play_as_their_own_kind(kind: str, path: str) -> None:
    house, hass, _ = home(listed(FakeHass()))
    house.play(link=f"https://open.spotify.com/intl-en/{path}/4aawyAB9vmqN3uQ7FjRGTy")
    assert hass.calls[-1][2]["uri"] == f"spotify:{kind}:4aawyAB9vmqN3uQ7FjRGTy"


def test_open_spotify_wakes_the_tv_and_waits_for_spotify_without_playing() -> None:
    house, hass, tv = home(listed(FakeHass(), after=1))
    answer = house.open_spotify()
    assert tv.steps == ["open spotify"]
    assert tv.waits == [LISTING_PAUSE_SECONDS]
    assert changes(hass) == []
    assert answer == {"tv": "on", "spotify": "open", "music": {"state": "idle"}}


# MARK: - YouTube


@pytest.mark.parametrize(
    "link",
    [
        "https://www.youtube.com/watch?v=n0FBb6hnwTo",
        "https://youtu.be/n0FBb6hnwTo?si=abc",
        "https://m.youtube.com/watch?feature=share&v=n0FBb6hnwTo",
        "https://www.youtube.com/shorts/n0FBb6hnwTo",
        "https://music.youtube.com/watch?v=n0FBb6hnwTo&list=RD",
        "https://youtube.com/watch?v=n0FBb6hnwTo",
        "https://www.youtube.com/live/n0FBb6hnwTo?feature=share",
    ],
)
def test_a_youtube_link_plays_its_video_on_the_tv(link: str) -> None:
    house, _, tv = home()
    assert house.youtube(link=link) == {"youtube": {"video": "n0FBb6hnwTo", "playing": True}}
    assert tv.steps == ["youtube n0FBb6hnwTo"]


@pytest.mark.parametrize(
    "link",
    [
        "https://www.youtube.com.evil.example/watch?v=n0FBb6hnwTo",
        "http://youtu.be/n0FBb6hnwTo",
        "https://www.youtube.com/watch?v=short",
        "youtube://watch/n0FBb6hnwTo",
        "https://www.youtube.com/watch?v=n0FBb6hnwTo1",
        "https://www.youtube.com/watch?v=n0FBb6hnwTo\n",
        "goodness of god",
        None,
    ],
)
def test_only_a_youtube_link_to_one_video_opens(link: object) -> None:
    house, _, tv = home()
    with pytest.raises(HomeError) as refused:
        house.youtube(link=link)
    assert refused.value.code == "not_youtube"
    assert tv.steps == []


def test_a_video_that_does_not_start_says_why() -> None:
    tv = FakeTV()
    tv.is_youtube_playing = False
    house, _, _ = home(tv=tv)
    with pytest.raises(HomeError) as refused:
        house.youtube(link="https://youtu.be/n0FBb6hnwTo")
    assert refused.value.code == "youtube_not_playing"
    assert "who is watching" in refused.value.message


@pytest.mark.parametrize(
    ("control", "seconds", "sent", "is_playing"),
    [
        ("pause", None, "pause 0", False),
        ("resume", None, "resume 0", True),
        ("next", None, "next 0", True),
        ("previous", None, "previous 0", True),
        ("seek", 30, "seek 30", True),
        ("seek", -600, "seek -600", True),
    ],
)
def test_video_controls_reach_the_tv_and_read_back(
    control: str, seconds: int | None, sent: str, is_playing: bool
) -> None:
    house, _, tv = home()
    assert house.video(control=control, seconds=seconds) == {"video": {"playing": is_playing}}
    assert tv.steps == [sent]


@pytest.mark.parametrize(
    ("control", "seconds"),
    [("seek", None), ("seek", 0), ("seek", 601), ("seek", 1.5), ("pause", 10), ("stop", None)],
)
def test_video_controls_take_only_their_own_seconds(control: str, seconds: object) -> None:
    house, _, tv = home()
    with pytest.raises(HomeError) as refused:
        house.video(control=control, seconds=seconds)
    assert refused.value.code == "invalid_arguments"
    assert tv.steps == []


# MARK: - The TV


def test_the_tv_turns_on_and_off() -> None:
    house, _, tv = home()
    house.tv_power(power="on")
    house.tv_power(power="off")
    assert tv.steps == ["wake", "sleep"]
    with pytest.raises(HomeError):
        house.tv_power(power="loud")
