// Tests for the class-revision op that can run synchronously.
//
// The op itself is async (it touches the filesystem), and a MoonBit
// `test` block cannot call an async function — the compiler rejects it
// with "cannot call async function in non-async function". The async
// half is therefore covered by `qa/class_revision_stdio_blackbox.test.mjs`,
// which drives the real `--stdio` bridge end to end. What is left here
// is the part that *is* callable: the dispatcher advertises the op, and
// the request/reply structs carry the shape the frontend sends.

///|
test "the dispatcher advertises the rename_class op" {
  let ops = dispatch_op_list()
  assert_true(ops.contains("rename_class"))
}

///|
test "the rename_class request decodes the shape the frontend sends" {
  let payload = @json.parse(
    "{\"image_path\":\"D:/x/Image@Foo/a.jpg\",\"from\":\"knife\"," +
    "\"to\":\"blade\",\"scope\":\"folder\",\"apply\":true}",
  )
  let req : RenameClassRequest = @json.from_json(payload)
  assert_eq(req.image_path, "D:/x/Image@Foo/a.jpg")
  assert_eq(req.from, "knife")
  assert_eq(req.to, "blade")
  assert_eq(req.scope, "folder")
  assert_eq(req.apply, true)
}

///|
test "the rename_class request decodes a preview request" {
  let payload = @json.parse(
    "{\"image_path\":\"D:/x/Image@Foo/a.jpg\",\"from\":\"knife\"," +
    "\"to\":\"blade\",\"scope\":\"current\",\"apply\":false}",
  )
  let req : RenameClassRequest = @json.from_json(payload)
  assert_eq(req.scope, "current")
  assert_eq(req.apply, false)
}
