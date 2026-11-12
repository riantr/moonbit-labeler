// Black-box test for the class-revision op, driven through the real
// `--stdio` JSON-RPC bridge.
//
// Why this is a Node script and not a MoonBit test: the op is async (it
// touches the filesystem), and a MoonBit `test` block cannot call an async
// function — the compiler rejects it with "cannot call async function in
// non-async function". The bridge is the same code path the CEF frontend
// uses, so driving it here covers the whole feature: request parsing, the
// handlers, the filesystem, and the JSON wire format.
//
// Usage:
//   node tests/stdio/class_revision_stdio_blackbox.test.mjs <path-to-app.exe>
//
// The executable must have the CEF runtime beside it (`libcef.dll` and
// friends): the app links against libcef even in `--stdio` mode, so a
// bare `moon build` output exits with STATUS_DLL_NOT_FOUND. The packaged
// app under `target/proton-dist/moonbit-labeler/` is staged correctly.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { mkdtempSync, mkdirSync, rmSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const exeArg = process.argv[2];
if (!exeArg) {
  console.error("usage: node tests/stdio/class_revision_stdio_blackbox.test.mjs <app-exe>");
  process.exit(2);
}
const exe = path.resolve(exeArg);
if (!existsSync(exe)) {
  console.error(`[class-revision] executable not found: ${exe}`);
  process.exit(2);
}

// ---------------------------------------------------------------------
// Fixture: an Image@demo/ folder with three annotated images, and a
// Video@vid/ folder with one clip that carries two per-frame sets.
// ---------------------------------------------------------------------

const root = mkdtempSync(path.join(tmpdir(), "moonbit-labeler-classrev-"));
const imageDir = path.join(root, "Image@demo");
const imageLabelDir = path.join(root, "Label@demo");
const videoDir = path.join(root, "Video@vid");
const videoLabelDir = path.join(root, "Label@vid");
for (const d of [imageDir, imageLabelDir, videoDir, videoLabelDir]) {
  mkdirSync(d, { recursive: true });
}

const imagePaths = ["a.jpg", "b.jpg", "c.jpg"].map((n) => path.join(imageDir, n));
const videoPath = path.join(videoDir, "clip.mp4");

function labelDoc(id, className, x = 0) {
  return JSON.stringify({
    img_name: "x",
    infos: [{ id, shape: "rect", type: className, points: [[x, 0], [x + 10, 10]] }],
    bindings: [],
  });
}

function frameDoc(id, className, x = 0) {
  return JSON.stringify({
    img_name: "clip.mp4",
    infos: [{ id, shape: "rect", type: className, points: [[x, 0], [x + 10, 10]] }],
    bindings: [],
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

function labelFile(p) {
  // `Image@X/<name>` and `Video@X/<name>` both map to `Label@X/<name>.json`.
  const dir = path.dirname(p);
  const leaf = path.basename(dir);
  const parent = path.dirname(dir);
  return path.join(parent, leaf.replace(/^(Image|Video)@/, "Label@"), path.basename(p).replace(/\.[^.]+$/, ".json"));
}

function typesOnDisk(p) {
  const f = labelFile(p);
  if (!existsSync(f)) return null;
  const doc = JSON.parse(readFileSync(f, "utf8"));
  return (doc.infos || []).map((i) => i.type);
}

// The classes of every per-frame set of a video document. A video keeps
// its annotations in `frame_labels`, so the top-level `infos` is empty
// and this is where the classes actually live.
function frameTypesOnDisk(p) {
  const f = labelFile(p);
  if (!existsSync(f)) return null;
  const doc = JSON.parse(readFileSync(f, "utf8"));
  const out = [];
  for (const set of doc.frame_labels || []) {
    for (const i of set.infos || []) out.push(i.type);
  }
  return out;
}

// ---------------------------------------------------------------------
// The test
// ---------------------------------------------------------------------

(async () => {
  await new Promise((r) => setTimeout(r, 400));
  if (!banner) {
    console.error("[class-revision] the bridge never sent its ready banner");
    process.exit(1);
  }
  checkTrue("the bridge advertises the rename_class op", banner.ops.includes("rename_class"));

  // ---- seed the label documents ------------------------------------
  let r = await call("write_label", { image_path: imagePaths[0], content: labelDoc("obj_a", "knife", 0) });
  checkTrue("write_label seeds image a", r.ok);
  r = await call("write_label", { image_path: imagePaths[1], content: labelDoc("obj_b", "knife", 20) });
  checkTrue("write_label seeds image b", r.ok);
  r = await call("write_label", { image_path: imagePaths[2], content: labelDoc("obj_c", "scissors", 40) });
  checkTrue("write_label seeds image c", r.ok);
  // A curated class list, so the rename has to keep it in step.
  r = await call("save_classes", { image_path: imageDir, classes: ["knife", "scissors"] });
  checkTrue("save_classes writes the curated list", r.ok);

  // Two frames of the video, each with its own class.
  r = await call("write_video_label", { path: videoPath, frame: 5, content: frameDoc("obj_f5", "knife", 0) });
  checkTrue("write_video_label seeds frame 5", r.ok);
  r = await call("write_video_label", { path: videoPath, frame: 9, content: frameDoc("obj_f9", "knife", 30) });
  checkTrue("write_video_label seeds frame 9", r.ok);

  // ---- preview (apply=false) writes nothing ------------------------
  const before = readFileSync(labelFile(imagePaths[0]), "utf8");
  r = await call("rename_class", {
    image_path: imagePaths[0], from: "knife", to: "blade", scope: "current", apply: false,
  });
  checkTrue("the preview answers", r.ok);
  if (r.ok) {
    check("the preview reports the annotations it would change", r.result.changed_annotations, 1);
    check("the preview reports the files it would change", r.result.changed_files, 1);
    check("the preview is not applied", r.result.applied, false);
  }
  check("the preview left the file alone", readFileSync(labelFile(imagePaths[0]), "utf8"), before);

  // ---- apply on the current document --------------------------------
  r = await call("rename_class", {
    image_path: imagePaths[0], from: "knife", to: "blade", scope: "current", apply: true,
  });
  checkTrue("the current-document rename answers", r.ok);
  if (r.ok) {
    check("the rename reports one annotation", r.result.changed_annotations, 1);
    check("the rename reports one file", r.result.changed_files, 1);
    check("the rename is applied", r.result.applied, true);
    check("the reply names the label path", r.result.current_label_path, labelFile(imagePaths[0]));
  }
  check("the renamed document carries the new class", typesOnDisk(imagePaths[0]), ["blade"]);
  check("the other image is untouched", typesOnDisk(imagePaths[1]), ["knife"]);
  check("the image of another class is untouched", typesOnDisk(imagePaths[2]), ["scissors"]);
  check("the video is untouched by a current-document rename", frameTypesOnDisk(videoPath), ["knife", "knife"]);

  // The reply carries the rewritten document, so the frontend can put it
  // into its in-memory state instead of saving the old name back.
  if (r.ok) {
    const doc = JSON.parse(r.result.current_content);
    check("the reply carries the rewritten document", (doc.infos || []).map((i) => i.type), ["blade"]);
  }

  // ---- a class that is not used changes nothing ---------------------
  const untouched = readFileSync(labelFile(imagePaths[2]), "utf8");
  r = await call("rename_class", {
    image_path: imagePaths[2], from: "battery", to: "cell", scope: "folder", apply: true,
  });
  checkTrue("the rename of an unused class answers", r.ok);
  if (r.ok) {
    check("an unused class changes no annotation", r.result.changed_annotations, 0);
    check("an unused class changes no file", r.result.changed_files, 0);
  }
  check("an unused class leaves the file byte-identical", readFileSync(labelFile(imagePaths[2]), "utf8"), untouched);

  // ---- folder-wide rename -------------------------------------------
  r = await call("rename_class", {
    image_path: imagePaths[1], from: "knife", to: "blade", scope: "folder", apply: false,
  });
  checkTrue("the folder preview answers", r.ok);
  if (r.ok) {
    // Image b holds a knife; image a was renamed already.
    check("the folder preview counts the remaining annotation", r.result.changed_annotations, 1);
    check("the folder preview counts the remaining file", r.result.changed_files, 1);
    check("the folder preview scans the label folder", r.result.scanned_files, 3);
  }
  check("the folder preview left the file alone", typesOnDisk(imagePaths[1]), ["knife"]);

  r = await call("rename_class", {
    image_path: imagePaths[1], from: "knife", to: "blade", scope: "folder", apply: true,
  });
  checkTrue("the folder rename answers", r.ok);
  if (r.ok) {
    check("the folder rename reports one annotation", r.result.changed_annotations, 1);
    check("the folder rename is applied", r.result.applied, true);
    check("the folder rename updated the curated list", r.result.curated_updated, true);
  }
  check("the renamed image carries the new class", typesOnDisk(imagePaths[1]), ["blade"]);
  check("the already-renamed image is unchanged", typesOnDisk(imagePaths[0]), ["blade"]);
  check("the image of another class is unchanged", typesOnDisk(imagePaths[2]), ["scissors"]);

  const curatedPath = path.join(imageDir, "classes.json");
  checkTrue("the curated list still exists", existsSync(curatedPath));
  if (existsSync(curatedPath)) {
    const curated = JSON.parse(readFileSync(curatedPath, "utf8"));
    check("the curated list carries the new class", curated.classes, ["blade", "scissors"]);
  }

  // ---- the class list follows the rename ---------------------------
  r = await call("scan_classes", { image_path: imageDir });
  checkTrue("scan_classes answers", r.ok);
  if (r.ok) {
    const names = (r.result.classes || []).map((c) => c.name);
    checkTrue("the class list no longer offers the old name", !names.includes("knife"));
    checkTrue("the class list offers the new name", names.includes("blade"));
  }

  // ---- a video document: every frame is renamed ---------------------
  r = await call("rename_class", {
    image_path: videoPath, from: "knife", to: "blade", scope: "current", apply: true,
  });
  checkTrue("the video rename answers", r.ok);
  if (r.ok) {
    // Both frames carry a knife.
    check("the video rename reports both frames", r.result.changed_annotations, 2);
  }
  r = await call("read_video_label", { path: videoPath, frame: 5 });
  check("frame 5 carries the new class", (JSON.parse(r.result.content).infos || []).map((i) => i.type), ["blade"]);
  r = await call("read_video_label", { path: videoPath, frame: 9 });
  check("frame 9 carries the new class", (JSON.parse(r.result.content).infos || []).map((i) => i.type), ["blade"]);
  // The per-frame sets must survive the rewrite.
  const videoDoc = JSON.parse(readFileSync(labelFile(videoPath), "utf8"));
  checkTrue("the video document still carries its per-frame sets", Array.isArray(videoDoc.frame_labels));
  check("the video document still lists both frames", (videoDoc.frame_labels || []).map((s) => s.frames), [[5], [9]]);

  // ---- the op rejects an empty name --------------------------------
  r = await call("rename_class", {
    image_path: imagePaths[0], from: "blade", to: "", scope: "current", apply: true,
  });
  check("an empty target name is rejected", r.ok, false);
  checkTrue("the rejection explains itself", typeof r.error === "string" && r.error.includes("rename_class"));

  child.stdin.end();
  await new Promise((r) => setTimeout(r, 300));
  child.kill();
  rmSync(root, { recursive: true, force: true });

  console.log(failures === 0 ? "\nALL CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
})().catch((err) => {
  console.error("[class-revision] the test crashed:", err);
  child.kill();
  rmSync(root, { recursive: true, force: true });
  process.exit(1);
});
