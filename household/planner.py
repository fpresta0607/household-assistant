"""The proactive planner: a free evening on the shared calendar, and a real suggestion.

Three parts, in the order they run.

**Windows.** The shared household calendar is the only availability source. An event
on it makes that time busy for the household, whoever put it there. Nothing here
guesses whose event it is, because a guess must never decide whether a slot is free.

Every boundary in this module is computed in :data:`HOUSEHOLD_TZ` and never in the
process's local time. The gateways ran on UTC once, which put a seven o'clock concert
on the calendar at breakfast, and the container's ``TZ`` is now Central; this module
does not depend on that being true. Six in the evening means six in Itasca on both
sides of a daylight-saving change, on a machine set to anything.

**Taste.** Proposals have to come from what Franco and Gia actually enjoy, so
something records it. What goes in comes from the group, from the shared calendar,
both of which the whole household can already see. Nothing comes from either
person's mail.

**Research.** Finding a restaurant or an event costs something, so it is capped:
:data:`RESEARCH_TURNS_PER_DAY` research turns per calendar day, cached in the
database, and the cache is what a second run of the day reads.
"""

from __future__ import annotations

import dataclasses
import json
import re
import uuid
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from typing import ClassVar
from zoneinfo import ZoneInfo

from .db import Database
from .errors import HouseholdError
from .identity import Clock, system_clock

HOUSEHOLD_TZ = ZoneInfo("America/Chicago")

# An evening out, in Central. Franco is at Cognex eight to five Monday to Friday and
# runs two more businesses around it, so a weekday before six is not free even when
# the calendar is empty. A weekend day is: an afternoon at a patch or up at the lake
# is the whole point of October, and it is not an evening.
EVENING_START = time(18, 0)
WEEKEND_START = time(12, 0)
DAY_END = time(23, 0)
MINIMUM_WINDOW = timedelta(hours=2)
WEEKEND = (5, 6)

# How much of the taste store a proposal is allowed to be built from. Five tags is
# more than the ranking has ever held; it is a bound on a query and not a shape anyone
# tunes. Two quotes because a reason carrying more than that is a paragraph, and three
# reasons because a message naming every tag they have persuades nobody.
RANKED_TAGS = 5
EVIDENCE_PER_TAG = 2
REASONS_IN_A_PROPOSAL = 3

# Friday and Saturday first, because that is what the Overlord asked for. Any other
# evening is still offered when neither is free.
PREFERRED_WEEKDAYS = (4, 5)

# How far ahead the nearest window may be. Four hours' notice is not a date night, it
# is an interruption, and a planner run that happens to land on a Friday should not
# propose that same Friday.
#
# Nothing in this module reads it, on purpose. The rule is applied by the caller that
# owns the clock, which passes ``horizon_start=now + PLANNING_LEAD`` into
# :func:`free_windows`. That caller was scripts/coordination-daemon.py, retired with
# Telegram, so nothing calls the planner now. ``free_windows`` takes the horizon it is
# given and does not second-guess it, so a caller asking for this evening gets this
# evening.
PLANNING_LEAD = timedelta(hours=24)

# The whole research budget. One turn a day, cached; the assistants' own model
# subscription pays for it and no third-party search or places API is called, so the
# incremental spend for a planner run is zero dollars and it cannot loop.
RESEARCH_TURNS_PER_DAY = 1

_ENJOYED = re.compile(
    r"\b(loved|love|loving|amazing|so good|we should go back|again soon|favou?rite)\b",
    re.IGNORECASE,
)
_DECLINED = re.compile(r"\b(hated|too loud|too expensive|never again|not for us)\b", re.IGNORECASE)

# A negated word is not that word. "I didn't love that concert" is not an endorsement
# and "it wasn't too loud" is not a complaint, and neither of them is the clear signal
# this store holds: read the first one as a liking and a complaint becomes the support
# for naming that very tag in the group as the reason for going again, read the second
# as a complaint and a tag goes on the strength of a sentence that said the opposite.
# Neither is flipped into the other reading, because a negated liking is not a dislike.
#
# The negation has to be looked for over the whole clause and not a few words back,
# because the ordinary way to say it in English puts the negation on the verb of
# thought: "I don't think the concert was amazing" has five words between the two, and
# reading it as a liking is the dangerous direction. Scoping it to the clause rather
# than the sentence is what keeps "the patch was so good, no lines either" a liking,
# and keeps the second half of "I don't like crowds, but that concert was amazing".
#
# The ceiling has two halves and both belong here. A word list cannot parse scope, so
# a negation set off by commas inside its own clause ("I don't think, honestly, that
# the concert was amazing") still reads as a liking. And a negation that intensifies
# rather than cancels ("I can't believe how amazing that was", "I never loved a show
# this much") drops a real liking, which is the direction this guard is allowed to be
# wrong in: it costs a signal silently instead of reading a complaint out in the group.
# The question guard below misses in the same quiet direction: a liking sharing an
# unpunctuated sentence with a trailing question ("the food was amazing, was the
# concert too loud?") is dropped. A complaint this cannot read is the loud direction,
# because failing to read one used to promote the sentence to a liking, and that is why
# ``learn_from_group`` decides the complaint branch on the word being present rather
# than on this function. The reading that costs a complaint is now the negation guard
# and not the question guard, as in "nothing was open and dinner was too expensive":
# the subject-dropped declarative that used to be the example here stopped being one
# when the question guard began requiring a subject after the auxiliary.
# The question guard has a quiet miss of its own on the same footing: a subject-dropped
# declarative after a copula ("loved it, was the best concert ever") is the one shape
# the inversion test cannot tell from a real question, because "was the best concert"
# and "was the concert amazing" open identically and only the word order after the noun
# separates them. The liking is lost, silently, which is the tolerable direction.
# One more on the quiet side, because a reader will find it: the reading is chosen for
# the whole message, so a complaint anywhere in it silences every liking in every other
# sentence. "Loved the lake. The restaurant was too expensive." records the complaint
# against the restaurant and loses the lake. The complaint lands correctly and the
# liking is dropped, which is this guard's tolerated direction.
# The upgrade for any of them is asking a model what a sentence means, which is a
# research turn, not a regex, and nothing here should grow into half of one.
# Negation lands on the subject as often as on the verb, so the determiners and
# pronouns are here beside the adverbs: "nobody loved that concert" is the same
# sentence as "I didn't love that concert" as far as this store is concerned. The list
# is a closed class rather than a judgement, and it grows when a real sentence falls
# outside it.
_NEGATION = re.compile(
    r"\b(?:not|never|no|nobody|none|nothing|neither|nor|cannot|hardly|barely"
    # Both apostrophes: a phone types the curly one.
    "|(?:do|does|did|is|are|was|were|ai|wo|ca|could|would|should|has|have|had)n['\u2019]?t)"
    r"\b",
    re.IGNORECASE,
)
# **Where a reading may reach, decided once for every boundary there is.**
#
# A reading whose own clause names no tag looks elsewhere in the message for a subject,
# and the whole class of defect on this surface is that look landing on a subject that
# belongs to a different statement. It was found and fixed five times one case at a
# time, each fix correct and each the same bug, so the boundaries were enumerated
# instead: every call that spans text, crossed with every separator, in both
# directions, against both shapes a neighbouring clause can take.
#
#   full stop, question, exclamation   no reach crosses it
#   line break                         no reach crosses it; a phone ends a thought
#                                      with one and no punctuation at all
#   semicolon                          no reach crosses it; it joins two statements
#   contrast word                      a complaint crosses it and a liking does not,
#                                      because a contrast marks the correction of what
#                                      precedes it: "amazing but way too loud" is about
#                                      the concert, "a letdown but we loved getting
#                                      out" is not about dinner
#   and, while                         a clause boundary like any other; "the concert
#                                      was amazing and the restaurant was awful" was
#                                      giving the restaurant the liking. It costs a
#                                      coordinated subject: "the walk and the lake were
#                                      amazing" keeps the lake and loses the walk, which
#                                      is a dropped liking and therefore the tolerable
#                                      direction. And it bounds a search for a subject
#                                      only, never a negation, which is what _PREDICATE
#                                      below is for
#   comma                              crossed only into a clause that states nothing
#                                      of its own, which a copula is the mark of
#
# Both reaches go backwards only. "What a concert, it was amazing" is the shape the
# looking exists for and it points that way; forwards it found "loved it, shame about
# dinner".
#
# "So" is not on the list although it joins clauses, because "so good" is one of the
# liking words and the boundary would cut it in half.
#
# **What the enumeration cannot close**, two of them, and both are the limit of a word
# list rather than another case to fix.
#
# The first is a complaint whose subject is a bare noun the vocabulary does not hold.
# "The concert was amazing but parking, never again" books the complaint against the
# concert, because there is no boundary between them to stop at and nothing marks
# "parking" as a subject. Knowing it is one needs the model call the ceiling above
# already names.
#
# The second is a complaint that reaches back past the clause it corrects and takes
# the liking with it. "Loved brunch but the concert, never again" records the complaint
# against live music, which is right, and against food, which the same sentence said
# they loved. "Loved the concert but the restaurant, never again" is the same shape and
# loses live music the same way. The mechanism is that the reach needing no licence
# spans the whole sentence back from the complaint and collects every clause in it that
# states nothing of its own, and a liking phrased with a verb rather than a copula
# ("loved brunch") is exactly such a clause.
#
# It has a third outcome, and this one the precedence itself produces rather than
# inherits. The unlicensed reach runs first and short-circuits, so a non-empty
# unlicensed result suppresses the licensed fallback entirely and the complaint can
# land ONLY on the wrong tag, with the subject the contrast corrects never recorded at
# all. "Loved the lake, the concert was amazing but way too loud, never again" took
# live music and the lake before the precedence and takes the lake alone now: the trade
# is a wrong tag plus a right one for a wrong tag on its own. The wrong tag is the part
# that matters, because it is the loud half in either version.
#
# It is not closed here because closing it needs a rule about how many subjects a reach
# may take, and the table above enumerates where a reach may cross, not how many it may
# collect. That is a new rule rather than a precedence between two that already exist,
# and a new rule is the line this module does not cross again.
#
# It is worse than the parking one and differs in kind. Parking fails to credit a tag
# and surfaces as a visibly odd reason in a proposal, which a human corrects in one
# message. This one subtracts four points from a tag somebody said they liked, and it
# surfaces as an absence: the tag stops being proposed and nobody notices there was
# anything to correct. The answer is the same model call.
_CLAUSE = re.compile(r"[.!?;,\n]|\b(?:but|though|however|and|while)\b", re.IGNORECASE)

# How far a negation or a question reaches, which is not how far a subject search
# does, and sharing one pattern for both was a mistake. A coordinator separates two
# subjects, so it bounds a search for one. It does not separate a negation from what
# it negates: "I don't think the concert and the dinner were amazing" is one thing
# said about two, and cutting at the "and" left the second conjunct looking like a
# plain liking. So this is the clause without the coordinators, and it is what
# :func:`_says` asks against.
_PREDICATE = re.compile(r"[.!?;,\n]|\b(?:but|though|however)\b", re.IGNORECASE)

# Asking is not saying. "Is that restaurant too expensive?" is Gia wondering, and
# recording it as a complaint puts a tag on the strength of a question nobody has
# answered. Two readings, because a phone often drops the mark: the clause the word
# sits in opens as a question, or the sentence it sits in ends in a question mark. The
# nearest terminator decides the second, so "that concert was amazing. Want to go
# again?" stays a liking.
#
# A question is an inversion, and it reads the same from either end: the auxiliary
# comes before the subject ("was the concert amazing"), or the wh-word comes before
# the auxiliary ("why is that restaurant too expensive"). Asking for the second word
# is what tells both of those from the declaratives that open the same way, and this
# family types all of them:
#
#   had an amazing time at the concert   auxiliary, then no subject   not a question
#   what a concert, it was amazing       wh-word, then no auxiliary   not a question
#   when we went to that concert         wh-word, then no auxiliary   not a question
#   had the best night at that concert   not a copula, so an object    not a question
#
# Nothing here recognises a question by its opening word alone. An earlier version
# accepted a clause beginning "anyone", which is not an inversion and threw away
# "anyone who loves live music would have loved that concert". A real question of that
# shape almost always carries its mark, and the mark is checked separately.
_AUXILIARY = r"is|are|was|were|am|do|does|did|can|could|would|should|will|shall|have|has|had"
_COPULA = r"is|are|was|were|am"
_PRONOUN = r"i|you|he|she|it|we|they"
# A definite or demonstrative noun phrase is an inversion after a copula, "was the
# concert amazing" and "was that restaurant expensive". After the other auxiliaries
# the same words are an ordinary verb and its object: "had the best night at that
# concert", "did that corn maze on saturday". A personal pronoun is a subject after
# any of them, which is what keeps "did you love it" a question.
_DEFINITE = r"the|that|this|these|those"
_INTERROGATIVE = re.compile(
    rf"\s*(?:(?:{_AUXILIARY})\s+(?:{_PRONOUN})\b"
    rf"|(?:{_COPULA})\s+(?:{_DEFINITE})\b"
    rf"|(?:how|what|why|when|where|who|which|whose)\s+(?:{_AUXILIARY})\b)",
    re.IGNORECASE,
)
_SENTENCE_END = re.compile(r"[.!?;\n]")
_COPULA_WORD = re.compile(rf"\b(?:{_COPULA})\b", re.IGNORECASE)

# How far a liking may look, per the table above. The cost of stopping at a contrast is
# real and it is the trade rather than an oversight: "the concert was loud but we loved
# it" recorded live music before and records nothing now, because the liking's clause
# names no tag and the concert sits on the far side of the "but". A correct liking
# becomes a silence, which is the direction this module is allowed to be wrong in.
_CONTRAST = re.compile(r"[.!?;\n]|\bbut\b|\bthough\b|\bhowever\b", re.IGNORECASE)

# A complaint may only reach back for a subject when it has none of its own, which
# matters most when what it named is a word this module does not know, because reaching
# back then lands on whatever the sentence praised.
#
# A complaint states its subject in one of two places. After it, as the thing it is
# about: "hated the parking". Or before it, in the ordinary English order, with a
# copula joining the two: "the parking was too expensive". Neither is true of a
# complaint that names nothing at all, which is "way too loud" and "never again".
#
# The determiner has to sit directly after the complaint, because one belonging to
# anything else says nothing about what is being complained about: "a bit too loud" and
# "never again on a Friday" both carry one. On the other side the copula is what marks
# it, for the same reason: "a bit" has a determiner and no verb, so it states nothing.
_OWN_SUBJECT = re.compile(
    r"\s*\b(?:the|a|an|that|this|these|those|my|our|your|their|his|her|its)\b", re.IGNORECASE
)


def _says(text: str, match: re.Match[str]) -> bool:
    """Whether this one match is said rather than negated or asked.

    Always against the whole message and never against a clause already cut out of it.
    ``_PREDICATE`` splits on the sentence terminators, so a clause handed here on its own
    can never contain the question mark that the check below looks for, and the guard
    would be inert exactly where it reads as present.

    The negation is looked for over the whole clause and not only the part in front of
    the word, because English puts it behind just as readily: "the restaurant was
    amazing, the concert not so much" disparages the concert after naming it. The word
    being judged is cut out of what gets scanned, since several complaints carry a
    negation of their own and "never again" would otherwise negate itself.
    """
    start, end = _span(text, match.start(), _PREDICATE)
    if _INTERROGATIVE.match(text[start:end]) is not None:
        return False
    terminator = _SENTENCE_END.search(text, match.end())
    if terminator is not None and terminator.group() == "?":
        return False
    around = text[start : match.start()] + " " + text[match.end() : end]
    return _NEGATION.search(around) is None


def _span(text: str, at: int, boundary: re.Pattern[str]) -> tuple[int, int]:
    """Where the stretch holding ``at`` starts and ends, boundaries excluded."""
    start, end = 0, len(text)
    for found in boundary.finditer(text):
        if found.end() <= at:
            start = found.end()
        elif found.start() > at:
            end = found.start()
            break
    return start, end


# Signals are grouped under a tag so a venue can be matched to them without a model.
# Deliberately short: it covers what the household's own calendar and group actually
# contain, and it grows when a real signal falls outside it.
# Every entry has to survive both readings, because this matcher has two inputs and
# a word can be unambiguous in one and not the other. A wrong tag is never silent
# here: it comes back out as the stated reason for a suggestion, in front of both of
# them.
#
# **The admission rule: an entry earns its place only if it means the same thing in a
# calendar title and typed in the family chat.** Applied to every entry, not to the
# one that was reported, because checking the instances is what let "group" through
# and then "service" beside it and then "tour" beside that.
#
# The test is sameness of subject, not sameness of occasion. "Walk at the arboretum"
# and "walk the dog" are both being outdoors, so "walk" stays. "Pumpkin patch" and
# "patch the drywall" are not the same thing at all, so "patch" goes and "pumpkin"
# carries it. What failed and why:
#
#   tour     a band on tour, or a Lake Geneva boat tour     dropped
#   band     a band at the Abbey, or a wedding band         "live band"
#   grill    a cookout, or the appliance that is broken     "cookout", "bbq"
#   patch    a pumpkin patch, or patching drywall           dropped
#   harvest  a harvest festival, or the crop coming in      "harvest festival"
#   gril     a typo in one calendar entry, nothing in chat  dropped
#   geneva   Lake Geneva WI, or Geneva IL in Kane County    dropped
#
# **A proper noun's second reading is a lookup, not a guess.** The sweep that found
# the five above probed each entry in a household sense and an invented other sense,
# which is bounded by what the person running it already suspects. That is how
# "geneva" survived it: the other reading of a place name is another place carrying
# the same name, and whether one exists is a question with an answer rather than
# something to imagine. Checked, September 2026:
#
#   geneva        Geneva, Illinois is the Kane County seat, 40 miles west of
#                 Chicago and about twenty from Itasca. A live collision, and the
#                 entry earned nothing anyway: "lake" already fires on both
#                 "Lake Geneva" and "Geneva Lakes". Dropped.
#   fontana       Fontana, California exists. Fontana-on-Geneva Lake, Walworth
#                 County, Wisconsin is where the family lake house is. Both are
#                 real, but only one is live for these two people, and an ambiguity
#                 that cannot occur for them is not an ambiguity. Kept.
#   teddy swims   a musician, not a place. Kept.
INTEREST_TAGS: dict[str, tuple[str, ...]] = {
    "live music": ("concert", "gig", "live band", "live music", "teddy swims"),
    "worship": (
        "church",
        "worship",
        "church service",
        "sunday service",
        "bible",
        "small group",
        "prayer",
    ),
    "family": ("bday", "birthday", "family", "sis", "sister", "auntie"),
    "food": ("dinner", "lunch", "brunch", "restaurant", "cookout", "bbq", "coffee"),
    # The gerunds are spelt out because they are how people say these, and the matcher
    # allows a plural "s" and nothing else on purpose. Bare "park" is not here: parking
    # the car is not an afternoon out, and "a walk in the park" is caught by "walk".
    "outdoors": ("walk", "walking", "hike", "hiking", "garden", "trail"),
    "autumn": (
        "pumpkin",
        "haunted",
        "corn maze",
        "harvest festival",
        "halloween",
        # Both, because the matcher is anchored at both ends: "fall fest" alone never
        # matched "Fall Festival", which is the phrase the research prompt asks for
        # by name, so the entry was failing silently on its own best case.
        "fall fest",
        "fall festival",
    ),
    "lake": ("lake", "fontana", "boat", "cabin"),
}


class ResearchBudgetSpent(HouseholdError):
    """The planner already researched today. It reads the cache or it waits."""


@dataclass(frozen=True, slots=True)
class CalendarEvent:
    """One event on the shared household calendar, as the CalDAV read returns it."""

    uid: str
    summary: str
    start: datetime
    end: datetime
    # An all-day event has to arrive as a half-open span between two local midnights
    # in :data:`HOUSEHOLD_TZ`: a DATE value of 25 September is start 09-25 00:00
    # Central, end 09-26 00:00 Central. The CalDAV read is what owns that conversion.
    # Reading the DATE as UTC midnight instead shifts the blocked day, because
    # midnight UTC is seven the evening before in Central.
    all_day: bool = False


@dataclass(frozen=True, slots=True)
class Window:
    start: datetime
    end: datetime

    def describe(self) -> str:
        """``Friday 25 September from 6:00pm to 11:00pm``, always in Central."""
        local_start = self.start.astimezone(HOUSEHOLD_TZ)
        local_end = self.end.astimezone(HOUSEHOLD_TZ)
        day = f"{local_start:%A} {local_start.day} {local_start:%B}"
        return f"{day} from {_clock_time(local_start)} to {_clock_time(local_end)}"


def _clock_time(moment: datetime) -> str:
    hour = moment.hour % 12 or 12
    suffix = "am" if moment.hour < 12 else "pm"
    return f"{hour}:{moment.minute:02d}{suffix}"


@dataclass(frozen=True, slots=True)
class TasteSignal:
    kind: str
    subject: str
    detail: str = ""
    source: str = "group"
    person_id: str | None = None
    ref: str = ""


@dataclass(frozen=True, slots=True)
class Candidate:
    """One place or event the research turn came back with."""

    name: str
    area: str
    what: str
    tags: tuple[str, ...]


def day_starts_at(day: date) -> time:
    """When the household is plausibly free: midday at the weekend, six on a workday."""
    return WEEKEND_START if day.weekday() in WEEKEND else EVENING_START


def free_windows(
    events: Iterable[CalendarEvent],
    *,
    horizon_start: datetime,
    horizon_end: datetime,
) -> list[Window]:
    """Free stretches in the horizon, with nothing on the shared calendar.

    An all-day event blocks its whole day rather than a slice of it, because an
    all-day entry is the household saying the day is spoken for.

    Both ends of the horizon are instants and every boundary below is built in
    :data:`HOUSEHOLD_TZ`, so this returns the same answer on a box set to UTC as on
    one set to Central, and the same answer either side of a clock change.
    """
    if horizon_start.tzinfo is None or horizon_end.tzinfo is None:
        raise ValueError("the planning horizon is a pair of instants, not wall clock times")
    busy = sorted(
        (event for event in events if event.end > horizon_start and event.start < horizon_end),
        key=lambda event: event.start,
    )
    windows: list[Window] = []
    day = horizon_start.astimezone(HOUSEHOLD_TZ).date()
    last_day = horizon_end.astimezone(HOUSEHOLD_TZ).date()
    while day <= last_day:
        evening_start = datetime.combine(day, day_starts_at(day), tzinfo=HOUSEHOLD_TZ)
        evening_end = datetime.combine(day, DAY_END, tzinfo=HOUSEHOLD_TZ)
        cursor = max(evening_start, horizon_start)
        blocked = False
        for event in busy:
            if event.all_day and _covers_day(event, day):
                blocked = True
                break
            if event.end <= cursor or event.start >= evening_end:
                continue
            if event.start - cursor >= MINIMUM_WINDOW:
                windows.append(Window(start=cursor, end=event.start))
            cursor = max(cursor, event.end)
        end = min(evening_end, horizon_end)
        if not blocked and end - cursor >= MINIMUM_WINDOW:
            windows.append(Window(start=cursor, end=end))
        day += timedelta(days=1)
    return sorted(windows, key=lambda window: window.start)


def _covers_day(event: CalendarEvent, day: date) -> bool:
    """Which days an all-day event spoke for, per the contract on ``all_day``.

    The half-open comparison depends on the span being local midnight to local
    midnight. An event handed in on UTC midnight blocks the day before instead, and
    nothing here can tell the two apart.
    """
    start = event.start.astimezone(HOUSEHOLD_TZ).date()
    end = event.end.astimezone(HOUSEHOLD_TZ).date()
    return start <= day < end


def choose_window(windows: Sequence[Window]) -> Window | None:
    """The soonest Friday or Saturday evening, else the soonest evening at all."""
    preferred = [
        window
        for window in windows
        if window.start.astimezone(HOUSEHOLD_TZ).weekday() in PREFERRED_WEEKDAYS
    ]
    pool = preferred or list(windows)
    return min(pool, key=lambda window: window.start) if pool else None


def tags_for(text: str) -> tuple[str, ...]:
    """Which interests a sentence or a calendar title is about.

    Matched on whole words, the way the group's other two matchers are. A bare
    substring found "band" inside "husband", so "my husband is amazing" was recorded
    as live music, and live music was then given to both of them as the reason for
    suggesting a concert. A wrong label here is not a silent one: the tag it picks is
    read out in the group.

    A trailing "s" is allowed because the vocabulary is nouns and they say "concerts"
    as often as "concert".
    """
    return tuple(tag for tag, pattern in _TAG_PATTERNS.items() if pattern.search(text))


def _tag_pattern(words: tuple[str, ...]) -> re.Pattern[str]:
    return re.compile(
        r"\b(?:" + "|".join(re.escape(word) for word in words) + r")s?\b", re.IGNORECASE
    )


_TAG_PATTERNS: dict[str, re.Pattern[str]] = {
    tag: _tag_pattern(words) for tag, words in INTEREST_TAGS.items()
}


def _borrowed_subjects(text: str, liking: re.Match[str]) -> tuple[str, ...]:
    """Tags a liking may take from a neighbouring clause when its own names none.

    Only from a clause that states nothing of its own, which a copula is the mark of.
    "What a concert, it was amazing" is one statement split by a comma and the first
    half is the subject of the second. "Dinner was a letdown, we loved getting out" is
    two statements, and borrowing across the comma there gave food the heaviest
    positive weight from the only clause in the message that mentions dinner.

    Never past a contrast word either, which is the same rule stated for the same
    reason: "but" is where the subject changes.
    """
    lower = _span(text, liking.start(), _CONTRAST)[0]
    upper = liking.start()
    return tuple(
        tag
        for tag, pattern in _TAG_PATTERNS.items()
        if any(
            lower <= match.start() < upper and _says(text, match) and _states_nothing(text, match)
            for match in pattern.finditer(text)
        )
    )


def _states_nothing(text: str, match: re.Match[str]) -> bool:
    """Whether the clause holding ``match`` is a fragment rather than a statement."""
    start, end = _span(text, match.start(), _CLAUSE)
    return _COPULA_WORD.search(text, start, end) is None


def _liked_about(text: str) -> tuple[str, ...]:
    """Which tags a liking is about, which is not everything the message mentions.

    A liking stays in its own sentence, the same way a complaint does. "Loved the lake.
    Dinner was a disaster." gave food the heaviest positive weight it has, because one
    sentence held a liking word and the other held a tag, and disaster is not in the
    complaint vocabulary so nothing stopped it. Both directions cross a clause and
    neither crosses a full stop.

    Its own clause first, for the same reason a complaint's does: "loved the concert
    but the restaurant was a disaster" praises the concert and nothing else, and
    disaster is not in the complaint vocabulary so nothing else would have stopped
    food taking the heaviest positive weight there is.

    A liking whose clause names nothing reaches into its sentence, and unlike a
    complaint it reaches both ways, because a liking names its subject on either side
    of itself: "loved the concert" and "the concert was amazing" are the same sentence
    twice, and "what a concert, it was amazing" splits them across the comma.
    """
    named: list[str] = []
    for liking in _ENJOYED.finditer(text):
        if not _says(text, liking):
            continue
        start, end = _span(text, liking.start(), _CLAUSE)
        subjects = tuple(
            tag
            for tag, pattern in _TAG_PATTERNS.items()
            if pattern.search(text[start:end]) is not None
        ) or _borrowed_subjects(text, liking)
        named.extend(tag for tag in subjects if tag not in named)
    return tuple(named)


def _reached_back(text: str, complaint: re.Match[str]) -> tuple[str, ...]:
    """Tags a subjectless complaint may take from the text in front of it.

    The reach runs twice, which is a precedence between the two rules the boundary
    table above already enumerates and not a sixth rule beside them. A comma is
    crossed only into a clause that states nothing of its own; a contrast word is
    crossed by a complaint whichever shape the clause behind it takes. So the reach
    that needs no licence goes first, and the contrast only licenses a reach when
    that one comes back with nothing.

    Without the precedence the licence applied to every tag in front of the
    complaint rather than to the clause the contrast corrects, so "that concert was
    amazing but the restaurant, never again" took live music along with the
    restaurant, on the strength of a clause that praised it.

    The fallback is the case the licence exists for: "that concert was amazing but
    way too loud, never again" finds nothing unlicensed, because the concert's clause
    carries a copula and therefore states something of its own, and falls back to
    live music.
    """
    lower = _span(text, complaint.start(), _SENTENCE_END)[0]
    upper = complaint.start()

    def reach(*, licensed: bool) -> tuple[str, ...]:
        return tuple(
            tag
            for tag, pattern in _TAG_PATTERNS.items()
            if any(
                lower <= match.start() < upper
                and _says(text, match)
                and (licensed or _states_nothing(text, match))
                for match in pattern.finditer(text)
            )
        )

    unlicensed = reach(licensed=False)
    if unlicensed or _CONTRAST.search(text, lower, upper) is None:
        return unlicensed
    return reach(licensed=True)


def _complained_about(text: str) -> tuple[str, ...]:
    """Which tags a complaint is about, which is not always what the sentence is about.

    The clause carrying the complaint names its subject when it has one. "That concert
    was amazing but the restaurant was too expensive" is a complaint about the
    restaurant and not one word against the concert, and giving the concert the
    complaint's weight is a wrong label rather than a missing one.

    A complaint with no subject of its own reaches back for one, and only back:
    "that concert was amazing but way too loud, never again" is the shape the
    both-kinds rule was written for, and the tag it removes is the one the praise
    named. Back as far as the start of its own sentence and no further, because a
    fronted subject sits one clause away ("the restaurant, never again") while a full
    stop puts a different subject out of reach entirely.

    Backwards is the whole of it, because that is the difference between a complaint
    correcting the praise in front of it and a complaint the praise is answering.
    "The parking was a nightmare, hated it, but that concert was amazing" concedes
    rather than corrects, and the tag it named is not the one being complained about;
    reading forwards took four points off the concert.

    "No subject of its own" is not the same as "no tag of its own", and reading it as
    the same was the bug that outlived two rounds: "that concert was amazing, hated the
    parking" names a subject this module has never heard of, and treating that clause
    as subjectless sent the complaint back to the concert. A determiner directly after
    the complaint is what says it named something: "hated the parking" has one, while
    "way too loud" and "never again on a Friday" name nothing at all. A complaint that
    named a word outside the vocabulary therefore records nothing at all, in either
    word order, which is the right answer for a thing this module cannot recognise.

    The praised tag in the first shape earns nothing rather than the liking. The
    sentence is mixed, this cannot tell how mixed, and silence is what the rest of this
    module does with a sentence it cannot resolve.

    Inside a complaining clause the tag is matched on presence, not through
    :func:`_says`. The clause's polarity is already settled by the time we are
    looking for its subject, and several complaints carry a negation word of their
    own: "never again at that restaurant" has ``never`` in front of the restaurant, so
    asking whether the restaurant is negated there books the complaint against
    whatever the rest of the sentence praised.

    The ceiling, which is the module's ceiling and not a new one: a clause names its
    subject, not which of its words is the subject. "Dinner at the lake was too
    expensive" is one clause naming two tags, and both take the complaint, so a lake
    with four real afternoons behind it can drop out of the ranking on the price of a
    meal. Telling the subject from the place it happened needs a parse, which is the
    thing :func:`_says` already says this module will not grow into. The cost is a
    tag ranked too low, and nothing typed is read back out either way.
    """
    named: list[str] = []
    for complaint in _DECLINED.finditer(text):
        if not _says(text, complaint):
            continue
        start, end = _span(text, complaint.start(), _CLAUSE)
        clause = text[start:end]
        subjects = tuple(
            tag for tag, pattern in _TAG_PATTERNS.items() if pattern.search(clause) is not None
        )
        if not subjects:
            stated_before = _COPULA_WORD.search(text, start, complaint.start()) is not None
            if stated_before or _OWN_SUBJECT.match(text, complaint.end(), end) is not None:
                continue
            subjects = _reached_back(text, complaint)
        named.extend(tag for tag in subjects if tag not in named)
    return tuple(named)


class TasteMemory:
    """What the household enjoys, and how it learned it.

    Two inputs and no others:

    * the shared calendar, where every event is an ``attended`` signal, so a thing
      they do every week outweighs a thing they did once;
    * the group, where a short vocabulary of liking and disliking turns a sentence
      either of them typed into an ``enjoyed`` or ``declined`` signal.

    Both are things the whole household has already seen, which is what lets the
    proposal show its reasoning rather than assert it. The two are not read back the
    same way: a calendar entry is quoted, a sentence typed in the group contributes
    its tag and nothing else, and :meth:`evidence_for` says why. A third input, one
    person telling their own assistant something in private, is designed and
    deliberately not built: see `docs/plan/coordination-between-assistants.md`.
    Nothing in here reads either person's mail, at any weight, for any purpose.

    The second proposal beats the first because the first one's outcome, said in the
    group, is in here before the second one runs.
    """

    # What they said about it outweighs the fact that they turned up to it, and
    # saying they disliked it outweighs both, so one clear no removes a tag rather
    # than merely slowing it down.
    WEIGHTS: ClassVar[dict[str, int]] = {"enjoyed": 3, "attended": 1, "declined": -4}

    def __init__(self, database: Database, clock: Clock = system_clock) -> None:
        self._database = database
        self._clock = clock

    def record(self, signal: TasteSignal) -> bool:
        """Store one signal, and say whether it was new.

        A calendar detail is quoted back to both of them, so details are tidied here
        rather than at the point of reading one out.
        A signal whose ``ref`` has already been seen is the same occasion read again
        and stores nothing, which is what the caller's count has to mean.
        """
        signal_id = uuid.uuid4().hex
        detail = " ".join(signal.detail.split())
        with self._database.write() as cx:
            stored = cx.execute(
                "INSERT OR IGNORE INTO taste_signal (id, kind, subject, detail, source, "
                "person_id, observed_at, ref) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    signal_id,
                    signal.kind,
                    signal.subject,
                    detail,
                    signal.source,
                    signal.person_id,
                    self._clock().isoformat(),
                    signal.ref or signal_id,
                ),
            ).rowcount
        return stored == 1

    def learn_from_calendar(self, events: Iterable[CalendarEvent]) -> int:
        """What the household actually did, which means the ones that have happened.

        An event still ahead of them is a plan, not an attendance, and the planner
        reads forward to find a free evening. Recording those as ``attended`` made
        every calendar signal in production a prediction, and put next Friday's
        concert in line to be quoted back as the reason for suggesting a concert.
        Filtered here rather than at the call site, because the claim is this
        function's.

        ``ref`` carries the occurrence's start as well as its uid. In iCalendar every
        instance of a recurrence shares one UID, so a weekly church on uid alone was
        one signal forever, against a migration comment promising that two separate
        Sundays are two signals. :mod:`household.service` already keys busy intervals
        this way, for this reason, and this is the same fact arriving twice.
        """
        now = self._clock()
        learned = 0
        for event in events:
            if event.end > now:
                continue
            for tag in tags_for(event.summary):
                learned += self.record(
                    TasteSignal(
                        kind="attended",
                        subject=tag,
                        detail=event.summary,
                        source="shared_calendar",
                        ref=f"{event.uid}@{event.start.isoformat()}",
                    )
                )
        return learned

    def learn_from_group(self, *, text: str, person_id: str, ref: str) -> int:
        """A sentence either of them typed in the group, and nothing they typed elsewhere.

        ``ref`` is the group message's own id, so the same sentence said after two
        different outings is two signals while a re-read of one message is still one.

        A sentence carrying both kinds of word is a complaint. "That concert was
        amazing but way too loud, never again" is not an endorsement with a caveat,
        and reading it as one both contradicts the rule that one clear no removes a
        tag and makes the complaint itself the support for naming that tag in the
        group as the reason for suggesting the thing again.

        A word with a negation in front of it is not that word, in either direction,
        and neither reading is a clear enough signal to record. "Honestly I didn't
        love that concert" is not an endorsement, and "it wasn't too loud" is not a
        complaint.

        Those two rules meet here, and the order matters. A complaint word takes the
        sentence out of the liking reading whether or not :func:`_says` can read
        it as asserted, because the alternative is that failing to read a complaint
        promotes the same sentence to a liking: "nothing was open and dinner was too
        expensive, but the walk was amazing" would be stored as an endorsement and
        read back out in the group. A mixed sentence this cannot resolve records
        nothing, which is the outcome the rest of this module already accepts.

        The reading belongs to the sentence and the subject to the clause, which is
        why the two directions ask different functions for their tags. See
        :func:`_liked_about` and :func:`_complained_about`.
        """
        if _DECLINED.search(text) is not None:
            kind, subjects = "declined", _complained_about(text)
        else:
            kind, subjects = "enjoyed", _liked_about(text)
        learned = 0
        for tag in subjects:
            learned += self.record(
                TasteSignal(
                    kind=kind,
                    subject=tag,
                    detail=text,
                    source="group",
                    person_id=person_id,
                    ref=ref,
                )
            )
        return learned

    def scores(self) -> list[tuple[str, int]]:
        """Every tag the store holds an opinion about, best first, negatives included.

        What orders candidates. A tag they said never again to is remembered taste and
        has to sort below a tag nothing is known about, not beside it.
        """
        with self._database.read() as cx:
            rows = cx.execute(
                "SELECT kind, subject FROM taste_signal ORDER BY observed_at"
            ).fetchall()
        totals: dict[str, int] = {}
        for row in rows:
            subject = str(row["subject"])
            totals[subject] = totals.get(subject, 0) + self.WEIGHTS[str(row["kind"])]
        return sorted(totals.items(), key=lambda item: (-item[1], item[0]))

    def ranked(self) -> list[tuple[str, int]]:
        """The tags worth naming: positives only, best first, the strongest few.

        What a reason and a research turn are built from, neither of which has any use
        for a tag the household has ruled out.
        """
        return [(tag, score) for tag, score in self.scores() if score > 0][:RANKED_TAGS]

    def evidence_for(self, tag: str) -> list[str]:
        """What can be quoted back for this tag: entries off the shared calendar.

        Not a disclosure rule. Both a calendar entry and a sentence typed in the group
        are already in front of both of them, so quoting either reveals nothing. The
        difference is interpretation. A calendar entry reading "Church" means they went
        to church and needs no reading. A sentence somebody typed has to be understood
        before it can be called a reason, and every way this module has been wrong was
        a failure of exactly that: a negated liking, a raised negation, a negation on
        the subject, a question read as an answer. So what needs no interpretation is
        quoted, and where interpretation was required only the conclusion is named, by
        :func:`_because`, as the tag on its own.

        This does not make the ranking right. A misread sentence can still lift a tag
        and make the suggestion slightly wrong, which costs one message to correct.
        What it removes is the failure that would not be recoverable: reading somebody's
        complaint, or a question they asked and nobody answered, back to them in the
        family group as the reason they are being offered the thing again.

        Only a signal supporting the pick is quoted either way. A ``declined`` keeps its
        weight in :meth:`scores`, where a complaint belongs.

        The source predicate is the rule and the kind predicate is the whole of what
        that source produces today, which is why it names one kind rather than a set:
        a set would imply a group-sourced liking could reach this, and nothing writes
        one. Neither is decoration, since a calendar signal that was not an attendance
        should not become the stated reason for anything.
        """
        with self._database.read() as cx:
            rows = cx.execute(
                "SELECT detail FROM taste_signal WHERE subject = ? AND detail <> '' "
                "AND source = 'shared_calendar' AND kind = 'attended' "
                "ORDER BY observed_at DESC LIMIT ?",
                (tag, EVIDENCE_PER_TAG),
            ).fetchall()
        return [str(row["detail"]) for row in rows]


class ResearchBudget:
    """One research turn a calendar day, and the day's answer is cached."""

    def __init__(self, database: Database, clock: Clock = system_clock) -> None:
        self._database = database
        self._clock = clock

    def candidates(
        self, window: Window, produce: Callable[[], Sequence[Candidate]]
    ) -> list[Candidate]:
        """Candidates for this window, from the cache if today's turn is already spent."""
        day = self._clock().astimezone(HOUSEHOLD_TZ).date().isoformat()
        window_start = window.start.isoformat()
        with self._database.read() as cx:
            cached = cx.execute(
                "SELECT result_json FROM research_budget WHERE day = ? AND window_start = ?",
                (day, window_start),
            ).fetchone()
            taken = int(
                cx.execute(
                    "SELECT COUNT(*) AS taken FROM research_budget WHERE day = ?", (day,)
                ).fetchone()["taken"]
            )
        if cached is not None:
            if cached["result_json"] is None:
                raise ResearchBudgetSpent(f"the {day} research turn is spent and returned nothing")
            return [
                Candidate(**{**item, "tags": tuple(item["tags"])})
                for item in json.loads(str(cached["result_json"]))
            ]
        if taken >= RESEARCH_TURNS_PER_DAY:
            raise ResearchBudgetSpent(
                f"{day} is out of research turns and nothing is cached for {window_start}"
            )

        # Reserve the turn before spending it, so a crash inside ``produce`` cannot be
        # retried into a second billable run.
        with self._database.write() as cx:
            cx.execute(
                "INSERT INTO research_budget (day, window_start) VALUES (?, ?)",
                (day, window_start),
            )
        found = [
            Candidate(
                name=candidate.name,
                area=candidate.area,
                what=candidate.what,
                tags=tuple(candidate.tags),
            )
            for candidate in produce()
        ]
        with self._database.write() as cx:
            cx.execute(
                "UPDATE research_budget SET result_json = ? WHERE day = ? AND window_start = ?",
                (
                    json.dumps([dataclasses.asdict(candidate) for candidate in found]),
                    day,
                    window_start,
                ),
            )
        return found


def rank_candidates(
    candidates: Sequence[Candidate], tag_scores: Sequence[tuple[str, int]]
) -> list[Candidate]:
    """A candidate that matches a strong signal comes first. Ties keep research order.

    Scored against :meth:`TasteMemory.scores` rather than :meth:`TasteMemory.ranked`,
    so a candidate carrying a tag they declined sorts below one carrying a tag the
    store has never heard of.
    """
    weights = dict(tag_scores)
    return sorted(
        candidates,
        key=lambda candidate: -sum(weights.get(tag, 0) for tag in candidate.tags),
    )


def compose_proposal(
    *,
    window: Window,
    candidates: Sequence[Candidate],
    taste: TasteMemory,
) -> str:
    """The message the planner opens with.

    Written to sound like Corey in the group rather than like a calendar diff: the
    Overlord's brief for the whole feature was handle all the details, make it fun.
    Specific enough to say a number to, and honest about the one thing it looked at.

    Candidates are grouped by whatever area the research came back with rather than by
    a fixed near-or-city split. Home is Itasca, all of Chicagoland is fair game, and
    the family's lake house at Fontana is a real option for a weekend, so the geography
    is data and not a constant in here.

    ``candidates`` must be non-empty. The message it composes states a window and then
    asks for a number, so a run with nothing to offer is not a proposal at all and is
    not this function's to word. Deciding there is nothing to propose belongs to the
    caller that owns the research turn, which checks the candidates it got back and
    says so itself rather than reaching here.
    """
    ranked = taste.ranked()
    ordered = rank_candidates(candidates, taste.scores())
    # "The only thing either of us looked at" was true of the whole message once and
    # stopped being true twice over: the places below come from a research turn that
    # read the open web, and a reason can now name something one of them typed in the
    # group. The claim that still holds is the one that matters to them, that nothing
    # except their own shared calendar decided they are free, so that is the claim it
    # makes.
    opening = (
        f"Corey and Denise here, comparing notes. You two are both clear "
        f"{window.describe()} - that is the shared calendar talking, and nothing except "
        "that calendar decided you are free."
    )
    lines = [opening, ""]

    number = 1
    for area in _areas_in_order(ordered):
        lines.append(f"{area}:")
        for candidate in ordered:
            if candidate.area != area:
                continue
            lines.append(f"{number}. {candidate.name} - {candidate.what}")
            number += 1
        lines.append("")

    reason = _because(ordered, ranked, taste)
    if reason:
        lines.append(f"We picked those because of {reason}.")
    lines.append(
        "Say a number, or tell us what you would rather do and we will go again. "
        "Neither of us can book a table or put anything on the shared calendar yet, "
        "so the next move is still yours."
    )
    lines.append(
        'Either of you says "stop" and we both drop it on the spot. '
        '"!coordination off" retires the two of us talking to each other entirely, '
        "and we carry on working for you separately either way."
    )
    return "\n".join(lines)


def _areas_in_order(candidates: Sequence[Candidate]) -> list[str]:
    """Each area once, in the order its best candidate ranked."""
    seen: list[str] = []
    for candidate in candidates:
        if candidate.area not in seen:
            seen.append(candidate.area)
    return seen


def _because(
    candidates: Sequence[Candidate],
    ranked: Sequence[tuple[str, int]],
    taste: TasteMemory,
) -> str:
    """Why these places, in terms that hold.

    A tag earns a mention when a listed candidate actually carries it. A strong tag no
    candidate matches is a true fact about them and a false reason for these picks, so
    it is dropped.

    A mention carries its evidence in brackets only when :meth:`TasteMemory.evidence_for`
    has something needing no interpretation, which means the shared calendar. Otherwise
    the tag is named alone, and the sentence around it must not imply the quote it is
    not making: "because of live music" is the claim, and anything shaped like "because
    you said" would have the reader supply the words themselves.

    Returns an empty string when nothing survives, and the caller then says nothing
    at all. A stated reason that does not hold is worse than no reason.
    """
    carried = {tag for candidate in candidates for tag in candidate.tags}
    reasons = []
    for tag, _ in ranked:
        if tag not in carried:
            continue
        evidence = taste.evidence_for(tag)
        reasons.append(f"{tag} ({'; '.join(evidence)})" if evidence else tag)
        if len(reasons) == REASONS_IN_A_PROPOSAL:
            break
    if not reasons:
        return ""
    if len(reasons) == 1:
        return reasons[0]
    return ", ".join(reasons[:-1]) + " and " + reasons[-1]


__all__ = [
    "DAY_END",
    "EVENING_START",
    "EVIDENCE_PER_TAG",
    "HOUSEHOLD_TZ",
    "INTEREST_TAGS",
    "MINIMUM_WINDOW",
    "PLANNING_LEAD",
    "PREFERRED_WEEKDAYS",
    "RANKED_TAGS",
    "REASONS_IN_A_PROPOSAL",
    "RESEARCH_TURNS_PER_DAY",
    "WEEKEND",
    "WEEKEND_START",
    "CalendarEvent",
    "Candidate",
    "ResearchBudget",
    "ResearchBudgetSpent",
    "TasteMemory",
    "TasteSignal",
    "Window",
    "choose_window",
    "compose_proposal",
    "day_starts_at",
    "free_windows",
    "rank_candidates",
    "tags_for",
]
