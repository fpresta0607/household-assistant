"""The home key holder's Apple TV: woken, put to sleep and asked to open Spotify over the tailnet.

pyatv is replaced by a fake, so nothing reaches the TV.
"""

from __future__ import annotations

import asyncio
from enum import Enum
from types import SimpleNamespace
from typing import Any

import pytest

from household.home import apple_tv
from household.home.actions import HomeError, TVReading
from household.home.apple_tv import SPOTIFY_APP, CompanionTV


class PowerState(Enum):
    """pyatv's own names for the TV's power."""

    Unknown = 0
    Off = 1
    On = 2


class Feature(Enum):
    Volume = 1
    PlayPause = 2
    Play = 3
    Pause = 4
    Next = 5
    Previous = 6
    SkipForward = 7
    SkipBackward = 8


class FeatureState(Enum):
    Unavailable = 1
    Available = 2


class FakeAudio:
    """The TV's volume as pyatv holds it: 0 until the TV announces it `late` checks in."""

    def __init__(
        self,
        steps: list[str],
        volume: float,
        *,
        announces: bool,
        late: int = 0,
        volume_late: int = 0,
    ) -> None:
        self.steps = steps
        self.announced = volume
        self.volume = volume if late == 0 and volume_late == 0 else 0.0
        self.announces = announces
        self.late = late
        # Checks for which the TV offers volume but pyatv still holds 0.
        self.volume_late = volume_late
        self.offered = True
        # The media controls the TV offers: Pause while something plays, Play while paused.
        self.media: set[str] = set()
        # Checks before the media controls arrive after a connection opens.
        self.media_late = 0

    def all_features(self) -> dict[Enum, Any]:
        if self.late > 0:
            self.late -= 1
        elif self.volume_late > 0:
            self.volume_late -= 1
        elif self.offered:
            self.volume = self.announced
        media: set[str] = set()
        if self.media_late > 0:
            self.media_late -= 1
        else:
            media = self.media
        state = (
            FeatureState.Available if self.offered and self.late == 0 else FeatureState.Unavailable
        )
        return {
            Feature.Volume: SimpleNamespace(state=state),
            Feature.PlayPause: SimpleNamespace(state=FeatureState.Available),
            **{Feature[name]: SimpleNamespace(state=FeatureState.Available) for name in media},
        }

    async def set_volume(self, level: float) -> None:
        self.steps.append(f"set_volume {level}")
        self.volume = self.announced = level
        if not self.announces:
            # What the living room TV does: it takes the level and never says so.
            await asyncio.Event().wait()


class FakeRemote:
    def __init__(self, steps: list[str], audio: FakeAudio) -> None:
        self.steps = steps
        self.audio = audio

    def _now(self, playing: str) -> None:
        self.audio.media = (self.audio.media - {"Play", "Pause"}) | {playing}

    async def play(self) -> None:
        self.steps.append("play")
        self._now("Pause")

    async def pause(self) -> None:
        self.steps.append("pause")
        self._now("Play")

    async def next(self) -> None:
        self.steps.append("next")

    async def previous(self) -> None:
        self.steps.append("previous")

    async def skip_forward(self, time_interval: float = 0.0) -> None:
        self.steps.append(f"skip_forward {time_interval}")

    async def skip_backward(self, time_interval: float = 0.0) -> None:
        self.steps.append(f"skip_backward {time_interval}")


class FakeDevice:
    def __init__(
        self, steps: list[str], power: PowerState, *, obeys: bool, audio: FakeAudio
    ) -> None:
        self.steps = steps
        self.power_state = power
        self.obeys = obeys
        self.power = self
        self.apps = self
        self.audio = audio
        self.features = audio
        self.ignored_wakes = 0
        self.remote_control = FakeRemote(steps, audio)
        # How many launches of a YouTube link it takes before the video plays.
        self.launches_until_playing = 1

    async def turn_on(self) -> None:
        self.steps.append("turn_on")
        if self.ignored_wakes > 0:
            self.ignored_wakes -= 1
        elif self.obeys:
            self.power_state = PowerState.On

    async def turn_off(self) -> None:
        self.steps.append("turn_off")
        if self.obeys:
            self.power_state = PowerState.Off

    async def launch_app(self, bundle_id: str) -> None:
        self.steps.append(f"launch {bundle_id}")
        if bundle_id.startswith("youtube://"):
            self.launches_until_playing -= 1
            if self.launches_until_playing == 0:
                self.audio.media = {"Pause", "Next", "Previous"}

    def close(self) -> set[Any]:
        self.steps.append("close")
        return set()


@pytest.fixture(autouse=True)
def quick_power_checks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(apple_tv, "POWER_CHECK_SECONDS", 0.001)
    monkeypatch.setattr(apple_tv, "WAKE_SECONDS", 0.012)
    monkeypatch.setattr(apple_tv, "WAKE_RESEND_SECONDS", 0.003)
    monkeypatch.setattr(apple_tv, "SLEEP_SECONDS", 0.01)
    monkeypatch.setattr(apple_tv, "VOLUME_SECONDS", 0.01)
    monkeypatch.setattr(apple_tv, "VOLUME_KNOWN_SECONDS", 0.006)
    monkeypatch.setattr(apple_tv, "YOUTUBE_START_SECONDS", 0.006)
    monkeypatch.setattr(apple_tv, "MEDIA_KNOWN_SECONDS", 0.006)
    monkeypatch.setattr(apple_tv, "CONTROL_SETTLE_SECONDS", 0.003)


def tv(
    steps: list[str],
    *,
    power: PowerState = PowerState.Off,
    obeys: bool = True,
    fails: bool = False,
    audio: FakeAudio | None = None,
) -> CompanionTV:
    kept = audio or FakeAudio(steps, 50.0, announces=True)

    async def connect(address: str, port: int, credentials: str) -> FakeDevice:
        steps.append(f"connect {address}:{port}")
        if fails:
            raise OSError("no route to host")
        return FakeDevice(steps, power, obeys=obeys, audio=kept)

    return CompanionTV(
        address="100.64.0.20", port=49153, credentials="kept-in-state", connect=connect
    )


CONNECT = "connect 100.64.0.20:49153"


def test_wake_turns_a_sleeping_tv_on_and_closes() -> None:
    steps: list[str] = []
    tv(steps).wake()
    assert steps == [CONNECT, "turn_on", "close"]


def test_wake_leaves_a_tv_that_is_already_on() -> None:
    steps: list[str] = []
    tv(steps, power=PowerState.On).wake()
    assert steps == [CONNECT, "close"]


def test_a_tv_that_stays_asleep_is_said_plainly() -> None:
    steps: list[str] = []
    with pytest.raises(HomeError) as refused:
        tv(steps, obeys=False).wake()
    assert refused.value.code == "tv_asleep"
    assert refused.value.message == "The living room TV is off and did not wake up when asked."
    assert steps == [CONNECT, "turn_on", "turn_on", "turn_on", "turn_on", "close"]


def test_a_tv_that_just_fell_asleep_is_woken_by_a_later_wake() -> None:
    steps: list[str] = []
    devices: list[FakeDevice] = []

    async def connect(address: str, port: int, credentials: str) -> FakeDevice:
        steps.append("connect")
        device = FakeDevice(
            steps, PowerState.Off, obeys=True, audio=FakeAudio(steps, 20.0, announces=True)
        )
        device.ignored_wakes = 2
        devices.append(device)
        return device

    CompanionTV(address="100.64.0.20", port=49153, credentials="kept", connect=connect).wake()
    assert steps == ["connect", "turn_on", "turn_on", "turn_on", "close"]
    assert devices[0].power_state == PowerState.On


def test_a_tv_that_keeps_its_power_to_itself_is_woken_without_a_refusal() -> None:
    steps: list[str] = []
    tv(steps, power=PowerState.Unknown, obeys=False).wake()
    assert steps == [CONNECT, "turn_on", "close"]


def test_open_spotify_wakes_the_tv_then_launches_the_spotify_app() -> None:
    steps: list[str] = []
    tv(steps).open_spotify()
    assert steps == [CONNECT, "turn_on", f"launch {SPOTIFY_APP}", "close"]
    assert SPOTIFY_APP == "com.spotify.client"


def test_open_spotify_on_a_tv_that_will_not_wake_launches_nothing() -> None:
    steps: list[str] = []
    with pytest.raises(HomeError) as refused:
        tv(steps, obeys=False).open_spotify()
    assert refused.value.code == "tv_asleep"
    assert f"launch {SPOTIFY_APP}" not in steps


def test_read_answers_the_tvs_power_and_its_own_volume() -> None:
    steps: list[str] = []
    reading = tv(
        steps, power=PowerState.On, audio=FakeAudio(steps, 20.000000298, announces=True)
    ).read()
    assert reading == TVReading(power="on", volume=20)
    assert steps == [CONNECT, "close"]


def test_read_waits_for_the_tv_to_announce_its_volume() -> None:
    steps: list[str] = []
    audio = FakeAudio(steps, 20.0, announces=True, late=2)
    assert tv(steps, power=PowerState.On, audio=audio).read().volume == 20


def test_a_real_zero_counts_once_the_tv_has_offered_volume_a_moment() -> None:
    steps: list[str] = []
    audio = FakeAudio(steps, 0.0, announces=True)
    assert tv(steps, power=PowerState.On, audio=audio).read().volume == 0


def test_a_tv_offering_no_volume_reads_none() -> None:
    steps: list[str] = []
    audio = FakeAudio(steps, 20.0, announces=True)
    audio.offered = False
    audio.volume = 0.0
    assert tv(steps, power=PowerState.On, audio=audio).read() == TVReading(power="on", volume=None)


def test_a_sleeping_tv_reads_no_volume_at_once() -> None:
    steps: list[str] = []
    audio = FakeAudio(steps, 20.0, announces=True, late=99)
    assert tv(steps, power=PowerState.Off, audio=audio).read() == TVReading(
        power="off", volume=None
    )
    assert audio.late == 99


def test_a_volume_the_tv_takes_silently_counts_once_it_reads_back() -> None:
    steps: list[str] = []
    audio = FakeAudio(steps, 50.0, announces=False)
    assert tv(steps, power=PowerState.On, audio=audio).set_volume(20) == 20
    assert steps == [CONNECT, "set_volume 20.0", "close", CONNECT, "close"]


def test_a_volume_the_tv_does_not_take_is_said() -> None:
    steps: list[str] = []
    audio = FakeAudio(steps, 50.0, announces=True)

    async def ignore(level: float) -> None:
        steps.append(f"ignored {level}")

    audio.set_volume = ignore  # type: ignore[method-assign]
    with pytest.raises(HomeError) as refused:
        tv(steps, power=PowerState.On, audio=audio).set_volume(20)
    assert refused.value.code == "volume_not_set"
    assert refused.value.message == "The living room TV is at 50%, not the 20% asked."


def test_a_level_the_tv_rounds_to_its_own_step_counts() -> None:
    steps: list[str] = []
    audio = FakeAudio(steps, 50.0, announces=True)

    async def round_up(level: float) -> None:
        audio.volume = audio.announced = level + 1

    audio.set_volume = round_up  # type: ignore[method-assign]
    assert tv(steps, power=PowerState.On, audio=audio).set_volume(55) == 56


def test_a_level_the_tv_does_not_confirm_is_said() -> None:
    steps: list[str] = []
    audio = FakeAudio(steps, 50.0, announces=True)

    async def go_quiet(level: float) -> None:
        audio.offered = False

    audio.set_volume = go_quiet  # type: ignore[method-assign]
    with pytest.raises(HomeError) as refused:
        tv(steps, power=PowerState.On, audio=audio).set_volume(20)
    assert refused.value.message == "The living room TV did not confirm its volume at 20%."


def test_a_volume_announced_after_volume_is_offered_is_waited_for() -> None:
    steps: list[str] = []
    audio = FakeAudio(steps, 50.0, announces=True, volume_late=2)
    assert tv(steps, power=PowerState.On, audio=audio).read().volume == 50


def device_tv(
    launches_until_playing: int = 1,
    media: set[str] | None = None,
    *,
    media_late: int = 0,
    power: PowerState = PowerState.On,
    obeys: bool = True,
) -> tuple[CompanionTV, list[str]]:
    """A paired TV, by default on, offering `media` once `media_late` checks have passed."""
    steps: list[str] = []
    audio = FakeAudio(steps, 20.0, announces=True)
    audio.media = media or set()
    audio.media_late = media_late

    async def connect(address: str, port: int, credentials: str) -> FakeDevice:
        steps.append("connect")
        device = FakeDevice(steps, power, obeys=obeys, audio=audio)
        device.launches_until_playing = launches_until_playing
        return device

    return CompanionTV(
        address="100.64.0.20", port=49153, credentials="kept", connect=connect
    ), steps


def test_a_youtube_video_opens_by_its_youtube_link_and_reads_back_playing() -> None:
    paired, steps = device_tv()
    assert paired.open_youtube("n0FBb6hnwTo") is True
    assert steps == ["connect", "launch youtube://watch/n0FBb6hnwTo", "close"]


def test_a_video_that_does_not_start_gets_no_key_pressed_in_youtube() -> None:
    paired, steps = device_tv(launches_until_playing=2)
    assert paired.open_youtube("n0FBb6hnwTo") is False
    assert steps == ["connect", "launch youtube://watch/n0FBb6hnwTo", "close"]


def test_what_already_plays_is_paused_so_playing_after_is_the_new_video() -> None:
    paired, steps = device_tv(media={"Pause", "Next"}, media_late=1)
    assert paired.open_youtube("n0FBb6hnwTo") is True
    assert steps == ["connect", "pause", "launch youtube://watch/n0FBb6hnwTo", "close"]


def test_a_link_that_does_nothing_while_music_played_is_not_taken_for_the_video() -> None:
    paired, _ = device_tv(launches_until_playing=99, media={"Pause", "Next"})
    assert paired.open_youtube("n0FBb6hnwTo") is False


def test_youtube_on_a_tv_that_will_not_wake_opens_nothing() -> None:
    paired, steps = device_tv(power=PowerState.Off, obeys=False)
    with pytest.raises(HomeError) as refused:
        paired.open_youtube("n0FBb6hnwTo")
    assert refused.value.code == "tv_asleep"
    assert not [step for step in steps if step.startswith("launch")]


def test_a_video_that_never_starts_reads_back_not_playing() -> None:
    paired, _ = device_tv(launches_until_playing=99)
    assert paired.open_youtube("n0FBb6hnwTo") is False


@pytest.mark.parametrize(
    ("control", "seconds", "sent", "is_playing"),
    [
        ("pause", 0, "pause", False),
        ("next", 0, "next", True),
        ("previous", 0, "previous", True),
        ("seek", 30, "skip_forward 30", True),
        ("seek", -15, "skip_backward 15", True),
    ],
)
def test_a_playing_video_is_controlled_and_read_back(
    control: str, seconds: int, sent: str, is_playing: bool
) -> None:
    paired, steps = device_tv(
        media={"Pause", "Next", "Previous", "SkipForward", "SkipBackward"}, media_late=1
    )
    assert paired.control(control, seconds) is is_playing
    assert steps == ["connect", sent, "close"]


@pytest.mark.parametrize(("control", "media"), [("pause", {"Play"}), ("resume", {"Pause"})])
def test_a_pause_or_resume_already_true_sends_nothing(control: str, media: set[str]) -> None:
    paired, steps = device_tv(media=media)
    assert paired.control(control, 0) is (control == "resume")
    assert steps == ["connect", "close"]


@pytest.mark.parametrize("control", ["next", "previous"])
def test_a_next_or_previous_the_tv_does_not_offer_is_said(control: str) -> None:
    paired, steps = device_tv(media={"Pause"})
    with pytest.raises(HomeError) as refused:
        paired.control(control, 0)
    assert refused.value.code == f"no_{control}"
    assert steps == ["connect", "close"]


def test_a_paused_video_resumes() -> None:
    paired, steps = device_tv(media={"Play"})
    assert paired.control("resume", 0) is True
    assert steps == ["connect", "play", "close"]


def test_a_video_that_offers_no_skipping_is_not_seeked() -> None:
    paired, steps = device_tv(media={"Pause"})
    with pytest.raises(HomeError) as refused:
        paired.control("seek", 30)
    assert refused.value.code == "cannot_seek"
    assert steps == ["connect", "close"]


def test_controls_with_nothing_playing_on_the_tv_say_so() -> None:
    paired, steps = device_tv()
    with pytest.raises(HomeError) as refused:
        paired.control("pause", 0)
    assert refused.value.code == "nothing_playing"
    assert steps == ["connect", "close"]


def test_sleep_turns_it_off() -> None:
    steps: list[str] = []
    tv(steps, power=PowerState.On).sleep()
    assert steps == [CONNECT, "turn_off", "close"]


def test_a_tv_that_stays_on_after_sleep_is_said_plainly() -> None:
    with pytest.raises(HomeError) as refused:
        tv([], power=PowerState.On, obeys=False).sleep()
    assert refused.value.code == "tv_awake"


def test_a_tv_that_does_not_answer_is_said_plainly() -> None:
    with pytest.raises(HomeError) as refused:
        tv([], fails=True).wake()
    assert refused.value.code == "tv_unreachable"
    assert "unplugged" in refused.value.message
    assert "kept-in-state" not in refused.value.message


def pyatv_failure(name: str) -> Exception:
    """An exception of pyatv's own, which the key holder knows by its module and name."""
    failure: type[Exception] = type(name, (Exception,), {"__module__": "pyatv.exceptions"})
    return failure("raw pyatv detail")


@pytest.mark.parametrize(
    ("name", "code"),
    [
        ("AuthenticationError", "tv_not_paired"),
        ("ConnectionLostError", "tv_unreachable"),
        ("CommandError", "tv_refused"),
    ],
)
def test_pyatvs_own_failures_are_said_plainly(name: str, code: str) -> None:
    async def connect(address: str, port: int, credentials: str) -> FakeDevice:
        raise pyatv_failure(name)

    paired = CompanionTV(address="100.64.0.20", port=49153, credentials="kept", connect=connect)
    with pytest.raises(HomeError) as refused:
        paired.open_spotify()
    assert refused.value.code == code
    assert "raw pyatv detail" not in refused.value.message


def test_a_failure_that_is_not_the_tvs_is_not_hidden() -> None:
    async def connect(address: str, port: int, credentials: str) -> FakeDevice:
        raise KeyError("a bug")

    paired = CompanionTV(address="100.64.0.20", port=49153, credentials="kept", connect=connect)
    with pytest.raises(KeyError):
        paired.wake()


def test_a_tv_not_yet_paired_is_said_plainly_without_reaching_it() -> None:
    steps: list[str] = []

    async def connect(address: str, port: int, credentials: str) -> FakeDevice:
        steps.append("connect")
        return FakeDevice(
            steps, PowerState.Off, obeys=True, audio=FakeAudio(steps, 0.0, announces=True)
        )

    unpaired = CompanionTV(address="100.64.0.20", port=49153, credentials=None, connect=connect)
    with pytest.raises(HomeError) as refused:
        unpaired.wake()
    assert refused.value.code == "tv_not_paired"
    assert steps == []
