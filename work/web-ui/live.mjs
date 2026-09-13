// The live edit queue (LIVE_COEFFICIENTS_DESIGN.md step 5).
//
// Edits arrive faster than the Pi can take them: a slider drag is dozens of
// events a second, the applier is a fresh process per request, and the
// bridge answers within a poll. So: debounce, keep only the newest draft,
// never have more than one request in flight, and send whatever is newest
// once the previous one has answered. Pure and timer-injectable so the
// policy is testable without a browser.

export const LIVE_DEBOUNCE_MS = 150;

export class LiveQueue {
  /**
   * @param {object} options
   * @param {(draft: any) => Promise<any>} options.send   one request; resolves when the Pi answered
   * @param {number} [options.delayMs]                     debounce after the last edit
   * @param {(fn: Function, ms: number) => any} [options.setTimeout]
   * @param {(handle: any) => void} [options.clearTimeout]
   * @param {(outcome: {ok: boolean, draft: any, result?: any, error?: Error}) => void} [options.onSettled]
   */
  constructor({send, delayMs = LIVE_DEBOUNCE_MS, setTimeout: setT = globalThis.setTimeout, clearTimeout: clearT = globalThis.clearTimeout, onSettled = () => {}}) {
    this.send = send;
    this.delayMs = delayMs;
    this.setT = setT;
    this.clearT = clearT;
    this.onSettled = onSettled;
    this.pending = null;      // the newest draft not yet sent
    this.timer = null;
    this.inFlight = null;     // the promise of the request under way
    this.sent = 0;
    this.coalesced = 0;
  }

  /** A new draft: replaces any waiting one and restarts the debounce. */
  submit(draft) {
    if (this.pending !== null) this.coalesced += 1;
    this.pending = draft;
    if (this.timer !== null) this.clearT(this.timer);
    this.timer = this.setT(() => { this.timer = null; this.flush(); }, this.delayMs);
  }

  /** Send the waiting draft now, unless one is already in flight. */
  flush() {
    if (this.pending === null || this.inFlight) return this.inFlight;
    const draft = this.pending;
    this.pending = null;
    this.sent += 1;
    this.inFlight = Promise.resolve()
      .then(() => this.send(draft))
      .then(result => { this.onSettled({ok: true, draft, result}); },
            error => { this.onSettled({ok: false, draft, error}); })
      .finally(() => {
        this.inFlight = null;
        // Whatever arrived meanwhile goes next, without another debounce.
        if (this.pending !== null) this.flush();
      });
    return this.inFlight;
  }

  /** Drop what is waiting and let the in-flight request finish. */
  cancel() {
    if (this.timer !== null) { this.clearT(this.timer); this.timer = null; }
    this.pending = null;
  }

  get busy() { return this.inFlight !== null || this.pending !== null; }
}
