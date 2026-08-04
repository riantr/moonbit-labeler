// log.js — Lightweight instrumentation for the image-annotation pipeline.
//
// Why a dedicated module?
//   - We need monotonic, comparable timings across the full load path
//     (folder submit → list_images → selectImage → showImage → IPC
//     read_image / read_label → onload → layoutCanvas → first paint).
//   - The browser DevTools "Performance" panel is great for one-offs but
//     doesn't give us per-image percentiles. The listImages → pickImage
//     flow runs 100s of times in a real session; aggregating per-image
//     timings is what tells us if a 4K image is bottlenecking.
//   - The existing `console.log` calls in main.js are noisy; a typed
//     event log with `log.imageLoad(...)` calls gives us a structured
//     timeline that we can dump to disk or to a side panel later.
//
// Design:
//   - One global Log singleton. Each event has { type, t0, t1, ms, meta }.
//   - start("type", meta) returns a stop handle. The stop fn records
//     t1, ms, fires the event to every registered sink, and updates
//     the rolling summary. Awkward shape because some events aren't a
//     clean pair (e.g. "thumb loaded" for each of 50 thumbs), so we
//     also expose log.emit("type", meta) for fire-and-forget events.
//   - Sinks: `console` (default), and you can attach others. A future
//     "persist to %TEMP%/moonbit-labeler-load.log" sink is a 5-line
//     addition; for now we keep it simple.
//   - The summary is per-event-type: count / mean / p50 / p95 / max.
//     It's reset only on demand (`log.reset()`) so a session's worth
//     of data is preserved across images.

const _events = [];
const _summary = new Map(); // type -> { count, sum, max, samples[] }
const _sinks = [];
const _MAX_EVENTS = 2000;
const _SUMMARY_BUCKETS = 200; // cap on raw samples; pct is computed from sorted snapshot

function _defaultConsoleSink(ev) {
  const tag = `[labeler][${ev.type}]`;
  if (ev.error) {
    console.warn(tag, ev.ms?.toFixed?.(1) + "ms", ev.meta || "", "ERR", ev.error);
  } else if (ev.ms != null) {
    console.log(tag, ev.ms.toFixed(1) + "ms", ev.meta || "");
  } else {
    console.log(tag, ev.meta || "");
  }
}

_sinks.push(_defaultConsoleSink);

/** Register a sink. Returns an unregister fn. */
export function addSink(fn) {
  _sinks.push(fn);
  return () => {
    const i = _sinks.indexOf(fn);
    if (i >= 0) _sinks.splice(i, 1);
  };
}

function _recordSummary(type, ms) {
  let s = _summary.get(type);
  if (!s) {
    s = { count: 0, sum: 0, max: 0, samples: [] };
    _summary.set(type, s);
  }
  s.count += 1;
  s.sum += ms;
  if (ms > s.max) s.max = ms;
  // Reservoir-light: keep last N raw samples for pct computation.
  if (s.samples.length < _SUMMARY_BUCKETS) {
    s.samples.push(ms);
  } else {
    // Drop the smallest sample (rough but cheap). Better: random swap
    // with prob 1/N; for our volume a deterministic roll is fine.
    s.samples[Math.floor(Math.random() * s.samples.length)] = ms;
  }
}

function _emit(ev) {
  _events.push(ev);
  if (_events.length > _MAX_EVENTS) _events.shift();
  if (typeof ev.ms === "number") _recordSummary(ev.type, ev.ms);
  for (const s of _sinks) {
    try { s(ev); } catch (err) { /* don't let a sink crash the app */ }
  }
}

/**
 * Start a timed event. `meta` is arbitrary JSON-serializable data
 * attached to the event. Returns a `stop` function you call when the
 * work completes. If `stop` is never called the event is dropped.
 *
 * The returned stop fn is idempotent — calling it twice is a no-op.
 * The handle also exposes a `done` flag for cases where two parallel
 * paths (e.g. image-show and label-load) share one logical timer.
 */
export function start(type, meta) {
  const t0 = performance.now();
  const handle = {
    /** True once .stop() or .cancel() has been called. */
    done: false,
    stop(extraMeta, error) {
      if (handle.done) return;
      handle.done = true;
      const t1 = performance.now();
      _emit({
        type,
        t0,
        t1,
        ms: t1 - t0,
        meta: extraMeta ? { ...meta, ...extraMeta } : meta,
        error: error ? String(error) : undefined,
      });
    },
    /** Drop the event without recording (e.g. cancelled navigation). */
    cancel() { handle.done = true; },
  };
  return handle;
}

/** A convenience wrapper for "this happens when both A and B finish".
 * Either side can call .stop(); subsequent calls are no-ops.
 *
 *   const sw = pipelineStart("image.select");
 *   showImage(item, { onFirstPaint: () => sw.stop() });
 *   loadLabelFor(item, { onLoaded: () => sw.stop() });
 *
 * Under the hood it's just a start() handle with a done flag exposed.
 */
export function pipelineStart(type, meta) {
  return start(type, meta);
}

/** Emit a fire-and-forget event (no duration). */
export function emit(type, meta) {
  _emit({ type, t0: performance.now(), t1: performance.now(), meta });
}

/** Read the most recent N events. */
export function recent(n = 100) {
  return _events.slice(-n);
}

/** Reset all in-memory events + summary. */
export function reset() {
  _events.length = 0;
  _summary.clear();
}

/**
 * Compute a percentile over a numeric array (0-100). Uses nearest-rank
 * for stability on small samples.
 */
function _pct(arr, p) {
  if (arr.length === 0) return 0;
  const sorted = arr.slice().sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

/** Snapshot the per-type summary as a plain object. */
export function summary() {
  const out = {};
  for (const [type, s] of _summary) {
    out[type] = {
      count: s.count,
      mean: s.count ? s.sum / s.count : 0,
      p50: _pct(s.samples, 50),
      p95: _pct(s.samples, 95),
      max: s.max,
    };
  }
  return out;
}

/** Format a human-readable one-line summary. */
export function summaryText() {
  const s = summary();
  const keys = Object.keys(s).sort();
  if (keys.length === 0) return "(no events yet)";
  return keys
    .map((k) => {
      const v = s[k];
      return `${k.padEnd(28)} n=${String(v.count).padStart(4)}  mean=${v.mean.toFixed(1).padStart(6)}  p50=${v.p50.toFixed(1).padStart(6)}  p95=${v.p95.toFixed(1).padStart(6)}  max=${v.max.toFixed(1).padStart(6)}`;
    })
    .join("\n");
}

// ============================================================
// Convenience helpers — semantic event types we care about.
//
// Naming convention: snake_case, dot-separated for grouping.
// Keep this list small and stable; ad-hoc strings are fine, but
// the named types here are what `summary()` keys off.
// ============================================================
export const Event = Object.freeze({
  IMAGE_SELECT:       "image.select",         // user clicks an item in the sidebar
  IMAGE_SHOW:         "image.show",           // showImage() ran to completion
  IMAGE_DECODE:       "image.decode",         // await img.decode() resolved
  IMAGE_FALLBACK:     "image.fallback",       // base64 fallback path used
  IMAGE_FIRST_PAINT:  "image.first_paint",    // canvas painted the new frame
  IMAGE_THUMB_LOAD:   "image.thumb",          // sidebar thumbnail (one per item)
  IPC_LIST_IMAGES:    "ipc.list_images",
  IPC_LIST_VIDEOS:    "ipc.list_videos",
  IPC_READ_IMAGE:      "ipc.read_image",
  IPC_READ_LABEL:      "ipc.read_label",
  IPC_SCAN_CLASSES:    "ipc.scan_classes",
});

// Expose a global handle for ad-hoc inspection in DevTools. Useful
// for live tuning during a session: `__log.summary()` returns the
// per-type timing table.
if (typeof window !== "undefined") {
  window.__log = { start, emit, recent, summary, summaryText, reset, addSink, Event };
}
