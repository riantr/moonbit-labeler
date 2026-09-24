// examples/read_label — minimal demo of the @labeler.dispatch_op
// embedding API. Reads a single label JSON file from disk via the
// `read_label` IPC op, parses the normalized schema, and prints the
// result. Useful as a quick smoke test outside the CEF shell.
//
// Usage:
//   moon run examples/read_label --target native -- <label_path.json>
//
// The JSON must already be on disk in the modern normalized schema
// (see extensions/labeler/labeler.mbt for the `read_label` contract).

async fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: read_label <label_path.json>")
    return
  }
  let label_path = args[1]

  // Build the request payload (the same JSON shape the frontend
  // would POST via `ext:labeler/read_label`).
  let payload : Json = { "path": Json::string(label_path) }

  // Dispatch via the public embedding entry point.
  let reply = @labeler.dispatch_op("read_label", payload)

  // Pretty-print the parsed label.
  println(reply.stringify(indent=2))
}