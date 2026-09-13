// canvas.js — Canvas 2D overlay with two-layer compositing + pan/zoom transform.
//
// Why Canvas 2D instead of SVG?
//   - The old SVG implementation called `clearChildren()` on every render and
//     re-created dozens of <path>/<text> nodes. With CARS images carrying
//     30+ annotations this thrashes the DOM and is the main source of the
//     lag observed while drawing / dragging.
//   - Canvas 2D gives us hardware-accelerated raster output (Chromium uses
//     GPU compositing for 2D canvas) and we only pay the per-pixel cost on
//     the static layer once per image load.
//
// Two layers, each as an offscreen canvas, composited into a single visible
// <canvas> at display time. Coordinates inside draw calls are image-natural
// pixels; the view transform (pan + zoom) is applied via ctx.setTransform
// on the composite layer.
//
// View transform:
//   - identity  : drawImage resamples natural -> display exactly
//   - zoomed    : visible canvas shows a zoomed+panned subset of the image,
//                 static/dynamic layers paint the FULL natural bitmap and
//                 the transform crops+zooms them on composite.
//
// Public API:
//   createCanvas(container) -> {
//     element, resize(natural, display),
//     render(state), getView(), setView(view), resetView(),
//     fitView(), setZoom(z, centerNatural?), zoomBy(factor, screenPt?),
//     panBy(dx, dy),
//     onMouseDown/Move/Up/Click/DblClick(fn)
//   }
//
// Mouse interactions wired by main.js:
//   - left click / drag : shape drawing / hit-testing (existing)
//   - middle button     : pan (always)
//   - right button      : pan (always)
//   - space + left drag : pan (always)
//   - ctrl + wheel      : zoom (around mouse)
//   - wheel             : scroll page OR pan (browser default prevented)

export function createCanvas(container) {
  // ---------- DOM ----------
  const canvas = document.createElement("canvas");
  canvas.classList.add("annotation-overlay");
  Object.assign(canvas.style, {
    position: "absolute",
    left: "0",
    top: "0",
    width: "100%",
    height: "100%",
    pointerEvents: "auto",
    touchAction: "none", // we'll handle wheel/pinch ourselves
  });

  const ctx = canvas.getContext("2d", { alpha: true, desynchronized: true });

  const layerStatic = document.createElement("canvas");
  const layerDynamic = document.createElement("canvas");
  const staticCtx = layerStatic.getContext("2d", { alpha: true });
  const dynamicCtx = layerDynamic.getContext("2d", { alpha: true });

  // ---------- state ----------
  let natural = { w: 0, h: 0 };
  // `display` is the fitted image rect relative to the full stage. The
  // canvas itself covers the complete stage so black letterbox/pan areas are
  // part of the same viewport as the image.
  let display = { w: 0, h: 0, left: 0, top: 0, dpr: window.devicePixelRatio || 1 };
  let viewport = { w: 0, h: 0 };
  /** The <img> DOM element we rasterize into the static layer. Held by
   * reference so paintStatic can drawImage it once per image change,
   * then the composite layer resamples it under the view transform. */
  let _sourceImage = null;
  /** View transform. pan is in display pixels (CSS), zoom multiplies scale. */
  let view = { pan: { x: 0, y: 0 }, zoom: 1 };

  // Min/max zoom — clamp at sensible values.
  const ZOOM_MIN = 0.05;
  const ZOOM_MAX = 32;

  function applyDpr(c, w, h) {
    const dpr = display.dpr;
    if (c.canvas.width !== Math.round(w * dpr) ||
        c.canvas.height !== Math.round(h * dpr)) {
      c.canvas.width = Math.round(w * dpr);
      c.canvas.height = Math.round(h * dpr);
    }
  }

  // ---------- coordinate mapping ----------
  // After Fix A, the canvas is co-located with the <img>: its CSS
  // left/top/width/height mirror the image's screen rect, so
  // canvas.getBoundingClientRect() agrees with the <img>'s rect. The
  // canvas-local CSS px (the offset from the canvas's top-left) is
  // therefore the same as the image-local CSS px. Clicks on the
  // visible bitmap always land on the canvas, and there are no
  // "letterbox" zones that the canvas covers but the image doesn't.
  //
  // The annotation layers are stored in natural image pixels; the view
  // transform (`view.pan`, `view.zoom`) is applied externally by
  // main.js's `syncNativeImageView`, which sets the canvas's CSS
  // `left = display.left + view.pan.x` and `width = natural.w * zoom`.
  // `display.left/top` is the untransformed image origin in stage
  // CSS px (its position before any pan/zoom) — still used by
  // fitView/setZoom to compute the pan that keeps the image centered
  // in the stage. The canvas-local -> natural map is therefore just:
  //   natural = canvas_local / zoom
  function toNatural(sx, sy) {
    return [sx / view.zoom, sy / view.zoom];
  }
  function toScreen(nx, ny) {
    return [nx * view.zoom, ny * view.zoom];
  }

  // ---------- event forwarding ----------
  const handlers = {
    mousedown: null, mousemove: null, mouseup: null, mouseleave: null,
    click: null, dblclick: null, wheel: null,
  };

  function mouseToImg(ev) {
    if (display.w === 0) return null;
    // After Fix A, the canvas is co-located with the <img>: its
    // getBoundingClientRect() is the image's screen rect, so
    // (clientX - rect.left) is canvas-local CSS px. Divide by zoom
    // for natural pixels. (No `display.left` / `view.pan` math here —
    // the canvas's CSS left/top already bakes those in.)
    let rect = canvas.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) {
      // Fix B (defensive fallback): if the canvas's CSS hasn't been
      // positioned yet (e.g. before the first labeler:viewchange
      // event fires, or when the stage flex-collapses to 0 with
      // DevTools docked), the canvas's rect is degenerate. Fall back
      // to the <img> element's rect, which main.js positions via
      // syncNativeImageView and which is the source of truth.
      const img = document.getElementById("image");
      if (!img) return null;
      rect = img.getBoundingClientRect();
      if (rect.width === 0) return null;
    }
    const point = [
      (ev.clientX - rect.left) / view.zoom,
      (ev.clientY - rect.top) / view.zoom,
    ];
    // The canvas now exactly matches the image's rect, so this bounds
    // check is theoretically redundant — but it's cheap insurance
    // against any future refactor that lets the canvas's rect drift
    // from the image's rect.
    if (point[0] < 0 || point[1] < 0 || point[0] > natural.w || point[1] > natural.h) {
      return null;
    }
    return point;
  }

  // ---------- pan/zoom drag state ----------
  // We swallow mousedown for pan buttons (middle/right) and Space+Left and
  // panning — the shape-drawing logic only sees left-button without space.
  let _panActive = false;
  let _panStartX = 0;
  let _panStartY = 0;
  let _panStartViewPan = { x: 0, y: 0 };
  let _spaceDown = false;

  function bindEvents() {
    canvas.addEventListener("mousedown", (ev) => {
      const isMiddle = ev.button === 1;
      const isRight = ev.button === 2;
      const wantsPan = isMiddle || isRight || (_spaceDown && ev.button === 0);
      if (wantsPan) {
        _panActive = true;
        _panStartX = ev.clientX;
        _panStartY = ev.clientY;
        _panStartViewPan = { x: view.pan.x, y: view.pan.y };
        const stage = document.getElementById("stage");
        stage?.classList.add("cursor-grabbing");
        ev.preventDefault();
        return;
      }
      if (handlers.mousedown) handlers.mousedown(ev, mouseToImg(ev));
    });
    canvas.addEventListener("mousemove", (ev) => {
      if (_panActive) {
        const dx = ev.clientX - _panStartX;
        const dy = ev.clientY - _panStartY;
        view = {
          pan: {
            x: _panStartViewPan.x + dx,
            y: _panStartViewPan.y + dy,
          },
          zoom: view.zoom,
        };
        emitViewChange();
        return;
      }
      if (handlers.mousemove) handlers.mousemove(ev, mouseToImg(ev));
    });
    canvas.addEventListener("mouseup", (ev) => {
      if (_panActive) {
        _panActive = false;
        const stage = document.getElementById("stage");
        stage?.classList.remove("cursor-grabbing");
        return;
      }
      if (handlers.mouseup) handlers.mouseup(ev, mouseToImg(ev));
    });
    canvas.addEventListener("click", (ev) => {
      if (_panActive) return;
      if (handlers.click) handlers.click(ev, mouseToImg(ev));
    });
    canvas.addEventListener("dblclick", (ev) => {
      if (handlers.dblclick) handlers.dblclick(ev, mouseToImg(ev));
    });
    canvas.addEventListener("wheel", (ev) => {
      ev.preventDefault();
      if (ev.ctrlKey) {
        // Zoom around mouse position
        const rect = canvas.getBoundingClientRect();
        const sx = ev.clientX - rect.left;
        const sy = ev.clientY - rect.top;
        const factor = Math.exp(-ev.deltaY * 0.0015);
        const newZoom = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, view.zoom * factor));
        zoomAtScreenPoint(newZoom, sx, sy);
      } else {
        // Pan with scroll
        view = {
          pan: {
            x: view.pan.x - ev.deltaX,
            y: view.pan.y - ev.deltaY,
          },
          zoom: view.zoom,
        };
      }
      emitViewChange();
      if (handlers.wheel) handlers.wheel(ev, mouseToImg(ev));
    }, { passive: false });
    // Suppress browser context menu on right-click so we can use it for pan.
    canvas.addEventListener("contextmenu", (ev) => ev.preventDefault());
    // Mouse leave / enter: lets the host reset overlays like the
    // status-bar cursor readout. Fires only on the canvas element itself,
    // not on child elements.
    canvas.addEventListener("mouseleave", (ev) => {
      if (handlers.mouseleave) handlers.mouseleave(ev);
    });
  }

  /** Zoom to `z` keeping the natural point currently under (sx, sy) in place.
   *  After Fix A, (sx, sy) is canvas-local CSS px (the offset from the
   *  canvas's CSS top-left). The mouse's stage CSS position is
   *    (display.left + view.pan.x + sx, display.top + view.pan.y + sy)
   *  and we want the same stage position after the zoom, with the
   *  natural point's new canvas-local position being (nx*z, ny*z).
   *  Solving for the new view.pan:
   *    display.left + view.pan.x_new + nx*z = display.left + view.pan.x + sx
   *    view.pan.x_new = view.pan.x + sx - nx*z
   *  (The old formula `sx - display.left - nx*z` was correct in the
   *  pre-Fix-A model where the canvas covered the full stage and
   *  `(sx, sy)` was stage-local CSS px. Don't mix the two.) */
  function zoomAtScreenPoint(z, sx, sy) {
    const [nx, ny] = toNatural(sx, sy);
    view = {
      pan: {
        x: view.pan.x + sx - nx * z,
        y: view.pan.y + sy - ny * z,
      },
      zoom: z,
    };
  }

  // track Space hold for "pan mode"
  window.addEventListener("keydown", (ev) => {
    if (ev.code === "Space" && !ev.repeat) {
      const tag = ev.target?.tagName;
      if (tag !== "INPUT" && tag !== "TEXTAREA") {
        _spaceDown = true;
        const stage = document.getElementById("stage");
        stage?.classList.add("cursor-grab");
      }
    }
  });
  window.addEventListener("keyup", (ev) => {
    if (ev.code === "Space") {
      _spaceDown = false;
      const stage = document.getElementById("stage");
      stage?.classList.remove("cursor-grab");
    }
  });

  bindEvents();

  // ---------- drawing primitives — all in IMAGE NATURAL coords ----------
  // Note: these ignore view transform on purpose. The composite layer
  // applies the transform via drawImage resampling.
  function fillPolyPath(c, points) {
    if (points.length < 2) return;
    c.beginPath();
    c.moveTo(points[0][0], points[0][1]);
    for (let i = 1; i < points.length; i++) c.lineTo(points[i][0], points[i][1]);
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
    const x2 = Math.max(points[0][0], points[1][0]);
    const y2 = Math.max(points[0][1], points[1][1]);
    const w = x2 - x1;
    const h = y2 - y1;
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
  // Hit radius in image-natural px. Used both for handle drawing
  // size and for the same handle's hit region. 8 px in image
  // space — large enough that "在点附近" (hovering near a
  // vertex / corner) reliably lands a drag, but not so large
  // that the on-screen marker looks chunky on a 1000-px image
  // at default zoom. The draw radius matches the hit radius so
  // what the user sees is what they can grab.
  const HANDLE_R = 8;
  // Render the corner / edge / vertex handles of one selected
  // annotation. Only ever called from paintDynamic — handles are
  // expected to move with the annotation under the cursor, so we
  // can't keep them on the cached static layer.
  function drawHandles(c, a, color) {
    if (!a || !a.points || a.points.length === 0) return;
    c.save();
    c.fillStyle = "#ffffff";
    c.strokeStyle = color;
    c.lineWidth = 2;
    if (a.shape === "rect" && a.points.length >= 2) {
      const x1 = Math.min(a.points[0][0], a.points[1][0]);
      const x2 = Math.max(a.points[0][0], a.points[1][0]);
      const y1 = Math.min(a.points[0][1], a.points[1][1]);
      const y2 = Math.max(a.points[0][1], a.points[1][1]);
      const cx = (x1 + x2) / 2;
      const cy = (y1 + y2) / 2;
      const corners = [[x1, y1], [x2, y1], [x2, y2], [x1, y2]];
      for (const [x, y] of corners) {
        c.beginPath();
        c.arc(x, y, HANDLE_R, 0, Math.PI * 2);
        c.fill();
        c.stroke();
      }
      // 4 edge midpoints as small squares so they read as
      // resize-from-edge rather than another corner.
      const edges = [[cx, y1], [cx, y2], [x1, cy], [x2, cy]];
      c.fillRect(cx - HANDLE_R, y1 - HANDLE_R, HANDLE_R * 2, HANDLE_R * 2);
      c.strokeRect(cx - HANDLE_R, y1 - HANDLE_R, HANDLE_R * 2, HANDLE_R * 2);
      c.fillRect(cx - HANDLE_R, y2 - HANDLE_R, HANDLE_R * 2, HANDLE_R * 2);
      c.strokeRect(cx - HANDLE_R, y2 - HANDLE_R, HANDLE_R * 2, HANDLE_R * 2);
      c.fillRect(x1 - HANDLE_R, cy - HANDLE_R, HANDLE_R * 2, HANDLE_R * 2);
      c.strokeRect(x1 - HANDLE_R, cy - HANDLE_R, HANDLE_R * 2, HANDLE_R * 2);
      c.fillRect(x2 - HANDLE_R, cy - HANDLE_R, HANDLE_R * 2, HANDLE_R * 2);
      c.strokeRect(x2 - HANDLE_R, cy - HANDLE_R, HANDLE_R * 2, HANDLE_R * 2);
    } else if (a.shape === "polygon" || a.shape === "keypoint") {
      for (const [x, y] of a.points) {
        c.beginPath();
        c.arc(x, y, HANDLE_R, 0, Math.PI * 2);
        c.fill();
        c.stroke();
      }
    }
    c.restore();
  }
  // What kind of handle (if any) is at image-natural (x, y) for
  // the currently-selected annotation? Returns one of:
  //   { kind: "body" }
  //   { kind: "rect-corner", corner: "nw"|"ne"|"sw"|"se" }
  //   { kind: "rect-edge",   edge:   "n"|"s"|"w"|"e" }
  //   { kind: "vertex", index: <int> }
  //   null  →  not on any handle
  // Body hit is intentionally not returned by this function; the
  // caller layers a body-drag check (existing hitTestAnnotation) on
  // top, since "body" and "in handle" have different UX.
  function hitTestHandle(x, y, a) {
    if (!a || !a.points || a.points.length === 0) return null;
    const r = HANDLE_R;
    if (a.shape === "rect" && a.points.length >= 2) {
      const x1 = Math.min(a.points[0][0], a.points[1][0]);
      const x2 = Math.max(a.points[0][0], a.points[1][0]);
      const y1 = Math.min(a.points[0][1], a.points[1][1]);
      const y2 = Math.max(a.points[0][1], a.points[1][1]);
      const cx = (x1 + x2) / 2;
      const cy = (y1 + y2) / 2;
      const cornerPts = [[x1, y1, "nw"], [x2, y1, "ne"], [x2, y2, "se"], [x1, y2, "sw"]];
      for (const [hx, hy, name] of cornerPts) {
        if (Math.hypot(x - hx, y - hy) <= r) {
          return { kind: "rect-corner", corner: name };
        }
      }
      const edgePts = [[cx, y1, "n"], [cx, y2, "s"], [x1, cy, "w"], [x2, cy, "e"]];
      for (const [hx, hy, name] of edgePts) {
        if (Math.abs(x - hx) <= r && Math.abs(y - hy) <= r) {
          return { kind: "rect-edge", edge: name };
        }
      }
    } else if (a.shape === "polygon" || a.shape === "keypoint") {
      // For polygon we want any vertex to be grabbable. We pick
      // the closest one within the radius; ties go to the lower
      // index. The same function covers keypoint (1 vertex) so the
      // caller doesn't have to special-case shape.
      let best = -1;
      let bestD = r;
      for (let i = 0; i < a.points.length; i++) {
        const [vx, vy] = a.points[i];
        const d = Math.hypot(x - vx, y - vy);
        if (d <= bestD) { bestD = d; best = i; }
      }
      if (best >= 0) return { kind: "vertex", index: best };
    }
    return null;
  }

  // ---------- paint ----------
  function paintStatic(state) {
    if (natural.w === 0) return;
    if (!state.label) return;
    applyDpr(staticCtx, natural.w, natural.h);
    staticCtx.setTransform(display.dpr, 0, 0, display.dpr, 0, 0);
    staticCtx.clearRect(0, 0, natural.w, natural.h);
    // Rasterize the source bitmap into the static layer if one is
    // attached. Two paths feed this:
    //   - native: an <img> element from the previous "setImage" API;
    //   - mizchi: an ImageBitmap decoded from the backend's PNG reply.
    // We don't draw the source image when the host hasn't given us one
    // — that's the "canvas overlay only" mode where the <img> element
    // renders the bitmap directly (see main.js showImage).
    if (_sourceImage) {
      try {
        staticCtx.drawImage(_sourceImage, 0, 0, natural.w, natural.h);
      } catch {
        // drawImage can throw synchronously if the bitmap has been
        // closed (e.g. between image switches). Clear and continue.
      }
    }
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
    if (!state.label) return;
    applyDpr(dynamicCtx, natural.w, natural.h);
    dynamicCtx.setTransform(display.dpr, 0, 0, display.dpr, 0, 0);
    dynamicCtx.clearRect(0, 0, natural.w, natural.h);
    const { mode, draftPoints, bindingFromId, selectedId, colorForType, cursorImgPt } = state;
    if (bindingFromId) {
      const a = state.label.infos.find((x) => x.id === bindingFromId);
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
      drawDraftRect(dynamicCtx, draftPoints, state.colorForType?.("draft") || "#fbbf24");
    } else if (mode === "polygon" && draftPoints.length > 0) {
      drawDraftPolygon(dynamicCtx, draftPoints, state.colorForType?.("draft") || "#fbbf24");
    }
    // Cursor crosshair — two dashed lines through the current
    // pointer position, extending to the image edges. Drawn
    // regardless of mode (rect / select / polygon / keypoint /
    // binding) and regardless of whether any annotation exists, so
    // the user always has a precise alignment reference while
    // hovering over the canvas. Hidden when the pointer leaves
    // the canvas (cursorImgPt is null in that case).
    if (cursorImgPt) {
      const [cx, cy] = cursorImgPt;
      dynamicCtx.save();
      dynamicCtx.strokeStyle = "rgba(255, 255, 255, 0.55)";
      dynamicCtx.globalAlpha = 0.45;
      dynamicCtx.setLineDash([4, 4]);
      dynamicCtx.lineWidth = 1;
      dynamicCtx.beginPath();
      dynamicCtx.moveTo(0, cy);
      dynamicCtx.lineTo(natural.w, cy);
      dynamicCtx.moveTo(cx, 0);
      dynamicCtx.lineTo(cx, natural.h);
      dynamicCtx.stroke();
      // Small cross at the cursor itself so the user can pinpoint
      // exactly where the lines meet even when the image is
      // textured.
      dynamicCtx.globalAlpha = 1;
      dynamicCtx.strokeStyle = "rgba(255, 255, 255, 0.85)";
      dynamicCtx.lineWidth = 1.5;
      dynamicCtx.beginPath();
      dynamicCtx.moveTo(cx - 6, cy); dynamicCtx.lineTo(cx + 6, cy);
      dynamicCtx.moveTo(cx, cy - 6); dynamicCtx.lineTo(cx, cy + 6);
      dynamicCtx.stroke();
      dynamicCtx.restore();
    }
    // Modification handles (selected annotation only). Drawn on the
    // dynamic layer so they track the annotation point-for-point
    // during a drag — the static layer caches the bulk render and
    // only repaints when label.infos / label.bindings change.
    if (selectedId) {
      const a = state.label.infos.find((x) => x.id === selectedId);
      if (a) drawHandles(dynamicCtx, a, colorForType(a.type));
    }
  }
  function composite() {
    if (natural.w === 0) return;
    const op = stateRef && stateRef.opacity != null ? stateRef.opacity : 1;
    // After Fix A, the canvas's CSS size is the image's rendered size
    // (set externally by main.js's syncNativeImageView). So the
    // backing buffer and the draw target should both be the image's
    // rendered size, and we draw at (0, 0) in canvas-local CSS px.
    // The canvas's CSS left/top positions the whole thing at the
    // image's screen rect — no further pan math needed in this layer.
    const w = natural.w * view.zoom;
    const h = natural.h * view.zoom;
    applyDpr(ctx, w, h);
    ctx.setTransform(display.dpr, 0, 0, display.dpr, 0, 0);
    ctx.globalAlpha = op;
    ctx.clearRect(0, 0, w, h);
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    // Source rect must cover the entire static/dynamic layer bitmap,
    // which `applyDpr` already scaled to (natural.w*dpr, natural.h*dpr)
    // — labels are painted with a dpr transform into that scaled
    // bitmap. Sampling only (natural.w, natural.h) (the pre-Fix C
    // mistake) captures just the top-left 1/dpr² of the painted
    // content and stretches it to fit the destination, which makes
    // labels render at view.zoom * dpr instead of view.zoom and
    // pushes them off-position by (label_natural * view.zoom *
    // (dpr - 1)) CSS px. On a HiDPI display with dpr=2 that's a
    // large offset (e.g. ~300 CSS px for a keypoint near the image
    // center at 1.29× zoom).
    const srcW = Math.round(natural.w * display.dpr);
    const srcH = Math.round(natural.h * display.dpr);
    ctx.drawImage(layerStatic, 0, 0, srcW, srcH, 0, 0, w, h);
    ctx.drawImage(layerDynamic, 0, 0, srcW, srcH, 0, 0, w, h);
    ctx.globalAlpha = 1;
  }

  // We accept external opacity from main.js (settings slider)
  // via a setter on the returned object. For simplicity we use a tiny
  // options bag passed to render().
  let _opacity = 1;

  function getView() {
    return { pan: { ...view.pan }, zoom: view.zoom };
  }
  function emitViewChange(isFit) {
    // The host also needs the screen-space rect of the rendered bitmap
    // so it can keep the <img> element AND the annotation canvas
    // overlay in lock-step with the canvas composite (used by the
    // native render path which paints the bitmap in <img> and the
    // labels in the canvas, and by Fix A which moves the canvas
    // overlay to be co-located with the <img>).
    const rect = {
      x: display.left + view.pan.x,
      y: display.top + view.pan.y,
      w: natural.w * view.zoom,
      h: natural.h * view.zoom,
    };
    document.dispatchEvent(new CustomEvent("labeler:viewchange", {
      detail: { ...getView(), imageRect: rect, isFit: !!isFit },
    }));
  }
  function setView(v) {
    view = { pan: { ...v.pan }, zoom: Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, v.zoom)) };
    emitViewChange(v.__fit === true);
  }
  function resetView() { setView({ pan: { x: 0, y: 0 }, zoom: 1 }); }
  function fitView() {
    // Pick a zoom so the entire image fits inside the stage (the
    // canvas container) and pan so the bitmap is centered inside the
    // unused area. The view transform must keep image and
    // annotations in lock-step.
    if (viewport.w === 0 || viewport.h === 0 || natural.w === 0) return;
    const z = Math.min(viewport.w / natural.w, viewport.h / natural.h);
    const dw = natural.w * z;
    const dh = natural.h * z;
    // The image's CSS left = display.left + view.pan.x; the center
    // condition is (display.left + view.pan.x) = (viewport.w - dw) / 2,
    // i.e. view.pan.x = (viewport.w - dw) / 2 - display.left.
    const panX = (viewport.w - dw) / 2 - display.left;
    const panY = (viewport.h - dh) / 2 - display.top;
    setView({ pan: { x: panX, y: panY }, zoom: z, __fit: true });
  }
  function setZoom(z, centerNatural) {
    const newZ = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, z));
    if (centerNatural) {
      const [sx, sy] = toScreen(centerNatural[0], centerNatural[1]);
      zoomAtScreenPoint(newZ, sx, sy);
    } else {
      // Zoom around the stage's center, expressed in canvas-local CSS
      // px (post-Fix-A, the canvas may not be at the stage's origin).
      zoomAtScreenPoint(newZ,
        viewport.w / 2 - display.left - view.pan.x,
        viewport.h / 2 - display.top - view.pan.y);
    }
    emitViewChange();
  }
  function zoomBy(factor, screenPt) {
    const newZ = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, view.zoom * factor));
    if (screenPt) {
      zoomAtScreenPoint(newZ, screenPt[0], screenPt[1]);
    } else {
      zoomAtScreenPoint(newZ,
        viewport.w / 2 - display.left - view.pan.x,
        viewport.h / 2 - display.top - view.pan.y);
    }
    emitViewChange();
  }
  function panBy(dx, dy) {
    view = {
      pan: { x: view.pan.x + dx, y: view.pan.y + dy },
      zoom: view.zoom,
    };
    emitViewChange();
  }

  // helper so paintStatic/Dynamic read opacity — close over _opacity
  const stateRef = { get opacity() { return _opacity; } };

  container.appendChild(canvas);

  let _lastStaticKey = null;
  // Last full state object passed to render(). Held at module
  // scope inside createCanvas so hitTestHandle (a method on the
  // returned object) can read the current selectedId / label
  // outside of a paint pass. Without this cache, hitTestHandle
  // would have to take the state as a parameter — and the call
  // site in main.js doesn't always have the same object identity
  // (each renderAnnotations builds a fresh object). Updating on
  // every render keeps the closure honest with the host's view of
  // the world.
  let _lastState = null;
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

  return {
    element: canvas,
    get natural() { return natural; },
    get view() { return view; },
    setImageBitmap(bitmap) {
      // Used by the mizchi/image bypass path: the frontend asks the
      // backend to decode + (optionally) resize the source image,
      // parses the PNG reply into an ImageBitmap, and hands it here.
      // paintStatic rasterizes it into the static layer; composite()
      // draws the layer through the view transform so the image and
      // annotations move together on zoom/pan.
      _sourceImage = bitmap;
      _lastStaticKey = null;
    },
    resize(newNatural, newDisplay) {
      natural = newNatural;
      const rect = container.getBoundingClientRect();
      viewport = {
        w: rect.width,
        h: rect.height,
      };
      display = {
        w: newDisplay.w,
        h: newDisplay.h,
        left: newDisplay.left,
        top: newDisplay.top,
        dpr: window.devicePixelRatio || 1,
      };
      _lastStaticKey = null;
      // Notify host of new dims (e.g. for zoom/pan clamped to display)
      emitViewChange();
    },
    render(state) {
      if (natural.w === 0) return;
      if (typeof state.opacity === "number") _opacity = state.opacity;
      _lastState = state;
      const k = staticKey(state.label);
      // While a modify drag is in progress, force a static-layer
      // repaint on every frame. The drag handler mutates points
      // in place, so staticKey (which hashes id + length + type
      // but not point coordinates) doesn't change and the cache
      // would otherwise hold the pre-drag outline — visible as a
      // ghost rect / polygon that snaps to the new position only
      // when the drag ends. paintStatic is cheap (a few rect /
      // polygon paths) so this is fine for the duration of a
      // single user drag.
      if (k !== _lastStaticKey || state.drag) {
        paintStatic(state);
        _lastStaticKey = k;
      }
      paintDynamic(state);
      composite();
    },
    getView, setView, resetView, fitView,
    setZoom, zoomBy, panBy,
    onMouseDown(fn) { handlers.mousedown = fn; },
    onMouseMove(fn) { handlers.mousemove = fn; },
    onMouseUp(fn) { handlers.mouseup = fn; },
    onMouseLeave(fn) { handlers.mouseleave = fn; },
    onClick(fn) { handlers.click = fn; },
    onDblClick(fn) { handlers.dblclick = fn; },
    onWheel(fn) { handlers.wheel = fn; },
    /// Hit-test the modification handles of the currently-selected
    /// annotation at image-natural (x, y). Returns one of:
    ///   { kind: "body" }
    ///   { kind: "rect-corner", corner: "nw"|"ne"|"sw"|"se" }
    ///   { kind: "rect-edge",   edge:   "n"|"s"|"w"|"e" }
    ///   { kind: "vertex", index: <int> }
    ///   null  →  no handle hit
    /// Body hit is layered on by the caller (existing
    /// hitTestAnnotation) so the same hover/press does both jobs.
    /// Reads from `_lastState` (set in `render`) rather than a
    /// closure on a `state` parameter that doesn't exist in this
    /// scope — using a free `state` reference would ReferenceError
    /// and silently null out, which is why the previous commit's
    /// drag never fired in practice.
    hitTestHandle(x, y) {
      const a = _lastState?.label?.infos?.find(
        (it) => it.id === _lastState?.selectedId,
      );
      if (!a) return null;
      return hitTestHandle(x, y, a);
    },
  };
}