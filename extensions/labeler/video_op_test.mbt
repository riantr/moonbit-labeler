// Tests for the video ops that can run synchronously.
//
// The ops themselves are async (they touch the filesystem and spawn
// ffmpeg), and a MoonBit `test` block cannot call an async function —
// the compiler rejects it with "cannot call async function in non-async
// function". The async half of the video path is therefore covered by
// `qa/video_stdio_blackbox.test.mjs`, which drives the real `--stdio`
// bridge end to end. What is left here is the part that *is* callable:
// the dispatcher advertises the ops, and the ops are registered under the
// names the frontend uses.

///|
test "the dispatcher advertises the video label ops" {
  let ops = dispatch_op_list()
  assert_true(ops.contains("read_video_label"))
  assert_true(ops.contains("write_video_label"))
}

///|
test "the dispatcher advertises the media ops" {
  let ops = dispatch_op_list()
  assert_true(ops.contains("list_videos"))
  assert_true(ops.contains("read_video_info"))
  assert_true(ops.contains("read_video_frame"))
}
