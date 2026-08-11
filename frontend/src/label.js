// Label JSON schema — thin wrapper over the shared MoonBit IPC ops.
//
// The actual parse / normalize / serialize logic lives in
// `extensions/labeler/labeler.mbt` (parse_label_text and
// serialize_label_text) so the on-disk schema has a single source of
// truth shared with the VOC/YOLO export path. The frontend only
// shuttles JSON text in and out and lets the backend do the work.
//
// On-disk schema (image + video, same shape):
//   {
//     "img_name": "<image or video basename>",
//     "frames":   [<frame numbers>],   // image mode: [] or omitted
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

export function emptyLabel() {
  return { img_name: "", infos: [], bindings: [], frames: [] };
}

/// Parse a label JSON text via the MoonBit IPC layer. Returns the
/// normalized label object (or `null` if the input was empty).
///
/// Both the legacy `points: "x,y;x,y;..."` shape and the modern
/// `points: [[x, y], ...]` shape are accepted on the wire; the
/// backend normalizes to the modern shape, infers `shape` from the
/// point count when missing, mints `id`s, and strips UTF-8 BOMs.
export async function parseLabel(text, fallbackImgName) {
  if (!text) return null;
  const bridge = window.__MoonBit__?.core;
  if (!bridge) {
    throw new Error("MoonBit IPC bridge not available");
  }
  const reply = await bridge.invokeOp("ext:labeler/parse_label", {
    text,
    fallback_img_name: fallbackImgName || null,
  });
  if (!reply?.ok) {
    throw new Error(reply?.error || "parse_label failed");
  }
  return JSON.parse(reply.label_text);
}

/// Re-serialize a label object back to disk-shape JSON text. Round-
/// trips through the MoonBit normalizer so we always write the
/// modern schema: `id`, `shape`, nested `points` array, integer pixel
/// coordinates, and `frames` included only when non-empty.
export async function serializeLabel(label) {
  const bridge = window.__MoonBit__?.core;
  if (!bridge) {
    throw new Error("MoonBit IPC bridge not available");
  }
  const reply = await bridge.invokeOp("ext:labeler/serialize_label", {
    label_text: JSON.stringify(label),
  });
  if (!reply?.ok) {
    throw new Error(reply?.error || "serialize_label failed");
  }
  return reply.text;
}
