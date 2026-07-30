// video.js — video mode glue for MoonBit Labeler.
//
// Video = a sequence of static frames. We reuse the existing canvas /
// annotation / autosave stack by treating each frame as a tiny in-memory
// label document and serializing the union back to disk on every save.
//
// The on-disk schema is documented in docs/VIDEO_LABELING.md:
//   {
//     "img_name": "<video>.mp4",
//     "frames": [<frame numbers this annotation set applies to>],
//     "infos":   [...],
//     "bindings":[...]
//   }
//
// Public API (used by main.js):
//   - createVideoController(deps) -> { on, ... }
//
// `deps` provides hooks into the main app:
//   - invokeLabeler(op, payload): IPC
//   - getState() / setState(patch): read/write main state
//   - renderAnnotations(): trigger a canvas redraw
//   - showEmptyHint(text), flashHint(msg, kind)
//   - setTimelineVisible(boolean)
//   - updateFrameReadout(frame, total, fps, coverage)
//
// main.js only needs to wire three things into its existing keyboard /
// file-list handlers:
//   - on item click  -> selectVideo(idx) instead of selectImage
//   - prev/next item -> support either media type
//   - keyboard ←/→   -> step frame when in video mode

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

  /** Fetch ffprobe info for one video. Cached per-path. */
  async function getVideoMeta(path) {
    if (_videoMetaCache.has(path)) return _videoMetaCache.get(path);
    try {
      const reply = await invokeLabeler("read_video_info", { path });
      const meta = {
        width: reply?.width || 0,
        height: reply?.height || 0,
        fps: reply?.fps || 0,
        frameCount: reply?.frame_count || reply?.frameCount || 0,
        durationMs: reply?.duration_ms || reply?.durationMs || 0,
        codec: reply?.codec || "",
        ok: !!reply?.ok,
      };
      _videoMetaCache.set(path, meta);
      return meta;
    } catch (err) {
      console.error("[video] read_video_info failed:", err);
      return { width: 0, height: 0, fps: 0, frameCount: 0, durationMs: 0, codec: "", ok: false };
    }
  }

  /** Build an empty per-frame label doc. */
  function emptyFrameLabel(frame) {
    return {
      img_name: getState().currentVideo?.name || "",
      infos: [],
      bindings: [],
      frames: [frame],
    };
  }

  /** Select a video file and load frame 0 by default. */
  async function selectVideo(idx) {
    const st = getState();
    if (idx < 0 || idx >= st.videos.length) return;
    if (st.dirty) {
      // Best-effort flush before swapping items. The caller should not
      // depend on this; the main selectImage path handles dirty flushes
      // too. We rely on the same autosave path.
    }
    const item = st.videos[idx];
    setState({
      currentVideoIdx: idx,
      currentVideo: item,
      currentFrame: 0,
      frameLabels: new Map(),
      diskJson: null,
    });
    setTimelineVisible(true);
    showEmptyHint("读取视频信息…");
    const meta = await getVideoMeta(item.path);
    if (!meta.ok) {
      flashHint(`无法读取视频元数据: ${item.name}`, "info");
    }
    setState({ videoMeta: meta });
    await loadLabelForFrame(item, 0);
    await loadAndShowFrame(item, 0);
  }

  /** Switch to a different frame within the currently selected video. */
  async function selectFrame(frame) {
    const st = getState();
    if (!st.currentVideo) return;
    const meta = st.videoMeta || (await getVideoMeta(st.currentVideo.path));
    if (!setState) return;
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
   * Read the per-frame label from the in-memory `frameLabels` cache or
   * the on-disk JSON. We keep the cache so multiple save()s within a
   * session don't drift the in-memory document.
   */
  async function loadLabelForFrame(item, frame) {
    const st = getState();
    if (st.frameLabels.has(frame)) {
      setState({ label: st.frameLabels.get(frame), loadedFromDisk: true });
      renderAnnotations();
      return;
    }
    // Read the on-disk JSON once for the whole video, then project to
    // this frame. Subsequent calls hit the in-memory cache.
    let disk = st.diskJson;
    if (!disk) {
      const token = ++_frameLoadToken;
      try {
        const reply = await invokeLabeler("read_label", { image_path: item.path });
        if (token !== _frameLoadToken) return; // a newer nav preempted us
        if (reply?.found && reply.content) {
          const { parseLabel, normalizeLabel } = await import("./label.js");
          const parsed = parseLabel(reply.content);
          disk = parsed
            ? normalizeLabel(parsed, item.name)
            : { img_name: item.name, infos: [], bindings: [], frames: [] };
        } else {
          disk = { img_name: item.name, infos: [], bindings: [], frames: [] };
        }
        setState({ diskJson: disk });
        if (reply?.found) {
          st.labeledPaths.add(item.path);
        }
      } catch (err) {
        if (token !== _frameLoadToken) return;
        console.error("[video] read_label failed:", err);
        disk = { img_name: item.name, infos: [], bindings: [], frames: [] };
        setState({ diskJson: disk });
      }
    }
    // Project the per-frame subset. The "applies to all frames" case is
    // represented by an empty `frames` array; we then show the same label
    // on every frame. (We could special-case this to also write it back
    // per-frame on save; for MVP we just always set frames = [frame] when
    // a user adds an annotation.)
    const frameSet = new Set(disk.frames || []);
    const appliesToAll = frameSet.size === 0;
    const isInScope = appliesToAll || frameSet.has(frame);
    const projected = {
      img_name: disk.img_name,
      infos: isInScope ? disk.infos : [],
      bindings: isInScope ? disk.bindings : [],
      frames: [frame],
    };
    st.frameLabels.set(frame, projected);
    setState({ label: projected, loadedFromDisk: true });
    renderAnnotations();
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
      const reply = await invokeLabeler("read_video_frame", { path: item.path, frame });
      if (token !== _frameLoadToken) return;
      if (!reply?.ok || !reply.base64) {
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
   * Persist the current frame's in-memory edits into the cache, and
   * update the coverage stat. Called from the main autosave path.
   */
  async function flushCurrentFrame() {
    const st = getState();
    if (!st.currentVideo) return;
    if (!st.dirty) return;
    const frame = st.currentFrame;
    const next = {
      img_name: st.label.img_name || st.currentVideo.name,
      infos: st.label.infos,
      bindings: st.label.bindings,
      frames: [frame],
    };
    st.frameLabels.set(frame, next);
    updateCoverage();
  }

  /**
   * Merge the per-frame cache back into a single on-disk document and
   * write it. Frame 0 in the cache is always preserved; we union the
   * remaining frames that the user has touched.
   */
  async function flushSave() {
    const st = getState();
    if (!st.currentVideo) return;
    await flushCurrentFrame();
    const framesTouched = Array.from(st.frameLabels.keys()).sort((a, b) => a - b);
    if (framesTouched.length === 0) return;
    // Merge: take the FIRST frame's infos as the seed (they are usually
    // identical across the video anyway), but keep `frames` as the union
    // of touched frames. We keep a simple, deterministic merge: each
    // frame's label is its own document; we union their `infos`/
    // `bindings` IDs, deduplicating by id. This way the same id used
    // across frames is preserved (track-friendly).
    const idSet = new Set();
    const mergedInfos = [];
    const mergedBindings = [];
    for (const f of framesTouched) {
      const lbl = st.frameLabels.get(f);
      if (!lbl) continue;
      for (const a of lbl.infos || []) {
        if (!idSet.has(a.id)) {
          idSet.add(a.id);
          mergedInfos.push(a);
        }
      }
      for (const b of lbl.bindings || []) {
        if (!idSet.has(b.id)) {
          idSet.add(b.id);
          mergedBindings.push(b);
        }
      }
    }
    const { serializeLabel } = await import("./label.js");
    const out = {
      img_name: st.currentVideo.name,
      frames: framesTouched,
      infos: mergedInfos,
      bindings: mergedBindings,
    };
    const content = serializeLabel(out);
    await invokeLabeler("write_label", {
      image_path: st.currentVideo.path,
      content,
    });
    // Update diskJson to the freshly-saved form so the next dirty check
    // can compare against it.
    setState({ diskJson: structuredClone(out), dirty: false });
    st.labeledPaths.add(st.currentVideo.path);
    if (deps.markLabeled) deps.markLabeled(st.currentVideo.path);
  }

  /** Copy the current frame's annotations to the next frame. */
  function copyFrameToNext() {
    const st = getState();
    if (!st.currentVideo) return;
    const cur = st.currentFrame;
    const next = cur + 1;
    const meta = st.videoMeta;
    if (meta?.frameCount && next >= meta.frameCount) {
      flashHint("已经到最后一帧了", "info");
      return;
    }
    const cur_lbl = st.frameLabels.get(cur) || st.label;
    if (!cur_lbl || (cur_lbl.infos || []).length === 0) {
      flashHint("当前帧没有可复制的标注", "info");
      return;
    }
    // Deep-clone the per-frame label so the same IDs land on the next
    // frame. Using structuredClone keeps the ID stable, which is what
    // track-aware consumers want.
    const cloned = structuredClone({
      ...cur_lbl,
      frames: [next],
    });
    st.frameLabels.set(next, cloned);
    setState({ dirty: true });
    updateCoverage();
    flashHint(`已复制第 ${cur} 帧标注到第 ${next} 帧`, "info");
  }

  function updateCoverage() {
    const st = getState();
    if (!st.currentVideo) return;
    const n = st.frameLabels.size;
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

  return {
    selectVideo,
    selectFrame,
    stepFrame,
    copyFrameToNext,
    flushSave,
    flushCurrentFrame,
    getVideoMeta,
    clearCache: () => _videoMetaCache.clear(),
  };
}
