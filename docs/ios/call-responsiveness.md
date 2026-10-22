# Faster, more conversational calls

Steward 0.1.4 reduces the pause after a complete spoken phrase from 1.0 to 0.7 seconds.
Complete short answers such as “yes”, “no” and “go ahead” wait 0.55 seconds instead of
the 1.6 seconds reserved for fragments. Unfinished thoughts such as “add eggs and” and
greetings such as “Hey Corey” still get 1.6 seconds. New words restart the clock.

The first spoken reply can begin at a natural clause boundary when the opening is long
(at least eight words and sixty characters). Later clauses stay together for smoother
delivery. Numbers and times are not split at their internal punctuation. The existing
sentence queue still prefetches only one chunk ahead and interruption cancels queued
speech. The voice provider, chosen model and daily speech ceiling are unchanged.

The gateway's call-only instruction asks for a useful, short first sentence, usually one
or two sentences per turn, contractions and everyday phrasing. It avoids repetitive
acknowledgments and unnecessary follow-up questions. Tool requests retain a brief,
truthful acknowledgment before work begins, and farewell behavior is unchanged.

The timing and chunking changes ship in the phone build. The conversational instruction
ships with the household-app plugin on both gateways. A TestFlight upload does not deploy
the gateway plugin. These are configured timing reductions, not a measured end-to-end
latency claim: model, tools, speech synthesis and network time still contribute.
