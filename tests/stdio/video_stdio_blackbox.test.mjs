// Black-box test for the video-mode ops, driven through the real
// `--stdio` JSON-RPC bridge.
//
// Why this is a Node script and not a MoonBit test: the video ops are
// async (they touch the filesystem and spawn ffmpeg), and a MoonBit
// `test` block cannot call an async function — the compiler rejects it
// with "cannot call async function in non-async function". The bridge is
// the same code path the CEF frontend uses, so driving it here covers
// the whole video pipeline: request parsing, the handlers, the
// filesystem, and the JSON wire format.
//
// Usage:
//   node tests/stdio/video_stdio_blackbox.test.mjs <path-to-app.exe> [--expect-ffmpeg]
//
// The executable must have the CEF runtime beside it (`libcef.dll` and
// friends): the app links against libcef even in `--stdio` mode, so a
// bare `moon build` output exits with STATUS_DLL_NOT_FOUND. The packaged
// app under `target/proton-dist/moonbit-labeler/` is staged correctly.
//
// Without `--expect-ffmpeg` the media-tool checks only assert that the
// ops answer with a structured failure when ffmpeg is absent; with it,
// they assert that a frame is actually extracted. The CI job installs
// ffmpeg and passes the flag.
//
// The label checks do not need ffmpeg at all and always run.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { mkdtempSync, mkdirSync, rmSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const exeArg = process.argv[2];
const expectFfmpeg = process.argv.includes("--expect-ffmpeg");
if (!exeArg) {
  console.error("usage: node tests/stdio/video_stdio_blackbox.test.mjs <app-exe> [--expect-ffmpeg]");
  process.exit(2);
}
const exe = path.resolve(exeArg);
if (!existsSync(exe)) {
  console.error(`[video] executable not found: ${exe}`);
  process.exit(2);
}

// ---------------------------------------------------------------------
// Fixture: a Video@demo/ folder with one small clip.
// ---------------------------------------------------------------------

const root = mkdtempSync(path.join(tmpdir(), "moonbit-labeler-video-"));
const videoDir = path.join(root, "Video@demo");
const labelDir = path.join(root, "Label@demo");
const videoPath = path.join(videoDir, "clip_001.mp4");
// Both folders exist even when the clip cannot be generated: the label
// ops only need the *path*, so the label checks still run without ffmpeg.
mkdirSync(videoDir, { recursive: true });
mkdirSync(labelDir, { recursive: true });

function makeVideo() {
  // `lavfi`'s testsrc needs no input file, so the fixture is generated
  // rather than committed: the repo stays free of binary blobs and the
  // clip is always exactly what the test expects.
  return new Promise((resolve) => {
    let res;
    try {
      res = spawn(
        "ffmpeg",
        [
          "-loglevel", "error",
          "-f", "lavfi",
          "-i", "testsrc=duration=1:size=160x120:rate=10",
          "-pix_fmt", "yuv420p",
          "-y",
          videoPath,
        ],
        { stdio: ["ignore", "ignore", "pipe"] },
      );
    } catch (err) {
      console.log(`[video] ffmpeg is not available (${err.message}) — the label checks still run`);
      resolve(false);
      return;
    }
    let stderr = "";
    res.stderr.on("data", (d) => (stderr += d.toString()));
    // A missing binary surfaces as an 'error' event rather than a
    // non-zero exit code.
    res.on("error", (err) => {
      console.log(`[video] ffmpeg is not available (${err.message}) — the label checks still run`);
      resolve(false);
    });
    res.on("close", (code) => {
      if (code !== 0) {
        console.error(`[video] ffmpeg could not build the fixture (exit ${code}):\n${stderr}`);
      }
      resolve(code === 0);
    });
  });
}

// ---------------------------------------------------------------------
// Bridge client
// ---------------------------------------------------------------------

const child = spawn(exe, ["--stdio"], { stdio: ["pipe", "pipe", "pipe"] });
const rl = createInterface({ input: child.stdout });
const pending = new Map();
let nextId = 1;
let banner = null;

rl.on("line", (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.type === "ready") { banner = msg; return; }
  if (msg.type) return;
  const p = pending.get(msg.id);
  if (p) { pending.delete(msg.id); p(msg); }
});
child.stderr.on("data", (d) => process.stderr.write("[stderr] " + d));

function call(op, payload) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, resolve);
    child.stdin.write(JSON.stringify({ id, op, payload }) + "\n");
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        reject(new Error(`op ${op} timed out`));
      }
    }, 60000);
  });
}

// ---------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------

let failures = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failures++;
  const suffix = ok ? "" : `\n      expected ${JSON.stringify(expected)}\n      actual   ${JSON.stringify(actual)}`;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${suffix}`);
}
function checkTrue(name, value) {
  check(name, !!value, true);
}

function annotationDoc(id, x) {
  return JSON.stringify({
    img_name: "clip_001.mp4",
    infos: [{ id, shape: "rect", type: "person", points: [[x, 0], [x + 10, 10]] }],
    bindings: [],
  });
}

function idsOf(labelText) {
  return (JSON.parse(labelText).infos || []).map((i) => i.id);
}

// ---------------------------------------------------------------------
// The test
// ---------------------------------------------------------------------

(async () => {
  const haveVideo = await makeVideo();
  if (!haveVideo) {
    console.log("[video] no fixture video — the label checks still run");
  }

  await new Promise((r) => setTimeout(r, 400));
  if (!banner) {
    console.error("[video] the bridge never sent its ready banner");
    process.exit(1);
  }
  checkTrue("the bridge advertises the video label ops", banner.ops.includes("read_video_label"));
  checkTrue("the bridge advertises write_video_label", banner.ops.includes("write_video_label"));

  // ---- list_videos -------------------------------------------------
  let r = await call("list_videos", { path: videoDir });
  checkTrue("list_videos answers", r.ok);
  if (r.ok && haveVideo) {
    check("list_videos finds the clip", (r.result.videos || []).map((v) => v.name), ["clip_001.mp4"]);
  } else if (r.ok) {
    // Without ffmpeg there is no fixture to find. The label checks
    // below still run: they only need the *path*.
    console.log("      (no fixture video — the list check was skipped)");
  }

  // ---- per-frame labels (no ffmpeg needed) --------------------------
  r = await call("write_video_label", {
    path: videoPath,
    frame: 5,
    content: annotationDoc("obj_five", 1),
  });
  checkTrue("write_video_label accepts frame 5", r.ok);
  r = await call("write_video_label", {
    path: videoPath,
    frame: 9,
    content: annotationDoc("obj_nine", 50),
  });
  checkTrue("write_video_label accepts frame 9", r.ok);

  r = await call("read_video_label", { path: videoPath, frame: 5 });
  check("frame 5 holds only its own object", idsOf(r.result.content), ["obj_five"]);
  r = await call("read_video_label", { path: videoPath, frame: 9 });
  check("frame 9 holds only its own object", idsOf(r.result.content), ["obj_nine"]);
  r = await call("read_video_label", { path: videoPath, frame: 7 });
  check("an unannotated frame stays empty", idsOf(r.result.content), []);
  r = await call("read_video_label", { path: videoPath, frame: 5 });
  check("the annotated frames are reported", r.result.annotated_frames, [5, 9]);

  // Re-writing one frame must not disturb the other.
  r = await call("write_video_label", {
    path: videoPath,
    frame: 5,
    content: annotationDoc("obj_five2", 2),
  });
  r = await call("read_video_label", { path: videoPath, frame: 5 });
  check("the rewritten frame is replaced", idsOf(r.result.content), ["obj_five2"]);
  r = await call("read_video_label", { path: videoPath, frame: 9 });
  check("the other frame is untouched", idsOf(r.result.content), ["obj_nine"]);

  // The document on disk must carry the per-frame sets.
  const labelFile = path.join(labelDir, "clip_001.json");
  checkTrue("the label document was written", existsSync(labelFile));
  if (existsSync(labelFile)) {
    const doc = JSON.parse(readFileSync(labelFile, "utf8"));
    checkTrue("the document carries frame_labels", Array.isArray(doc.frame_labels));
    check("the document lists both frames", (doc.frame_labels || []).map((s) => s.frames), [[5], [9]]);
  }

  // ---- the media ops -----------------------------------------------
  r = await call("read_video_info", { path: videoPath });
  checkTrue("read_video_info answers", r.ok);
  const info = r.ok ? r.result : {};
  if (expectFfmpeg) {
    checkTrue("read_video_info succeeds with ffmpeg installed", info.ok === true);
    checkTrue("the video has frames", (info.frame_count || 0) > 0);
  } else {
    // Without ffmpeg the op must still answer with a structured reply.
    if (info.ok === false) {
      checkTrue("a missing tool is reported with a code", !!info.error);
    } else {
      console.log("      (ffmpeg is installed — the success path was exercised)");
    }
  }

  r = await call("read_video_frame", { path: videoPath, frame: 3 });
  checkTrue("read_video_frame answers", r.ok);
  const frame = r.ok ? r.result : {};
  if (expectFfmpeg) {
    checkTrue("read_video_frame extracts a frame", frame.ok === true);
    checkTrue("the frame carries image data", (frame.base64 || "").length > 0);
    check("the frame is a JPEG", frame.mime, "image/jpeg");
  } else if (frame.ok === false) {
    checkTrue("a missing tool is reported with a code", !!frame.error);
  }

  child.stdin.end();
  await new Promise((r) => setTimeout(r, 300));
  child.kill();
  rmSync(root, { recursive: true, force: true });

  console.log(failures === 0 ? "\nALL CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
})().catch((err) => {
  console.error("[video] the test crashed:", err);
  child.kill();
  rmSync(root, { recursive: true, force: true });
  process.exit(1);
});
