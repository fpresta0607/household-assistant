// Which family-room posts belong to a turn the other assistant's @mention started, so
// every one of them is marked as that turn's own reply is, handed over or final (see
// room.js). The turn's own reply is marked where it is delivered. A tool's post reaches
// this channel's sender with no word of the turn that made it, so the turn names each
// run OpenClaw starts for it, as it starts, and OpenClaw's tool hooks say which run each
// tool call is: a post made while a tool call of one of those runs is under way is the
// turn's. Nothing outlives the turn, so a tool call whose end never came marks nothing
// after it.

export function createHandovers() {
  // The handed-over turns' runs, each with its mark and its tool calls under way.
  const runs = new Map();

  return {
    // Runs one handed-over turn, its posts marked `mark`, `true` or `"final"`. `work` is handed
    // the function that names a run it starts.
    async during(work, mark = true) {
      const named = new Set();
      try {
        return await work((runId) => {
          named.add(runId);
          runs.set(runId, { mark, calls: new Set() });
        });
      } finally {
        for (const runId of named) runs.delete(runId);
      }
    },

    toolStarted(runId, toolCallId) {
      runs.get(runId)?.calls.add(toolCallId);
    },

    toolEnded(runId, toolCallId) {
      runs.get(runId)?.calls.delete(toolCallId);
    },

    // How a post to `conversation` is marked now: as a handed-over turn's, `true` or
    // `"final"`, or `false` when it belongs to none. Final wins when two turns overlap.
    marks(conversation) {
      if (conversation !== "family") return false;
      const busy = [...runs.values()].filter((run) => run.calls.size > 0);
      if (busy.some((run) => run.mark === "final")) return "final";
      return busy.length > 0;
    },
  };
}
