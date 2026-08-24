// Stdio JSON-RPC bridge. Imported into the `app` executable via
// `@stdio_main.run_stdio()`; not used by the CEF/Proton code path.
//
// Protocol (one line per request, one line per response):
//
//   req  = {"id": <int|null>, "op": "<name>", "payload": <op-specific-json>}
//   resp = {"id": <int|null>, "ok": true,  "result": <op-specific-json>}
//        | {"id": <int|null>, "ok": false, "error": "<message>"}
//
// Op names match the CEF/Proton op names with `ext:labeler/` stripped.
// The full list is @labeler.dispatch_op_list().

///|
/// Build a JSON response object.
fn make_response(id : Json, ok : Bool, result : Json, err : String) -> Json {
  let base : Map[String, Json] = Map::from_array([
    ("id", id),
    ("ok", Json::boolean(ok)),
  ])
  if ok {
    base.set("result", result)
  } else {
    base.set("error", Json::string(err))
  }
  Json::object(base)
}

///|
/// Read a single line from stdin. Returns None on EOF.
async fn read_line() -> String? {
  @stdio.stdin.read_until("\n")
}

///|
/// Handle one parsed request and return the response. Caller takes
/// care of writing the response to stdout.
async fn handle_request(req : Json) -> Json {
  let id = match req {
    Object(m) =>
      match m.get("id") {
        Some(v) => v
        None => Json::null()
      }
    _ => Json::null()
  }
  let op = match req {
    Object(m) =>
      match m.get("op") {
        Some(String(s)) => s
        _ =>
          return make_response(
            id, false, Json::null(), "missing or non-string `op` field",
          )
      }
    _ =>
      return make_response(
        id, false, Json::null(), "request must be a JSON object",
      )
  }
  let payload = match req {
    Object(m) =>
      match m.get("payload") {
        Some(p) => p
        None => Json::null()
      }
    _ => Json::null()
  }
  let result = try? @labeler.dispatch_op(op, payload)
  match result {
    Ok(json) => make_response(id, true, json, "")
    Err(e) =>
      make_response(
        id,
        false,
        Json::null(),
        "op '" + op + "' raised: " + e.to_string(),
      )
  }
}

///|
/// Main loop. Reads one JSON request per line from stdin, writes one
/// JSON response per line to stdout. Exits cleanly on EOF.
pub async fn run_stdio() -> Unit {
  let stdout = @stdio.stdout
  // Startup banner so the parent can log "connected" only after the
  // child is actually ready to accept requests.
  let banner : Json = Json::object(
    Map::from_array([
      ("type", Json::string("ready")),
      ("ops", @labeler.dispatch_op_list().to_json()),
    ]),
  )
  stdout.write(banner.stringify())
  stdout.write("\n")
  while true {
    let line_opt = read_line()
    let line = match line_opt {
      None => break
      Some(s) => s
    }
    let trimmed = line.trim()
    if trimmed.length() == 0 {
      continue
    }
    let resp = match (@json.parse(trimmed) : Result[Json, _]) {
      Ok(req) => handle_request(req)
      Err(e) =>
        make_response(
          Json::null(),
          false,
          Json::null(),
          "json parse error: " + e.to_string(),
        )
    }
    stdout.write(resp.stringify())
    stdout.write("\n")
  }
  // EOF — emit a clean shutdown marker.
  stdout.write(
    Json::object(Map::from_array([("type", Json::string("bye"))])).stringify() +
    "\n",
  )
}
