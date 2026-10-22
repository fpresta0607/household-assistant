"""The living room Apple TV, reached over the tailnet with pyatv's Companion protocol.

Discovery does not cross the tailnet, so the TV is addressed by hand, as the test of
15 October 2026 proved: its tailnet address, its Companion port and the pairing kept in
the key holder's own state. Each step opens one connection and closes it, and waking or
sleeping counts only once the TV itself reports the new power state.
"""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import Awaitable, Callable, Mapping
from enum import Enum
from typing import Protocol

from .actions import HomeError, TVReading

SPOTIFY_APP = "com.spotify.client"
# The TV refuses a youtube.com web link ("Open URL failed") and plays this form, which Home
# Assistant's Apple TV integration documents for YouTube.
YOUTUBE_LINK = "youtube://watch/{video}"
# A warm YouTube started a video in 2 seconds on 17 October 2026.
YOUTUBE_START_SECONDS = 10.0
# Waking (up to 21 s), pausing what played and starting the video take longer than a step.
YOUTUBE_STEP_SECONDS = 45
CONTROL_SETTLE_SECONDS = 3.0
# The TV's media controls arrive a moment after a connection opens, like its volume.
MEDIA_KNOWN_SECONDS = 2.0
STEP_SECONDS = 30
# Measured on 17 October 2026: asleep to on in about 6 seconds, on to asleep in about 2,
# and a TV that fell asleep ignores every wake for about 10 seconds, so the wake goes
# again every few seconds until the TV takes it.
WAKE_SECONDS = 21.0
WAKE_RESEND_SECONDS = 3.0
SLEEP_SECONDS = 10.0
POWER_CHECK_SECONDS = 0.5
# The TV takes a new volume without announcing it, so pyatv's wait for the announcement is
# cut to this, and the level counts once a fresh connection reads it back.
VOLUME_SECONDS = 2.0
# pyatv says 0 until the TV announces its volume after a connection opens, which took under
# a second on 17 October 2026, so a 0 counts only after this many checks with volume offered.
VOLUME_KNOWN_SECONDS = 3.0
ZERO_CHECKS = 2
UNREACHABLE = "The living room TV did not answer. It may be unplugged or off the network."
# pyatv's own failures share no base class and pyatv is only in the key holder's venv, so
# they are known by name here.
TV_FAILURES = {
    "ConnectionFailedError": "tv_unreachable",
    "ConnectionLostError": "tv_unreachable",
    "OperationTimeoutError": "tv_unreachable",
    "AuthenticationError": "tv_not_paired",
    "InvalidCredentialsError": "tv_not_paired",
}
FAILURE_MESSAGES = {
    "tv_unreachable": UNREACHABLE,
    "tv_not_paired": (
        "The living room TV no longer accepts the house's pairing, so it needs pairing again."
    ),
    # Seen once on 17 October 2026, right after a wake, and gone when asked again.
    "tv_refused": "The living room TV refused the request. Try again in a moment.",
}


class Power(Protocol):
    @property
    def power_state(self) -> Enum: ...

    async def turn_on(self) -> None: ...

    async def turn_off(self) -> None: ...


class Apps(Protocol):
    async def launch_app(self, bundle_id: str) -> None: ...


class Audio(Protocol):
    @property
    def volume(self) -> float: ...

    async def set_volume(self, level: float) -> None: ...


class Remote(Protocol):
    async def play(self) -> None: ...

    async def pause(self) -> None: ...

    async def next(self) -> None: ...

    async def previous(self) -> None: ...

    async def skip_forward(self, time_interval: float = 0.0) -> None: ...

    async def skip_backward(self, time_interval: float = 0.0) -> None: ...


class FeatureInfo(Protocol):
    @property
    def state(self) -> Enum: ...


class Features(Protocol):
    def all_features(self) -> Mapping[Enum, FeatureInfo]: ...


class Device(Protocol):
    """The part of pyatv's connected Apple TV a step uses."""

    @property
    def power(self) -> Power: ...

    @property
    def apps(self) -> Apps: ...

    @property
    def audio(self) -> Audio: ...

    @property
    def features(self) -> Features: ...

    @property
    def remote_control(self) -> Remote: ...

    def close(self) -> object: ...


Connect = Callable[[str, int, str], Awaitable[Device]]


async def pyatv_connect(address: str, port: int, credentials: str) -> Device:
    import pyatv
    from pyatv import conf
    from pyatv.const import PairingRequirement
    from pyatv.const import Protocol as Service

    config = conf.AppleTV(address, "Living room")
    config.add_service(
        conf.ManualService(
            "living-room",
            Service.Companion,
            port,
            {},
            credentials=credentials,
            pairing_requirement=PairingRequirement.Mandatory,
        )
    )
    device: Device = await pyatv.connect(config, asyncio.get_running_loop())
    return device


async def _settle(device: Device, wanted: str, seconds: float) -> str:
    """Wait for the TV to report `wanted` (pyatv's On or Off), and return what it reports."""
    for _ in range(round(seconds / POWER_CHECK_SECONDS)):
        if device.power.power_state.name == wanted:
            break
        await asyncio.sleep(POWER_CHECK_SECONDS)
    return device.power.power_state.name


# pyatv says Unknown on a tvOS that keeps its power to itself, so then there is nothing to
# wait for and nothing to refuse.


async def _wake(device: Device) -> None:
    state = device.power.power_state.name
    if state == "On":
        return
    for _ in range(round(WAKE_SECONDS / WAKE_RESEND_SECONDS)):
        await device.power.turn_on()
        if state != "Off" or await _settle(device, "On", WAKE_RESEND_SECONDS) == "On":
            return
    raise HomeError("tv_asleep", "The living room TV is off and did not wake up when asked.")


async def _sleep(device: Device) -> None:
    state = device.power.power_state.name
    if state == "Off":
        return
    await device.power.turn_off()
    if state == "On" and await _settle(device, "Off", SLEEP_SECONDS) == "On":
        raise HomeError("tv_awake", "The living room TV did not go to sleep when asked.")


async def _open_spotify(device: Device) -> None:
    await _wake(device)
    await device.apps.launch_app(SPOTIFY_APP)


def _offered(device: Device) -> set[str]:
    """The controls the TV offers now, by pyatv's names: Pause only while something plays."""
    return {
        name.name
        for name, info in device.features.all_features().items()
        if info.state.name == "Available"
    }


def _offers_volume(device: Device) -> bool:
    return "Volume" in _offered(device)


async def _offers(device: Device, controls: set[str], seconds: float) -> bool:
    """Wait up to `seconds` for the TV to offer any of `controls`."""
    for _ in range(round(seconds / POWER_CHECK_SECONDS)):
        if controls & _offered(device):
            return True
        await asyncio.sleep(POWER_CHECK_SECONDS)
    return bool(controls & _offered(device))


async def _open_youtube(device: Device, video: str) -> bool:
    """Play a video by its link alone.

    No key such as Select ever goes to YouTube: on its "Who's watching?" screen one can
    choose watching signed out, which a live check did on 17 October 2026. What already
    plays is paused first, so Pause offered afterwards is the new video's.
    """
    await _wake(device)
    if await _offers(device, {"Pause", "Play"}, MEDIA_KNOWN_SECONDS) and "Pause" in _offered(
        device
    ):
        await device.remote_control.pause()
        await _offers(device, {"Play"}, CONTROL_SETTLE_SECONDS)
    await device.apps.launch_app(YOUTUBE_LINK.format(video=video))
    return await _offers(device, {"Pause"}, YOUTUBE_START_SECONDS)


async def _control(device: Device, control: str, seconds: int) -> bool:
    await _offers(device, {"Play", "Pause"}, MEDIA_KNOWN_SECONDS)
    offered = _offered(device)
    remote = device.remote_control
    # Only media commands go, never the remote's buttons: on a focused screen such as
    # YouTube's "Who's watching?", even Play/Pause can act as Select.
    if not offered & {"Play", "Pause"}:
        raise HomeError("nothing_playing", "Nothing is playing on the living room TV.")
    if control == "seek":
        skip = "SkipForward" if seconds > 0 else "SkipBackward"
        if skip not in offered:
            raise HomeError(
                "cannot_seek", "What is playing on the living room TV does not offer skipping."
            )
        await (remote.skip_forward(seconds) if seconds > 0 else remote.skip_backward(-seconds))
    elif control in ("next", "previous"):
        if control.capitalize() not in offered:
            raise HomeError(
                f"no_{control}",
                f"What is playing on the living room TV does not offer a {control} one.",
            )
        await (remote.next() if control == "next" else remote.previous())
    elif control == "pause" and "Pause" in offered:
        await remote.pause()
    elif control == "resume" and "Play" in offered:
        await remote.play()
    expected = {"pause": {"Play"}, "resume": {"Pause"}}.get(control)
    if expected is not None:
        await _offers(device, expected, CONTROL_SETTLE_SECONDS)
    else:
        await asyncio.sleep(CONTROL_SETTLE_SECONDS)
    return "Pause" in _offered(device)


async def _volume(device: Device) -> int | None:
    """The TV's own volume once it has announced it, or None while it offers no control."""
    if device.power.power_state.name == "Off":
        return None
    offered = 0
    for _ in range(round(VOLUME_KNOWN_SECONDS / POWER_CHECK_SECONDS)):
        if _offers_volume(device):
            offered += 1
            if device.audio.volume > 0 or offered > ZERO_CHECKS:
                return round(device.audio.volume)
        await asyncio.sleep(POWER_CHECK_SECONDS)
    return None


async def _read(device: Device) -> TVReading:
    return TVReading(power=device.power.power_state.name.lower(), volume=await _volume(device))


async def _set_volume(device: Device, level: int) -> None:
    with contextlib.suppress(TimeoutError):
        await asyncio.wait_for(device.audio.set_volume(float(level)), VOLUME_SECONDS)


class CompanionTV:
    def __init__(
        self,
        *,
        address: str,
        port: int,
        credentials: str | None,
        connect: Connect = pyatv_connect,
    ) -> None:
        self.address = address
        self.port = port
        self.credentials = credentials
        self.connect = connect

    def _step[T](self, act: Callable[[Device], Awaitable[T]], seconds: float = STEP_SECONDS) -> T:
        credentials = self.credentials
        if credentials is None:
            raise HomeError("tv_not_paired", "The living room TV is not paired with the house yet.")

        async def run() -> T:
            device = await self.connect(self.address, self.port, credentials)
            try:
                return await act(device)
            finally:
                device.close()

        try:
            return asyncio.run(asyncio.wait_for(run(), seconds))
        except (OSError, TimeoutError, ConnectionError):
            raise HomeError("tv_unreachable", UNREACHABLE) from None
        except Exception as error:
            if type(error).__module__ != "pyatv.exceptions":
                raise
            code = TV_FAILURES.get(type(error).__name__, "tv_refused")
            raise HomeError(code, FAILURE_MESSAGES[code]) from None

    def wake(self) -> None:
        self._step(_wake)

    def sleep(self) -> None:
        self._step(_sleep)

    def open_spotify(self) -> None:
        """Wake the TV if it sleeps and bring its Spotify app to the front."""
        self._step(_open_spotify)

    def read(self) -> TVReading:
        return self._step(_read)

    def open_youtube(self, video: str) -> bool:
        """Wake the TV and play a YouTube video, and answer whether the TV shows it playing."""
        return self._step(lambda device: _open_youtube(device, video), YOUTUBE_STEP_SECONDS)

    def control(self, control: str, seconds: int) -> bool:
        """Pause, resume, skip or seek what plays on the TV, and answer whether it plays."""
        return self._step(lambda device: _control(device, control, seconds))

    def set_volume(self, level: int) -> int:
        """Set the TV's own volume, and answer the level a fresh connection reads back."""
        self._step(lambda device: _set_volume(device, level))
        volume = self.read().volume
        if volume is None:
            raise HomeError(
                "volume_not_set", f"The living room TV did not confirm its volume at {level}%."
            )
        # A TV may round a level to its own steps.
        if abs(volume - level) > 1:
            raise HomeError(
                "volume_not_set", f"The living room TV is at {volume}%, not the {level}% asked."
            )
        return volume
