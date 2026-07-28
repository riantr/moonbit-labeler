// Canvas overlay — SVG layer over the image for drawing + selecting
// rect / polygon / keypoint / binding annotations.
//
// Coords:
//   - Image coordinates (img_x, img_y) are used everywhere internally.
//   - The SVG viewBox is `0 0 naturalW naturalH`, so SVG units == image coords.
//   - When the image resizes we update `viewBox` and call `resize()`.

const SVG_NS = "http://www.w3.org/2000/svg";

export function createCanvas(stage) {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.classList.add("annotation-overlay");
  svg.setAttribute("preserveAspectRatio", "none");

  const handlers = {
    mousedown: null,
    mousemove: null,
    mouseup: null,
    click: null,
    dblclick: null,
  };

  function mouseToImg(ev) {
    const rect = svg.getBoundingClientRect();
    if (rect.width === 0) return null;
    const rx = (ev.clientX - rect.left) / rect.width;
    const ry = (ev.clientY - rect.top) / rect.height;
    const viewBox = svg.viewBox.baseVal;
    return [rx * viewBox.width, ry * viewBox.height];
  }

  function bindEvents() {
    svg.addEventListener("mousedown", (ev) => {
      if (handlers.mousedown) handlers.mousedown(ev, mouseToImg(ev));
    });
    svg.addEventListener("mousemove", (ev) => {
      if (handlers.mousemove) handlers.mousemove(ev, mouseToImg(ev));
    });
    svg.addEventListener("mouseup", (ev) => {
      if (handlers.mouseup) handlers.mouseup(ev, mouseToImg(ev));
    });
    svg.addEventListener("click", (ev) => {
      if (handlers.click) handlers.click(ev, mouseToImg(ev));
    });
    svg.addEventListener("dblclick", (ev) => {
      if (handlers.dblclick) handlers.dblclick(ev, mouseToImg(ev));
    });
  }
  bindEvents();

  function clearChildren() {
    while (svg.firstChild) svg.removeChild(svg.firstChild);
  }

  function addEl(name, attrs) {
    const el = document.createElementNS(SVG_NS, name);
    for (const [k, v] of Object.entries(attrs)) {
      el.setAttribute(k, String(v));
    }
    svg.appendChild(el);
    return el;
  }

  function drawPolygon(points, color, fillOpacity, isSelected) {
    if (points.length < 2) return;
    const d = points.map((p, i) => (i === 0 ? "M" : "L") + p[0] + "," + p[1]).join(" ") + " Z";
    addEl("path", {
      d,
      fill: color,
      "fill-opacity": fillOpacity,
      stroke: color,
      "stroke-width": isSelected ? 3 : 2,
      "stroke-linejoin": "round",
    });
  }

  function drawRect(points, color, fillOpacity, isSelected) {
    if (points.length < 2) return;
    const x1 = Math.min(points[0][0], points[1][0]);
    const y1 = Math.min(points[0][1], points[1][1]);
    const w = Math.abs(points[1][0] - points[0][0]);
    const h = Math.abs(points[1][1] - points[0][1]);
    addEl("rect", {
      x: x1, y: y1, width: w, height: h,
      fill: color, "fill-opacity": fillOpacity,
      stroke: color, "stroke-width": isSelected ? 3 : 2,
    });
  }

  function drawKeypoint(points, color, isSelected) {
    for (const [x, y] of points) {
      addEl("circle", {
        cx: x, cy: y, r: isSelected ? 8 : 6,
        fill: color, stroke: "white", "stroke-width": 2,
      });
    }
  }

  function centroid(a) {
    const pts = a.points || [];
    if (pts.length === 0) return [0, 0];
    let sx = 0, sy = 0;
    for (const [x, y] of pts) { sx += x; sy += y; }
    return [sx / pts.length, sy / pts.length];
  }

  function drawBinding(a, b, color, isSelected) {
    if (!a || !b) return;
    const pa = centroid(a);
    const pc = centroid(b);
    addEl("line", {
      x1: pa[0], y1: pa[1], x2: pc[0], y2: pc[1],
      stroke: color,
      "stroke-width": isSelected ? 3 : 1.5,
      "stroke-dasharray": "6,4",
    });
  }

  function drawDraftPolygon(points, color) {
    if (points.length === 0) return;
    const d = points.map((p, i) => (i === 0 ? "M" : "L") + p[0] + "," + p[1]).join(" ");
    if (points.length >= 3) {
      addEl("path", {
        d: d + " Z",
        fill: color,
        "fill-opacity": 0.15,
        stroke: color,
        "stroke-width": 2,
        "stroke-dasharray": "4,3",
      });
    } else {
      addEl("path", {
        d, fill: "none",
        stroke: color, "stroke-width": 2, "stroke-dasharray": "4,3",
      });
    }
    for (const [x, y] of points) {
      addEl("circle", {
        cx: x, cy: y, r: 4,
        fill: color, stroke: "white", "stroke-width": 1.5,
      });
    }
  }

  function drawDraftRect(points, color) {
    if (points.length < 2) return;
    const x1 = Math.min(points[0][0], points[1][0]);
    const y1 = Math.min(points[0][1], points[1][1]);
    const w = Math.abs(points[1][0] - points[0][0]);
    const h = Math.abs(points[1][1] - points[0][1]);
    addEl("rect", {
      x: x1, y: y1, width: w, height: h,
      fill: color, "fill-opacity": 0.15,
      stroke: color, "stroke-width": 2, "stroke-dasharray": "4,3",
    });
  }

  return {
    element: svg,
    resize(natural, display) {
      // Natural == SVG viewBox dims. Display == displayed rect of the image,
      // (left/top are relative to the stage so we can position the SVG to
      // overlay exactly on top of the <img> — the image is centred in the
      // stage with `align-items: center`, so without this offset the SVG
      // would sit at (0,0) and the annotations would be misaligned).
      svg.setAttribute("viewBox", `0 0 ${natural.w} ${natural.h}`);
      svg.setAttribute("width", String(display.w));
      svg.setAttribute("height", String(display.h));
      svg.style.left = `${display.left | 0}px`;
      svg.style.top = `${display.top | 0}px`;
      // Re-append so it stays last child of the stage.
      stage.appendChild(svg);
    },
    render(state) {
      clearChildren();
      const { label, mode, selectedId, draftPoints, bindingFromId, colorForType } = state;
      const byId = new Map();
      for (const a of label.infos) byId.set(a.id, a);

      // Existing bindings
      for (const b of label.bindings) {
        const a = byId.get(b.from);
        const c = byId.get(b.to);
        if (!a || !c) continue;
        drawBinding(a, c, "#fbbf24", selectedId === b.id);
      }

      // Existing annotations
      for (const a of label.infos) {
        const color = colorForType(a.type);
        const sel = selectedId === a.id || bindingFromId === a.id;
        if (a.shape === "polygon") drawPolygon(a.points, color, 0.18, sel);
        else if (a.shape === "rect") drawRect(a.points, color, 0.12, sel);
        else if (a.shape === "keypoint") drawKeypoint(a.points, color, sel);
        // Type label
        if (a.points.length > 0) {
          const [lx, ly] = centroid(a);
          addEl("text", {
            x: lx, y: ly - 8,
            "text-anchor": "middle",
            "font-size": 12,
            "font-family": "system-ui, sans-serif",
            fill: color,
            "paint-order": "stroke",
            stroke: "rgba(0,0,0,0.55)",
            "stroke-width": 3,
          }).textContent = a.type;
        }
      }

      // Highlight first picked for binding
      if (bindingFromId) {
        const a = byId.get(bindingFromId);
        if (a) {
          const [cx, cy] = centroid(a);
          addEl("circle", {
            cx, cy, r: 10,
            fill: "none", stroke: "#fbbf24", "stroke-width": 2,
          });
        }
      }

      // Draft geometry
      if (mode === "rect" && draftPoints.length === 2) {
        drawDraftRect(draftPoints, colorForType("draft"));
      } else if (mode === "polygon" && draftPoints.length > 0) {
        drawDraftPolygon(draftPoints, colorForType("draft"));
      }
    },
    onMouseDown(fn) { handlers.mousedown = fn; },
    onMouseMove(fn) { handlers.mousemove = fn; },
    onMouseUp(fn) { handlers.mouseup = fn; },
    onClick(fn) { handlers.click = fn; },
    onDblClick(fn) { handlers.dblclick = fn; },
  };
}