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
  // The canvas covers the full stage. `display.left/top` locate the fitted
  // image inside that stage; pan and zoom apply to both image and labels.
  function baseScaleX() {
    return natural.w > 0 ? display.w / natural.w : 1;
  }
  function baseScaleY() {
    return natural.h > 0 ? display.h / natural.h : 1;
  }
  /** stage CSS pixels -> image-natural pixels */
  function toNatural(screenX, screenY) {
    const originX = display.left + view.pan.x;
    const originY = display.top + view.pan.y;
    return [
      (screenX - originX) / (baseScaleX() * view.zoom),
      (screenY - originY) / (baseScaleY() * view.zoom),
    ];
  }
  /** image-natural -> stage CSS pixels */
  function toScreen(nx, ny) {
    return [
      display.left + nx * baseScaleX() * view.zoom + view.pan.x,
      display.top + ny * baseScaleY() * view.zoom + view.pan.y,
    ];
  }

  // ---------- event forwarding ----------
  const handlers = {
    mousedown: null, mousemove: null, mouseup: null,
    click: null, dblclick: null, wheel: null,
  };

  function mouseToImg(ev) {
    if (display.w === 0) return null;
    const rect = canvas.getBoundingClientRect();
    if (rect.width === 0) return null;
    const point = toNatural(ev.clientX - rect.left, ev.clientY - rect.top);
    // The canvas intentionally covers black stage areas too, but drawing
    // outside the actual image should not create invalid negative points.
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
        document.dispatchEvent(new CustomEvent("labeler:viewchange", { detail: getView() }));
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
      document.dispatchEvent(new CustomEvent("labeler:viewchange", { detail: getView() }));
      if (handlers.wheel) handlers.wheel(ev, mouseToImg(ev));
    }, { passive: false });
    // Suppress browser context menu on right-click so we can use it for pan.
    canvas.addEventListener("contextmenu", (ev) => ev.preventDefault());
  }

  /** Zoom to `z` keeping the natural point currently under (sx, sy) in place. */
  function zoomAtScreenPoint(z, sx, sy) {
    const [nx, ny] = toNatural(sx, sy);
    const sxScale = baseScaleX();
    const syScale = baseScaleY();
    view = {
      pan: {
        x: sx - nx * sxScale * z,
        y: sy - ny * syScale * z,
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

  // ---------- paint ----------
  function paintStatic(state) {
    if (natural.w === 0) return;
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
    applyDpr(dynamicCtx, natural.w, natural.h);
    dynamicCtx.setTransform(display.dpr, 0, 0, display.dpr, 0, 0);
    dynamicCtx.clearRect(0, 0, natural.w, natural.h);
    const { mode, draftPoints, bindingFromId } = state;
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
  }
  function composite() {
    if (natural.w === 0) return;
    const op = stateRef && stateRef.opacity != null ? stateRef.opacity : 1;
    applyDpr(ctx, viewport.w, viewport.h);
    ctx.setTransform(display.dpr, 0, 0, display.dpr, 0, 0);
    ctx.globalAlpha = op;
    ctx.clearRect(0, 0, viewport.w, viewport.h);
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
    // Composite in full-stage CSS pixels. The fitted image rect supplies
    // the base natural->display scale and left/top letterbox offset;
    // `view.zoom` and `view.pan` then move image and labels together.
    const destX = display.left + view.pan.x;
    const destY = display.top + view.pan.y;
    const destW = display.w * view.zoom;
    const destH = display.h * view.zoom;
    ctx.drawImage(layerStatic, 0, 0, natural.w, natural.h,
      destX, destY, destW, destH);
    ctx.drawImage(layerDynamic, 0, 0, natural.w, natural.h,
      destX, destY, destW, destH);
    ctx.globalAlpha = 1;
  }

  // We accept external opacity from main.js (settings slider)
  // via a setter on the returned object. For simplicity we use a tiny
  // options bag passed to render().
  let _opacity = 1;

  function getView() {
    return { pan: { ...view.pan }, zoom: view.zoom };
  }
  function setView(v) {
    view = { pan: { ...v.pan }, zoom: Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, v.zoom)) };
    document.dispatchEvent(new CustomEvent("labeler:viewchange", { detail: getView() }));
  }
  function resetView() { setView({ pan: { x: 0, y: 0 }, zoom: 1 }); }
  function fitView() {
    // "适应窗口" — pick a zoom so the image fits entirely inside the stage
    // (the canvas container), and pan so the image's top-left lands on the
    // stage's top-left. After this, the user can pan/zoom freely, but the
    // first fit always renders the picture fully inside the black area.
    if (viewport.w === 0 || viewport.h === 0 || natural.w === 0) return;
    const z = Math.min(viewport.w / natural.w, viewport.h / natural.h);
    // dest origin (image top-left in stage CSS pixels) = (0, 0) by design.
    // We still go through the existing view math so pan / zoom stay
    // consistent with the rest of the canvas.
    const dw = natural.w * z;
    const dh = natural.h * z;
    // The fitted image rect lives at (display.left + view.pan, display.top + view.pan).
    // We want destX = 0, destY = 0, so solve for view.pan.
    const panX = -display.left;
    const panY = -display.top;
    setView({ pan: { x: panX, y: panY }, zoom: z });
  }
  function setZoom(z, centerNatural) {
    const newZ = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, z));
    if (centerNatural) {
      const [sx, sy] = toScreen(centerNatural[0], centerNatural[1]);
      zoomAtScreenPoint(newZ, sx, sy);
    } else {
      // Zoom around viewport center
      zoomAtScreenPoint(newZ, viewport.w / 2, viewport.h / 2);
    }
    document.dispatchEvent(new CustomEvent("labeler:viewchange", { detail: getView() }));
  }
  function zoomBy(factor, screenPt) {
    const newZ = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, view.zoom * factor));
    if (screenPt) {
      zoomAtScreenPoint(newZ, screenPt[0], screenPt[1]);
    } else {
      zoomAtScreenPoint(newZ, viewport.w / 2, viewport.h / 2);
    }
    document.dispatchEvent(new CustomEvent("labeler:viewchange", { detail: getView() }));
  }
  function panBy(dx, dy) {
    view = {
      pan: { x: view.pan.x + dx, y: view.pan.y + dy },
      zoom: view.zoom,
    };
    document.dispatchEvent(new CustomEvent("labeler:viewchange", { detail: getView() }));
  }

  // helper so paintStatic/Dynamic read opacity — close over _opacity
  const stateRef = { get opacity() { return _opacity; } };

  container.appendChild(canvas);

  let _lastStaticKey = null;
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
      document.dispatchEvent(new CustomEvent("labeler:viewchange", { detail: getView() }));
    },
    render(state) {
      if (natural.w === 0) return;
      if (typeof state.opacity === "number") _opacity = state.opacity;
      const k = staticKey(state.label);
      if (k !== _lastStaticKey) {
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
    onClick(fn) { handlers.click = fn; },
    onDblClick(fn) { handlers.dblclick = fn; },
    onWheel(fn) { handlers.wheel = fn; },
  };
}