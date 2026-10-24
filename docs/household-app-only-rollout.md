# Household app communication rollout

Telegram is retired.
The household-app prompt hook identifies the app's `family` room as The Fam.
For peer coordination, follow [the assistants' direct line](deploy/openclaw.md#the-assistants-direct-line).
Normal replies stay in their current app conversation; private posts use the owner's household id.
A post addressed to the family by one of its names goes to that app room, and anything addressed to Telegram is refused with where to post instead.

This first rollout switched Telegram's channel off and left its config in place.
[Retiring Telegram](deploy/retiring-telegram.md) takes out what was left: the channel's config and bot token, the plugins and the relay that worked around Telegram, and the Telegram ids PocketPiggies and memory were keyed by.

Phone-call closing turns receive a brief goodbye instruction. The iPhone waits until the final spoken sentence finishes before hanging up. A new request after thanks keeps the call open.
