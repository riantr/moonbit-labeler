///|
/// A consumer of the package public API.
///
/// It reaches nothing but the public surface: `dispatch_op_list()` for
/// the op names, and `dispatch_op(op, payload)` for one op. There is no
/// file-level `import` line on purpose -- the package path belongs in
/// `moon.pkg`, and the code refers to the package as `@labeler`.
async fn main {
  let ops = @labeler.dispatch_op_list()
  println("op count = " + ops.length().to_string())

  // Round-trip a label through the shared normalizer. `parse_label`
  // touches no filesystem, so the result is deterministic.
  //
  // `dispatch_op` is async and raises, so `main` is async and the error
  // is handled at the call site rather than by letting `main` raise.
  let payload = ToJson::to_json(ParsePayload::{
    text: ToJson::to_json(ProbeLabel::{ img_name: "probe.png", }).stringify(),
    fallback_img_name: "probe.png",
  })
  let text = @labeler.dispatch_op("parse_label", payload).stringify() catch {
    _ => "dispatch failed"
  }
  println(text)
}

///|
/// The label the probe round-trips.
#derive(ToJson)
struct ProbeLabel {
  img_name : String
}

///|
/// The `parse_label` request payload.
#derive(ToJson)
struct ParsePayload {
  text : String
  fallback_img_name : String
}
