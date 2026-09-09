// Stdio JSON-RPC bridge. Lives in the `app` package; `main.mbt` calls
// `run_stdio()` when the executable is launched with `--stdio`.
//
// Protocol (one line per request, one line per response):
//
//   req  = {"id": <int|null>, "op": "<name>", "payload": <op-specific-json>}
//   resp = {"id": <int|null>, "ok": true,  "result": <op-specific-json>}
//        | {"id": <int|null>, "ok": false, "error": "<message>"}
//
// Op names match the CEF/Proton op names with `ext:labeler/` stripped.
// The full list is `@labeler.dispatch_op_list()`.

///|
/// Wire-format response. `derive(ToJson)` on a struct is the only public
/// way to build a `Json::Object` in 0.2.5 (the variant constructors
/// `Object` / `Null` / `String` / `True` / `False` are read-only outside
/// `core/json`). One of `result` / `error` is always null on the wire;
/// the parent ignores the null sibling after it sees `ok`.
struct Response {
  id : Json
  ok : Bool
  result : Json?
  error : String?
} derive(ToJson)

///|
fn make_response(id : Json, ok : Bool, result : Json, err : String) -> Response {
  if ok {
    { id, ok, result: Some(result), error: None, }
  } else {
    { id, ok, result: None, error: Some(err), }
  }
}

///|
/// Wrap the raw `id` field of a request, defaulting to null when the
/// field is missing or the request is not a JSON object.
fn extract_id(req : Json) -> Json {
  match req {
    Object(m) =>
      match m.get("id") {
        Some(v) => v
        None => null
      }
    _ => null
  }
}

///|
/// Read the `op` field. Returns either the op name or, on a missing/
/// non-string field, a fully-formed error response ready to ship.
fn extract_op(req : Json) -> Result[String, Response] {
  match req {
    Object(m) =>
      match m.get("op") {
        Some(String(s)) => Ok(s)
        _ =>
          Err(
            make_response(
              extract_id(req),
              false,
              null,
              "missing or non-string `op` field",
            ),
          )
      }
    _ => Err(make_response(null, false, null, "request must be a JSON object"))
  }
}

///|
/// Read the `payload` field, defaulting to null.
fn extract_payload(req : Json) -> Json {
  match req {
    Object(m) =>
      match m.get("payload") {
        Some(p) => p
        None => null
      }
    _ => null
  }
}

///|
/// Handle one parsed request and return the response. The caller is
/// responsible for writing the response (and a trailing newline) to
/// stdout. Errors raised by the labeler dispatcher become a JSON
/// error response; they never bubble out.
async fn handle_request(req : Json) -> Response {
  let id = extract_id(req)
  let op = match extract_op(req) {
    Ok(name) => name
    Err(ready) => return ready
  }
  let payload = extract_payload(req)
  match (try? @labeler.dispatch_op(op, payload)) {
    Ok(json) => make_response(id, true, json, "")
    Err(e) =>
      make_response(id, false, null, "op '" + op + "' raised: " + e.to_string())
  }
}

///|
/// Main loop. Reads one JSON request per line from stdin, writes one
/// JSON response per line to stdout. Exits cleanly on EOF (parent
/// closed stdin, or the Python side tore down the pipe).
pub async fn run_stdio() -> Unit {
  // Startup banner so the parent can log "connected" only after the
  // child is actually ready to accept requests.
  let banner : Json = {
    "type": "ready",
    "ops": @labeler.dispatch_op_list().to_json(),
  }
  @stdio.stdout.write(banner.stringify())
  @stdio.stdout.write("\n")
  while true {
    let line_opt : String? = @stdio.stdin.read_until("\n")
    let line = match line_opt {
      None => break
      Some(s) => s
    }
    let trimmed = line.trim()
    if trimmed.length() == 0 {
      continue
    }
    let resp = match (try? @json.parse(trimmed)) {
      Ok(req) => handle_request(req)
      Err(e) =>
        make_response(null, false, null, "json parse error: " + e.to_string())
    }
    @stdio.stdout.write(resp.to_json().stringify())
    @stdio.stdout.write("\n")
  }
  // EOF — emit a clean shutdown marker.
  let bye : Json = { "type": "bye" }
  @stdio.stdout.write(bye.stringify())
  @stdio.stdout.write("\n")
}
