// video.js — video mode glue for MoonBit Labeler.
//
// Video = a sequence of static frames. We reuse the existing canvas /
// annotation / autosave stack by treating each frame as a tiny in-memory
// label document and handing each frame's document to the backend, which
// owns the on-disk schema.
//
// The on-disk schema is documented in doc/VIDEO_LABELING.md:
//
//   {
//     "img_name": "<video>.mp4",
//     "infos": [], "bindings": [], "frames": [],   // the default set
//     "frame_labels": [
//       { "frames": [12], "infos": [ ... ], "bindings": [ ... ] },
//       { "frames": [24, 25], "infos": [ ... ], "bindings": [ ... ] }
//     ]
//   }
//
// The backend (`read_video_label` / `write_video_label`) keeps one
// annotation set per frame (or per group of frames). That is the whole
// reason the merge lives there and not here: an earlier version of this
// file merged every frame's objects into one flat union before writing,
// so a box drawn on frame 5 silently reappeared on frame 9.
//
// Public API (used by main.js):
//   - createVideoController(deps) -> { selectVideo, selectFrame, ... }
//
// `deps` provides hooks into the main app:
//   - invokeLabeler(op, payload): IPC
//   - getState() / setState(patch): read/write main state
//   - renderAnnotations(): trigger a canvas redraw
//   - showEmptyHint(text), flashHint(msg, kind)
//   - setTimelineVisible(boolean)
//   - updateFrameReadout(frame, total, fps, coverage)
//   - onFrameLoaded({w, h}), markLabeled(path)
//
// main.js only needs to wire three things into its existing keyboard /
// file-list handlers:
//   - on item click  -> selectVideo(idx) instead of selectImage
//   - prev/next item -> support either media type
//   - keyboard ←/→   -> step frame when in video mode

import { serializeLabel } from "./label.js";

export function createVideoController(deps) {
  const {
    invokeLabeler,
    getState,
    setState,
    renderAnnotations,
    showEmptyHint,
    flashHint,
    setTimelineVisible,
    updateFrameReadout,
    onFrameLoaded,
  } = deps;

  let _frameLoadToken = 0;
  let _videoMetaCache = new Map(); // path -> { width, height, fps, frameCount, durationMs }

  /// Turn a backend failure code into something a user can act on. The
  /// backend speaks English and machine-readable codes; the UI speaks
  /// Chinese.
  function describeToolError(error, message) {
    if (error === "tool_not_found") {
      return (
        "未找到 ffmpeg/ffprobe。视频标注需要这两个工具：" +
        "请先安装 ffmpeg 并把它加入 PATH" +
        "（或设置 MOONBIT_LABELER_FFMPEG 环境变量指向可执行文件）。"
      );
    }
    if (error === "tool_failed") {
      return `ffmpeg 执行失败：${message || "未知错误"}`;
    }
    if (error === "bad_request") {
      return message || "请求无效";
    }
    return message || "未知错误";
  }

  /** Fetch ffprobe info for one video. Cached per-path. */
  async function getVideoMeta(path) {
    if (_videoMetaCache.has(path)) return _videoMetaCache.get(path);
    try {
      const reply = await invokeLabeler("read_video_info", { path });
      // The reply is the raw `ReadVideoInfoReply` struct: top-level
      // `{ width, height, fps, frame_count, codec, duration_ms, ok,
      // error, message }` — there is no `{ ok, result }` wrapper in CEF
      // mode. `ok` is false when ffprobe is missing or failed, and
      // `error` says which.
      const meta = {
        width: reply?.width || 0,
        height: reply?.height || 0,
        fps: reply?.fps || 0,
        frameCount: reply?.frame_count || reply?.frameCount || 0,
        durationMs: reply?.duration_ms || reply?.durationMs || 0,
        codec: reply?.codec || "",
        ok: reply?.ok === true,
        error: reply?.error || "",
        message: reply?.message || "",
      };
      _videoMetaCache.set(path, meta);
      return meta;
    } catch (err) {
      console.error("[video] read_video_info failed:", err);
      return {
        width: 0, height: 0, fps: 0, frameCount: 0, durationMs: 0,
        codec: "", ok: false, error: "tool_failed",
        message: String(err),
      };
    }
  }

  /** Select a video file and load frame 0 by default. */
  async function selectVideo(idx) {
    const st = getState();
    if (idx < 0 || idx >= st.videos.length) return;
    const item = st.videos[idx];
    // Persist whatever the previous video had pending before switching.
    await flushCurrentFrame();
    setState({
      currentVideoIdx: idx,
      currentVideo: item,
      currentFrame: 0,
      annotatedFrames: [],
    });
    setTimelineVisible(true);
    showEmptyHint("读取视频信息…");
    const meta = await getVideoMeta(item.path);
    setState({ videoMeta: meta });
    if (!meta.ok) {
      flashHint(describeToolError(meta.error, meta.message), "info");
    }
    await selectFrame(0);
  }

  /** Switch to a different frame within the currently selected video. */
  async function selectFrame(frame) {
    const st = getState();
    if (!st.currentVideo) return;
    const meta = st.videoMeta || (await getVideoMeta(st.currentVideo.path));
    const max = (meta.frameCount || 0) > 0 ? meta.frameCount - 1 : 0;
    const clamped = Math.max(0, Math.min(max, Math.floor(frame)));
    // Persist any pending edits for the current frame before switching.
    await flushCurrentFrame();
    setState({ currentFrame: clamped });
    await loadLabelForFrame(st.currentVideo, clamped);
    await loadAndShowFrame(st.currentVideo, clamped);
    updateCoverage();
  }

  /**
   * Read the annotation set that applies to `frame`. The backend owns the
   * projection, so the frontend never has to know how the on-disk
   * document is structured.
   */
  async function loadLabelForFrame(item, frame) {
    const st = getState();
    const token = ++_frameLoadToken;
    try {
      const reply = await invokeLabeler("read_video_label", {
        path: item.path,
        frame,
      });
      if (token !== _frameLoadToken) return; // a newer nav preempted us
      let label = { img_name: item.name, infos: [], bindings: [], frames: [frame] };
      if (reply?.content) {
        try {
          label = JSON.parse(reply.content);
        } catch (err) {
          console.error("[video] read_video_label returned bad JSON:", err);
        }
      }
      setState({
        label,
        loadedFromDisk: true,
        annotatedFrames: reply?.annotated_frames || [],
      });
      if (reply?.found) {
        st.labeledPaths.add(item.path);
      }
      renderAnnotations();
    } catch (err) {
      if (token !== _frameLoadToken) return;
      console.error("[video] read_video_label failed:", err);
      setState({
        label: { img_name: item.name, infos: [], bindings: [], frames: [frame] },
        loadedFromDisk: false,
      });
      renderAnnotations();
    }
  }

  /**
   * Read the JPEG bytes for a frame and render it into the existing
   * <img> element so the canvas overlay still lines up.
   */
  async function loadAndShowFrame(item, frame) {
    const token = ++_frameLoadToken;
    const st = getState();
    showEmptyHint("加载帧…");
    const els = st.els;
    try {
      const reply = await invokeLabeler("read_video_frame", {
        path: item.path,
        frame,
      });
      if (token !== _frameLoadToken) return;
      // The reply is the raw `ReadVideoFrameReply` struct: top-level
      // `{ base64, mime, width, height, ok, error, message }`. The op
      // reports a missing or broken ffmpeg through `ok`/`error` rather
      // than raising, so the UI can say something useful.
      if (!reply || reply.ok === false) {
        showEmptyHint(describeToolError(reply?.error, reply?.message));
        flashHint(describeToolError(reply?.error, reply?.message), "info");
        return;
      }
      if (!reply.base64) {
        showEmptyHint(`无法抽帧 #${frame}`);
        return;
      }
      const dataUrl = `data:${reply.mime};base64,${reply.base64}`;
      // Reuse the same onload path the image loader uses, so natural-size
      // measurement and layout reflow happen uniformly.
      els.image.hidden = false;
      els.image.onload = () => {
        const w = els.image.naturalWidth, h = els.image.naturalHeight;
        setState({ imgNatural: { w, h } });
        // The frame's <img> element renders the decoded video frame via
        // object-fit: contain inside the aspect-locked frame. The canvas
        // overlay is transparent except for annotations. Same wiring as
        // image-mode.
        onFrameLoaded?.({ w, h });
      };
      els.image.onerror = () => showEmptyHint(`第 ${frame} 帧加载失败`);
      els.image.src = dataUrl;
      // Update menubar zoom + frame readout.
      updateFrameReadout(frame, st.videoMeta?.frameCount || 0, st.videoMeta?.fps || 0);
    } catch (err) {
      if (token !== _frameLoadToken) return;
      console.error("[video] read_video_frame failed:", err);
      showEmptyHint(`抽帧失败: ${err}`);
    }
  }

  /**
   * Write the current frame's in-memory edits to disk. Only the current
   * frame is touched: the backend merges it into the document and leaves
   * every other frame's annotations exactly as they were.
   */
  async function flushCurrentFrame() {
    const st = getState();
    if (!st.currentVideo) return;
    if (!st.dirty) return;
    const frame = st.currentFrame;
    const content = await serializeLabel({
      img_name: st.label?.img_name || st.currentVideo.name,
      infos: st.label?.infos || [],
      bindings: st.label?.bindings || [],
      frames: [frame],
    });
    const reply = await invokeLabeler("write_video_label", {
      path: st.currentVideo.path,
      frame,
      content,
    });
    setState({ dirty: false });
    // Keep the annotated-frame list in step with what we just wrote.
    const annotated = Array.from(new Set([...(st.annotatedFrames || []), frame])).sort(
      (a, b) => a - b,
    );
    setState({ annotatedFrames: annotated });
    st.labeledPaths.add(st.currentVideo.path);
    if (deps.markLabeled) deps.markLabeled(st.currentVideo.path);
    updateCoverage();
    return reply;
  }

  /**
   * Save the current frame. The autosave path in main.js calls this.
   */
  async function flushSave() {
    await flushCurrentFrame();
  }

  /** Copy the current frame's annotations to the next frame. */
  async function copyFrameToNext() {
    const st = getState();
    if (!st.currentVideo) return;
    const cur = st.currentFrame;
    const next = cur + 1;
    const meta = st.videoMeta;
    if (meta?.frameCount && next >= meta.frameCount) {
      flashHint("已经到最后一帧了", "info");
      return;
    }
    const cur_lbl = st.label;
    if (!cur_lbl || (cur_lbl.infos || []).length === 0) {
      flashHint("当前帧没有可复制的标注", "info");
      return;
    }
    // The copy keeps the object ids, so a downstream consumer can still
    // follow one object across frames, but the two frames' point
    // coordinates are independent: editing one does not move the other.
    const content = await serializeLabel({
      img_name: cur_lbl.img_name || st.currentVideo.name,
      infos: structuredClone(cur_lbl.infos || []),
      bindings: structuredClone(cur_lbl.bindings || []),
      frames: [next],
    });
    await invokeLabeler("write_video_label", {
      path: st.currentVideo.path,
      frame: next,
      content,
    });
    const annotated = Array.from(new Set([...(st.annotatedFrames || []), next])).sort(
      (a, b) => a - b,
    );
    setState({ annotatedFrames: annotated });
    flashHint(`已复制第 ${cur} 帧标注到第 ${next} 帧`, "info");
    await selectFrame(next);
  }

  function updateCoverage() {
    const st = getState();
    if (!st.currentVideo) return;
    const n = (st.annotatedFrames || []).length;
    if (deps.updateFrameReadout) {
      deps.updateFrameReadout(
        st.currentFrame,
        st.videoMeta?.frameCount || 0,
        st.videoMeta?.fps || 0,
        n,
      );
    }
  }

  /** Step relative to the current frame. */
  async function stepFrame(delta) {
    const st = getState();
    if (!st.currentVideo) return;
    await selectFrame(st.currentFrame + delta);
  }

  /**
   * Re-read the current frame's annotation set from disk.
   *
   * The class-revision op rewrites the whole video document on disk;
   * the frontend only holds the *current frame's* set in memory, so
   * the frame has to be read back after such a rewrite. Nothing is
   * flushed here — the in-memory set is exactly what the rewrite just
   * replaced, so writing it back would undo the rename.
   */
  async function reloadCurrentFrame() {
    const st = getState();
    if (!st.currentVideo) return;
    await loadLabelForFrame(st.currentVideo, st.currentFrame);
  }

  return {
    selectVideo,
    selectFrame,
    stepFrame,
    copyFrameToNext,
    flushSave,
    flushCurrentFrame,
    reloadCurrentFrame,
    getVideoMeta,
    clearCache: () => _videoMetaCache.clear(),
  };
}
