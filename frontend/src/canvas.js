// canvas.js — Canvas 2D overlay with two-layer compositing.
//
// Why Canvas 2D instead of SVG?
//   - The old SVG implementation called `clearChildren()` on every render
//     and re-created dozens of <path>/<text> nodes. With CARS images
//     carrying 30+ annotations this thrashes the DOM and is the main
//     source of the lag observed while drawing / dragging.
//   - Canvas 2D gives us hardware-accelerated raster output (Chromium
//     uses GPU compositing for 2D canvas) and we only pay the per-pixel
//     cost on the static layer once per image load.
//
// Two layers, each an OffscreenCanvas-style backing store that we render
// to a <canvas> at display time:
//   - static layer: the saved annotations (infos + bindings). Painted
//     only when the underlying label changes (load / undo / new shape
//     committed / delete).
//   - dynamic layer: draft polygon in progress, hover hint, selection
//     ring, the binding "first-pick" indicator. Painted every frame
//     during interaction, then composited on top of the static layer.
//
// Both layers share the same backing bitmap; the dynamic layer is
// cleared with clearRect and redrawn cheaply. We use the same drawing
// primitives in both, so they always look identical.
//
// All coordinates are in image natural pixels; we apply a single
// ctx.setTransform(sx, 0, 0, sy, 0, 0) per draw so callers can pass
// natural coords and ignore display size.
//
// Public API matches the previous createCanvas(stage) shape so main.js
// needs minimal changes:
//   { element, resize(natural, display), render(state),
//     onMouseDown/Move/Up/Click/DblClick(fn) }

export function createCanvas(container) {
  // Use a single full-size canvas, but expose two offscreen "layers" as
  // ImageBitmaps that we composite. This is closer to the C# Graphics
  // model (Bitmap backbuffer) and gives us the cleanest perf: one
  // drawImage per layer to the visible canvas.
  const canvas = document.createElement("canvas");
  canvas.classList.add("annotation-overlay");
  // canvas takes the size of its CSS-sized parent (image-box).
  canvas.style.position = "absolute";
  canvas.style.left = "0";
  canvas.style.top = "0";
  canvas.style.width = "100%";
  canvas.style.height = "100%";
  canvas.style.pointerEvents = "auto";

  const ctx = canvas.getContext("2d", { alpha: true, desynchronized: true });

  // Offscreen buffers (one per layer). The backing bitmaps are in image
  // natural pixel space; we rescale on composite. This keeps draw code
  // in natural coords and avoids floating-point drift on every redraw.
  const layerStatic = document.createElement("canvas");
  const layerDynamic = document.createElement("canvas");
  const staticCtx = layerStatic.getContext("2d", { alpha: true });
  const dynamicCtx = layerDynamic.getContext("2d", { alpha: true });

  // Transform: image natural (w, h) -> on-screen CSS pixels (dw, dh).
  // Recomputed on every resize().
  let natural = { w: 0, h: 0 };
  let display = { w: 0, h: 0, dpr: window.devicePixelRatio || 1 };

  function applyDpr(c, w, h) {
    // Use device-pixel backing for crisp rendering on HiDPI.
    const dpr = display.dpr;
    if (c.canvas.width !== Math.round(w * dpr) ||
        c.canvas.height !== Math.round(h * dpr)) {
      c.canvas.width = Math.round(w * dpr);
      c.canvas.height = Math.round(h * dpr);
    }
  }

  const handlers = {
    mousedown: null, mousemove: null, mouseup: null,
    click: null, dblclick: null,
  };

  // Map a mouse event to image natural coords.
  // canvas fills image-box 100%; rect.left/top is the canvas's viewport
  // position (== image-box's position), so we just divide.
  function mouseToImg(ev) {
    if (display.w === 0) return null;
    const rect = canvas.getBoundingClientRect();
    if (rect.width === 0) return null;
    const rx = (ev.clientX - rect.left) / rect.width;
    const ry = (ev.clientY - rect.top) / rect.height;
    return [rx * natural.w, ry * natural.h];
  }

  function bindEvents() {
    canvas.addEventListener("mousedown", (ev) => {
      if (handlers.mousedown) handlers.mousedown(ev, mouseToImg(ev));
    });
    canvas.addEventListener("mousemove", (ev) => {
      if (handlers.mousemove) handlers.mousemove(ev, mouseToImg(ev));
    });
    canvas.addEventListener("mouseup", (ev) => {
      if (handlers.mouseup) handlers.mouseup(ev, mouseToImg(ev));
    });
    canvas.addEventListener("click", (ev) => {
      if (handlers.click) handlers.click(ev, mouseToImg(ev));
    });
    canvas.addEventListener("dblclick", (ev) => {
      if (handlers.dblclick) handlers.dblclick(ev, mouseToImg(ev));
    });
  }
  bindEvents();

  // ============================================================
  // Drawing primitives — all in IMAGE NATURAL coords.
  // The caller calls setTransform so that natural -> bitmap.
  // ============================================================

  function fillPolyPath(c, points) {
    if (points.length < 2) return;
    c.beginPath();
    c.moveTo(points[0][0], points[0][1]);
    for (let i = 1; i < points.length; i++) {
      c.lineTo(points[i][0], points[i][1]);
    }
    c.closePath();
  }

  function drawPolygonShape(c, points, color, fillOpacity, isSelected) {
    if (points.length < 2) return;
    fillPolyPath(c, points);
    c.fillStyle = color;
    c.globalAlpha = fillOpacity;
    c.fill();
    c.globalAlpha = 1;
    c.lineWidth = isSelected ? 3 : 2;
    c.strokeStyle = color;
    c.lineJoin = "round";
    c.stroke();
    // vertex dots (skip for very dense polygons to keep it cheap)
    if (points.length <= 30) {
      c.fillStyle = color;
      c.strokeStyle = "rgba(255,255,255,0.9)";
      c.lineWidth = 1;
      for (const [x, y] of points) {
        c.beginPath();
        c.arc(x, y, isSelected ? 4 : 3, 0, Math.PI * 2);
        c.fill();
        c.stroke();
      }
    }
  }

  function drawRectShape(c, points, color, fillOpacity, isSelected) {
    if (points.length < 2) return;
    const x1 = Math.min(points[0][0], points[1][0]);
    const y1 = Math.min(points[0][1], points[1][1]);
    const w = Math.abs(points[1][0] - points[0][0]);
    const h = Math.abs(points[1][1] - points[0][1]);
    c.fillStyle = color;
    c.globalAlpha = fillOpacity;
    c.fillRect(x1, y1, w, h);
    c.globalAlpha = 1;
    c.lineWidth = isSelected ? 3 : 2;
    c.strokeStyle = color;
    c.strokeRect(x1, y1, w, h);
  }

  function drawKeypointShape(c, points, color, isSelected) {
    for (const [x, y] of points) {
      c.beginPath();
      c.arc(x, y, isSelected ? 8 : 6, 0, Math.PI * 2);
      c.fillStyle = color;
      c.fill();
      c.lineWidth = 2;
      c.strokeStyle = "#ffffff";
      c.stroke();
    }
  }

  function drawBindingShape(c, a, b, isSelected) {
    if (!a || !b) return;
    const pa = centroid(a);
    const pc = centroid(b);
    c.beginPath();
    c.moveTo(pa[0], pa[1]);
    c.lineTo(pc[0], pc[1]);
    c.lineWidth = isSelected ? 3 : 1.5;
    c.strokeStyle = "#fbbf24";
    c.setLineDash([6, 4]);
    c.stroke();
    c.setLineDash([]);
  }

  function drawDraftPolygon(c, points, color) {
    if (points.length === 0) return;
    if (points.length >= 3) {
      fillPolyPath(c, points);
      c.fillStyle = color;
      c.globalAlpha = 0.15;
      c.fill();
      c.globalAlpha = 1;
    }
    c.beginPath();
    c.moveTo(points[0][0], points[0][1]);
    for (let i = 1; i < points.length; i++) c.lineTo(points[i][0], points[i][1]);
    c.lineWidth = 2;
    c.strokeStyle = color;
    c.setLineDash([4, 3]);
    c.stroke();
    c.setLineDash([]);
    c.fillStyle = color;
    c.strokeStyle = "rgba(255,255,255,0.9)";
    c.lineWidth = 1.5;
    for (const [x, y] of points) {
      c.beginPath();
      c.arc(x, y, 4, 0, Math.PI * 2);
      c.fill();
      c.stroke();
    }
  }

  function drawDraftRect(c, points, color) {
    if (points.length < 2) return;
    const x1 = Math.min(points[0][0], points[1][0]);
    const y1 = Math.min(points[0][1], points[1][1]);
    const w = Math.abs(points[1][0] - points[0][0]);
    const h = Math.abs(points[1][1] - points[0][1]);
    c.fillStyle = color;
    c.globalAlpha = 0.15;
    c.fillRect(x1, y1, w, h);
    c.globalAlpha = 1;
    c.lineWidth = 2;
    c.strokeStyle = color;
    c.setLineDash([4, 3]);
    c.strokeRect(x1, y1, w, h);
    c.setLineDash([]);
  }

  function drawLabelText(c, cx, cy, text, color) {
    c.font = "12px system-ui, sans-serif";
    c.textAlign = "center";
    c.textBaseline = "alphabetic";
    c.lineWidth = 3;
    c.strokeStyle = "rgba(0,0,0,0.55)";
    c.strokeText(text, cx, cy - 8);
    c.fillStyle = color;
    c.fillText(text, cx, cy - 8);
  }

  function centroid(a) {
    const pts = a.points || [];
    if (pts.length === 0) return [0, 0];
    let sx = 0, sy = 0;
    for (const [x, y] of pts) { sx += x; sy += y; }
    return [sx / pts.length, sy / pts.length];
  }

  // ============================================================
  // Layer paint
  // ============================================================

  function paintStatic(state) {
    if (natural.w === 0) return;
    applyDpr(staticCtx, natural.w, natural.h);
    staticCtx.setTransform(display.dpr, 0, 0, display.dpr, 0, 0);
    staticCtx.clearRect(0, 0, natural.w, natural.h);
    const { label, selectedId, colorForType } = state;
    const byId = new Map();
    for (const a of label.infos) byId.set(a.id, a);
    for (const b of label.bindings) {
      const a = byId.get(b.from);
      const c = byId.get(b.to);
      if (!a || !c) continue;
      drawBindingShape(staticCtx, a, c, selectedId === b.id);
    }
    for (const a of label.infos) {
      const color = colorForType(a.type);
      const sel = selectedId === a.id;
      if (a.shape === "polygon") drawPolygonShape(staticCtx, a.points, color, 0.18, sel);
      else if (a.shape === "rect") drawRectShape(staticCtx, a.points, color, 0.12, sel);
      else if (a.shape === "keypoint") drawKeypointShape(staticCtx, a.points, color, sel);
      if (a.points && a.points.length > 0) {
        const [cx, cy] = centroid(a);
        drawLabelText(staticCtx, cx, cy, a.type, color);
      }
    }
  }

  function paintDynamic(state) {
    if (natural.w === 0) return;
    applyDpr(dynamicCtx, natural.w, natural.h);
    dynamicCtx.setTransform(display.dpr, 0, 0, display.dpr, 0, 0);
    dynamicCtx.clearRect(0, 0, natural.w, natural.h);
    const { mode, draftPoints, bindingFromId, selectedId, label, colorForType } = state;

    // binding first-pick indicator
    if (bindingFromId) {
      const a = label.infos.find((x) => x.id === bindingFromId);
      if (a) {
        const [cx, cy] = centroid(a);
        dynamicCtx.beginPath();
        dynamicCtx.arc(cx, cy, 10, 0, Math.PI * 2);
        dynamicCtx.lineWidth = 2;
        dynamicCtx.strokeStyle = "#fbbf24";
        dynamicCtx.stroke();
      }
    }

    if (mode === "rect" && draftPoints.length === 2) {
      drawDraftRect(dynamicCtx, draftPoints, colorForType("draft"));
    } else if (mode === "polygon" && draftPoints.length > 0) {
      drawDraftPolygon(dynamicCtx, draftPoints, colorForType("draft"));
    }
  }

  function composite() {
    if (natural.w === 0) return;
    applyDpr(ctx, display.w, display.h);
    ctx.setTransform(display.dpr, 0, 0, display.dpr, 0, 0);
    ctx.clearRect(0, 0, display.w, display.h);
    // drawImage resamples from natural->display in one cheap GPU op.
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(layerStatic, 0, 0, display.w, display.h);
    ctx.drawImage(layerDynamic, 0, 0, display.w, display.h);
  }

  // ============================================================
  // Public API
  // ============================================================

  let _lastStaticKey = null;
  // Cheap deep-equal key: when this changes we repaint the static layer,
  // otherwise we only repaint the dynamic layer (cheap, no allocations).
  function staticKey(label) {
    if (!label) return null;
    return [
      label.infos.length,
      label.bindings.length,
      label.infos.map((a) => a.id + ":" + (a.points?.length || 0)).join(","),
      label.bindings.map((b) => b.id + ":" + b.from + ":" + b.to).join(","),
      label.infos.map((a) => a.type).join(","),
    ].join("|");
  }

  container.appendChild(canvas);

  return {
    element: canvas,
    resize(newNatural, newDisplay) {
      natural = newNatural;
      display = {
        w: newDisplay.w,
        h: newDisplay.h,
        dpr: window.devicePixelRatio || 1,
      };
      // Invalidate static cache so a resize triggers a repaint (if we
      // ever add display-size-dependent rendering; currently we don't).
      _lastStaticKey = null;
    },
    render(state) {
      if (natural.w === 0) return;
      const k = staticKey(state.label);
      if (k !== _lastStaticKey) {
        paintStatic(state);
        _lastStaticKey = k;
      }
      paintDynamic(state);
      composite();
    },
    onMouseDown(fn) { handlers.mousedown = fn; },
    onMouseMove(fn) { handlers.mousemove = fn; },
    onMouseUp(fn) { handlers.mouseup = fn; },
    onClick(fn) { handlers.click = fn; },
    onDblClick(fn) { handlers.dblclick = fn; },
  };
}