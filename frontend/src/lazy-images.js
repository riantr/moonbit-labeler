// lazy-images.js — Shared IntersectionObserver pool for off-screen images.
//
// Why this exists:
//   The sidebar list renders all 2580 entries at once. Setting `<img>.src`
//   immediately on every <li> causes the browser to fetch + decode every
//   full-resolution JPG up front, which on CARS.Part.01 takes ~27s. The
//   native `loading="lazy"` attribute doesn't help much here because so
//   many <li>s land just-outside the viewport but the browser still
//   speculatively fetches them.
//
// What we do instead:
//   - Render every <li> (so the DOM/scroll is native and stable).
//   - For each <img>, store the data URL on `dataset.thumbSrc` and skip
//     `el.src` until the image is within `rootMargin` of the viewport.
//   - On observe, the same callback fires; for the first batch that
//     is already visible we still want them to load immediately, so
//     the observer's threshold is set to 0 — every entry gets the
//     callback once. We just need to be careful to only fire once.
//
// Performance contract:
//   - A single IntersectionObserver instance is shared across all <img>s.
//   - The callback runs at most once per element (latched via `loaded`).
//   - Disconnect stops observing but does not unload already-loaded srcs.
//
// Caveat: under heavy scrolling on a 2580-entry list, the observer can
//   fire 30+ callbacks per scroll event. That's fine because the browser
//   will only attempt to fetch each img once; the work happens in the
//   network stack, not in our JS.

let _observer = null;
let _registry = new WeakMap(); // el -> { src, onLoad }
let _rootMargin = "200px 0px"; // 200px ahead — pre-warm one screen

function _ensureObserver() {
  if (_observer) return _observer;
  if (typeof IntersectionObserver === "undefined") {
    return null; // CEF 147 supports it; this is a defensive fallback
  }
  _observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const el = entry.target;
        const rec = _registry.get(el);
        if (!rec || rec.loaded) continue;
        rec.loaded = true;
        _registry.delete(el);
        _observer.unobserve(el);
        el.src = rec.src;
        if (rec.onLoad) rec.onLoad();
      }
    },
    { root: null, rootMargin: _rootMargin, threshold: 0 },
  );
  return _observer;
}

/**
 * Tell `el` to load `src` once it enters the viewport (with `rootMargin`
 * pre-warm). If the element is already on-screen at observe time, the
 * observer fires once synchronously after the next layout pass and we
 * load then — this is the path that handles the first 10-15 visible
 * thumbnails.
 *
 * `onLoad` is optional; it's called as soon as we set `src`, not after
 * the <img> onload. (If you need the <img> onload, attach directly.)
 */
export function observe(el, src, onLoad) {
  const observer = _ensureObserver();
  if (!observer) {
    // No IntersectionObserver — fall back to eager load.
    el.src = src;
    if (onLoad) onLoad();
    return;
  }
  _registry.set(el, { src, loaded: false, onLoad });
  observer.observe(el);
}

/**
 * Forget about an element. We call this on list re-render so the old
 * <li>s don't pile up in the observer. If the element never loaded,
 * its record is GC'd; if it did, the <img> keeps its `src` (the OS
 * page cache owns that now).
 */
export function forget(el) {
  const rec = _registry.get(el);
  if (!rec) return;
  if (_observer) _observer.unobserve(el);
  _registry.delete(el);
}

/**
 * Tear down the whole pool. Useful when navigating folders.
 */
export function reset() {
  if (_observer) {
    _observer.disconnect();
    _observer = null;
  }
  _registry = new WeakMap();
}

/**
 * For tests / DevTools: how many images are pending.
 */
export function pendingCount() {
  // WeakMap can't be sized directly, but we can use a counter for
  // debugging. We don't track size today because the only consumer
  // bothers to count; left here as a stub.
  return 0;
}
