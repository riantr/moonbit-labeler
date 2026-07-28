// MoonBit Labeler — frontend (Step 4 + 5 + 6)
//
// Layers:
//   1. label.js — schema parser/normalizer/serializer for the annotation JSON
//   2. canvas.js — SVG overlay + mouse handling for the four shapes
//   3. main.js  — bootstrap, state, IPC, autosave, UI glue
//
// IPC ops:
//   ext:labeler/list_images  - list images in a folder
//   ext:labeler/read_image   - read image bytes (base64 fallback)
//   ext:labeler/read_label   - load label JSON for an image
//   ext:labeler/write_label  - save label JSON for an image
//
// Annotation shapes: rect / polygon / keypoint / binding
// Bindings reference two annotations by id; geometry is computed live.

import { parseLabel, normalizeLabel, serializeLabel, emptyLabel, inferShape } from "./label.js";
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
  mode: "select", // 'select' | 'rect' | 'polygon' | 'keypoint' | 'binding'
  classType: "object",
  selectedId: null,
  draftPoints: [], // for polygon/keypoint: [[x,y], ...] in image coords
  bindingFromId: null, // for binding mode: first picked obj id
  // Persistent class list (scanned from label dir on folder load)
  classes: [], // [{ name, count }] sorted by count desc
  classIndex: -1, // currently active index in `classes`, or -1 if custom
  // UI
  dirty: false,
  saving: false,
  saveError: null,
  history: [], // simple undo stack: snapshots of `label`
  // Image mapping
  imgNatural: { w: 0, h: 0 },
  imgDisplay: { w: 0, h: 0 },
  // Per-folder label cache (Set of paths we know have a label file)
  labeledPaths: new Set(),
  // Monotonic counter incremented on each selectImage(); used to discard
  // stale async replies from a previous image.
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

function loadRecent() {
  try {
    const raw = localStorage.getItem(RECENT_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((s) => typeof s === "string") : [];
  } catch {
    return [];
  }
}

function saveRecent(folder) {
  try {
    const list = loadRecent();
    const filtered = list.filter((s) => s !== folder);
    filtered.unshift(folder);
    localStorage.setItem(RECENT_KEY, JSON.stringify(filtered.slice(0, MAX_RECENT)));
  } catch (err) {
    // localStorage is blocked under proton://app/ (opaque origin); fall back
    // to an in-memory list so the input still gets pre-filled next launch.
    if (!state._memRecent) state._memRecent = [];
    const list = state._memRecent;
    const filtered = list.filter((s) => s !== folder);
    filtered.unshift(folder);
    state._memRecent = filtered.slice(0, MAX_RECENT);
  }
}

function detectLabelFolder(imageFolder) {
  const norm = imageFolder.replace(/[\\/]+$/, "");
  const lastSlash = Math.max(
    norm.lastIndexOf("/"),
    norm.lastIndexOf("\\"),
  );
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
  // Hash a class string into a deterministic pastel hue.
  let hash = 0;
  for (let i = 0; i < type.length; i++) {
    hash = (hash * 31 + type.charCodeAt(i)) | 0;
  }
  const hue = ((hash % 360) + 360) % 360;
  return `hsl(${hue} 70% 55%)`;
}

function setImages(images) {
  state.images = images;
  els.imageCount.textContent = `${images.length} 张`;
  els.fileList.innerHTML = "";
  console.log("[setImages] rendering", images.length, "files");
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
    thumb.onerror = async () => {
      try {
        const reply = await invokeLabeler("read_image", { path: img.path });
        if (reply && reply.base64) {
          thumb.onerror = null;
          thumb.src = `data:${reply.mime};base64,${reply.base64}`;
        }
      } catch {}
    };
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
    meta.appendChild(ext);
    meta.appendChild(name);
    li.appendChild(meta);

    if (state.labeledPaths && state.labeledPaths.has(img.path)) {
      const dot = document.createElement("span");
      dot.className = "labeled-dot";
      dot.title = "已标注";
      li.appendChild(dot);
    }

    li.addEventListener("click", () => selectImage(idx));
    els.fileList.appendChild(li);
  });
  if (images.length > 0) {
    selectImage(0);
  } else {
    state.currentIndex = -1;
    showEmptyHint("所选文件夹中没有图片（jpg/png/bmp/webp/gif）");
    updateStatus(null, 0, 0);
  }
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
  // Encode characters that would break the file:// URL (spaces, #, ?, %, etc.).
  // Don't touch the slashes or the drive-letter colon.
  let encoded = p.split("/").map(encodeURIComponent).join("/");
  if (/^[a-zA-Z]:\//.test(p)) return "file:///" + encoded;
  if (p.startsWith("/")) return "file://" + encoded;
  return "file:///" + encoded;
}

// ============================================================================
// Image loading + label load/save
// ============================================================================

async function showImage(item) {
  showEmptyHint("加载图片...");
  els.image.hidden = false;
  els.image.onload = () => {
    state.imgNatural = { w: els.image.naturalWidth, h: els.image.naturalHeight };
    requestAnimationFrame(() => {
      const rect = els.image.getBoundingClientRect();
      const stage = document.getElementById("stage").getBoundingClientRect();
      state.imgDisplay = { w: rect.width, h: rect.height, left: rect.left - stage.left, top: rect.top - stage.top };
      canvasApi.resize(state.imgNatural, state.imgDisplay);
      renderAnnotations();
      hideEmptyHint();
    });
  };
  els.image.onerror = async () => {
    try {
      const reply = await invokeLabeler("read_image", { path: item.path });
      if (reply && reply.base64) {
        // Clear the error handler so a failed data: URL doesn't loop back
        // into read_image again. The existing onload already handles the
        // decode + render.
        els.image.onerror = null;
        els.image.src = `data:${reply.mime};base64,${reply.base64}`;
      } else {
        showEmptyHint("无法加载图片");
      }
    } catch (err) {
      showEmptyHint(`无法加载图片: ${err}`);
    }
  };
  els.image.src = fileUrl(item.path);
}

function hideEmptyHint() {
  els.emptyHint.hidden = true;
}

async function loadLabelFor(item) {
  state.label = emptyLabel();
  state.labelPath = "";
  state.loadedFromDisk = false;
  state.history = [];
  state.dirty = false;
  // Capture the load token so a stale reply (from a previous navigation)
  // can't overwrite the latest image's state.
  const token = ++state.loadToken;
  try {
    const reply = await invokeLabeler("read_label", { image_path: item.path });
    if (token !== state.loadToken) return;
    state.labelPath = reply.label_path;
    if (reply.found && reply.content) {
      const parsed = parseLabel(reply.content);
      if (parsed) {
        state.label = normalizeLabel(parsed, item.name);
        state.loadedFromDisk = true;
      } else {
        state.label = { img_name: item.name, infos: [], bindings: [] };
      }
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
  renderAnnotations();
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
  if (state.dirty) {
    flushSave().catch(() => {});
  }
  state.currentIndex = idx;
  Array.from(els.fileList.children).forEach((li) => {
    li.classList.toggle("active", Number(li.dataset.index) === idx);
  });
  const item = state.images[idx];
  updateStatus(item, idx, state.images.length);
  showImage(item);
  loadLabelFor(item);
}

// ============================================================================
// Annotation CRUD + autosave
// ============================================================================

let saveTimer = null;

function pushHistory() {
  state.history.push(JSON.stringify(state.label));
  if (state.history.length > 50) state.history.shift();
}

function markDirty() {
  state.dirty = true;
  updateDirtyBadge();
  renderAnnotations();
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(flushSave, AUTOSAVE_MS);
}

function undo() {
  if (state.history.length === 0) return;
  const prev = state.history.pop();
  try {
    state.label = JSON.parse(prev);
    // Cheaper than markDirty() (no immediate save) but still keeps the
    // state in sync: trigger the autosave timer so the next idle point
    // writes the change out.
    state.dirty = true;
    updateDirtyBadge();
    renderAnnotations();
    updateDeleteBtn();
    if (state.labelPath) {
      if (saveTimer) clearTimeout(saveTimer);
      saveTimer = setTimeout(flushSave, AUTOSAVE_MS);
    }
  } catch {}
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

// ============================================================================
// Annotation rendering
// ============================================================================

let canvasApi = null;

function renderAnnotations() {
  if (!canvasApi) return;
  canvasApi.render({
    label: state.label,
    mode: state.mode,
    selectedId: state.selectedId,
    draftPoints: state.draftPoints,
    bindingFromId: state.bindingFromId,
    colorForType,
  });
}

// ============================================================================
// Toolbar + mode handling
// ============================================================================

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
  stage.style.cursor =
    state.mode === "select" ? "default"
      : state.mode === "binding" ? "crosshair"
      : "crosshair";
}

function hitTestAnnotation(x, y) {
  // Returns the topmost annotation under (x, y) in image coords.
  // bindings are tested by their line distance.
  const tol = 8 / state.imgNatural.w * Math.max(state.imgNatural.w, state.imgNatural.h);
  // Bindings first so they win over their endpoints.
  for (let i = state.label.bindings.length - 1; i >= 0; i--) {
    const b = state.label.bindings[i];
    const a = findObjById(state.label.infos, b.from);
    const c = findObjById(state.label.infos, b.to);
    if (!a || !c) continue;
    const pa = centroid(a);
    const pc = centroid(c);
    const d = pointToSegmentDistance(x, y, pa, pc);
    if (d <= tol) return { kind: "binding", id: b.id };
  }
  for (let i = state.label.infos.length - 1; i >= 0; i--) {
    const a = state.label.infos[i];
    if (pointInAnnotation(x, y, a, tol)) return { kind: "info", id: a.id };
  }
  return null;
}

function findObjById(infos, id) {
  return infos.find((a) => a.id === id) || null;
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
  // polygon: point-in-polygon
  let inside = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i];
    const [xj, yj] = pts[j];
    const intersect = ((yi > y) !== (yj > y)) && (x < ((xj - xi) * (y - yi)) / (yj - yi) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}

function pointToSegmentDistance(px, py, a, b) {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
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

// ============================================================================
// Mouse handlers (image-coord dispatch)
// ============================================================================

function imageCoordsFromEvent(ev) {
  // ev is a mouse event on the SVG overlay.
  const rect = els.image.getBoundingClientRect();
  const stageRect = document.getElementById("stage").getBoundingClientRect();
  const dx = ev.clientX - rect.left;
  const dy = ev.clientY - rect.top;
  const rx = dx / rect.width;
  const ry = dy / rect.height;
  return [rx * state.imgNatural.w, ry * state.imgNatural.h];
}

function bindCanvasEvents(api) {
  api.onMouseDown((ev, imgPt) => {
    if (!imgPt) return;
    if (state.mode === "rect") {
      state.draftPoints = [imgPt, imgPt];
    }
  });
  api.onMouseMove((ev, imgPt) => {
    if (!imgPt) return;
    if (state.mode === "rect" && state.draftPoints.length === 2) {
      state.draftPoints[1] = imgPt;
      renderAnnotations();
    }
  });
  api.onMouseUp((ev, imgPt) => {
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
  api.onClick((ev, imgPt) => {
    if (!imgPt) return;
    const hit = hitTestAnnotation(imgPt[0], imgPt[1]);
    if (state.mode === "select") {
      state.selectedId = hit ? hit.id : null;
      renderAnnotations();
      updateDeleteBtn();
      return;
    }
    if (state.mode === "polygon") {
      // Click near first point -> close
      if (state.draftPoints.length >= 3) {
        const first = state.draftPoints[0];
        // Compare against display pixels (not image pixels) so the close
        // radius stays consistent regardless of zoom / image size.
        const close = displayDistPx(imgPt, first) < POLYGON_CLOSE_RADIUS_PX;
        if (close) { commitPolygon(); return; }
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
        // Same object -> cancel
        state.bindingFromId = null;
        renderAnnotations();
        return;
      }
      // Avoid duplicate binding
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
  api.onDblClick((ev, imgPt) => {
    if (state.mode === "polygon" && state.draftPoints.length >= 3) {
      commitPolygon();
    }
  });
}

function displayDist(a, b) {
  // Return image-coord distance normalized to image-width (unitless fraction).
  // Multiply by `state.imgDisplay.w` to get display pixels.
  if (!state.imgNatural.w) return 0;
  return Math.hypot(a[0] - b[0], a[1] - b[1]) / state.imgNatural.w;
}

function displayDistPx(a, b) {
  // True display-pixel distance (uses rendered image width).
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
  const before = state.label;
  const id = state.selectedId;
  const next = {
    img_name: before.img_name,
    infos: before.infos.filter((a) => a.id !== id),
    bindings: before.bindings.filter((b) => b.id !== id && b.from !== id && b.to !== id),
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

// ============================================================================
// Bootstrap
// ============================================================================

async function listImages(folder) {
  console.log("[listImages] called with:", folder);
  setFolder(folder);
  try {
    const reply = await invokeLabeler("list_images", { path: folder });
    console.log("[listImages] reply:", reply?.images?.length, "images");
    if (reply && Array.isArray(reply.images)) {
      saveRecent(folder);
      setImages(reply.images);
    }
  } catch (err) {
    console.error("[listImages] list_images failed:", err);
    setImages([]);
    showEmptyHint(`无法列出图片: ${err}`);
    updateStatus(null, 0, 0);
  }
  // Scan classes in the background — failures here shouldn't block folder
  // loading, the class list will just stay empty.
  try {
    console.log("[listImages] calling scan_classes...");
    const cr = await invokeLabeler("scan_classes", { image_path: folder });
    console.log("[listImages] scan_classes reply:", cr?.classes?.length, "classes");
    if (cr && Array.isArray(cr.classes)) {
      state.classes = cr.classes;
      renderClassList();
    }
  } catch (err) {
    console.error("[listImages] scan_classes failed:", err);
  }
}

function renderClassList() {
  if (!els.classList) return;
  els.classList.innerHTML = "";
  state.classes.forEach((cls, idx) => {
    const li = document.createElement("li");
    li.dataset.index = String(idx);
    li.dataset.name = cls.name;

    const key = document.createElement("span");
    key.className = "key";
    // Number keys 1-9 map to indexes 0-8; index 9 has no shortcut.
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
    els.classList.appendChild(li);
  });
  if (els.classCount) {
    els.classCount.textContent = `${state.classes.length} 个`;
  }
}

function selectClass(idx) {
  if (idx < 0 || idx >= state.classes.length) return;
  state.classIndex = idx;
  const cls = state.classes[idx];
  if (!cls) return;
  state.classType = cls.name;
  if (els.classInput) {
    els.classInput.value = cls.name;
    // mirror to toolbar input so the user sees what's selected
    els.classInput.dataset.fromList = "1";
  }
  // Update visual selection without re-rendering the whole list.
  els.classList.querySelectorAll("li").forEach((li, i) => {
    li.classList.toggle("active", i === idx);
  });
}

function pickInitialFolder() {
  const recent = loadRecent();
  return recent.length > 0 ? recent[0] : DEFAULT_IMAGE_FOLDER;
}

function bindToolbar() {
  for (const btn of document.querySelectorAll(".mode-btn")) {
    btn.addEventListener("click", () => setMode(btn.dataset.mode));
  }
  els.classInput.addEventListener("input", () => {
    const v = els.classInput.value.trim() || "object";
    state.classType = v;
    // If the typed value matches a known class, also mark it as the
    // active one; otherwise clear the active selection.
    const idx = state.classes.findIndex((c) => c.name === v);
    if (idx !== state.classIndex) {
      state.classIndex = idx;
      els.classList.querySelectorAll("li").forEach((li, i) => {
        li.classList.toggle("active", i === idx);
      });
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
    if (reply && reply.path) {
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
    const inField = active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA");
    if (inField) return;
    if ((ev.ctrlKey || ev.metaKey) && ev.key === "z") { ev.preventDefault(); undo(); return; }
    if (ev.key === "Delete" || ev.key === "Backspace") { ev.preventDefault(); deleteSelected(); return; }
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
    // Mode shortcuts
    const m = { v: "select", r: "rect", p: "polygon", k: "keypoint", b: "binding" };
    if (m[ev.key.toLowerCase()]) setMode(m[ev.key.toLowerCase()]);

    // Class shortcuts 1-9: select Nth class in the scanned list.
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

async function invokeLabeler(op, payload) {
  const app = window.__MoonBit__;
  if (!app || !app.core || !app.core.invokeOp) throw new Error("bridge not ready");
  return app.core.invokeOp(`ext:labeler/${op}`, payload);
}

function waitForBridge(attempt = 0) {
  const app = window.__MoonBit__;
  if (app && app.core && app.core.invokeOp) {
    canvasApi = createCanvas(document.getElementById("stage"));
    bindCanvasEvents(canvasApi);
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