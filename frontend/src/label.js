// Label JSON schema helpers for MoonBit Labeler.
//
// On-disk schema (current):
//   {
//     "img_name": "<image basename>",
//     "infos": [
//       { "id": "obj_xxx", "shape": "polygon"|"rect"|"keypoint",
//         "type": "<class string>",
//         "points": [[x, y], ...]  // image-coordinate pixels
//       }
//     ],
//     "bindings": [
//       { "id": "b_xxx", "from": "obj_xxx", "to": "obj_yyy",
//         "type": "same_group" }
//     ]
//   }
//
// Backwards compatibility:
//   - Old shape: { img_name, infos: [{ points, type }] } (no id/shape/bindings).
//     - We auto-assign ids.
//     - shape is inferred from the point count (>=3 -> polygon, 2 -> rect).
//     - bindings default to [].

export function emptyLabel() {
  return { img_name: "", infos: [], bindings: [] };
}

export function parseLabel(text) {
  try {
    // Strip BOM and stray whitespace — many legacy CARS label files start
    // with a UTF-8 BOM (EF BB BF) which JSON.parse rejects.
    if (typeof text === "string" && text.charCodeAt(0) === 0xFEFF) {
      text = text.slice(1);
    }
    const obj = JSON.parse(text);
    if (!obj || typeof obj !== "object") return null;
    return obj;
  } catch (err) {
    console.error("parseLabel failed:", err);
    return null;
  }
}

///| Decode `"x1,y1;x2,y2;..."` -> [[x1,y1], [x2,y2], ...]
export function parsePoints(s) {
  if (!s) return [];
  return s
    .split(";")
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => {
      const parts = p.split(",");
      if (parts.length < 2) return null;
      const x = Number(parts[0]);
      const y = Number(parts[1]);
      if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
      return [x, y];
    })
    .filter((p) => p !== null);
}

///| Encode [[x,y], ...] -> `"x1,y1;x2,y2;..."` (rounded to integers)
export function serializePoints(points) {
  return points.map(([x, y]) => `${Math.round(x)},${Math.round(y)}`).join(";");
}

export function inferShape(points) {
  const n = points.length;
  if (n === 0) return "polygon";
  if (n === 1) return "keypoint";
  if (n === 2) return "rect";
  return "polygon";
}

function randomId(prefix) {
  return prefix + "_" + Math.random().toString(36).slice(2, 9);
}

export function normalizeLabel(parsed, fallbackImgName) {
  const imgName = parsed.img_name || fallbackImgName || "";
  const infos = Array.isArray(parsed.infos) ? parsed.infos : [];
  const normInfos = infos.map((raw, idx) => {
    let pts;
    if (Array.isArray(raw.points) && raw.points.length > 0 &&
        Array.isArray(raw.points[0])) {
      pts = raw.points
        .map((p) => Array.isArray(p) && p.length >= 2 ? [Number(p[0]), Number(p[1])] : null)
        .filter((p) => p !== null && Number.isFinite(p[0]) && Number.isFinite(p[1]));
    } else if (typeof raw.points === "string") {
      pts = parsePoints(raw.points);
    } else {
      pts = [];
    }
    const shape = raw.shape || inferShape(pts);
    const type = raw.type || "object";
    const id = raw.id || `obj_${randomId("m").slice(0, 5)}${idx}`;
    return { id, shape, type, points: pts };
  }).filter((a) => a.points.length > 0);

  const rawBindings = Array.isArray(parsed.bindings) ? parsed.bindings : [];
  const normBindings = rawBindings.map((b, idx) => ({
    id: b.id || `b_${randomId("m").slice(0, 5)}${idx}`,
    from: b.from,
    to: b.to,
    type: b.type || "same_group",
  })).filter((b) =>
    normInfos.some((a) => a.id === b.from) &&
    normInfos.some((a) => a.id === b.to) &&
    b.from !== b.to,
  );

  return { img_name: imgName, infos: normInfos, bindings: normBindings };
}

///| Serialize the in-memory label back to the on-disk schema.
/// Always writes the modern shape (`id`, `shape`, `points` as nested array,
/// `bindings`) so the next read is a no-op migration.
export function serializeLabel(label) {
  const out = {
    img_name: label.img_name || "",
    infos: label.infos.map((a) => ({
      id: a.id,
      shape: a.shape,
      type: a.type,
      points: a.points.map(([x, y]) => [Math.round(x), Math.round(y)]),
    })),
    bindings: (label.bindings || []).map((b) => ({
      id: b.id,
      from: b.from,
      to: b.to,
      type: b.type,
    })),
  };
  return JSON.stringify(out);
}