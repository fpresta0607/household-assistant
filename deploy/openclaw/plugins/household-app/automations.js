// This assistant's automations that post in the family room, as the household note mirrors
// them (notes.js), so the other assistant knows they exist.
//
// Before either assistant could take a family reminder into the note, the family's weekly
// posts were automations of one gateway's, delivered to The Fam, and the other assistant
// never heard of them. The owning gateway lists its scheduler's jobs as OpenClaw reconciles
// it, again whenever a job changes, and as the channel starts, and keeps one line per job
// that posts in the family room: its name and when it runs, never what it tells the model.

import { spokenSchedule } from "./approval-asks.js";
import { familyGroupOf } from "./family-posts.js";

const AGENT = "main";
const TELEGRAM_CHAT = /^(?:(?:telegram|tg):)?(-?[1-9]\d*)$/i;

// Whether a job's delivery is the family room: The Fam on Telegram, or the app's own room.
function isFamilyDelivery(delivery, group) {
  if (delivery?.mode !== "announce" || typeof delivery.to !== "string") return false;
  if (delivery.channel === "telegram") return group !== undefined && TELEGRAM_CHAT.exec(delivery.to)?.[1] === group;
  return delivery.channel === "household" && delivery.to.trim().replace(/^household:/i, "").toLowerCase() === "family";
}

// When a job runs, in words, and in which zone when its schedule names one.
function scheduleWords(schedule, timeZone) {
  const spoken = spokenSchedule(schedule, timeZone);
  if (!spoken) return undefined;
  return schedule.kind === "cron" && typeof schedule.tz === "string" && schedule.tz.trim() ? `${spoken} (${schedule.tz.trim()})` : spoken;
}

// The enabled jobs of this gateway's assistant that post in the family room, each as the
// note mirrors it: `{ job, name, schedule }`. A job with no schedule the note can say is left out.
export function familyAutomations(jobs, { config, timeZone }) {
  const group = familyGroupOf(config);
  return jobs
    .filter((job) => job?.enabled !== false && (job?.agentId === undefined || job.agentId === AGENT) && isFamilyDelivery(job?.delivery, group))
    .map((job) => ({ job: job.id, name: typeof job.name === "string" ? job.name : "", schedule: scheduleWords(job.schedule, timeZone) }))
    .filter((job) => typeof job.job === "string" && job.schedule !== undefined);
}

// How long a run of a reminder may take before its Time Sensitive window closes anyway.
const REMINDER_RUN_MS = 10 * 60_000;

// A reminder someone made, announced straight to the app since Telegram went off (issue #6),
// is pushed Time Sensitive, as household-job-mirror's copies of it were, so it gets through a
// Focus. A channel's send is not told which run it comes from, so this keeps which jobs are
// reminders, a job with no declaration key that announces to the app, and while one runs its
// sends to that conversation are marked. `target` is the app conversation: family, or a person.
export function createReminderPushes({ now = Date.now } = {}) {
  let reminders = new Map();
  const running = new Map();
  const appTarget = (delivery) => {
    if (delivery?.mode !== "announce" || delivery.channel !== "household" || typeof delivery.to !== "string") return undefined;
    return delivery.to.trim().replace(/^household:/i, "").toLowerCase() || undefined;
  };
  return {
    // The scheduler's jobs, as listed.
    know(jobs) {
      reminders = new Map(jobs
        .filter((job) => typeof job?.id === "string" && !(typeof job.declarationKey === "string" && job.declarationKey.trim()))
        .map((job) => [job.id, appTarget(job.delivery)])
        .filter(([, target]) => target !== undefined));
    },
    // A `cron_changed` event: a reminder's run starting opens its window, and its end closes it.
    observe(event) {
      if (event?.action === "started" && reminders.has(event.jobId)) running.set(event.jobId, { target: reminders.get(event.jobId), until: now() + REMINDER_RUN_MS });
      else if (event?.action === "finished" || event?.action === "removed") running.delete(event.jobId);
    },
    isTimeSensitive(target) {
      for (const [jobId, run] of running) {
        if (run.until <= now()) running.delete(jobId);
        else if (run.target === target) return true;
      }
      return false;
    },
  };
}
