"""The planner: real windows, learned taste, a capped research budget."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from household.app import Household
from household.planner import (
    HOUSEHOLD_TZ,
    RESEARCH_TURNS_PER_DAY,
    CalendarEvent,
    Candidate,
    ResearchBudget,
    ResearchBudgetSpent,
    TasteMemory,
    TasteSignal,
    Window,
    choose_window,
    compose_proposal,
    free_windows,
    rank_candidates,
    tags_for,
)

from .conftest import FakeClock

# The window the tests search, matching the real horizon a planner run uses.
HORIZON_START = datetime(2026, 9, 21, 0, 0, tzinfo=UTC)
HORIZON_END = datetime(2026, 9, 28, 0, 0, tzinfo=UTC)

FRIDAY = Window(
    start=datetime(2026, 9, 25, 23, 0, tzinfo=UTC), end=datetime(2026, 9, 26, 4, 0, tzinfo=UTC)
)
SATURDAY = Window(
    start=datetime(2026, 9, 26, 23, 0, tzinfo=UTC), end=datetime(2026, 9, 27, 4, 0, tzinfo=UTC)
)


def local(year: int, month: int, day: int, hour: int, minute: int = 0) -> datetime:
    return datetime(year, month, day, hour, minute, tzinfo=HOUSEHOLD_TZ)


def event(
    summary: str, start: datetime, hours: float = 1, *, all_day: bool = False
) -> CalendarEvent:
    return CalendarEvent(
        uid=summary.lower().replace(" ", "-"),
        summary=summary,
        start=start,
        end=start + timedelta(hours=hours),
        all_day=all_day,
    )


@pytest.fixture
def taste(household: Household, clock: FakeClock) -> TasteMemory:
    return TasteMemory(household.database, clock=clock)


# -- windows -------------------------------------------------------------------


def test_an_empty_evening_is_a_window() -> None:
    windows = free_windows([], horizon_start=HORIZON_START, horizon_end=HORIZON_END)

    friday = [window for window in windows if window.start.astimezone(HOUSEHOLD_TZ).weekday() == 4]
    assert len(friday) == 1
    assert friday[0].start == local(2026, 9, 25, 18)
    assert friday[0].end == local(2026, 9, 25, 23)


def test_an_event_in_the_middle_of_the_evening_leaves_what_is_left() -> None:
    windows = free_windows(
        [event("Small group", local(2026, 9, 25, 20, 30), hours=1.5)],
        horizon_start=HORIZON_START,
        horizon_end=HORIZON_END,
    )

    friday = [
        window for window in windows if window.start.astimezone(HOUSEHOLD_TZ).date().day == 25
    ]
    assert [(window.start, window.end) for window in friday] == [
        (local(2026, 9, 25, 18), local(2026, 9, 25, 20, 30))
    ]


def test_an_evening_with_no_two_hour_gap_is_not_offered() -> None:
    windows = free_windows(
        [event("Teddy Swims concert", local(2026, 9, 25, 19), hours=3)],
        horizon_start=HORIZON_START,
        horizon_end=HORIZON_END,
    )

    assert not [
        window for window in windows if window.start.astimezone(HOUSEHOLD_TZ).date().day == 25
    ]


def test_an_all_day_event_takes_the_whole_day() -> None:
    windows = free_windows(
        [event("Pack Expo", local(2026, 9, 25, 0), hours=48, all_day=True)],
        horizon_start=HORIZON_START,
        horizon_end=HORIZON_END,
    )

    days = {window.start.astimezone(HOUSEHOLD_TZ).day for window in windows}
    assert 25 not in days
    assert 26 not in days
    assert 24 in days


def test_friday_wins_over_a_free_wednesday() -> None:
    windows = free_windows([], horizon_start=HORIZON_START, horizon_end=HORIZON_END)

    chosen = choose_window(windows)

    assert chosen is not None
    assert chosen.start.astimezone(HOUSEHOLD_TZ).weekday() == 4


def test_any_evening_will_do_when_neither_weekend_day_is_free() -> None:
    busy = [
        event("Teddy Swims concert", local(2026, 9, 25, 18), hours=5),
        event("Auntie's 75th", local(2026, 9, 26, 12), hours=11),
        event("Church and lunch", local(2026, 9, 27, 12), hours=11),
    ]
    windows = free_windows(busy, horizon_start=HORIZON_START, horizon_end=HORIZON_END)

    chosen = choose_window(windows)

    assert chosen is not None
    assert chosen.start.astimezone(HOUSEHOLD_TZ).weekday() not in (4, 5)


def test_no_free_evening_is_an_honest_none() -> None:
    assert choose_window([]) is None


# -- taste ---------------------------------------------------------------------


def test_the_shared_calendar_is_what_the_household_actually_did(taste: TasteMemory) -> None:
    taste.learn_from_calendar(
        [
            event("Church and Nathan's Bday", local(2026, 9, 6, 17)),
            event("Church", local(2026, 9, 13, 17)),
            event("Teddy Swims concert with Mario & Megan", local(2026, 9, 12, 19)),
        ]
    )

    ranked = dict(taste.ranked())

    assert ranked["worship"] > ranked["live music"]


def test_what_they_said_in_the_group_outweighs_what_they_merely_attended(
    taste: TasteMemory,
) -> None:
    taste.learn_from_calendar([event("Church", local(2026, 9, 13, 17))])
    learned = taste.learn_from_group(
        text="that concert was amazing, we should go back", person_id="franco", ref="m1"
    )

    ranked = dict(taste.ranked())

    assert learned == 1
    assert ranked["live music"] > ranked["worship"]


def test_a_sentence_with_no_opinion_teaches_nothing(taste: TasteMemory) -> None:
    assert taste.learn_from_group(text="what time is church", person_id="gia", ref="m1") == 0
    assert taste.ranked() == []


def test_a_dislike_pushes_a_tag_out_of_the_ranking(taste: TasteMemory) -> None:
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])
    taste.learn_from_group(text="that concert was too loud, never again", person_id="gia", ref="m1")

    assert "live music" not in dict(taste.ranked())


@pytest.mark.parametrize(
    "complained",
    [
        "nothing was open and dinner was too expensive, but the walk was amazing",
        "nothing about that restaurant was too expensive, the tacos were amazing",
        "is it too expensive? the tacos at that restaurant were amazing",
    ],
)
def test_a_complaint_word_keeps_a_sentence_out_of_the_liking_reading(
    taste: TasteMemory, complained: str
) -> None:
    """Failing to read a complaint must not promote the sentence to an endorsement.

    Each carries a complaint the guards cannot read as asserted: a negation in front
    of it, and a complaint somebody asked rather than made. Falling through to the
    liking reading would store the complaint itself at the heaviest weight, and the
    tag it complains about would then be given to both of them in the group as the
    reason for going again.
    """
    assert taste.learn_from_group(text=complained, person_id="gia", ref="m1") == 0
    assert taste.ranked() == []


@pytest.mark.parametrize(
    ("said", "tag"),
    [
        ("the concert was amazing and the restaurant was awful", "live music"),
        ("dinner and drinks were amazing", "food"),
        ("did the corn maze on saturday and it was amazing", "autumn"),
    ],
)
def test_a_coordinated_clause_is_a_clause(taste: TasteMemory, said: str, tag: str) -> None:
    """ "And" joins two clauses as surely as "but" does, and nothing was stopping there.

    "The concert was amazing and the restaurant was awful" gave food the heaviest
    positive weight there is. The other two are what the boundary must not cost: a
    liking still finds a subject in the conjunct beside it when that conjunct states
    nothing of its own.
    """
    learned = taste.learn_from_group(text=said, person_id="franco", ref="m1")

    assert learned == 1
    assert dict(taste.ranked()) == {tag: TasteMemory.WEIGHTS["enjoyed"]}


def test_a_coordinator_bounds_a_subject_and_not_a_negation(taste: TasteMemory) -> None:
    """ "And" separates two subjects, never a negation from what it negates.

    "I don't think the concert and the dinner were amazing" is one thing said about
    two. Reading the coordinator as a boundary for the negation guard as well left the
    second conjunct looking like a plain liking, at the heaviest weight.
    """
    said = "I don't think the concert and the dinner were amazing"

    assert taste.learn_from_group(text=said, person_id="gia", ref="m1") == 0
    assert taste.ranked() == []


@pytest.mark.parametrize(
    "said",
    [
        "loved it, shame about dinner",
        "amazing day, awful dinner",
    ],
)
def test_a_liking_does_not_borrow_forward(taste: TasteMemory, said: str) -> None:
    """A fragment after a liking is its own remark, not the liking's subject.

    Both of these gave food the heaviest positive weight from the only clause in the
    message that mentions dinner, and both clauses say the opposite. A liking looks
    backwards for a subject now, the way a complaint already did: "what a concert, it
    was amazing" is the shape the looking exists for and it points that way.
    """
    assert taste.learn_from_group(text=said, person_id="gia", ref="m1") == 0
    assert taste.ranked() == []


@pytest.mark.parametrize(
    "complained",
    [
        "that concert was amazing, the parking, never again",
        "the concert was amazing; never again",
        "the restaurant was amazing, never again",
    ],
)
def test_a_complaint_does_not_step_over_a_statement(taste: TasteMemory, complained: str) -> None:
    """Reaching back stops at the first clause that states something of its own.

    The first steps over a subject outside the vocabulary to reach the concert the
    message praised. The second crosses a semicolon, which ends a statement as surely
    as a full stop. The third reaches into a statement across a comma, which only a
    contrast word licenses, because a contrast is what marks the correction of what
    precedes it.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])

    learned = taste.learn_from_group(text=complained, person_id="gia", ref="m1")

    assert learned == 0
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["attended"]}


def test_a_complaint_lands_on_its_own_subject_when_it_has_one(taste: TasteMemory) -> None:
    """A complaint about the restaurant is not one word against the concert.

    The reading is the sentence's and the complaint is a clause's, so handing the
    sentence's reading to every tag in it took four points off live music for a
    concert that had just been called amazing. The praised tag earns nothing either:
    the sentence is mixed, and silence is what this module does with one it cannot
    resolve.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])

    learned = taste.learn_from_group(
        text="that concert was amazing but the restaurant was too expensive",
        person_id="gia",
        ref="m1",
    )

    assert learned == 1
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["attended"]}


@pytest.mark.parametrize(
    "complained",
    [
        "the concert was amazing, never again at that restaurant",
        "the restaurant was too expensive. you thought the concert was too loud?",
    ],
)
def test_a_complaint_names_its_subject_through_its_own_words(
    taste: TasteMemory, complained: str
) -> None:
    """Two ways the complaint clause was reading as having no subject of its own.

    The first carries a negation inside the complaint itself: "never again" puts
    "never" in front of the restaurant, so asking whether the restaurant was negated
    there found nothing and booked the complaint against the concert instead. The
    second is a complaint somebody asked rather than made, which only stays a question
    while the question mark is still in view.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])

    learned = taste.learn_from_group(text=complained, person_id="gia", ref="m1")

    assert learned == 1
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["attended"]}


def test_a_tag_the_sentence_negated_gets_none_of_the_reading(taste: TasteMemory) -> None:
    """The reading belongs to the sentence; the subject has to belong to the clause.

    "I didn't love that concert but dinner was amazing" endorses dinner. Reading the
    sentence as a liking and then handing that liking to every tag in it gave live
    music the heaviest weight on the strength of the half that said the opposite.
    """
    learned = taste.learn_from_group(
        text="I didn't love that concert but dinner was amazing", person_id="gia", ref="m1"
    )

    assert learned == 1
    assert dict(taste.ranked()) == {"food": TasteMemory.WEIGHTS["enjoyed"]}


@pytest.mark.parametrize(
    "said",
    [
        "Had an amazing time at the concert",
        "Have to say that concert was amazing",
    ],
)
def test_a_dropped_subject_is_not_a_question(taste: TasteMemory, said: str) -> None:
    """An inverted question puts its subject straight after the auxiliary.

    Without that second word the guard read every dropped-subject declarative as a
    question, and these are phrasings the family group will actually produce.
    """
    learned = taste.learn_from_group(text=said, person_id="franco", ref="m1")

    assert learned == 1
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["enjoyed"]}


def test_a_negation_behind_the_word_counts_too(taste: TasteMemory) -> None:
    """English disparages after naming the thing as readily as before it.

    "The restaurant was amazing, the concert not so much" was reading the concert as a
    liking at the heaviest weight, because only the part of the clause in front of the
    word was scanned, and then naming live music in the group as a reason.
    """
    learned = taste.learn_from_group(
        text="the restaurant was amazing, the concert not so much", person_id="gia", ref="m1"
    )

    assert learned == 1
    assert dict(taste.ranked()) == {"food": TasteMemory.WEIGHTS["enjoyed"]}


@pytest.mark.parametrize(
    "complained",
    [
        "that concert was amazing, hated the parking",
        "the parking was a nightmare, hated it, but that concert was amazing",
        "that concert was amazing but the parking was too expensive",
    ],
)
def test_a_complaint_about_an_unknown_thing_touches_nothing(
    taste: TasteMemory, complained: str
) -> None:
    """Naming no tag is not the same as naming no subject.

    Parking is deliberately outside the vocabulary, so a complaint about it finds no
    tag in its own clause. Treating that as having no subject at all sent the
    complaint back to the concert the same sentence had praised, in whichever order
    they were typed.

    A complaint states its subject in one of two places: after it, as the thing it is
    about, or before it with a copula joining them. The third of these is the ordinary
    English order and it was the one that still reached back.

    The second of them concedes rather than corrects: the praise is answering the
    complaint rather than being corrected by it, so the tag in front of the complaint
    is not the one being complained about.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])

    learned = taste.learn_from_group(text=complained, person_id="gia", ref="m1")

    assert learned == 0
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["attended"]}


def test_a_contrast_licenses_the_clause_it_corrects_and_not_the_one_it_praises(
    taste: TasteMemory,
) -> None:
    """A complaint with a fronted subject of its own does not also take the praise.

    "That concert was amazing but the restaurant, never again" states the complaint's
    subject in the clause directly in front of it, and that clause states nothing else
    of its own. The contrast was licensing the whole reach rather than the clause it
    corrects, so the complaint was recorded against live music as well and took four
    points off a concert the same sentence called amazing.

    Unlike the unknown-thing cases above, the subject here is one the vocabulary
    holds, so the complaint lands: food is what is being complained about, and it is
    the only thing that moves.
    """
    taste.learn_from_calendar(
        [
            event("Teddy Swims concert", local(2026, 9, 12, 19)),
            event("Dinner at Salerno's", local(2026, 9, 13, 18)),
        ]
    )

    learned = taste.learn_from_group(
        text="that concert was amazing but the restaurant, never again",
        person_id="gia",
        ref="m1",
    )

    assert learned == 1
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["attended"]}


def test_a_line_break_ends_a_thought(taste: TasteMemory) -> None:
    """A phone ends a thought with a newline and no punctuation at all.

    Without it the complaint on the second line reached back to the concert praised on
    the first and took four points off it. Nothing is learned here, which is what this
    module does with a sentence carrying a complaint it cannot place, and the concert
    keeps what the calendar gave it.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])

    learned = taste.learn_from_group(
        text="that concert was amazing\nparking, never again", person_id="gia", ref="m1"
    )

    assert learned == 0
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["attended"]}


@pytest.mark.parametrize(
    ("said", "tag"),
    [
        ("had the best night at that concert, it was amazing", "live music"),
        ("did the corn maze on saturday and it was amazing", "autumn"),
    ],
)
def test_an_ordinary_verb_before_the_is_not_an_inversion(
    taste: TasteMemory, said: str, tag: str
) -> None:
    """A definite noun phrase is an inversion after a copula and an object after a verb.

    "Was the concert amazing" is a question; "had the best night" and "did the corn
    maze" are what somebody did. Accepting "the" after every auxiliary threw both of
    these away without a word.
    """
    learned = taste.learn_from_group(text=said, person_id="franco", ref="m1")

    assert learned == 1
    assert dict(taste.ranked()) == {tag: TasteMemory.WEIGHTS["enjoyed"]}


def test_a_clause_opening_on_anyone_is_not_a_question(taste: TasteMemory) -> None:
    """Nothing is a question because of the word it starts with.

    The guard had a third path that recognised "anyone" on sight, which is not an
    inversion and is not what the rest of it claims to do. It cost this sentence
    entirely. A real question of that shape almost always carries its mark.
    """
    learned = taste.learn_from_group(
        text="anyone who loves live music would have loved that concert",
        person_id="franco",
        ref="m1",
    )

    assert learned == 1
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["enjoyed"]}


@pytest.mark.parametrize(
    "said",
    [
        "loved the concert but the restaurant was a disaster",
        "the concert was amazing though dinner was a letdown",
    ],
)
def test_a_liking_does_not_cross_a_contrast_clause(taste: TasteMemory, said: str) -> None:
    """The clause is the scope for a liking as well as for a complaint.

    Disaster and letdown are outside the complaint vocabulary, so nothing else would
    have stopped food taking the heaviest positive weight there is from a clause
    saying the opposite.
    """
    learned = taste.learn_from_group(text=said, person_id="gia", ref="m1")

    assert learned == 1
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["enjoyed"]}


@pytest.mark.parametrize(
    "complained",
    [
        "the concert was amazing, but a bit too loud",
        "amazing concert but never again on a Friday",
    ],
)
def test_a_determiner_elsewhere_is_not_the_complaint_naming_a_subject(
    taste: TasteMemory, complained: str
) -> None:
    """Only a determiner directly after the complaint says it named something.

    "A bit" and "a Friday" carry one without naming what is being complained about,
    and reading either as a named subject stopped the complaint reaching the concert
    it was actually about.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])

    learned = taste.learn_from_group(text=complained, person_id="gia", ref="m1")

    assert learned == 1
    assert "live music" not in dict(taste.ranked())


def test_a_liking_does_not_look_for_a_subject_past_a_contrast(taste: TasteMemory) -> None:
    """The only clause mentioning dinner calls it a letdown, so dinner learns nothing.

    A liking whose own clause names no tag looks for one, and looking past the "but"
    found the thing the sentence was contrasting against. Letdown is outside the
    complaint vocabulary, so nothing else would have stopped food taking the heaviest
    positive weight there is.
    """
    learned = taste.learn_from_group(
        text="dinner was a letdown but we loved getting out", person_id="gia", ref="m1"
    )

    assert learned == 0
    assert taste.ranked() == []


def test_a_liking_does_not_borrow_a_subject_from_a_statement(taste: TasteMemory) -> None:
    """A comma is crossed to finish a fragment, not to reach into another statement.

    The fallback has to cross a comma, because "what a concert, it was amazing" splits
    one statement across one. "Dinner was a letdown, we loved getting out" is two
    statements, and crossing there gave food the heaviest positive weight there is
    from the only clause in the message that mentions dinner. A copula is what marks a
    clause as stating something of its own.
    """
    learned = taste.learn_from_group(
        text="dinner was a letdown, we loved getting out", person_id="gia", ref="m1"
    )

    assert learned == 0
    assert taste.ranked() == []


def test_a_liking_past_a_contrast_is_lost_rather_than_misplaced(taste: TasteMemory) -> None:
    """The accepted cost of the rule above, pinned so it reads as a decision.

    "The concert was loud but we loved it" is a liking about the concert, and the
    concert sits on the far side of the contrast from the word that likes it. Nothing
    is recorded. That is the direction this module is allowed to be wrong in, and it
    is a trade rather than an oversight.
    """
    learned = taste.learn_from_group(
        text="the concert was loud but we loved it", person_id="franco", ref="m1"
    )

    assert learned == 0
    assert taste.ranked() == []


def test_a_liking_stays_inside_its_own_sentence(taste: TasteMemory) -> None:
    """A liking crosses a clause and not a full stop, the same as a complaint does.

    "Loved the lake. Dinner was a disaster." gave food the heaviest positive weight
    there is, because one sentence held the liking word and the other held the tag.
    Disaster is not in the complaint vocabulary, so nothing stopped it.
    """
    learned = taste.learn_from_group(
        text="loved the lake. dinner was a disaster.", person_id="franco", ref="m1"
    )

    assert learned == 1
    assert dict(taste.ranked()) == {"lake": TasteMemory.WEIGHTS["enjoyed"]}


def test_a_liking_in_each_sentence_lands_in_each(taste: TasteMemory) -> None:
    """Scoping it to the sentence must not cost the second thing they praised."""
    learned = taste.learn_from_group(
        text="loved the concert. dinner was amazing too.", person_id="franco", ref="m1"
    )

    assert learned == 2
    assert dict(taste.ranked()) == {
        "live music": TasteMemory.WEIGHTS["enjoyed"],
        "food": TasteMemory.WEIGHTS["enjoyed"],
    }


@pytest.mark.parametrize(
    ("said", "tag"),
    [
        ("did that corn maze on saturday and it was amazing", "autumn"),
        ("had that restaurant last night, it was amazing", "food"),
    ],
)
def test_a_demonstrative_after_an_ordinary_verb_is_an_object(
    taste: TasteMemory, said: str, tag: str
) -> None:
    """The twin of the "the" case: only a copula makes a following noun phrase a subject.

    "Was that concert amazing" is a question. "Did that corn maze" and "had that
    restaurant" are what somebody did, and reading them as questions threw both away.
    """
    learned = taste.learn_from_group(text=said, person_id="franco", ref="m1")

    assert learned == 1
    assert dict(taste.ranked()) == {tag: TasteMemory.WEIGHTS["enjoyed"]}


def test_a_subordinate_clause_is_not_a_question(taste: TasteMemory) -> None:
    """ "When we went to that concert" opens on a wh-word and asks nothing.

    A question inverts: the wh-word comes before the auxiliary. Without asking for
    that second word, every subordinate clause opening on when, what or why read as a
    question, and the tag sitting in it was thrown away.
    """
    learned = taste.learn_from_group(
        text="when we went to that concert, it was amazing", person_id="franco", ref="m1"
    )

    assert learned == 1
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["enjoyed"]}


def test_a_complaint_stays_inside_its_own_sentence(taste: TasteMemory) -> None:
    """A subjectless complaint reaches back for a subject, but never past a full stop.

    "Loved the concert. The restaurant, never again" is one complaint about the
    restaurant. Reaching across the stop for a subject took four points off a concert
    that had just been called loved.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])

    learned = taste.learn_from_group(
        text="loved the concert. the restaurant, never again", person_id="gia", ref="m1"
    )

    assert learned == 1
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["attended"]}


def test_a_determiner_is_not_a_question(taste: TasteMemory) -> None:
    """A clause opening on "any" is a determiner far more often than a question."""
    learned = taste.learn_from_group(
        text="any night at that restaurant is amazing", person_id="franco", ref="m1"
    )

    assert learned == 1
    assert dict(taste.ranked()) == {"food": TasteMemory.WEIGHTS["enjoyed"]}


@pytest.mark.parametrize(
    "said",
    [
        "honestly I didn't love that concert, the sound was rough",
        "that concert was not amazing",
        "never going to love a concert that loud",
        "I don't love concerts",
        "the concert wasn't too loud at all",
        "that concert wasn't too expensive",
        "I don't think the concert was amazing",
        "I can't say the concert was amazing",
        "I wouldn't say that concert was amazing",
        "nobody loved that concert",
        "none of us loved that concert",
        "neither of us loved the concert",
        "I cannot say the concert was amazing",
    ],
)
def test_a_negated_word_is_not_that_word(taste: TasteMemory, said: str) -> None:
    """A negated liking is not a liking, and a negated complaint is not a complaint.

    Both halves matter, but only one is dangerous: a negated liking read as a liking
    makes the complaint the support for naming that tag in the group as the reason
    for suggesting the same thing again.

    Three of them put the negation on a verb of thought, which is how English usually
    says it and is further from the word than a few tokens, and four put it on the
    subject instead, where there is no verb carrying it at all.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])

    assert taste.learn_from_group(text=said, person_id="gia", ref="m1") == 0
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["attended"]}


@pytest.mark.parametrize(
    "asked",
    [
        "was the concert amazing?",
        "was the concert amazing",
        "should we do dinner, or was that restaurant too expensive?",
        "is that restaurant too expensive?",
    ],
)
def test_a_question_is_not_an_opinion(taste: TasteMemory, asked: str) -> None:
    """Wondering about a thing is not liking it, and not complaining about it either.

    Two of these carry a complaint word and would have removed a tag on the strength
    of a question nobody has answered yet. One drops the question mark, which a phone
    does constantly, so the word order has to carry it.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])

    assert taste.learn_from_group(text=asked, person_id="gia", ref="m1") == 0
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["attended"]}


def test_a_question_after_an_opinion_leaves_the_opinion(taste: TasteMemory) -> None:
    """The nearest terminator decides, so a following question costs nothing."""
    learned = taste.learn_from_group(
        text="that concert was amazing. want to go again?", person_id="gia", ref="m1"
    )

    assert learned == 1
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["enjoyed"]}


@pytest.mark.parametrize(
    "said",
    [
        "I don't like crowds, but that concert was amazing",
        "the concert was amazing, I didn't expect that",
        "no idea how they did it, the concert was amazing",
        "what a concert, it was amazing",
    ],
)
def test_a_negation_elsewhere_in_the_sentence_still_leaves_a_liking(
    taste: TasteMemory, said: str
) -> None:
    """Both guards are scoped to the clause, so something in another one costs nothing.

    Three carry a negation that is not about the liking, and the fourth opens on a
    wh-word that is an exclamation rather than a question.
    """
    assert taste.learn_from_group(text=said, person_id="gia", ref="m1") == 1
    assert dict(taste.ranked()) == {"live music": TasteMemory.WEIGHTS["enjoyed"]}


def test_a_complaint_is_never_the_stated_reason_for_a_pick(
    taste: TasteMemory, clock: FakeClock
) -> None:
    """A tag can outlive a complaint. The complaint still must not be read out.

    Months of concerts keep live music positive after one bad night, so the tag is
    fairly still in the running. Reading Gia's own words back at her as the reason
    for suggesting another one is a different thing entirely.

    Nothing typed in the group is quoted at all now, so this holds by construction
    rather than by filtering. It stays because the rule it pins is the older one:
    what the proposal says has to be true whatever the quoting rule is.
    """
    complaint = "that concert was too loud, never again"
    taste.learn_from_calendar(
        [event(f"Teddy Swims concert {week}", local(2026, 8, 1 + week, 19)) for week in range(4)]
    )
    taste.learn_from_group(
        text="the concert was amazing, we should go back", person_id="franco", ref="m1"
    )
    clock.advance(timedelta(days=1))
    taste.learn_from_group(text=complaint, person_id="gia", ref="m2")
    assert "live music" in dict(taste.ranked())

    text = compose_proposal(
        window=Window(start=local(2026, 9, 25, 18), end=local(2026, 9, 25, 23)),
        candidates=[Candidate("Thalia Hall", "Chicago", "an evening show", ("live music",))],
        taste=taste,
    )

    assert "We picked those because of live music" in text
    assert complaint not in text


def test_the_second_proposal_is_not_the_first(taste: TasteMemory) -> None:
    """The first proposal's outcome, said in the group, is what moves the second one."""
    window = Window(start=local(2026, 9, 25, 18), end=local(2026, 9, 25, 23))
    candidates = [
        Candidate("Il Sogno", "Itasca", "small Italian room", ("food",)),
        Candidate("Elgin Symphony", "Itasca", "an evening concert nearby", ("live music",)),
    ]
    taste.learn_from_calendar([event("Franco and Gia dinner", local(2026, 9, 6, 18))])
    first = compose_proposal(window=window, candidates=candidates, taste=taste)
    assert first.index("Il Sogno") < first.index("Elgin Symphony")

    taste.learn_from_group(
        text="that concert was amazing, we should go back", person_id="franco", ref="m2"
    )
    second = compose_proposal(window=window, candidates=candidates, taste=taste)

    assert first != second
    assert second.index("Elgin Symphony") < second.index("Il Sogno")


def test_a_keyword_inside_a_longer_word_is_not_a_signal() -> None:
    """A wrong label is not a silent one: the tag it picks is read out to both.

    "band" sits inside "husband", so a bare substring match recorded "my husband is
    amazing" as live music and then offered live music in the group as the reason
    for suggesting a concert. The group's other two matchers were already on word
    boundaries; this one now is too.
    """
    assert tags_for("my husband is amazing") == ()
    assert tags_for("the dispatcher called") == ()
    assert tags_for("bankruptcy hearing") == ()

    # And the words they actually use still land, plurals included.
    assert "live music" in tags_for("we love concerts")
    assert "lake" in tags_for("a weekend at the lake house in Fontana")


def test_tags_come_from_the_words_the_household_uses() -> None:
    assert "worship" in tags_for("Church and Nathan's Bday")
    assert "live music" in tags_for("Teddy Swims concert with Mario & Megan")
    assert "autumn" in tags_for("Pumpkin patch with sis and family")
    assert "lake" in tags_for("Weekend at the lake house in Fontana")
    assert tags_for("Oil change (reschedule)") == ()


def test_a_candidate_matching_a_strong_signal_comes_first(taste: TasteMemory) -> None:
    taste.learn_from_group(text="the concert was amazing", person_id="franco", ref="m1")
    candidates = [
        Candidate("Il Sogno", "Itasca", "Italian", ("food",)),
        Candidate("Thalia Hall", "Chicago", "live music", ("live music",)),
    ]

    assert [candidate.name for candidate in rank_candidates(candidates, taste.ranked())] == [
        "Thalia Hall",
        "Il Sogno",
    ]


def test_a_thing_they_said_never_again_to_goes_last(taste: TasteMemory) -> None:
    """A tag the household ruled out has to sort below one nothing is known about.

    The ranking read only the positive scores, so a tag at -3 and a tag the store had
    never heard of were the same number and the research order broke the tie. The
    concert they said never again to led the proposal, numbered first, with no reason
    line to give the household anything to argue with.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])
    taste.learn_from_group(text="that concert was too loud, never again", person_id="gia", ref="m1")
    candidates = [
        Candidate("Another loud gig", "Chicago", "an evening show", ("live music",)),
        Candidate("Mini golf", "Chicago", "eighteen holes", ("outdoors",)),
    ]

    proposal = compose_proposal(window=FRIDAY, candidates=candidates, taste=taste)

    assert taste.ranked() == []
    assert "1. Mini golf - eighteen holes" in proposal
    assert "2. Another loud gig - an evening show" in proposal


# -- research budget -----------------------------------------------------------


def test_research_is_capped_at_one_turn_a_day(household: Household, clock: FakeClock) -> None:
    budget = ResearchBudget(household.database, clock=clock)
    calls: list[int] = []

    def produce() -> list[Candidate]:
        calls.append(1)
        return [Candidate("Il Sogno", "Itasca", "Italian", ("food",))]

    first = budget.candidates(FRIDAY, produce)
    second = budget.candidates(FRIDAY, produce)

    assert len(calls) == RESEARCH_TURNS_PER_DAY
    assert first == second


def test_tomorrow_gets_its_own_turn(household: Household, clock: FakeClock) -> None:
    budget = ResearchBudget(household.database, clock=clock)
    calls: list[int] = []

    def produce() -> list[Candidate]:
        calls.append(1)
        return [Candidate("Il Sogno", "Itasca", "Italian", ("food",))]

    budget.candidates(FRIDAY, produce)
    clock.advance(timedelta(days=1))
    budget.candidates(FRIDAY, produce)

    assert len(calls) == 2


def test_a_research_turn_that_throws_is_not_retried_into_a_second(
    household: Household, clock: FakeClock
) -> None:
    """A billable loop is the failure mode here, so the turn is spent before it runs."""
    budget = ResearchBudget(household.database, clock=clock)
    calls: list[int] = []

    def produce() -> list[Candidate]:
        calls.append(1)
        raise RuntimeError("the research turn timed out")

    with pytest.raises(RuntimeError):
        budget.candidates(FRIDAY, produce)
    with pytest.raises(ResearchBudgetSpent):
        budget.candidates(FRIDAY, produce)

    assert len(calls) == 1


def test_a_different_evening_does_not_get_last_nights_places(
    household: Household, clock: FakeClock
) -> None:
    """A spent day waits rather than proposing what was found for another window."""
    budget = ResearchBudget(household.database, clock=clock)
    produce = lambda: [Candidate("Il Sogno", "Itasca", "Italian", ("food",))]  # noqa: E731

    budget.candidates(FRIDAY, produce)

    with pytest.raises(ResearchBudgetSpent):
        budget.candidates(SATURDAY, produce)


# -- the proposal --------------------------------------------------------------


def test_the_proposal_claims_only_what_the_calendar_decided(taste: TasteMemory) -> None:
    """The opening claimed the calendar was the only thing either assistant looked at.

    It covered the whole message and was false of two parts of it: the places come
    from a research turn that read the open web, and a reason can name something one
    of them typed in the group. What is true, and what matters to the two people
    reading it, is that nothing but their own calendar decided they are free.
    """
    taste.learn_from_group(text="that restaurant was amazing", person_id="gia", ref="m1")

    text = compose_proposal(
        window=Window(start=local(2026, 9, 25, 18), end=local(2026, 9, 25, 23)),
        candidates=[Candidate("Il Sogno", "Itasca", "small Italian room", ("food",))],
        taste=taste,
    )

    assert "nothing except that calendar decided you are free" in text
    assert "only thing either of us looked at" not in text
    assert "We picked those because of food." in text


def test_a_proposal_names_the_window_the_places_and_the_reason(taste: TasteMemory) -> None:
    taste.learn_from_calendar(
        [event("Church", local(2026, 9, 13, 17)), event("Sunday dinner", local(2026, 9, 13, 18))]
    )
    window = Window(start=local(2026, 9, 25, 18), end=local(2026, 9, 25, 23))

    text = compose_proposal(
        window=window,
        candidates=[
            Candidate("Il Sogno", "Itasca", "small Italian room on Irving Park", ("food",)),
            Candidate("Thalia Hall", "Chicago", "live music in Pilsen", ("live music",)),
        ],
        taste=taste,
    )

    assert "Friday 25 September from 6:00pm to 11:00pm" in text
    assert "Itasca:" in text
    assert "Chicago:" in text
    assert "1. Il Sogno - small Italian room on Irving Park" in text
    assert "2. Thalia Hall - live music in Pilsen" in text
    assert "We picked those because of food (Sunday dinner)." in text
    # worship outranks food and is not a reason for either of these places, so it is
    # not offered as one.
    assert "worship" not in text
    assert '"stop"' in text
    assert "!coordination off" in text


def test_a_proposal_groups_by_whatever_area_the_research_found(taste: TasteMemory) -> None:
    """Home is Itasca, all of Chicagoland is fair game, and the lake house is real."""
    taste.learn_from_group(text="the pumpkin patch was amazing", person_id="gia", ref="m1")
    window = Window(start=local(2026, 10, 10, 12), end=local(2026, 10, 10, 20))

    text = compose_proposal(
        window=window,
        candidates=[
            Candidate(
                "Goebbert's", "Northwest suburbs", "corn maze and a pumpkin field", ("autumn",)
            ),
            Candidate("Lake Geneva Oktoberfest", "Lake Geneva", "lakefront beer tent", ("lake",)),
        ],
        taste=taste,
    )

    assert "Lake Geneva:" in text
    assert "Northwest suburbs:" in text
    assert "Itasca" not in text
    assert text.index("Northwest suburbs:") < text.index("Lake Geneva:")


# -- the clock -----------------------------------------------------------------


def test_a_weekend_afternoon_counts_and_a_weekday_one_does_not() -> None:
    """Franco is at Cognex eight to five, so a Tuesday lunchtime is not free."""
    windows = free_windows([], horizon_start=HORIZON_START, horizon_end=HORIZON_END)
    by_day = {window.start.astimezone(HOUSEHOLD_TZ).day: window for window in windows}

    assert by_day[26].start.astimezone(HOUSEHOLD_TZ).hour == 12
    assert by_day[27].start.astimezone(HOUSEHOLD_TZ).hour == 12
    assert by_day[22].start.astimezone(HOUSEHOLD_TZ).hour == 18


def test_the_same_evening_expressed_in_any_offset_is_the_same_window() -> None:
    """Six in the evening means six in Itasca, whatever the box's clock says.

    The gateways ran on UTC and put a seven o'clock concert on the calendar at
    breakfast. Nothing in here reads the process's local time, so an event handed
    over as UTC and the same instant handed over as Central agree.
    """
    central = event("Small group", local(2026, 9, 25, 20, 30), hours=1.5)
    as_utc = CalendarEvent(
        uid=central.uid,
        summary=central.summary,
        start=central.start.astimezone(UTC),
        end=central.end.astimezone(UTC),
    )

    assert free_windows(
        [central], horizon_start=HORIZON_START, horizon_end=HORIZON_END
    ) == free_windows([as_utc], horizon_start=HORIZON_START, horizon_end=HORIZON_END)


def test_a_horizon_without_a_timezone_is_refused() -> None:
    """A naive horizon is the bug that shipped once. It is an error, not a guess."""
    with pytest.raises(ValueError, match="instants"):
        free_windows([], horizon_start=datetime(2026, 9, 21), horizon_end=datetime(2026, 9, 28))


def test_a_window_reads_back_in_central_whatever_it_was_built_from() -> None:
    window = Window(
        start=datetime(2026, 9, 25, 23, 0, tzinfo=UTC), end=datetime(2026, 9, 26, 4, 0, tzinfo=UTC)
    )

    assert window.describe() == "Friday 25 September from 6:00pm to 11:00pm"


def test_a_calendar_title_is_tidied_before_it_is_quoted_back(taste: TasteMemory) -> None:
    """Their own titles carry stray spacing, and the proposal reads it out loud."""
    taste.record(
        TasteSignal(
            kind="attended",
            subject="family",
            detail="Auntie Teresa's 75th bday  ",
            source="shared_calendar",
        )
    )

    assert taste.evidence_for("family") == ["Auntie Teresa's 75th bday"]


def test_an_evening_the_horizon_cuts_short_is_not_offered() -> None:
    """A planner run at half past seven must not call ninety minutes a free evening."""
    friday_noon = local(2026, 9, 25, 12)

    assert free_windows([], horizon_start=friday_noon, horizon_end=local(2026, 9, 25, 19, 30)) == []
    assert free_windows([], horizon_start=friday_noon, horizon_end=local(2026, 9, 25, 20, 30)) == [
        Window(start=local(2026, 9, 25, 18), end=local(2026, 9, 25, 20, 30))
    ]


def test_the_same_words_on_two_occasions_are_two_signals(taste: TasteMemory) -> None:
    """Repeated enthusiasm has to outweigh a single mention; a re-read still does not."""
    said = "the concert was amazing"

    assert taste.learn_from_group(text=said, person_id="gia", ref="msg-1") == 1
    assert taste.learn_from_group(text=said, person_id="gia", ref="msg-2") == 1
    assert taste.learn_from_group(text=said, person_id="gia", ref="msg-2") == 0

    assert dict(taste.ranked())["live music"] == 2 * TasteMemory.WEIGHTS["enjoyed"]


def test_reading_the_same_calendar_again_learns_nothing_new(taste: TasteMemory) -> None:
    """The planner runs over an overlapping fortnight each week; one event is one signal."""
    events = [event("Church", local(2026, 9, 13, 17))]

    assert taste.learn_from_calendar(events) == 1
    assert taste.learn_from_calendar(events) == 0


def test_a_proposal_offers_no_reason_rather_than_a_reason_that_does_not_hold(
    taste: TasteMemory,
) -> None:
    """Silence beats a stated reason none of the places actually support."""
    taste.learn_from_calendar([event("Church", local(2026, 9, 13, 17))])
    window = Window(start=local(2026, 9, 25, 18), end=local(2026, 9, 25, 23))

    text = compose_proposal(
        window=window,
        candidates=[Candidate("Il Sogno", "Itasca", "small Italian room", ("food",))],
        taste=taste,
    )

    assert "We picked those because" not in text
    assert "worship" not in text
    assert "Il Sogno" in text


def test_a_tag_learned_from_the_group_is_named_and_never_quoted(taste: TasteMemory) -> None:
    """The conclusion is theirs to check; the sentence behind it is not read out.

    Reading the calendar back needs no interpretation. Reading a typed sentence back
    means having understood it first, and that is the step this module has been wrong
    about every time, so the tag goes in the proposal and the words stay out of it.
    """
    said = "that restaurant was amazing"
    taste.learn_from_group(text=said, person_id="gia", ref="m1")
    window = Window(start=local(2026, 9, 25, 18), end=local(2026, 9, 25, 23))

    text = compose_proposal(
        window=window,
        candidates=[Candidate("Il Sogno", "Itasca", "small Italian room", ("food",))],
        taste=taste,
    )

    assert "We picked those because of food." in text
    assert said not in text
    assert "you said" not in text


def test_a_proposal_does_not_promise_what_neither_assistant_can_do(taste: TasteMemory) -> None:
    """Nothing here books a table or writes the calendar, so it must not imply it."""
    window = Window(start=local(2026, 9, 25, 18), end=local(2026, 9, 25, 23))

    text = compose_proposal(
        window=window,
        candidates=[Candidate("Il Sogno", "Itasca", "small Italian room", ("food",))],
        taste=taste,
    )

    assert "we will handle the rest" not in text
    assert "Neither of us can book a table or put anything on the shared calendar yet" in text


def test_the_vocabulary_matches_the_phrases_the_research_prompt_asks_for() -> None:
    """The prompt asks for fall festivals by name, so the tag for them has to fire.

    "fall fest" is anchored at both ends like every other entry, so it never matched
    "Fall Festival" and the tag was failing silently on its own best case. Found by
    sweeping the whole vocabulary rather than the one entry that was reported.
    """
    for title in ("Cantigny Fall Fest", "Goebbert's Fall Festival", "two fall festivals"):
        assert "autumn" in tags_for(title), title


def test_group_means_the_church_one_in_a_title_and_the_room_in_a_message() -> None:
    """One matcher, two inputs, and the word stopped meaning one thing when it got both."""
    assert "worship" in tags_for("Small group")
    assert tags_for("I love this group") == ()


def test_the_gerunds_they_actually_say_are_in_the_vocabulary() -> None:
    assert "outdoors" in tags_for("we went hiking")
    assert "outdoors" in tags_for("a long walk")
    # Not a walk in the park.
    assert tags_for("parking was awful") == ()


def test_a_sentence_with_both_kinds_of_word_is_a_complaint(taste: TasteMemory) -> None:
    """Amazing but never again is not an endorsement with a caveat.

    Reading it as one contradicts the rule that one clear no removes a tag, and it
    makes the complaint itself the support for naming that tag in the group as the
    reason for suggesting the very thing they objected to.
    """
    taste.learn_from_calendar([event("Teddy Swims concert", local(2026, 9, 12, 19))])
    said = "that concert was amazing but way too loud, never again"

    assert taste.learn_from_group(text=said, person_id="gia", ref="m1") == 1

    assert "live music" not in dict(taste.ranked())
    assert said not in taste.evidence_for("live music")


def test_a_word_has_to_mean_the_same_thing_on_a_calendar_and_in_the_chat() -> None:
    """The matcher has two inputs, so an entry that is ambiguous in either is out.

    `group` was the reported one and `service` was sitting next to it: a furnace
    service is not worship, and a wrong tag here is never silent because it comes
    back out as the stated reason for a suggestion.
    """
    assert tags_for("Furnace service") == ()
    assert tags_for("Car service 9am") == ()
    assert "worship" in tags_for("Sunday service")

    assert tags_for("she swims on Tuesdays") == ()
    assert "live music" in tags_for("Teddy Swims concert with Mario & Megan")

    assert tags_for("I need to park the car") == ()
    assert "outdoors" in tags_for("a walk in the park")


def test_every_entry_means_the_same_thing_in_both_readings() -> None:
    """The admission rule, applied to the whole list rather than to one entry.

    This matcher reads calendar titles and family-group messages with the same eyes.
    An entry earns its place only if it means the same thing in both. The test is
    sameness of subject, not of occasion: walking the dog and a walk at the arboretum
    are both being outdoors, so "walk" belongs; a pumpkin patch and patching drywall
    are not the same thing, so "patch" does not.

    Checking the instances is what let "group" through, then "service" beside it,
    then "tour" beside that. This checks the class.
    """
    other_senses = {
        "Lake Geneva boat tour": "live music",
        "the rubber band snapped": "live music",
        "her wedding band": "live music",
        "Furnace service": "worship",
        "Car service 9am": "worship",
        "I love this group": "worship",
        "the grill is broken again": "food",
        "patch the drywall": "autumn",
        "harvest was early this year": "autumn",
        "I need to park the car": "outdoors",
        "she swims on Tuesdays": "live music",
        "that show was amazing": "live music",
        # A place name's other reading is another place carrying it. Geneva, Illinois
        # is the Kane County seat, twenty-odd miles from Itasca and nothing to do with
        # the lake house.
        "Geneva IL farmers market": "lake",
        "dinner in Geneva on Thursday": "lake",
    }
    for sentence, must_not_fire in other_senses.items():
        assert must_not_fire not in tags_for(sentence), sentence

    household_senses = {
        "Teddy Swims concert with Mario & Megan": "live music",
        "we saw a great gig": "live music",
        "a live band at the Abbey": "live music",
        "Church and Nathan's Bday": "worship",
        "Sunday service": "worship",
        "Small group": "worship",
        "Pumpkin patch with sis and family": "autumn",
        "Harvest festival": "autumn",
        "Goebbert's Fall Festival": "autumn",
        "Cantigny Fall Fest": "autumn",
        "a walk in the park": "outdoors",
        "we went hiking": "outdoors",
        "Weekend at the lake house in Fontana": "lake",
        # Still caught without the "geneva" entry, which is why dropping it cost
        # nothing: "lake" is in both of the phrasings that matter.
        "Lake Geneva": "lake",
        "Geneva Lakes Antique and Classic Boat Show": "lake",
        "Dinner with Kate and Joey": "food",
    }
    for sentence, must_fire in household_senses.items():
        assert must_fire in tags_for(sentence), sentence


def test_an_event_still_ahead_of_them_is_a_plan_and_not_an_attendance(
    taste: TasteMemory,
) -> None:
    """The planner reads forward to find a free evening, and learned from that too.

    So every calendar signal in production was a prediction, and next Friday's
    concert was in line to be quoted back as the reason for suggesting a concert.
    """
    ahead = event("Teddy Swims concert", local(2026, 9, 25, 19))
    behind = event("Church", local(2026, 9, 13, 17))

    assert taste.learn_from_calendar([ahead, behind]) == 1

    assert dict(taste.ranked()) == {"worship": TasteMemory.WEIGHTS["attended"]}
    assert taste.evidence_for("live music") == []


def test_two_sundays_at_church_are_two_signals(taste: TasteMemory) -> None:
    """Every instance of a recurrence shares one UID, so the uid alone was one forever.

    household.service already keys busy intervals on uid plus the occurrence's times,
    and says why in a comment. This is the same fact arriving in a second place.
    """
    recurring = [
        CalendarEvent(
            uid="church-weekly",
            summary="Church",
            start=local(2026, 9, 6 + week * 7, 17),
            end=local(2026, 9, 6 + week * 7, 18),
        )
        for week in range(2)
    ]

    assert taste.learn_from_calendar(recurring) == 2
    assert dict(taste.ranked())["worship"] == 2 * TasteMemory.WEIGHTS["attended"]

    # And re-reading the same fortnight still learns nothing new.
    assert taste.learn_from_calendar(recurring) == 0
