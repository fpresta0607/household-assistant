# Family videos and agent quick reads

Sending, syncing and watching a video in The Fam uses no video AI. The existing
mention/reply admission rule still decides whether an assistant answers. To ask about
an existing clip, reply to its message and mention Corey or Denise.

An admitted human request uses Gemini 2.5 Flash Lite through the existing OpenRouter
key. It returns one short digest of visible events and audible content. Only that
digest enters the main agent's context; the original video never enters its media
pipeline. Assistant-to-assistant handovers do not initiate video analysis.

Limits are enforced on the gateway: MP4/MOV only, 50 MiB, two minutes verified from
the container's movie and track timing, one video per request, 500 output tokens and
20 attempts per gateway in a rolling 24 hours. The provider rate ceiling is $0.10/M
input tokens and $0.40/M output tokens, with reasoning and fallbacks off. Unknown
timing, fragmented containers and unsupported formats fail without an API request.
Clips outside these limits still share and play normally; the assistant explains when
it could not analyze one. This is a quick digest and can miss details.

Digests are cached by video hash and conversation in each gateway's private
`household-app/video-summaries.sqlite`. Concurrent requests share a job, restarts reuse
the cache, and failures have a ten-minute cooldown. The rate counter survives restarts
and failed requests consume a slot. Actual provider costs join that assistant's media
spend; the existing household key total remains authoritative. No captions, video
bytes, provider response bodies or keys are logged.

The iOS change drives inline playback from UIKit cell visibility. Prefetched rows
stay paused; visible rows play muted, and leaving the row or backgrounding pauses
playback. The thumbnail remains visible until AVPlayerLayer has a displayable frame.

Roll out the household-app plugin using the existing host deployment procedure,
restarting and verifying Corey then Denise. Ship the four changed iOS views through
the normal TestFlight workflow. Both halves are needed for the full fix.

Verification: the focused Node tests cover routing, reply scope, cache/restart behavior,
cost attribution, limits, malformed files and provider failure. `InlineVideoTests`
plays a real H.264 fixture in a hosted UIKit view and checks display readiness and
pause/resume. Existing media screenshots cover family light/dark and full-screen video.

Provider references:
- https://openrouter.ai/docs/guides/overview/multimodal/videos
- https://openrouter.ai/google/gemini-2.5-flash-lite
- https://openrouter.ai/docs/guides/routing/provider-selection
