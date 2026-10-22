"""The home key holder's Home Assistant client: its REST calls, and what a failure says.

A fake opener stands in for the network, so nothing reaches Home Assistant.
"""

from __future__ import annotations

import io
import json
import urllib.error
import urllib.request
from email.message import Message

import pytest

from household.home.actions import HomeError
from household.home.hass import HassClient

TOKEN = "eyJhbGciOiJIUzI1NiJ9.secret-token-body.signature"


class Opener:
    def __init__(
        self, answer: object = None, *, status: int = 200, error: Exception | None = None
    ) -> None:
        self.answer = answer
        self.status = status
        self.error = error
        self.requests: list[urllib.request.Request] = []

    def __call__(self, request: urllib.request.Request, timeout: float) -> io.BytesIO:
        self.requests.append(request)
        if self.error:
            raise self.error
        if self.status >= 400:
            raise urllib.error.HTTPError(
                request.full_url,
                self.status,
                "bad",
                Message(),
                io.BytesIO(json.dumps(self.answer).encode()),
            )
        return io.BytesIO(json.dumps(self.answer).encode())


def test_a_state_is_read_with_the_token_as_a_header_only() -> None:
    opener = Opener({"state": "heat_cool", "attributes": {}})
    client = HassClient(base="http://127.0.0.1:8123", token=TOKEN, opener=opener)
    assert client.state("climate.thermostat") == {"state": "heat_cool", "attributes": {}}
    request = opener.requests[0]
    assert request.full_url == "http://127.0.0.1:8123/api/states/climate.thermostat"
    assert request.get_method() == "GET"
    assert request.get_header("Authorization") == f"Bearer {TOKEN}"
    assert TOKEN not in request.full_url


def test_an_action_is_posted_as_json() -> None:
    opener = Opener([])
    client = HassClient(base="http://127.0.0.1:8123", token=TOKEN, opener=opener)
    client.call(
        "climate",
        "set_temperature",
        {"entity_id": "climate.thermostat", "target_temp_low": 70},
    )
    request = opener.requests[0]
    assert request.full_url == "http://127.0.0.1:8123/api/services/climate/set_temperature"
    assert request.get_method() == "POST"
    assert isinstance(request.data, bytes)
    assert json.loads(request.data) == {
        "entity_id": "climate.thermostat",
        "target_temp_low": 70,
    }


def test_a_refusal_carries_home_assistants_words_and_never_the_token() -> None:
    opener = Opener({"message": "Heat and cool setpoints must be 5 degrees apart"}, status=400)
    client = HassClient(base="http://127.0.0.1:8123", token=TOKEN, opener=opener)
    with pytest.raises(HomeError) as refused:
        client.call("climate", "set_temperature", {})
    assert refused.value.code == "home_assistant_refused"
    assert "5 degrees apart" in refused.value.message
    assert TOKEN not in refused.value.message


@pytest.mark.parametrize(
    ("error", "code"),
    [
        (urllib.error.URLError("connection refused"), "home_assistant_unreachable"),
        (TimeoutError("timed out"), "home_assistant_unreachable"),
    ],
)
def test_an_unreachable_home_assistant_says_so(error: Exception, code: str) -> None:
    client = HassClient(base="http://127.0.0.1:8123", token=TOKEN, opener=Opener(error=error))
    with pytest.raises(HomeError) as refused:
        client.state("climate.thermostat")
    assert refused.value.code == code


def test_an_unknown_entity_is_named_as_missing() -> None:
    client = HassClient(
        base="http://127.0.0.1:8123",
        token=TOKEN,
        opener=Opener({"message": "Entity not found."}, status=404),
    )
    with pytest.raises(HomeError) as refused:
        client.state("climate.nowhere")
    assert refused.value.code == "not_found"


@pytest.mark.parametrize(
    "name", ["../api/config", "climate.kitchen/../../x", "CLIMATE.X", "climate."]
)
def test_an_odd_entity_or_action_name_never_reaches_a_url(name: str) -> None:
    opener = Opener({})
    client = HassClient(base="http://127.0.0.1:8123", token=TOKEN, opener=opener)
    with pytest.raises(HomeError):
        client.state(name)
    with pytest.raises(HomeError):
        client.call("climate", name, {})
    assert opener.requests == []


def test_an_action_that_answers_asks_for_its_response_and_returns_it() -> None:
    answer = {"changed_states": [], "service_response": {"uri": "spotify:track:x", "name": "Song"}}
    opener = Opener(answer)
    client = HassClient(base="http://127.0.0.1:8123", token=TOKEN, opener=opener)
    assert client.ask("household_home", "search_spotify", {"query": "Song"}) == {
        "uri": "spotify:track:x",
        "name": "Song",
    }
    request = opener.requests[0]
    assert request.full_url == (
        "http://127.0.0.1:8123/api/services/household_home/search_spotify?return_response"
    )
    assert request.get_method() == "POST"


@pytest.mark.parametrize("answer", [[], {"changed_states": []}, {"service_response": None}])
def test_an_action_with_no_response_answers_empty(answer: object) -> None:
    client = HassClient(base="http://127.0.0.1:8123", token=TOKEN, opener=Opener(answer))
    assert client.ask("household_home", "search_spotify", {}) == {}
