// image-loader.js — Owns the "load image, load label, paint" pipeline.
//
// Extracted from main.js so the load-path is reviewable in one place and
// so video.js can mirror the same shape (onFrameLoaded). The pipeline is:
//
//   selectImage(idx)
//     └─ fork in parallel:
//          showImage(item)       → file:// src → img.decode() → onImageLoad
//              └─ on error → onImageError → IPC read_image → data: src
//          loadLabelFor(item)    → IPC read_label → parse → state.label
//     └─ whichever finishes last fires the IMAGE_SELECT stopwatch
//
// Why this is one module and not three:
//   - The three primary functions (showImage / onImageError / loadLabelFor)
//     share module-private state (the AbortController, the latch flags on
//     onload/onerror, the loadToken). Splitting them across files would
//     either expose that state or re-create it via globals.
//   - The Log instrumentation is sprinkled through the pipeline; keeping
//     it next to the code it measures makes the timing semantics obvious.
//
// What stays in main.js:
//   - The <img> element reference (els.image) — owned by the DOM
//   - The canvas API (canvasApi) — set on it after layout, not after load
//   - State mutation (state.imgNatural, state.label, …) — done by callbacks
//     the caller passes in. We don't reach into main.js's `state` from here.

import * as Log from "./log.js";

// ============================================================
// fileUrl: encode a filesystem path into a file:// URL the browser
// can fetch. Chromium refuses to load file:// URLs without proper
// escaping (spaces, #, ?, %, etc.) so we encodeURIComponent each
// path segment while leaving the slashes alone.
// ============================================================
export function fileUrl(path) {
  let p = path.replace(/\\/g, "/");
  let encoded = p.split("/").map(encodeURIComponent).join("/");
  if (/^[a-zA-Z]:\//.test(p)) return "file:///" + encoded;
  if (p.startsWith("/")) return "file://" + encoded;
  return "file:///" + encoded;
}

// ============================================================
// showImage — load the image into the <img> element, with a
// fallback to data: URL via the IPC bridge if file:// fails
// (CORS, weird schemes, portless paths, etc.).
//
// Returns nothing. The caller passes callbacks:
//   onLoad(natural)   — fired after first decode succeeds
//   onFirstPaint()    — fired after layoutCanvas+renderAnnotations
//   onError(reason)   — fired if both file:// and data: fallback fail
//
// The AbortController here lets us cancel in-flight loads when the
// user clicks through images fast. The latched onloadFired/onerrorFired
// flags prevent double-firing when Chromium re-dispatches onerror
// after img.decode() rejects (observed in CEF 147).
// ============================================================
let _currentLoadController = null;

export async function showImage(item, deps) {
  const {
    img,                  // the <img> DOM element
    signal,               // optional AbortSignal — caller-owned
    onLoad,               // (natural: {w,h}) => void
    onFirstPaint,         // optional () => void
    onError,              // (reason: string) => void
    onFallback,           // optional () => void   (IPC fallback started)
    invokeReadImage,      // (path) => Promise<{base64, mime} | null>
  } = deps;

  // Cancel any in-flight load from a previous nav. We use a single
  // module-private controller rather than taking the signal from the
  // caller so the function is self-contained.
  if (_currentLoadController) _currentLoadController.abort();
  const ctl = new AbortController();
  _currentLoadController = ctl;

  // The "image.show" timer measures file:// I/O + first decode round-trip.
  // The "image.decode" timer is a sub-event we fire from onImageLoad.
  const showStop = Log.start(Log.Event.IMAGE_SHOW, {
    path: item.path,
    size: item.size,
  });
  let decodeStop = null;

  let onloadFired = false;
  let onerrorFired = false;
  img.onload = () => {
    if (onloadFired) return;
    onloadFired = true;
    if (decodeStop) {
      decodeStop.stop({ w: img.naturalWidth, h: img.naturalHeight });
    }
    if (onLoad) onLoad({ w: img.naturalWidth, h: img.naturalHeight });
    if (onFirstPaint) onFirstPaint();
  };
  img.onerror = () => {
    if (onerrorFired) return;
    onerrorFired = true;
    if (decodeStop) decodeStop.cancel();
    handleImageError(item, { img, invokeReadImage, onError, onFallback })
      .catch(() => {});
  };
  try {
    decodeStop = Log.start(Log.Event.IMAGE_DECODE, { path: item.path });
    img.src = fileUrl(item.path);
    if (img.decode) {
      await img.decode();
      // decode() resolves before onload in some browsers; if onload
      // already fired we don't double-stop.
      if (decodeStop) {
        decodeStop.stop({ w: img.naturalWidth, h: img.naturalHeight });
      }
    }
    showStop.stop();
  } catch (err) {
    if (decodeStop) decodeStop.cancel();
    if (err?.name === "AbortError") {
      showStop.cancel();
      return;
    }
    await handleImageError(item, {
      img, invokeReadImage, onError, onFallback,
    });
    showStop.stop({ fallback: true }, err);
  }
}

// Internal — IPC fallback path. Split from showImage so the rejection
// branch above is symmetric with the onerror branch (both call into
// the same handler).
async function handleImageError(item, deps) {
  const { img, invokeReadImage, onError, onFallback } = deps;
  const ipcStop = Log.start(Log.Event.IPC_READ_IMAGE, {
    path: item.path, role: "fallback",
  });
  const fbStop = Log.start(Log.Event.IMAGE_FALLBACK, { path: item.path });
  if (onFallback) onFallback();
  try {
    const reply = await invokeReadImage(item.path);
    ipcStop.stop({ bytes: reply?.base64?.length || 0 });
    if (reply?.base64) {
      // Detach onerror so the data: URL load doesn't re-trigger fallback.
      img.onerror = null;
      img.src = `data:${reply.mime};base64,${reply.base64}`;
      fbStop.stop({ mime: reply.mime, bytes: reply.base64.length });
    } else {
      fbStop.stop({ ok: false });
      if (onError) onError("无法加载图片");
    }
  } catch (err) {
    ipcStop.stop({}, err);
    fbStop.stop({ ok: false }, err);
    if (onError) onError(`无法加载图片: ${err}`);
  }
}

// ============================================================
// loadLabelFor — read the JSON label for the given image and
// hand it back through the onLabel callback. The caller decides
// what to do with it (mutate state, mark UI, etc.).
//
// We track a loadToken so that if the user navigates away while
// we're awaiting the IPC, we don't clobber the new label with
// stale data. The token is owned by the caller — we just compare.
// ============================================================
export async function loadLabelFor(item, deps) {
  const {
    invokeReadLabel,      // (path) => Promise<{found, content, label_path} | null>
    parseLabel,           // (text) => object | null
    normalizeLabel,       // (parsed, name) => label
    emptyLabel,           // () => empty label object
    currentToken,         // number — caller's load counter
    checkToken,           // () => number — caller's current token
    onLabel,              // (parsed | null, labelJson) => void
    onMarkLabeled,        // optional (path) => void
  } = deps;

  const token = currentToken;
  const ipcStop = Log.start(Log.Event.IPC_READ_LABEL, { path: item.path });
  try {
    const reply = await invokeReadLabel(item.path);
    ipcStop.stop({ found: !!reply?.found, bytes: reply?.content?.length || 0 });
    if (token !== checkToken()) return;
    let parsed = null;
    if (reply?.found && reply?.content) {
      parsed = parseLabel(reply.content);
    }
    const label = parsed
      ? normalizeLabel(parsed, item.name)
      : { img_name: item.name, infos: [], bindings: [] };
    if (onLabel) {
      onLabel(parsed, label, reply?.label_path || "", !!reply?.found);
    }
    if (reply?.found && onMarkLabeled) onMarkLabeled(item.path);
  } catch (err) {
    ipcStop.stop({}, err);
    if (token !== checkToken()) return;
    if (onLabel) {
      onLabel(null, emptyLabel(), "", false);
    }
  }
}

// ============================================================
// onFrameLoaded — video-mode counterpart of onImageLoad. The video
// decoder gives us natural dimensions directly without going through
// <img>.onload, so we update the layout fields ourselves and let the
// caller run its own paint loop. The caller is responsible for the
// rAF scheduling (it needs to update state.imgNatural first).
// ============================================================
export function onFrameLoaded(natural, deps) {
  const { imageFrame, imageBox, onLayout } = deps;
  if (!natural || !natural.w || !natural.h) return;
  if (imageFrame) {
    imageFrame.style.aspectRatio = `${natural.w} / ${natural.h}`;
  }
  if (imageBox) imageBox.classList.add("has-image");
  // Defer to the next frame so CSS reflow has applied. This matches
  // what onImageLoad does for image-mode.
  requestAnimationFrame(() => onLayout(natural));
}

// ============================================================
// layoutCanvas — measure the image's display rect, lock the
// image-frame to the natural aspect ratio, and forward to the
// canvas API. The IMG_CHANGED gate ensures we only fire the
// first_paint event on real image transitions, not on every
// ResizeObserver tick during window resize.
//
// Caller provides:
//   - imgNatural        : {w, h}      (current state.imgNatural)
//   - currentSrc        : string       (current state._currentImgSrc)
//   - setSrcLocked(s)   : void         (state._currentImgSrc = s)
//   - canvasApi         : canvas module API
//   - renderAnnotations : () => void
//   - hideEmptyHint     : () => void
//
// Returns the new imgDisplay rect {w, h, left, top} for mouse math.
// ============================================================
export function layoutCanvas(deps) {
  const {
    img,
    imgBox,
    imageFrame,
    stage,
    imgNatural,
    currentSrc,
    setSrcLocked,
    canvasApi,
    renderAnnotations,
    hideEmptyHint,
  } = deps;

  if (!canvasApi) return null;
  if (imgNatural.w <= 0 || imgNatural.h <= 0) return null;

  // Switching images resets any pan/zoom the user left behind from
  // the previous one — much less disorienting than seeing the new frame
  // through the previous one's zoom window. This branch also gates the
  // `image.first_paint` event so it fires *once* per image.
  const imgChanged = currentSrc !== img.src;
  if (imgChanged) {
    canvasApi.resetView();
    setSrcLocked(img.src);
  }
  if (imageFrame) {
    imageFrame.style.aspectRatio = `${imgNatural.w} / ${imgNatural.h}`;
  }
  if (imgBox) imgBox.classList.add("has-image");
  // Force a layout read so the frame's CSS box settles on the natural
  // aspect-ratio (see image-frame[style*="aspect-ratio"] in style.css
  // — without an explicit reflow the frame might still be at the
  // previous image's size when we read getBoundingClientRect()).
  imageFrame && imageFrame.offsetHeight;
  const rect = img.getBoundingClientRect();
  const stageRect = stage.getBoundingClientRect();
  const imgDisplay = {
    w: rect.width,
    h: rect.height,
    left: rect.left - stageRect.left,
    top: rect.top - stageRect.top,
  };
  canvasApi.resize(imgNatural, imgDisplay);
  if (imgChanged) {
    const firstPaintStop = Log.start(Log.Event.IMAGE_FIRST_PAINT, {
      naturalW: imgNatural.w,
      naturalH: imgNatural.h,
      displayW: rect.width,
      displayH: rect.height,
    });
    requestAnimationFrame(() => {
      renderAnnotations();
      firstPaintStop.stop();
    });
  } else {
    requestAnimationFrame(renderAnnotations);
  }
  hideEmptyHint();
  return imgDisplay;
}

// ============================================================
// installResizeObserver — re-runs layoutCanvas whenever the <img>
// reflows. Caller owns the observer so it can disconnect on teardown.
// ============================================================
export function installResizeObserver(img, onResize) {
  const ro = new ResizeObserver(() => onResize());
  ro.observe(img);
  return ro;
}
