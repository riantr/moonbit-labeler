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
let _scrollRoot = null;       // element the observer scrolls relative to
let _registry = new WeakMap(); // el -> { loader, onLoad, loaded }
let _pendingSet = new Set();   // parallel to WeakMap for batch iteration
let _rootMargin = "100px 0px"; // 100px ahead — pre-warm one screen

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
        _pendingSet.delete(el);
        _observer.unobserve(el);
        // The loader is responsible for setting `el.src` (or whatever
        // wiring it wants). It may be async — that's fine, the observer
        // has already dropped its reference.
        Promise.resolve(rec.loader(el)).then(
          () => rec.onLoad && rec.onLoad(),
          (err) => rec.onLoad && rec.onLoad(err),
        );
      }
    },
    {
      // root=null uses the viewport (window). For a sidebar list inside
      // a scrolling container we want the container itself, not the
      // whole window — otherwise we end up issuing 48 simultaneous
      // fetches for things that are "below the window fold" but above
      // the sidebar's own scroll bottom. Callers attach the scroll
      // container via `setRoot()`.
      root: _scrollRoot,
      rootMargin: _rootMargin,
      threshold: 0,
    },
  );
  return _observer;
}

/**
 * Configure which scroll container the observer should use as its
 * root. Idempotent: re-initializes the observer against the new root
 * so existing entries become relative to the new container. PNG's
 * sidebar uses #file-list (`.file-list` in style.css).
 */
export function setRoot(el) {
  if (_scrollRoot === el) return;
  _scrollRoot = el;
  if (_observer) {
    _observer.disconnect();
    _observer = null;
    // Re-observe anything still pending.
    for (const target of _pendingSet) {
      _observer = _ensureObserver();
      _observer.observe(target);
    }
  }
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
  // Backward-compatible path: a static src is treated as a loader that
  // immediately sets `el.src`. Most callers used this with file:// URLs
  // before the IPC-thumbnail path was added.
  const loader = (target) => {
    target.src = src;
  };
  return observeLoader(el, loader, onLoad);
}

/**
 * Variant of `observe` that accepts a custom loader (an async function
 * that sets `el.src` itself). Used by the sidebar thumbnail path so the
 * actual data fetch goes through `op_read_thumb` (which produces a 128px
 * JPEG — 5 KB instead of 250 KB) rather than the full file:// URL.
 */
export function observeLoader(el, loader, onLoad) {
  const observer = _ensureObserver();
  if (!observer) {
    // No IntersectionObserver — fall back to eager load.
    Promise.resolve(loader(el)).then(
      () => onLoad && onLoad(),
      (err) => onLoad && onLoad(err),
    );
    return;
  }
  _registry.set(el, { loader, loaded: false, onLoad });
  _pendingSet.add(el);
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
  _pendingSet.delete(el);
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
  _pendingSet = new Set();
}

/**
 * For tests / DevTools: how many images are pending.
 */
export function pendingCount() {
  return _pendingSet.size;
}
