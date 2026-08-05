// main.js — rewritten with modern WHATWG APIs:
//   - <dialog> for error popups (no overlay divs)
//   - Image.decode() for async image readiness
//   - Pointer Events (consolidated mouse/touch/pen)
//   - ResizeObserver (reactive layout, no setTimeout polling)
//   - requestAnimationFrame batching (one render per frame)
//   - structuredClone for history snapshots (deep copy w/o JSON)
//   - URL + fetch for IPC (compatible with our proton bridge)
//   - AbortController for cancelling stale image loads
//
// State machine + IPC + autosave + keyboard + class list stays the same
// shape as before; canvas.js now uses Canvas 2D (see canvas.js header).

import { parseLabel, normalizeLabel, serializeLabel, emptyLabel } from "./label.js";
import { createCanvas } from "./canvas.js";
import { createVideoController } from "./video.js";
import {
  fileUrl,
  showImage as loadImageInto,
  loadLabelFor as loadLabelInto,
  onFrameLoaded as applyFrameLoaded,
  layoutCanvas as layoutImageCanvas,
  installResizeObserver as observeImageResize,
} from "./image-loader.js";
import * as LazyImages from "./lazy-images.js";
import * as Log from "./log.js";

const $ = (sel) => document.querySelector(sel);

const DEFAULT_IMAGE_FOLDER =
  "D:/src/Marvis/MoonBitLabeler/data/Image@CARS.Part.01";
const RECENT_KEY = "moonbit-labeler/recent-folders";
const MAX_RECENT = 6;
const AUTOSAVE_MS_INITIAL = 600;
const POLYGON_CLOSE_RADIUS_PX_INITIAL = 12;
// Settings — persisted to localStorage so they survive across launches.
// Each slider in the menubar drives one of these.
const SETTINGS_KEY = "moonbit-labeler/settings-v1";
const settings = {
  annotationOpacity: 0.8,
  polygonClosePx: 12,
  autosaveMs: 600,
  // "native"  : browser <img> element renders the bitmap; the canvas
  //             overlay is transparent except for annotations. This is
  //             the default path and what we ship.
  // "mizchi"  : the canvas overlay rasterizes the bitmap (decoded by
  //             the mizchi/image op in the backend). Slower than
  //             native because every image change is a full IPC round
  //             trip + a PNG round-trip, but it bypasses the
  //             proton://app file:// cascade and doesn't depend on
  //             the CEF image decoders. Toggle it by adding
  //             `?mode=mizchi` to the URL or by calling
  //             `settings.imageRenderMode = 'mizchi'` from the
  //             dev console. localStorage is unavailable in the
  //             proton://app origin so we don't read it from there.
  imageRenderMode: "native",
};
try {
  const raw = localStorage.getItem(SETTINGS_KEY);
  if (raw) Object.assign(settings, JSON.parse(raw));
} catch {}
// URL query string takes precedence over localStorage. Useful for
// quickly switching the render path during dev without the devtools.
try {
  const url = new URL(window.location.href);
  const mode = url.searchParams.get("mode");
  if (mode === "mizchi" || mode === "native") {
    settings.imageRenderMode = mode;
  }
} catch {}
function persistSettings() {
  try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch {}
}

const state = {
  folder: "",
  labelFolder: "",
  images: [],
  videos: [],
  // Active media index. `currentIndex` is into `images` (image mode) or
  // `videos` (video mode); `mediaKind` switches between them.
  currentIndex: -1,
  mediaKind: "image", // "image" | "video"
  // Per-image label state
  label: emptyLabel(),
  labelPath: "",
  loadedFromDisk: false,
  // Annotation interaction state
  mode: "select",
  classType: "object",
  selectedId: null,
  draftPoints: [],
  bindingFromId: null,
  // Persistent class list
  classes: [],
  classIndex: -1,
  // UI
  dirty: false,
  saving: false,
  saveError: null,
  history: [],
  // Image mapping
  imgNatural: { w: 0, h: 0 },
  imgDisplay: { w: 0, h: 0 },
  // Per-folder label cache
  labeledPaths: new Set(),
  // Monotonic counter to discard stale async replies
  loadToken: 0,
  // Video mode state — populated by video.js
  currentVideo: null,      // { name, path, ext, sizeBytes }
  currentVideoIdx: -1,
  videoMeta: null,         // { width, height, fps, frameCount, durationMs, codec, ok }
  currentFrame: 0,
  frameLabels: new Map(),  // frame -> { img_name, infos, bindings, frames }
  diskJson: null,          // most recent on-disk JSON for the active video
};

const els = {
  folderForm: $("#folder-form"),
  folderInput: $("#folder-input"),
  browseBtn: $("#browse-btn"),
  folderPath: $("#folder-path"),
  labelPath: $("#label-path"),
  fileList: $("#file-list"),
  imageCount: $("#image-count"),
  classList: $("#class-list"),
  classCount: $("#class-count"),
  image: $("#image"),
  imageBox: $("#image-box"),
  imageFrame: $("#image-frame"),
  emptyHint: $("#empty-hint"),
  statusPath: $("#status-path"),
  statusIndex: $("#status-index"),
  toolbar: $("#toolbar"),
  classInput: $("#class-input"),
  dirtyBadge: $("#dirty-badge"),
  saveBtn: $("#save-btn"),
  undoBtn: $("#undo-btn"),
  deleteBtn: $("#delete-btn"),
  // menubar
  menubar: $("#menubar"),
  zoomReadout: $("#zoom-readout"),
  opacitySlider: $("#opacity-slider"),
  closeRadiusSlider: $("#closeradius-slider"),
  autosaveSlider: $("#autosave-slider"),
  closePxLabel: $("#close-px-label"),
  autosaveLabel: $("#autosave-label"),
  // timeline (video mode)
  timeline: $("#timeline"),
  framePrev: $("#frame-prev"),
  frameNext: $("#frame-next"),
  frameSlider: $("#frame-slider"),
  frameNo: $("#frame-no"),
  frameTotal: $("#frame-total"),
  frameFps: $("#frame-fps"),
  frameCoverage: $("#frame-coverage"),
  frameCopyNext: $("#frame-copy-next"),
};

// Expose a few commonly-needed els to modules that don't import main.js.
state.els = els;

// ============================================================
// Persisted recent folders (localStorage with safe fallback)
// ============================================================

function readRecent() {
  try {
    const raw = localStorage.getItem(RECENT_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((s) => typeof s === "string") : [];
  } catch {
    return [];
  }
}

function writeRecent(folder) {
  try {
    const list = readRecent().filter((s) => s !== folder);
    list.unshift(folder);
    localStorage.setItem(RECENT_KEY, JSON.stringify(list.slice(0, MAX_RECENT)));
  } catch {
    // localStorage is blocked under proton://app/ (opaque origin); fall back
    // to an in-memory list so the input still gets pre-filled next launch.
    if (!state._memRecent) state._memRecent = [];
    state._memRecent = [folder, ...state._memRecent.filter((s) => s !== folder)].slice(0, MAX_RECENT);
  }
}

// ============================================================
// Label folder convention: Image@X/*  ->  Label@X/*
// ============================================================

function detectLabelFolder(imageFolder) {
  const norm = imageFolder.replace(/[\\/]+$/, "");
  const lastSlash = Math.max(norm.lastIndexOf("/"), norm.lastIndexOf("\\"));
  const parent = lastSlash >= 0 ? norm.substring(0, lastSlash) : "";
  const leaf = lastSlash >= 0 ? norm.substring(lastSlash + 1) : norm;
  const m = leaf.match(/^Image@(.*)$/);
  if (!m) return "";
  const labelLeaf = "Label@" + m[1];
  const sep = parent.includes("\\") || imageFolder.includes("\\") ? "\\" : "/";
  return parent ? parent + sep + labelLeaf : labelLeaf;
}

function setFolder(path) {
  state.folder = path;
  state.labelFolder = detectLabelFolder(path);
  els.folderPath.textContent = path || "未指定文件夹";
  els.folderPath.title = path || "";
  if (state.labelFolder) {
    els.labelPath.textContent = `标注 → ${state.labelFolder}`;
    els.labelPath.title = state.labelFolder;
  } else {
    els.labelPath.textContent = "";
    els.labelPath.title = "";
  }
}

function colorForType(type) {
  // Hash class string into a deterministic pastel hue.
  let hash = 0;
  for (let i = 0; i < type.length; i++) {
    hash = (hash * 31 + type.charCodeAt(i)) | 0;
  }
  const hue = ((hash % 360) + 360) % 360;
  return `hsl(${hue} 70% 55%)`;
}

// ============================================================
// File list rendering
// ============================================================

function setMedia({ images = [], videos = [] } = {}) {
  state.images = images;
  state.videos = videos;
  state.currentIndex = -1;
  state.currentVideoIdx = -1;
  state.currentVideo = null;
  state.videoMeta = null;
  state.currentFrame = 0;
  state.frameLabels = new Map();
  state.diskJson = null;
  setTimelineVisible(false);

  // Merge for the sidebar list. Images go on top, videos below, each
  // with their own index space. We dispatch click via the `data-kind`
  // attribute so the right selector is invoked.
  const total = images.length + videos.length;
  els.imageCount.textContent =
    `${images.length} 张 · ${videos.length} 段`;
  els.fileList.replaceChildren();
  // Drop any in-flight lazy thumb observations from the previous folder.
  // The new <li>s we create below will replace them, but the old ones
  // are still in the observer's watch list until they're GC'd.
  LazyImages.reset();
  const frag = document.createDocumentFragment();
  images.forEach((img, idx) => {
    frag.appendChild(renderListItem({
      kind: "image",
      index: idx,
      path: img.path,
      name: img.name,
      ext: img.ext,
      thumb: fileUrl(img.path),
      onClick: () => selectImage(idx),
    }));
  });
  videos.forEach((vid, idx) => {
    frag.appendChild(renderListItem({
      kind: "video",
      index: idx,
      path: vid.path,
      name: vid.name,
      ext: vid.ext,
      // We could show a still frame as the thumb later. For now we
      // draw a generic video placeholder.
      thumb: null,
      onClick: () => selectVideo(idx),
    }));
  });
  els.fileList.appendChild(frag);

  if (images.length > 0) {
    selectImage(0);
  } else if (videos.length > 0) {
    selectVideo(0);
  } else {
    showEmptyHint("所选文件夹里没有可标注的图片或视频");
    updateStatus(null, 0, 0);
  }
}

function renderListItem({ kind, index, path, name, ext, thumb, onClick }) {
  const li = document.createElement("li");
  li.dataset.kind = kind;
  li.dataset.index = String(index);
  li.dataset.path = path;
  if (kind === "video") li.classList.add("video-item");

  if (thumb) {
    const t = document.createElement("img");
    t.className = "thumb";
    t.alt = "";
    t.decoding = "async";
    // Defer setting `src` until the element is in (or near) the viewport.
    // The previous code set `t.src = thumb` immediately, which on a
    // 2580-entry list meant 2580 simultaneous file:// fetches; CDP timing
    // shows that took ~27s total. The native `loading="lazy"` attribute
    // alone wasn't enough — Chromium speculatively fetches nearby items.
    // We use a shared IntersectionObserver with a 200px rootMargin so
    // the first ~15 visible thumbs load immediately (the observer fires
    // once for each on next layout) and the rest wait for scroll.
    //
    // We tried routing thumbs through `op_read_thumb` (a 128px JPEG,
    // ~5 KB) to cut the per-thumb payload 50x. The CDP bench showed
    // it was actually slower per-thumb (~3.7s vs 178ms) because ffmpeg
    // cold-start cost per invocation dominates. The win is in lazy
    // loading itself, not in downscale. The backend op is kept for
    // future use (e.g. a low-bandwidth export pipeline).
    const thumbStop = Log.start(Log.Event.IMAGE_THUMB_LOAD, { path });
    t.onload = () => thumbStop.stop({ w: t.naturalWidth, h: t.naturalHeight });
    t.onerror = () => {
      thumbStop.stop({ ok: false });
      loadThumbFallback(t, path);
    };
    LazyImages.observe(t, thumb);
    li.appendChild(t);
  } else {
    // video placeholder
    const ph = document.createElement("div");
    ph.className = "thumb";
    ph.style.cssText = "display:flex;align-items:center;justify-content:center;color:#fff;background:#0f1c19;font-size:22px;";
    ph.textContent = "▶";
    li.appendChild(ph);
  }

  const meta = document.createElement("div");
  meta.className = "meta";
  const extTag = document.createElement("span");
  extTag.className = "ext-tag";
  extTag.textContent = (ext || "").replace(".", "") || "?";
  const nameEl = document.createElement("span");
  nameEl.className = "name";
  nameEl.textContent = name;
  nameEl.title = path;
  meta.append(extTag, nameEl);
  li.appendChild(meta);

  if (state.labeledPaths.has(path)) {
    const dot = document.createElement("span");
    dot.className = "labeled-dot";
    dot.title = "已标注";
    li.appendChild(dot);
  }

  li.addEventListener("click", onClick);
  return li;
}

async function loadThumbFallback(thumb, path) {
  try {
    const reply = await invokeLabeler("read_image", { path });
    if (reply?.base64) {
      thumb.onerror = null;
      thumb.src = `data:${reply.mime};base64,${reply.base64}`;
    }
  } catch {}
}

function updateStatus(item, currentIndex, total) {
  if (!item) {
    els.statusPath.textContent = "—";
    els.statusIndex.textContent = `0 / ${total}`;
    return;
  }
  els.statusPath.textContent = item.path;
  els.statusIndex.textContent = `${currentIndex + 1} / ${total}`;
}

function showEmptyHint(text) {
  els.emptyHint.hidden = false;
  els.emptyHint.textContent = text;
  els.image.hidden = true;
}

// Image loading pipeline now lives in image-loader.js. The thin
// wrappers below keep the original call sites compiling: they
// adapt main.js's state mutations + IPC handles into the deps
// object the module expects.

function hideEmptyHint() {
  els.emptyHint.hidden = true;
}

function showImage(item, opts = {}) {
  showEmptyHint("加载图片...");
  // Two render modes:
  //   - "native" (default): the <img> element renders the bitmap and
  //     the canvas overlay is transparent except for annotations.
  //   - "mizchi": the backend (mizchi/image) decodes + encodes the
  //     image and we hand the resulting PNG to the canvas overlay.
  //     The <img> element is hidden because the canvas now owns the
  //     bitmap.
  const mode = settings.imageRenderMode || "native";
  if (mode === "mizchi") {
    els.image.hidden = true;
    els.image.style.transform = "";
    return showImageMizchi(item, opts);
  }
  els.image.hidden = false;
  // A previous image may have been panned/zoomed. Clear its DOM transform
  // before the new fitted frame is measured; setupViewSync will apply the
  // fresh identity view again when layoutCanvas resets the canvas view.
  els.image.style.transform = "";
  return loadImageInto(item, {
    img: els.image,
    onLoad: (natural) => {
      state.imgNatural = natural;
      // The <img> element itself renders the bitmap (via object-fit:
      // contain inside the aspect-locked frame). The canvas overlay is
      // transparent except for the annotation shapes it draws on top.
      // Both share the same coordinate origin so pan/zoom/click
      // coordinate mapping is trivial.
      requestAnimationFrame(layoutCanvas);
    },
    onFirstPaint: opts.onFirstPaint,
    onError: (reason) => showEmptyHint(reason),
    invokeReadImage: (path) => invokeLabeler("read_image", { path }),
  });
}

///| Bypass path: ask the backend to decode the source image with
/// mizchi/image, then hand the resulting PNG to the canvas overlay.
/// The view transform (zoom/pan) moves the image and annotations
/// together because both are painted into the same static layer.
async function showImageMizchi(item, opts = {}) {
  const selectStop = Log.start(Log.Event.IMAGE_SELECT, {
    index: state.currentIndex,
    path: item.path,
    w: item.w,
    h: item.h,
    bytes: item.size,
    mode: "mizchi",
  });
  try {
    const reply = await invokeLabeler("decode_image", { path: item.path });
    if (!reply?.base64) {
      showEmptyHint("mizchi decode failed: empty reply");
      return;
    }
    const blob = await fetch(`data:${reply.mime};base64,${reply.base64}`).then(
      (r) => r.blob(),
    );
    const bitmap = await createImageBitmap(blob);
    state.imgNatural = { w: bitmap.width, h: bitmap.height };
    if (canvasApi && typeof canvasApi.setImageBitmap === "function") {
      canvasApi.setImageBitmap(bitmap);
    }
    requestAnimationFrame(layoutCanvas);
    if (opts.onLoaded) opts.onLoaded();
    Log.emit("image.mizchi", { path: item.path, w: bitmap.width, h: bitmap.height });
  } catch (err) {
    showEmptyHint(`mizchi decode failed: ${err}`);
  } finally {
    selectStop.stop();
  }
}

function loadLabelFor(item, opts = {}) {
  state.label = emptyLabel();
  state.labelPath = "";
  state.loadedFromDisk = false;
  state.history = [];
  state.dirty = false;
  const token = ++state.loadToken;
  return loadLabelInto(item, {
    invokeReadLabel: (path) =>
      invokeLabeler("read_label", { image_path: path }),
    parseLabel,
    normalizeLabel,
    emptyLabel,
    currentToken: token,
    checkToken: () => state.loadToken,
    onLabel: (parsed, label, labelPath, found) => {
      state.labelPath = labelPath;
      state.label = label;
      state.loadedFromDisk = !!parsed;
      if (found) {
        state.labeledPaths.add(item.path);
        markLabeled(item.path);
      }
    },
    onMarkLabeled: (path) => markLabeled(path),
  }).then(() => {
    if (token !== state.loadToken) return;
    if (opts.onLoaded) opts.onLoaded();
    updateDirtyBadge();
    requestAnimationFrame(() => renderAnnotations());
  });
}

// ============================================================
// Layout: lock the image and overlay to a shared viewport div.
// Re-measured whenever the stage reflows via ResizeObserver.
// ============================================================

function layoutCanvas() {
  const stage = document.getElementById("stage");
  // In mizchi mode the <img> element is hidden, so we can't read its
  // getBoundingClientRect. Compute the fitted frame size from the
  // stage's content box and imgNatural instead, and pass it through
  // displayOverride so image-loader.js uses that instead of the <img>.
  let displayOverride = null;
  if ((settings.imageRenderMode || "native") === "mizchi" && state.imgNatural.w > 0) {
    // Top-left alignment: anchor the frame at (0, 0) inside the stage so the
    // mizchi canvas overlay renders the bitmap at the same coordinate as the
    // <img>-driven native path.
    displayOverride = {
      w: state.imgNatural.w,
      h: state.imgNatural.h,
      left: 0,
      top: 0,
    };
  }
  const result = layoutImageCanvas({
    img: els.image,
    imgBox: els.imageBox,
    imageFrame: els.imageFrame,
    stage,
    imgNatural: state.imgNatural,
    currentSrc: state._currentImgSrc,
    setSrcLocked: (s) => { state._currentImgSrc = s; },
    canvasApi,
    renderAnnotations,
    hideEmptyHint,
    displayOverride,
  });
  if (result) state.imgDisplay = result;
}

let _imageResizeObserver = null;

function installResizeObserver() {
  if (_imageResizeObserver) return;
  _imageResizeObserver = observeImageResize(document.getElementById("stage"), () => {
    if (state.imgNatural.w > 0) layoutCanvas();
  });
}

function markLabeled(path) {
  state.labeledPaths.add(path);
  const li = els.fileList.querySelector(`li[data-path="${cssEscape(path)}"]`);
  if (li && !li.querySelector(".labeled-dot")) {
    const dot = document.createElement("span");
    dot.className = "labeled-dot";
    dot.title = "已标注";
    li.appendChild(dot);
  }
}

function setTimelineVisible(visible) {
  if (!els.timeline) return;
  els.timeline.classList.toggle("hidden", !visible);
}

function updateFrameReadout(frame, total, fps, coverage) {
  if (els.frameNo) els.frameNo.textContent = String(frame);
  if (els.frameTotal) els.frameTotal.textContent = String(Math.max(0, total - 1));
  if (els.frameSlider) {
    const maxAttr = Math.max(0, total - 1);
    if (Number(els.frameSlider.max) !== maxAttr) {
      els.frameSlider.max = String(maxAttr);
    }
    if (Number(els.frameSlider.value) !== frame) {
      els.frameSlider.value = String(frame);
    }
  }
  if (els.frameFps) {
    if (fps > 0) {
      els.frameFps.textContent = `${fps.toFixed(2)} fps · ${formatDuration(frame, fps)}`;
    } else {
      els.frameFps.textContent = "— fps";
    }
  }
  if (els.frameCoverage && coverage != null) {
    els.frameCoverage.textContent = `已标注 ${coverage} 帧`;
  }
}

function formatDuration(frame, fps) {
  if (!fps || fps <= 0) return "—";
  const sec = frame / fps;
  const m = Math.floor(sec / 60);
  const s = (sec - m * 60);
  return `${m.toString().padStart(2, "0")}:${s.toFixed(2).padStart(5, "0")}`;
}

function cssEscape(s) {
  return String(s).replace(/["\\]/g, "\\$&");
}

function selectImage(idx) {
  if (idx < 0 || idx >= state.images.length) return;
  if (state.dirty) flushSave().catch(() => {});
  state.mediaKind = "image";
  setTimelineVisible(false);
  state.currentIndex = idx;
  state.currentVideoIdx = -1;
  state.currentVideo = null;
  state.videoMeta = null;
  state.frameLabels = new Map();
  state.diskJson = null;
  for (const li of els.fileList.children) {
    li.classList.toggle(
      "active",
      li.dataset.kind === "image" && Number(li.dataset.index) === idx,
    );
  }
  const item = state.images[idx];
  updateStatus(item, idx, state.images.length);
  // End-to-end load instrumentation. The handle is idempotent: it
  // stops on whichever side (image show OR label load) finishes last,
  // and the other callback's stop() call is a no-op.
  const selectStop = Log.start(Log.Event.IMAGE_SELECT, {
    index: idx,
    path: item.path,
    w: item.w,
    h: item.h,
    bytes: item.size,
  });
  showImage(item, { onFirstPaint: () => selectStop.stop() });
  loadLabelFor(item, { onLoaded: () => selectStop.stop() });
}

// ============================================================
// Annotation CRUD + autosave
// ============================================================

let saveTimer = null;

function pushHistory() {
  // structuredClone is the modern way to deep-copy without the JSON round-trip.
  state.history.push(structuredClone(state.label));
  if (state.history.length > 50) state.history.shift();
}

function markDirty() {
  state.dirty = true;
  updateDirtyBadge();
  requestAnimationFrame(() => renderAnnotations());
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(flushSave, settings.autosaveMs);
}

function undo() {
  if (state.history.length === 0) return;
  const prev = state.history.pop();
  state.label = prev;
  state.dirty = true;
  updateDirtyBadge();
  requestAnimationFrame(() => renderAnnotations());
  updateDeleteBtn();
  if (state.labelPath) {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(flushSave, settings.autosaveMs);
  }
}

async function flushSave() {
  if (saveTimer) {
    clearTimeout(saveTimer);
    saveTimer = null;
  }
  if (state.mediaKind === "video") {
    if (!state.dirty || !state.currentVideo || !videoController) return;
    state.saving = true;
    updateDirtyBadge();
    try {
      await videoController.flushSave();
      state.dirty = false;
      state.saveError = null;
      markLabeled(state.currentVideo.path);
    } catch (err) {
      state.saveError = String(err);
      console.error("[video] write_label failed:", err);
    } finally {
      state.saving = false;
      updateDirtyBadge();
    }
    return;
  }
  if (!state.dirty || !state.labelPath) return;
  state.saving = true;
  updateDirtyBadge();
  try {
    const item = state.images[state.currentIndex];
    const content = serializeLabel(state.label);
    await invokeLabeler("write_label", { image_path: item.path, content });
    state.dirty = false;
    state.saveError = null;
    markLabeled(item.path);
  } catch (err) {
    state.saveError = String(err);
    console.error("write_label failed:", err);
  } finally {
    state.saving = false;
    updateDirtyBadge();
  }
}

function updateDirtyBadge() {
  if (!els.dirtyBadge) return;
  els.dirtyBadge.classList.remove("dirty", "saving", "ok");
  els.dirtyBadge.textContent = "";
  if (state.saving) {
    els.dirtyBadge.classList.add("saving");
    els.dirtyBadge.textContent = "保存中...";
  } else if (state.saveError) {
    els.dirtyBadge.classList.add("dirty");
    els.dirtyBadge.textContent = "保存失败";
  } else if (state.dirty) {
    els.dirtyBadge.classList.add("dirty");
    els.dirtyBadge.textContent = "未保存";
  } else if (state.loadedFromDisk) {
    els.dirtyBadge.classList.add("ok");
    els.dirtyBadge.textContent = "已保存";
  }
}

// ============================================================
// Annotation rendering — one rAF per state change (batched)
// ============================================================

let canvasApi = null;
let _renderQueued = false;

function renderAnnotations() {
  if (!canvasApi) return;
  // Coalesce multiple state changes into a single rAF tick.
  if (_renderQueued) return;
  _renderQueued = true;
  requestAnimationFrame(() => {
    _renderQueued = false;
    canvasApi.render({
      label: state.label,
      mode: state.mode,
      selectedId: state.selectedId,
      draftPoints: state.draftPoints,
      bindingFromId: state.bindingFromId,
      colorForType,
      opacity: settings.annotationOpacity,
    });
  });
}

function setMode(mode) {
  state.mode = mode;
  state.draftPoints = [];
  state.bindingFromId = null;
  state.selectedId = null;
  for (const btn of document.querySelectorAll(".mode-btn")) {
    btn.classList.toggle("active", btn.dataset.mode === mode);
  }
  renderAnnotations();
  updateCanvasCursor();
  updateDeleteBtn();
}

function updateCanvasCursor() {
  const stage = document.getElementById("stage");
  stage.style.cursor = state.mode === "select" ? "default" : "crosshair";
}

function hitTestAnnotation(x, y) {
  const tol = 8 / Math.max(state.imgNatural.w, 1) * Math.max(state.imgNatural.w, state.imgNatural.h);
  // Bindings first so they win over their endpoints.
  for (let i = state.label.bindings.length - 1; i >= 0; i--) {
    const b = state.label.bindings[i];
    const a = state.label.infos.find((x) => x.id === b.from);
    const c = state.label.infos.find((x) => x.id === b.to);
    if (!a || !c) continue;
    const pa = centroid(a);
    const pc = centroid(c);
    if (pointToSegmentDistance(x, y, pa, pc) <= tol) return { kind: "binding", id: b.id };
  }
  for (let i = state.label.infos.length - 1; i >= 0; i--) {
    const a = state.label.infos[i];
    if (pointInAnnotation(x, y, a, tol)) return { kind: "info", id: a.id };
  }
  return null;
}

function pointInAnnotation(x, y, a, tol) {
  const pts = a.points;
  if (!pts || pts.length === 0) return false;
  if (a.shape === "rect" && pts.length >= 2) {
    const x1 = Math.min(pts[0][0], pts[1][0]);
    const x2 = Math.max(pts[0][0], pts[1][0]);
    const y1 = Math.min(pts[0][1], pts[1][1]);
    const y2 = Math.max(pts[0][1], pts[1][1]);
    return x >= x1 - tol && x <= x2 + tol && y >= y1 - tol && y <= y2 + tol;
  }
  if (a.shape === "keypoint") {
    for (const [px, py] of pts) {
      if (Math.hypot(px - x, py - y) <= tol * 2) return true;
    }
    return false;
  }
  // polygon: ray casting
  let inside = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i];
    const [xj, yj] = pts[j];
    if (((yi > y) !== (yj > y)) && (x < ((xj - xi) * (y - yi)) / (yj - yi) + xi)) {
      inside = !inside;
    }
  }
  return inside;
}

function pointToSegmentDistance(px, py, a, b) {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  if (len2 === 0) return Math.hypot(px - a[0], py - a[1]);
  let t = ((px - a[0]) * dx + (py - a[1]) * dy) / len2;
  t = Math.max(0, Math.min(1, t));
  return Math.hypot(px - (a[0] + t * dx), py - (a[1] + t * dy));
}

function centroid(a) {
  const pts = a.points || [];
  if (pts.length === 0) return [0, 0];
  let sx = 0, sy = 0;
  for (const [x, y] of pts) { sx += x; sy += y; }
  return [sx / pts.length, sy / pts.length];
}

function newId(prefix) {
  return prefix + "_" + Math.random().toString(36).slice(2, 9);
}

function displayDist(a, b) {
  if (!state.imgNatural.w) return 0;
  return Math.hypot(a[0] - b[0], a[1] - b[1]) / state.imgNatural.w;
}

function displayDistPx(a, b) {
  if (!state.imgDisplay.w) return 0;
  return displayDist(a, b) * state.imgDisplay.w;
}

function commitPolygon() {
  if (state.draftPoints.length < 3) {
    state.draftPoints = [];
    renderAnnotations();
    return;
  }
  pushHistory();
  state.label.infos.push({
    id: newId("obj"),
    shape: "polygon",
    type: state.classType || "object",
    points: state.draftPoints.slice(),
  });
  state.draftPoints = [];
  markDirty();
}

function deleteSelected() {
  if (!state.selectedId) return;
  pushHistory();
  const id = state.selectedId;
  const next = {
    img_name: state.label.img_name,
    infos: state.label.infos.filter((a) => a.id !== id),
    bindings: state.label.bindings.filter((b) => b.id !== id && b.from !== id && b.to !== id),
  };
  state.label = next;
  state.selectedId = null;
  markDirty();
  updateDeleteBtn();
}

function updateDeleteBtn() {
  if (!els.deleteBtn) return;
  els.deleteBtn.disabled = !state.selectedId;
}

// ============================================================
// Canvas event wiring — uses Pointer Events (WHATWG Pointer Events).
// Falls back to Mouse Events if Pointer Events aren't supported.
// ============================================================

function bindCanvasEvents(api) {
  api.onMouseDown((_ev, imgPt) => {
    if (!imgPt) return;
    if (state.mode === "rect") {
      state.draftPoints = [imgPt, imgPt];
    }
  });
  api.onMouseMove((_ev, imgPt) => {
    if (!imgPt) return;
    if (state.mode === "rect" && state.draftPoints.length === 2) {
      state.draftPoints[1] = imgPt;
      renderAnnotations();
    }
  });
  api.onMouseUp((_ev, imgPt) => {
    if (!imgPt) return;
    if (state.mode === "rect" && state.draftPoints.length === 2) {
      const [a, b] = state.draftPoints;
      if (Math.abs(a[0] - b[0]) > 2 && Math.abs(a[1] - b[1]) > 2) {
        pushHistory();
        state.label.infos.push({
          id: newId("obj"),
          shape: "rect",
          type: state.classType || "object",
          points: [a, b],
        });
        markDirty();
      }
      state.draftPoints = [];
      renderAnnotations();
    }
  });
  api.onClick((_ev, imgPt) => {
    if (!imgPt) return;
    const hit = hitTestAnnotation(imgPt[0], imgPt[1]);
    if (state.mode === "select") {
      state.selectedId = hit ? hit.id : null;
      renderAnnotations();
      updateDeleteBtn();
      return;
    }
    if (state.mode === "polygon") {
      if (state.draftPoints.length >= 3) {
        const first = state.draftPoints[0];
        if (displayDistPx(imgPt, first) < settings.polygonClosePx) {
          commitPolygon();
          return;
        }
      }
      state.draftPoints.push(imgPt);
      renderAnnotations();
      return;
    }
    if (state.mode === "keypoint") {
      pushHistory();
      state.label.infos.push({
        id: newId("kp"),
        shape: "keypoint",
        type: state.classType || "keypoint",
        points: [imgPt],
      });
      markDirty();
      return;
    }
    if (state.mode === "binding") {
      if (!hit || hit.kind !== "info") {
        state.bindingFromId = null;
        renderAnnotations();
        return;
      }
      if (!state.bindingFromId) {
        state.bindingFromId = hit.id;
        renderAnnotations();
        return;
      }
      if (state.bindingFromId === hit.id) {
        state.bindingFromId = null;
        renderAnnotations();
        return;
      }
      const exists = state.label.bindings.some(
        (b) => (b.from === state.bindingFromId && b.to === hit.id) ||
               (b.from === hit.id && b.to === state.bindingFromId),
      );
      if (!exists) {
        pushHistory();
        state.label.bindings.push({
          id: newId("b"),
          from: state.bindingFromId,
          to: hit.id,
          type: "same_group",
        });
        markDirty();
      }
      state.bindingFromId = null;
      renderAnnotations();
    }
  });
  api.onDblClick(() => {
    if (state.mode === "polygon" && state.draftPoints.length >= 3) {
      commitPolygon();
    }
  });
}

// ============================================================
// Class list (sidebar) + number key shortcuts
// ============================================================

function renderClassList() {
  if (!els.classList) return;
  els.classList.replaceChildren();
  const frag = document.createDocumentFragment();
  state.classes.forEach((cls, idx) => {
    const li = document.createElement("li");
    li.dataset.index = String(idx);
    li.dataset.name = cls.name;

    const key = document.createElement("span");
    key.className = "key";
    key.textContent = idx < 9 ? String(idx + 1) : "-";
    li.appendChild(key);

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = cls.name;
    name.title = `${cls.name} (used in ${cls.count} annotations)`;
    li.appendChild(name);

    const count = document.createElement("span");
    count.className = "count";
    count.textContent = String(cls.count);
    li.appendChild(count);

    if (idx === state.classIndex) li.classList.add("active");
    li.addEventListener("click", () => selectClass(idx));
    frag.appendChild(li);
  });
  els.classList.appendChild(frag);
  if (els.classCount) els.classCount.textContent = `${state.classes.length} 个`;
}

function selectClass(idx) {
  if (idx < 0 || idx >= state.classes.length) return;
  state.classIndex = idx;
  const cls = state.classes[idx];
  if (!cls) return;
  state.classType = cls.name;
  if (els.classInput) {
    els.classInput.value = cls.name;
    els.classInput.dataset.fromList = "1";
  }
  for (const li of els.classList.children) {
    li.classList.toggle("active", Number(li.dataset.index) === idx);
  }
}

function pickInitialFolder() {
  const recent = readRecent();
  return recent.length > 0 ? recent[0] : DEFAULT_IMAGE_FOLDER;
}

function bindToolbar() {
  for (const btn of document.querySelectorAll(".mode-btn")) {
    btn.addEventListener("click", () => setMode(btn.dataset.mode));
  }
  els.classInput.addEventListener("input", () => {
    const v = els.classInput.value.trim() || "object";
    state.classType = v;
    const idx = state.classes.findIndex((c) => c.name === v);
    if (idx !== state.classIndex) {
      state.classIndex = idx;
      for (const li of els.classList.children) {
        li.classList.toggle("active", Number(li.dataset.index) === idx);
      }
    }
  });
  els.undoBtn.addEventListener("click", undo);
  els.deleteBtn.addEventListener("click", deleteSelected);
  els.saveBtn.addEventListener("click", () => flushSave());
  if (els.browseBtn) els.browseBtn.addEventListener("click", browseFolder);
  // timeline (video mode)
  if (els.framePrev) els.framePrev.addEventListener("click", () => videoController?.stepFrame(-1));
  if (els.frameNext) els.frameNext.addEventListener("click", () => videoController?.stepFrame(1));
  if (els.frameSlider) els.frameSlider.addEventListener("input", () => {
    if (!videoController || !state.currentVideo) return;
    const v = Number(els.frameSlider.value);
    if (v !== state.currentFrame) videoController.selectFrame(v);
  });
  if (els.frameCopyNext) els.frameCopyNext.addEventListener("click", () => videoController?.copyFrameToNext());
  updateDeleteBtn();
}

async function browseFolder() {
  if (!els.browseBtn) return;
  const prev = els.browseBtn.disabled;
  els.browseBtn.disabled = true;
  const original = els.browseBtn.textContent;
  els.browseBtn.textContent = "…";
  try {
    const reply = await invokeLabeler("pick_folder", {
      title: "选择图片文件夹",
      initial: els.folderInput.value.trim() || null,
    });
    if (reply?.path) {
      els.folderInput.value = reply.path;
      els.folderForm.dispatchEvent(new Event("submit", { cancelable: true }));
    }
  } catch (err) {
    console.error("pick_folder failed:", err);
    showEmptyHint(`选择文件夹失败: ${err}`);
  } finally {
    els.browseBtn.disabled = prev;
    els.browseBtn.textContent = original;
  }
}

function bindEvents() {
  bindToolbar();
  els.folderForm.addEventListener("submit", (ev) => {
    ev.preventDefault();
    const raw = els.folderInput.value.trim();
    if (raw) listImages(raw);
  });

  document.addEventListener("keydown", (ev) => {
    const active = document.activeElement;
    if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA")) return;
    if ((ev.ctrlKey || ev.metaKey) && !ev.shiftKey && (ev.key === "z" || ev.key === "Z")) {
      ev.preventDefault(); undo(); return;
    }
    if ((ev.ctrlKey || ev.metaKey) && (ev.key === "s" || ev.key === "S")) {
      ev.preventDefault(); flushSave(); return;
    }
    if ((ev.ctrlKey || ev.metaKey) && (ev.key === "+" || ev.key === "=")) {
      ev.preventDefault(); canvasApi?.zoomBy(1.25); return;
    }
    if ((ev.ctrlKey || ev.metaKey) && ev.key === "-") {
      ev.preventDefault(); canvasApi?.zoomBy(1 / 1.25); return;
    }
    if ((ev.ctrlKey || ev.metaKey) && ev.key === "0") {
      ev.preventDefault(); canvasApi?.resetView(); return;
    }
    if (ev.key === "Delete" || ev.key === "Backspace") {
      ev.preventDefault(); deleteSelected(); return;
    }
    if (ev.key === "Escape") {
      if (state.draftPoints.length > 0 || state.bindingFromId) {
        state.draftPoints = [];
        state.bindingFromId = null;
        renderAnnotations();
        return;
      }
    }
    if (state.images.length === 0 && state.videos.length === 0) return;
    if (ev.key === "ArrowDown" || ev.key === "j") {
      ev.preventDefault();
      if (state.mediaKind === "video" && videoController) {
        videoController.stepFrame(1);
      } else {
        const next = Math.min(state.currentIndex + 1, state.images.length - 1);
        if (next !== state.currentIndex) selectImage(next);
      }
    } else if (ev.key === "ArrowUp" || ev.key === "k") {
      ev.preventDefault();
      if (state.mediaKind === "video" && videoController) {
        videoController.stepFrame(-1);
      } else {
        const prev = Math.max(state.currentIndex - 1, 0);
        if (prev !== state.currentIndex) selectImage(prev);
      }
    } else if (state.mediaKind === "video" && (ev.key === "ArrowLeft" || ev.key === "ArrowRight")) {
      ev.preventDefault();
      videoController?.stepFrame(ev.key === "ArrowRight" ? 1 : -1);
    }
    const m = { v: "select", r: "rect", p: "polygon", k: "keypoint", b: "binding" };
    if (m[ev.key.toLowerCase()]) setMode(m[ev.key.toLowerCase()]);
    if (state.classes.length > 0 && /^[1-9]$/.test(ev.key)) {
      const idx = parseInt(ev.key, 10) - 1;
      if (idx < state.classes.length) {
        ev.preventDefault();
        selectClass(idx);
        return;
      }
    }
  });
}

// ============================================================
// IPC + bootstrap
// ============================================================

function setState(patch) {
  Object.assign(state, patch);
}

function getState() {
  return state;
}

async function invokeLabeler(op, payload) {
  const app = window.__MoonBit__;
  if (!app?.core?.invokeOp) throw new Error("bridge not ready");
  return app.core.invokeOp(`ext:labeler/${op}`, payload);
}

async function listImages(folder) {
  setFolder(folder);
  let images = [];
  let videos = [];
  // The three IPCs here all run sequentially. We want them separately
  // timed so the summary can flag, say, a slow list_images on a
  // remote/network folder.
  const listImagesStop = Log.start(Log.Event.IPC_LIST_IMAGES, { path: folder });
  try {
    const reply = await invokeLabeler("list_images", { path: folder });
    listImagesStop.stop({ count: reply?.images?.length || 0 });
    if (reply?.images && Array.isArray(reply.images)) {
      images = reply.images;
    }
  } catch (err) {
    listImagesStop.stop({}, err);
    console.error("[listImages] list_images failed:", err);
  }
  const listVideosStop = Log.start(Log.Event.IPC_LIST_VIDEOS, { path: folder });
  try {
    const reply = await invokeLabeler("list_videos", { path: folder });
    listVideosStop.stop({ count: reply?.videos?.length || 0 });
    if (reply?.videos && Array.isArray(reply.videos)) {
      videos = reply.videos;
    }
  } catch (err) {
    listVideosStop.stop({}, err);
    // Video support is opt-in; missing ffmpeg / list_videos shouldn't
    // block the image workflow.
    console.warn("[listImages] list_videos failed:", err);
  }
  writeRecent(folder);
  if (images.length === 0 && videos.length === 0) {
    setMedia({});
    showEmptyHint("所选文件夹里没有可标注的图片或视频");
    updateStatus(null, 0, 0);
  } else {
    setMedia({ images, videos });
  }
  const scanStop = Log.start(Log.Event.IPC_SCAN_CLASSES, { path: folder });
  try {
    const cr = await invokeLabeler("scan_classes", { image_path: folder });
    scanStop.stop({ count: cr?.classes?.length || 0 });
    if (cr?.classes && Array.isArray(cr.classes)) {
      state.classes = cr.classes;
      renderClassList();
    }
  } catch (err) {
    console.error("[listImages] scan_classes failed:", err);
  }
}

// Video-mode shim: forwarded to the video controller. Initialized in
// `initVideoController()` below (deferred until the IPC bridge is ready).
let videoController = null;
async function selectVideo(idx) {
  if (!videoController) return;
  if (state.dirty) await flushSave().catch(() => {});
  state.mediaKind = "video";
  await videoController.selectVideo(idx);
  for (const li of els.fileList.children) {
    li.classList.toggle(
      "active",
      li.dataset.kind === "video" && Number(li.dataset.index) === idx,
    );
  }
}

// ============================================================
// Menubar wiring (open/close + dispatch actions)
// ============================================================

function setupMenubar() {
  if (!els.menubar) return;

  // Click outside closes any open menu.
  document.addEventListener("click", (ev) => {
    if (!ev.target.closest(".menubar-item.open")) {
      for (const item of els.menubar.querySelectorAll(".menubar-item.open")) {
        item.classList.remove("open");
        const t = item.querySelector(".menubar-trigger");
        if (t) t.setAttribute("aria-expanded", "false");
      }
    }
  });
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") {
      for (const item of els.menubar.querySelectorAll(".menubar-item.open")) {
        item.classList.remove("open");
        const t = item.querySelector(".menubar-trigger");
        if (t) t.setAttribute("aria-expanded", "false");
      }
    }
  });

  // Click trigger toggles dropdown.
  for (const trigger of els.menubar.querySelectorAll(".menubar-trigger")) {
    trigger.addEventListener("click", (ev) => {
      ev.stopPropagation();
      const item = trigger.closest(".menubar-item");
      const wasOpen = item.classList.contains("open");
      // close all first
      for (const other of els.menubar.querySelectorAll(".menubar-item.open")) {
        other.classList.remove("open");
        const t = other.querySelector(".menubar-trigger");
        if (t) t.setAttribute("aria-expanded", "false");
      }
      if (!wasOpen) {
        item.classList.add("open");
        trigger.setAttribute("aria-expanded", "true");
      }
    });
  }

  // Click any menu item dispatches a "labeler:action" CustomEvent.
  for (const li of els.menubar.querySelectorAll("li[role='menuitem']")) {
    li.addEventListener("click", async (ev) => {
      const action = li.dataset.action;
      // close dropdown
      const item = li.closest(".menubar-item");
      item.classList.remove("open");
      const t = item.querySelector(".menubar-trigger");
      if (t) t.setAttribute("aria-expanded", "false");
      await runMenuAction(action);
    });
  }

  // Sliders in the Settings menu:
  const initSlider = (input, label, key, fmt = (v) => v) => {
    if (!input) return;
    input.value = String(settings[key]);
    if (label) label.textContent = fmt(settings[key]);
    input.addEventListener("input", () => {
      const v = Number(input.value);
      settings[key] = v;
      persistSettings();
      if (label) label.textContent = fmt(v);
      applySettings();
    });
  };
  initSlider(els.opacitySlider, null, "annotationOpacity", (v) => `${Math.round(v * 100)}%`);
  initSlider(els.closeRadiusSlider, els.closePxLabel, "polygonClosePx");
  initSlider(els.autosaveSlider, els.autosaveLabel, "autosaveMs");

  applySettings();
}

function applySettings() {
  // Opacity -> passed to canvas.render via state.opacity
  if (canvasApi) {
    requestAnimationFrame(() => renderAnnotations());
  }
}

/** Dispatch table for every menu action. */
async function runMenuAction(action) {
  switch (action) {
    case "open-folder":
      els.browseBtn?.click();
      break;
    case "reload":
      if (state.folder) listImages(state.folder);
      break;
    case "save-now":
      flushSave();
      break;
    case "save-all":
    case "export-voc":
    case "export-yolo":
      flashHint(`"${action}" 还在路上 —— 标记 TODO`, "info");
      break;
    case "quit":
      window.close();
      break;
    case "undo":
      undo(); break;
    case "redo":
      // redo stack not implemented yet
      flashHint("重做 (Ctrl+Y) 还没实现 —— 多步撤销用 Ctrl+Z 即可", "info");
      break;
    case "delete-selected":
      deleteSelected(); break;
    case "clear-all":
      flashHint("清空当前图的标注：按 Delete 逐个删", "info");
      break;
    case "mode-select": setMode("select"); break;
    case "mode-rect": setMode("rect"); break;
    case "mode-polygon": setMode("polygon"); break;
    case "mode-keypoint": setMode("keypoint"); break;
    case "mode-binding": setMode("binding"); break;
    case "zoom-in":   zoomMenu(1.25); break;
    case "zoom-out":  zoomMenu(1 / 1.25); break;
    case "zoom-reset": canvasApi?.resetView(); break;
    case "zoom-fit":   canvasApi?.fitView(); break;
    case "prev-image":
      if (state.images.length > 0)
        selectImage(Math.max(state.currentIndex - 1, 0));
      break;
    case "next-image":
      if (state.images.length > 0)
        selectImage(Math.min(state.currentIndex + 1, state.images.length - 1));
      break;
    case "clear-recent":
      try { localStorage.removeItem(RECENT_KEY); } catch {}
      flashHint("最近文件夹历史已清空", "info");
      break;
    case "rescan-classes":
      if (state.folder) {
        const cr = await invokeLabeler("scan_classes", { image_path: state.folder });
        if (cr?.classes) { state.classes = cr.classes; renderClassList(); }
      }
      break;
    case "add-prefix":
    case "add-suffix":
    case "open-devtools":
      flashHint(`"${action}" 还在路上 —— 标记 TODO`, "info");
      break;
    default:
      console.warn("unknown menubar action:", action);
  }
}

function zoomMenu(factor) {
  if (!canvasApi) return;
  // Zoom around screen center for keyboard shortcuts
  canvasApi.zoomBy(factor);
}

function flashHint(msg, kind) {
  // Lightweight one-shot toast near the statusbar.
  const el = document.createElement("div");
  el.textContent = msg;
  el.className = "toast";
  el.style.cssText = `
    position: fixed; bottom: 36px; left: 50%; transform: translateX(-50%);
    background: var(--panel); border: 1px solid var(--line);
    padding: 8px 16px; border-radius: 6px; box-shadow: 0 6px 18px rgba(0,0,0,0.18);
    font-size: 12px; color: var(--ink);
    z-index: 9999;
  `;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 2200);
}

// ============================================================
// View (zoom/pan) sync — keep the menubar "100%" readout accurate
// ============================================================

function syncNativeImageView(v) {
  if (!v || !els.image) return;
  const nativeMode = (settings.imageRenderMode || "native") === "native" && !els.image.hidden;
  els.image.style.transformOrigin = "0 0";
  els.image.style.transform = nativeMode
    ? `translate(${v.pan.x}px, ${v.pan.y}px) scale(${v.zoom})`
    : "";
}

function setupViewSync() {
  function fmtZoom(z) { return `${Math.round(z * 100)}%`; }
  document.addEventListener("labeler:viewchange", (ev) => {
    const v = ev.detail;
    if (els.zoomReadout && v) els.zoomReadout.textContent = fmtZoom(v.zoom);
    // Native mode renders the bitmap in <img>, so mirror the canvas view
    // transform there. Mizchi mode owns both bitmap and annotations in the
    // canvas and must not receive a second DOM transform.
    syncNativeImageView(v);
    // Force a redraw at the new view (composite picks up view.pan/zoom)
    requestAnimationFrame(() => renderAnnotations());
  });
}

function waitForBridge(attempt = 0) {
  const app = window.__MoonBit__;
  if (app?.core?.invokeOp) {
    canvasApi = createCanvas(document.getElementById("stage"));
    bindCanvasEvents(canvasApi);
    installResizeObserver();
    bindEvents();
    setupMenubar();
    setupViewSync();
    initVideoController();
    const initial = pickInitialFolder();
    els.folderInput.value = initial;
    listImages(initial);
    return;
  }
  if (attempt > 200) {
    showEmptyHint("Proton bridge 加载超时");
    return;
  }
  setTimeout(() => waitForBridge(attempt + 1), 50);
}

function initVideoController() {
  // Synchronous import: video.js has no main.js dependencies (deps are
  // passed in). We must initialize before the first listImages result
  // arrives, because the first list response can immediately select
  // the first video when there are no images.
  videoController = createVideoController({
    invokeLabeler,
    getState,
    setState,
    renderAnnotations,
    showEmptyHint,
    flashHint,
    setTimelineVisible,
    updateFrameReadout,
    markLabeled,
    onFrameLoaded, // rebind layout for video frames
    canvasApi,
  });
  window.__videoController = videoController;
}

///| Hook for video mode: re-apply the image-frame aspect ratio and
/// notify the canvas overlay when a freshly-decoded frame is ready.
/// Mirrors `onImageLoad` but takes dimensions from the caller since
/// the <img> onload may fire after we've moved on.
function onFrameLoaded(natural) {
  applyFrameLoaded(natural, {
    imageFrame: els.imageFrame,
    imageBox: els.imageBox,
    onLayout: (n) => {
      state.imgNatural = n;
      layoutCanvas();
    },
  });
}

waitForBridge();

// Tell the lazy-images module to use the sidebar's file-list as the
// scroll root. Without this, the IntersectionObserver defaults to the
// window viewport and fires for far more items than are visually
// relevant — in particular it fired 48 entries on a 1280x800 window
// when the sidebar can only show ~10 at a time, which caused
// 48 simultaneous file:// fetches that serialized at 6/frame.
LazyImages.setRoot(els.fileList);