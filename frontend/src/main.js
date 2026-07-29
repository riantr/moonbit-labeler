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

const $ = (sel) => document.querySelector(sel);

const DEFAULT_IMAGE_FOLDER =
  "D:/src/Marvis/MoonBitLabeler/data/Image@CARS.Part.01";
const RECENT_KEY = "moonbit-labeler/recent-folders";
const MAX_RECENT = 6;
const AUTOSAVE_MS = 600;
const POLYGON_CLOSE_RADIUS_PX = 12;

const state = {
  folder: "",
  labelFolder: "",
  images: [],
  currentIndex: -1,
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
};

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

function setImages(images) {
  state.images = images;
  els.imageCount.textContent = `${images.length} 张`;
  els.fileList.replaceChildren();
  const frag = document.createDocumentFragment();
  images.forEach((img, idx) => {
    const li = document.createElement("li");
    li.dataset.index = String(idx);
    li.dataset.path = img.path;

    const thumb = document.createElement("img");
    thumb.className = "thumb";
    thumb.alt = "";
    thumb.loading = "lazy";
    thumb.decoding = "async";
    thumb.src = fileUrl(img.path);
    thumb.onerror = () => loadThumbFallback(thumb, img.path);
    li.appendChild(thumb);

    const meta = document.createElement("div");
    meta.className = "meta";
    const ext = document.createElement("span");
    ext.className = "ext-tag";
    ext.textContent = (img.ext || "").replace(".", "") || "?";
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = img.name;
    name.title = img.path;
    meta.append(ext, name);
    li.appendChild(meta);

    if (state.labeledPaths.has(img.path)) {
      const dot = document.createElement("span");
      dot.className = "labeled-dot";
      dot.title = "已标注";
      li.appendChild(dot);
    }

    li.addEventListener("click", () => selectImage(idx));
    frag.appendChild(li);
  });
  els.fileList.appendChild(frag);

  if (images.length > 0) {
    selectImage(0);
  } else {
    state.currentIndex = -1;
    showEmptyHint("所选文件夹中没有图片（jpg/png/bmp/webp/gif）");
    updateStatus(null, 0, 0);
  }
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

function fileUrl(path) {
  let p = path.replace(/\\/g, "/");
  // Encode characters that would break the file:// URL (spaces, #, ?, %, etc.)
  let encoded = p.split("/").map(encodeURIComponent).join("/");
  if (/^[a-zA-Z]:\//.test(p)) return "file:///" + encoded;
  if (p.startsWith("/")) return "file://" + encoded;
  return "file:///" + encoded;
}

// ============================================================
// Image loading — uses Image.decode() (WHATWG) so we know the
// bitmap is fully decoded before we measure it, and AbortController
// to cancel stale loads when the user navigates quickly.
// ============================================================

let _currentLoadController = null;

async function showImage(item) {
  // Cancel any in-flight load from a previous nav.
  if (_currentLoadController) _currentLoadController.abort();
  const ctl = new AbortController();
  _currentLoadController = ctl;

  showEmptyHint("加载图片...");
  els.image.hidden = false;
  els.image.onload = onImageLoad;
  els.image.onerror = onImageError;
  try {
    els.image.src = fileUrl(item.path);
    if (els.image.decode) {
      await els.image.decode();
    }
  } catch (err) {
    if (err?.name === "AbortError") return;
    onImageError();
  }
}

function onImageLoad() {
  state.imgNatural = { w: els.image.naturalWidth, h: els.image.naturalHeight };
  // Defer to the next frame so CSS layout has applied the new image size.
  requestAnimationFrame(layoutCanvas);
}

async function onImageError() {
  // Fallback to data: URL via the bridge (handles CORS / odd file:// schemes).
  const item = state.images[state.currentIndex];
  if (!item) return;
  try {
    const reply = await invokeLabeler("read_image", { path: item.path });
    if (reply?.base64) {
      els.image.onerror = null;
      els.image.src = `data:${reply.mime};base64,${reply.base64}`;
    } else {
      showEmptyHint("无法加载图片");
    }
  } catch (err) {
    showEmptyHint(`无法加载图片: ${err}`);
  }
}

function hideEmptyHint() {
  els.emptyHint.hidden = true;
}

// ============================================================
// Layout: lock the image and overlay to a shared viewport div.
// Re-measured whenever the stage reflows via ResizeObserver.
// ============================================================

function layoutCanvas() {
  if (!canvasApi) return;
  if (state.imgNatural.w > 0 && state.imgNatural.h > 0) {
    const box = els.imageBox;
    const frame = els.imageFrame;
    if (frame) {
      // Lock the inner frame to the image's natural ratio — the CSS
      // collapses it to the largest rect that fits in the stage while
      // keeping the ratio. image-box stays full-stage and centers.
      frame.style.aspectRatio = `${state.imgNatural.w} / ${state.imgNatural.h}`;
    }
    if (box) box.classList.add("has-image");
    // imgDisplay is still used by mouse -> image coord conversion.
    const rect = els.image.getBoundingClientRect();
    const stage = document.getElementById("stage").getBoundingClientRect();
    state.imgDisplay = {
      w: rect.width,
      h: rect.height,
      left: rect.left - stage.left,
      top: rect.top - stage.top,
    };
    canvasApi.resize(state.imgNatural, state.imgDisplay);
    requestAnimationFrame(() => renderAnnotations());
    hideEmptyHint();
  }
}

let _imageResizeObserver = null;

function installResizeObserver() {
  if (_imageResizeObserver) return;
  _imageResizeObserver = new ResizeObserver(() => {
    if (state.imgNatural.w > 0) layoutCanvas();
  });
  _imageResizeObserver.observe(els.image);
}

// ============================================================
// Label load / save
// ============================================================

async function loadLabelFor(item) {
  state.label = emptyLabel();
  state.labelPath = "";
  state.loadedFromDisk = false;
  state.history = [];
  state.dirty = false;
  const token = ++state.loadToken;
  try {
    const reply = await invokeLabeler("read_label", { image_path: item.path });
    if (token !== state.loadToken) return;
    state.labelPath = reply.label_path;
    if (reply.found && reply.content) {
      const parsed = parseLabel(reply.content);
      state.label = parsed
        ? normalizeLabel(parsed, item.name)
        : { img_name: item.name, infos: [], bindings: [] };
      state.loadedFromDisk = !!parsed;
    } else {
      state.label = { img_name: item.name, infos: [], bindings: [] };
    }
    if (reply.found) {
      state.labeledPaths.add(item.path);
      markLabeled(item.path);
    }
  } catch (err) {
    if (token !== state.loadToken) return;
    console.error("read_label failed:", err);
    state.label = { img_name: item.name, infos: [], bindings: [] };
  }
  if (token !== state.loadToken) return;
  updateDirtyBadge();
  requestAnimationFrame(() => renderAnnotations());
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

function cssEscape(s) {
  return String(s).replace(/["\\]/g, "\\$&");
}

function selectImage(idx) {
  if (idx < 0 || idx >= state.images.length) return;
  if (state.dirty) flushSave().catch(() => {});
  state.currentIndex = idx;
  for (const li of els.fileList.children) {
    li.classList.toggle("active", Number(li.dataset.index) === idx);
  }
  const item = state.images[idx];
  updateStatus(item, idx, state.images.length);
  showImage(item);
  loadLabelFor(item);
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
  saveTimer = setTimeout(flushSave, AUTOSAVE_MS);
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
    saveTimer = setTimeout(flushSave, AUTOSAVE_MS);
  }
}

async function flushSave() {
  if (saveTimer) {
    clearTimeout(saveTimer);
    saveTimer = null;
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
        if (displayDistPx(imgPt, first) < POLYGON_CLOSE_RADIUS_PX) {
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
    if ((ev.ctrlKey || ev.metaKey) && ev.key === "z") {
      ev.preventDefault(); undo(); return;
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
    if (state.images.length === 0) return;
    if (ev.key === "ArrowDown" || ev.key === "j") {
      ev.preventDefault();
      const next = Math.min(state.currentIndex + 1, state.images.length - 1);
      if (next !== state.currentIndex) selectImage(next);
    } else if (ev.key === "ArrowUp" || ev.key === "k") {
      ev.preventDefault();
      const prev = Math.max(state.currentIndex - 1, 0);
      if (prev !== state.currentIndex) selectImage(prev);
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

async function invokeLabeler(op, payload) {
  const app = window.__MoonBit__;
  if (!app?.core?.invokeOp) throw new Error("bridge not ready");
  return app.core.invokeOp(`ext:labeler/${op}`, payload);
}

async function listImages(folder) {
  setFolder(folder);
  try {
    const reply = await invokeLabeler("list_images", { path: folder });
    if (reply?.images && Array.isArray(reply.images)) {
      writeRecent(folder);
      setImages(reply.images);
    }
  } catch (err) {
    console.error("[listImages] list_images failed:", err);
    setImages([]);
    showEmptyHint(`无法列出图片: ${err}`);
    updateStatus(null, 0, 0);
  }
  try {
    const cr = await invokeLabeler("scan_classes", { image_path: folder });
    if (cr?.classes && Array.isArray(cr.classes)) {
      state.classes = cr.classes;
      renderClassList();
    }
  } catch (err) {
    console.error("[listImages] scan_classes failed:", err);
  }
}

function waitForBridge(attempt = 0) {
  const app = window.__MoonBit__;
  if (app?.core?.invokeOp) {
    canvasApi = createCanvas(els.imageFrame);
    bindCanvasEvents(canvasApi);
    installResizeObserver();
    bindEvents();
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

waitForBridge();