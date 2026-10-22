// Video understanding through OpenRouter, for both household gateways.
//
// OpenClaw 2026.9.4 describes a video only through its Google provider, which calls
// Google directly, and its OpenRouter provider understands photos and audio but not
// video. OpenRouter's chat API takes a video as a `video_url` part for Gemini models:
// on 2026-10-07 google/gemini-2.5-flash described a four-second clip correctly through
// it for $0.0005. This plugin registers that as a media-understanding provider, so a
// video someone sends either assistant is described through OpenRouter the way a photo
// or a voice note already is.
//
// The key is the gateway's own OPENROUTER_API_KEY, from the root-only env file the
// compose file hands the container. OpenClaw's auth lookup knows nothing of this
// provider's id, so the provider opts out of it and reads the key itself.

export const PLUGIN_ID = "household-openrouter-video";
export const PROVIDER_ID = "openrouter-video";
export const DEFAULT_MODEL = "google/gemini-2.5-flash";

const ENDPOINT = "https://openrouter.ai/api/v1/chat/completions";
const DEFAULT_PROMPT = "Describe the video.";
const DEFAULT_MIME = "video/mp4";
const MAX_ERROR = 300;

function deadline(request) {
  const timeout = AbortSignal.timeout(request.timeoutMs);
  return request.signal ? AbortSignal.any([request.signal, timeout]) : timeout;
}

export async function describeVideo(request, { env = process.env, fetchFn = fetch } = {}) {
  const apiKey = env.OPENROUTER_API_KEY;
  if (!apiKey) {
    throw new Error("Video description failed: OPENROUTER_API_KEY is not in the gateway's environment");
  }
  const model = request.model?.trim() || DEFAULT_MODEL;
  const video = `data:${request.mime || DEFAULT_MIME};base64,${request.buffer.toString("base64")}`;
  const response = await fetchFn(ENDPOINT, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: request.prompt?.trim() || DEFAULT_PROMPT },
            { type: "video_url", video_url: { url: video } },
          ],
        },
      ],
    }),
    signal: deadline(request),
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`Video description failed (${response.status}): ${body.slice(0, MAX_ERROR)}`);
  }
  let payload;
  try {
    payload = JSON.parse(body);
  } catch {
    throw new Error(`Video description failed: OpenRouter answered with no JSON: ${body.slice(0, MAX_ERROR)}`);
  }
  const choice = payload?.choices?.[0];
  const error = payload?.error ?? choice?.error;
  if (error || choice?.finish_reason === "error") {
    throw new Error(`Video description failed: ${String(error?.message ?? error ?? "OpenRouter ended the choice with an error").slice(0, MAX_ERROR)}`);
  }
  const content = choice?.message?.content;
  const text = typeof content === "string" ? content.trim() : "";
  if (!text) throw new Error("Video description response missing text");
  return { text, model };
}

export const provider = {
  id: PROVIDER_ID,
  capabilities: ["video"],
  defaultModels: { video: DEFAULT_MODEL },
  resolveAuth: () => ({ kind: "none", source: `${PLUGIN_ID} reads OPENROUTER_API_KEY` }),
  describeVideo: (request) => describeVideo(request),
};

export default {
  id: PLUGIN_ID,
  name: "Household OpenRouter video",
  description: "Describes a video someone sends either assistant through OpenRouter.",
  register(api) {
    api.registerMediaUnderstandingProvider(provider);
  },
};
