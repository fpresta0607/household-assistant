# Plan and specifications

This directory is the written record of what this project is meant to be, kept beside the code so a clone of this repository is self-contained.

- `approved-build-plan.md` is the build plan the owner reviewed over four rounds and approved on 17 September 2026.
  It carries the measured host facts, the account data model, the phase order, the decisions and the reasons behind them, and the list of things only the owner can do.
- `briefs/` holds the exact specification each phase was built from, one file per phase.
  A brief is the contract for that phase: what to build, what proves it works, and what must never happen.
- `coordination-between-assistants.md` is how Corey and Denise reach each other, why the family group is the only transport, and the emergency control that does not go through Telegram.
- `phase1-independent-review.md` is an independent review of the identity and privacy spine.
  It confirmed the isolation guarantees by removing each guard and watching the leak tests fail, rather than by reading the tests.

These documents describe intent.
Where a document and the code disagree, the code is what runs, and the disagreement is a bug in one of them.
