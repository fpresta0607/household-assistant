// A request this plugin refused, with a code the phone is told and words that carry
// nothing anybody said. `detailCode` names the rule, so the phone can show one line for
// it. Its own module, so a rule room.js uses can throw it without importing room.js back.

export class RoomError extends Error {
  constructor(code, message, detailCode = undefined) {
    super(message);
    this.code = code;
    if (detailCode !== undefined) this.detailCode = detailCode;
  }
}
