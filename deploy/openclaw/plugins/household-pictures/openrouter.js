// OpenRouter's image and video APIs, called with the gateway's own OPENROUTER_API_KEY.
//
// Both answer what each request cost, in dollars, as `usage.cost`, and that is the figure
// the household's daily ceilings count. OpenClaw 2026.9.4's own image_generate and
// video_generate drop it, which is why this plugin makes pictures and videos itself.
//
// A picture is one request that answers with the image. A video is a job: it is started,
// asked about until it is done, and its file is then fetched. The key goes only to
// openrouter.ai, so a job is always asked about by its id at OpenRouter's own address,
// never at a URL an answer names.

export const API = "https://openrouter.ai/api/v1";
export const VIDEO_MODELS_URL = `${API}/videos/models`;
const PICTURE_TIMEOUT_MS = 180_000;
const VIDEO_REQUEST_TIMEOUT_MS = 60_000;
const VIDEO_DOWNLOAD_TIMEOUT_MS = 180_000;
const KEPT_MS = 3_600_000;
const MAX_REASON = 300;
const JOB_ID = /^[A-Za-z0-9_-]{1,200}$/;

export class OpenRouterError extends Error {}

function deadline(signal, timeoutMs) {
  const timeout = AbortSignal.timeout(timeoutMs);
  return signal ? AbortSignal.any([signal, timeout]) : timeout;
}

const headersOf = (apiKey) => ({ Authorization: `Bearer ${apiKey}`, Accept: "application/json" });

// What an answer that was not ok says went wrong, in OpenRouter's own words when it gives any.
async function reasonOf(answer) {
  const body = await answer.text().catch(() => "");
  let message = body;
  try {
    message = JSON.parse(body)?.error?.message ?? body;
  } catch {
    // Not JSON: the body itself is the reason.
  }
  const said = String(message).trim().slice(0, MAX_REASON);
  return said ? `: ${said}` : "";
}

const costOf = (usage) => {
  const cost = Number(usage?.cost);
  return usage?.cost !== undefined && usage?.cost !== null && Number.isFinite(cost) && cost >= 0 ? cost : null;
};

// A picture's type from its first bytes, which OpenRouter's `media_type` only names when
// it can tell.
export function pictureType(bytes, named) {
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes.toString("ascii", 1, 4) === "PNG") return "image/png";
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (bytes.length >= 12 && bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP") return "image/webp";
  return typeof named === "string" && /^image\/[a-z0-9.+-]+$/.test(named) ? named : null;
}

// One picture. `references` are data URLs of photos to change or build on.
export async function makePicture({ apiKey, model, prompt, aspectRatio, references = [], fetchFn = fetch, signal }) {
  const answer = await fetchFn(`${API}/images`, {
    method: "POST",
    headers: { ...headersOf(apiKey), "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      prompt,
      n: 1,
      ...(aspectRatio ? { aspect_ratio: aspectRatio } : {}),
      ...(references.length > 0
        ? { input_references: references.map((url) => ({ type: "image_url", image_url: { url } })) }
        : {}),
    }),
    signal: deadline(signal, PICTURE_TIMEOUT_MS),
  });
  // OpenRouter charges nothing for a picture it did not finish (502).
  if (!answer.ok) throw new OpenRouterError(`OpenRouter answered ${answer.status} for the picture${await reasonOf(answer)}`);
  const payload = await answer.json();
  const [image] = Array.isArray(payload?.data) ? payload.data : [];
  if (typeof image?.b64_json !== "string" || image.b64_json === "") {
    throw new OpenRouterError("OpenRouter's answer held no picture");
  }
  const bytes = Buffer.from(image.b64_json, "base64");
  const mime = pictureType(bytes, image.media_type);
  if (!mime) throw new OpenRouterError("OpenRouter's answer held something that is not a picture");
  return { bytes, mime, cost: costOf(payload?.usage) };
}

// Starts a video. `firstFrame` is a data URL of a photo the video starts from.
export async function startVideo({ apiKey, model, prompt, seconds, resolution, aspectRatio, firstFrame, fetchFn = fetch, signal }) {
  const answer = await fetchFn(`${API}/videos`, {
    method: "POST",
    headers: { ...headersOf(apiKey), "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      prompt,
      ...(seconds ? { duration: seconds } : {}),
      ...(resolution ? { resolution } : {}),
      ...(aspectRatio ? { aspect_ratio: aspectRatio } : {}),
      ...(firstFrame ? { frame_images: [{ type: "image_url", image_url: { url: firstFrame }, frame_type: "first_frame" }] } : {}),
    }),
    signal: deadline(signal, VIDEO_REQUEST_TIMEOUT_MS),
  });
  if (!answer.ok) throw new OpenRouterError(`OpenRouter answered ${answer.status} for the video${await reasonOf(answer)}`);
  const id = (await answer.json())?.id;
  if (typeof id !== "string" || !JOB_ID.test(id)) throw new OpenRouterError("OpenRouter started the video with no job id");
  return { id };
}

// Where a video job stands: `status` is pending, in_progress, completed or failed, and a
// finished job carries what it cost.
export async function videoStatus({ apiKey, id, fetchFn = fetch, signal }) {
  const answer = await fetchFn(`${API}/videos/${id}`, { headers: headersOf(apiKey), signal: deadline(signal, VIDEO_REQUEST_TIMEOUT_MS) });
  if (!answer.ok) throw new OpenRouterError(`OpenRouter answered ${answer.status} about the video${await reasonOf(answer)}`);
  const job = await answer.json();
  const error = job?.error;
  return {
    status: String(job?.status ?? ""),
    cost: costOf(job?.usage),
    error: error ? String(error?.message ?? error).slice(0, MAX_REASON) : null,
  };
}

// A finished video's file, refused past `maxBytes`.
export async function fetchVideo({ apiKey, id, maxBytes, fetchFn = fetch, signal }) {
  const answer = await fetchFn(`${API}/videos/${id}/content?index=0`, {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: deadline(signal, VIDEO_DOWNLOAD_TIMEOUT_MS),
  });
  if (!answer.ok) throw new OpenRouterError(`OpenRouter answered ${answer.status} for the video's file${await reasonOf(answer)}`);
  const length = Number(answer.headers?.get?.("content-length"));
  if (length > maxBytes) throw new OpenRouterError(`the video is over ${maxBytes} bytes`);
  const bytes = Buffer.from(await answer.arrayBuffer());
  if (bytes.length > maxBytes) throw new OpenRouterError(`the video is over ${maxBytes} bytes`);
  const named = String(answer.headers?.get?.("content-type") ?? "").split(";")[0].trim();
  return { bytes, mime: /^video\/[a-z0-9.+-]+$/.test(named) ? named : "video/mp4" };
}

// OpenRouter's public list of video models, with the lengths, sizes and prices each
// takes, read with no key and kept for an hour. A read that failed is tried again by the
// next caller. `latest` is the list last read, or null before any read has finished.
export function createVideoModels({ fetchFn = fetch, now = Date.now } = {}) {
  let kept = null;
  let latest = null;

  async function read() {
    if (kept && (kept.pending || now() - kept.at < KEPT_MS)) return kept.pending ?? kept.data;
    const pending = (async () => {
      const answer = await fetchFn(VIDEO_MODELS_URL, { headers: { Accept: "application/json" } });
      if (!answer.ok) throw new OpenRouterError(`OpenRouter answered ${answer.status} for its video models`);
      const data = (await answer.json())?.data;
      if (!Array.isArray(data)) throw new OpenRouterError("OpenRouter's list of video models has no models");
      return data;
    })();
    kept = { pending };
    try {
      const data = await pending;
      kept = { at: now(), data };
      latest = data;
      return data;
    } catch (error) {
      kept = null;
      throw error;
    }
  }

  return { read, latest: () => latest };
}
