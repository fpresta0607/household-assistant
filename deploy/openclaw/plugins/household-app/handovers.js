// Which family-room posts belong to a turn the other assistant's @mention started, so
// every one of them is marked `handedOver` and starts nothing on the other gateway (see
// room.js). The turn's own reply is marked where it is delivered. A tool's post reaches
// this channel's sender with no word of the turn that made it, so the turn names each
// run OpenClaw starts for it, as it starts, and OpenClaw's tool hooks say which run each
// tool call is: a post made while a tool call of one of those runs is under way is the
// turn's. Nothing outlives the turn, so a tool call whose end never came marks nothing
// after it.

export function createHandovers() {
  // The handed-over turns' runs, each with its tool calls under way.
  const runs = new Map();

  return {
    // Runs one handed-over turn. `work` is handed the function that names a run it starts.
    async during(work) {
      const named = new Set();
      try {
        return await work((runId) => {
          named.add(runId);
          runs.set(runId, new Set());
        });
      } finally {
        for (const runId of named) runs.delete(runId);
      }
    },

    toolStarted(runId, toolCallId) {
      runs.get(runId)?.add(toolCallId);
    },

    toolEnded(runId, toolCallId) {
      runs.get(runId)?.delete(toolCallId);
    },

    // Whether a post to `conversation` now belongs to a handed-over turn.
    marks(conversation) {
      return conversation === "family" && [...runs.values()].some((calls) => calls.size > 0);
    },
  };
}
