///|
/// A minimal demo of the `@labeler.dispatch_op` embedding API.
///
/// It reads the label JSON that belongs to one image through the
/// `read_label` op -- the same code path the frontend uses when it
/// issues `ext:labeler/read_label`, with the JSON-RPC frame replaced by
/// a direct call -- and prints the normalized result.
///
/// Usage:
///   moon run examples/read_label --target native -- <image_path>
///
/// The argument is an IMAGE path, not a label path: the op derives the
/// label path from the `Image@<name>` / `Label@<name>` folder layout
/// (see `extensions/labeler/labeler.mbt` for the `read_label` contract).
async fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: read_label <image_path>")
    return
  }
  let image_path = args[1]

  // The same JSON shape the frontend would POST via
  // `ext:labeler/read_label`.
  let payload = ToJson::to_json(ReadLabelPayload::{ image_path, })

  // Dispatch through the public embedding entry point. The package path
  // lives in `moon.pkg`; the code refers to the package as `@labeler`.
  let reply = @labeler.dispatch_op("read_label", payload)

  println(reply.stringify())
}

///|
/// The `read_label` request payload.
#derive(ToJson)
struct ReadLabelPayload {
  image_path : String
}
