///|
/// Discovery for the external media tools the video ops shell out to.
///
/// The tools are **not** bundled with the application: `ffmpeg` and
/// `ffprobe` are installed separately (`winget install ffmpeg`,
/// `apt install ffmpeg`, `brew install ffmpeg`) and are expected on
/// `PATH`. This module exists so that "the binary is not installed"
/// surfaces as an actionable message instead of the raw spawn error
/// "The system cannot find the file specified", and so that a user with
/// a non-`PATH` install can point at it explicitly.
///
/// The search order is:
///
///   1. `MOONBIT_LABELER_FFMPEG` / `MOONBIT_LABELER_FFPROBE` — an explicit
///      path to the executable.
///   2. `MOONBIT_LABELER_FFMPEG_DIR` — a directory holding both binaries.
///   3. Well-known install directories.
///   4. The bare name, which the OS loader resolves through `PATH`.
///
/// Step 4 is checked by actually running the tool with `-version` rather
/// than by parsing `PATH`: the OS loader already searches `PATH` (and the
/// directory of the running executable) when a bare name is spawned, so
/// parsing `PATH` here would only duplicate it — and would have to
/// re-implement the Windows `PATHEXT` rules to do it correctly. The
/// version probe also proves the binary actually runs, instead of merely
/// existing.

///|
/// Environment variable holding an explicit path to the ffmpeg binary.
let env_ffmpeg : String = "MOONBIT_LABELER_FFMPEG"

///|
/// Environment variable holding an explicit path to the ffprobe binary.
let env_ffprobe : String = "MOONBIT_LABELER_FFPROBE"

///|
/// Environment variable holding a directory that contains both binaries.
let env_media_dir : String = "MOONBIT_LABELER_FFMPEG_DIR"

///|
/// The environment variable that can hold an explicit path for `tool`.
fn media_tool_env_var(tool : String) -> String {
  if tool == "ffprobe" {
    env_ffprobe
  } else {
    env_ffmpeg
  }
}

///|
/// Well-known directories that are probed when the tool is not on `PATH`.
///
/// Both the Windows and the POSIX spellings are listed on every platform,
/// so no OS sniffing is needed: a candidate that does not exist is simply
/// skipped. `C:\ffmpeg\bin` is a relative path on Linux and never exists
/// there; `/usr/bin` resolves under the current drive root on Windows and
/// does not exist either.
let media_tool_dirs : Array[String] = [
  "C:\\ffmpeg\\bin", "C:\\Program Files\\ffmpeg\\bin", "C:\\ProgramData\\chocolatey\\bin",
  "C:\\tools\\ffmpeg\\bin", "/usr/local/bin", "/usr/bin", "/opt/homebrew/bin", "/opt/local/bin",
  "/snap/bin",
]

///|
/// Cache of resolved tool paths, keyed by tool name. The value is the
/// executable to spawn, or the empty string when the tool was looked for
/// and not found — both answers are worth keeping, because a missing
/// ffmpeg is a stable fact about the machine, not a transient one.
let media_tool_cache : @ref.Ref[Map[String, String]] = @ref.new(Map([]))

///|
/// Check whether `tool` can be executed by its bare name, i.e. whether
/// the OS loader finds it on `PATH`.
async fn media_tool_runs(tool : String) -> Bool {
  let result = @process.run(tool, ["-version"], stdout=@process.Collect) catch {
    _ => return false
  }
  result.exit_code == 0
}

///|
/// Locate `tool` ("ffmpeg" or "ffprobe") on this machine. Returns the
/// executable to spawn, or `None` when the tool cannot be found.
async fn find_media_tool(tool : String) -> String? {
  match media_tool_cache.val.get(tool) {
    Some(path) => if path == "" { None } else { Some(path) }
    None => {
      let resolved = resolve_media_tool(tool)
      media_tool_cache.val.set(tool, resolved)
      if resolved == "" {
        None
      } else {
        Some(resolved)
      }
    }
  }
}

///|
/// The actual lookup behind `find_media_tool`, without the cache.
async fn resolve_media_tool(tool : String) -> String {
  // 1. An explicit override for this exact tool.
  match @env.get_env_var(media_tool_env_var(tool)) {
    Some(p) => {
      let p = p.trim().to_string()
      if p != "" && @fs.exists(p) {
        return p
      }
    }
    None => ()
  }
  // 2. An explicit directory holding both binaries.
  match @env.get_env_var(env_media_dir) {
    Some(d) => {
      let d = d.trim().to_string()
      if d != "" {
        for name in [tool, tool + ".exe"] {
          let full = d + @path.sep.to_string() + name
          if @fs.exists(full) {
            return full
          }
        }
      }
    }
    None => ()
  }
  // 3. Well-known install directories.
  for dir in media_tool_dirs {
    for name in [tool, tool + ".exe"] {
      let full = dir + @path.sep.to_string() + name
      if @fs.exists(full) {
        return full
      }
    }
  }
  // 4. Whatever the OS loader finds on `PATH`.
  if media_tool_runs(tool) {
    return tool
  }
  ""
}

///|
/// The message shown when a media tool cannot be found. It names the
/// tool, the environment variable that overrides the search, and the
/// usual install route, so the user can act on it without reading the
/// source.
fn media_tool_missing_message(tool : String) -> String {
  tool +
  " was not found. Install it (winget install ffmpeg / apt install ffmpeg / " +
  "brew install ffmpeg) and make sure it is on PATH, or point " +
  media_tool_env_var(tool) +
  " at the executable."
}

///|
/// The directory that holds extracted video frames.
///
/// One directory is created lazily and then reused, so a long session
/// does not leave a trail of temp folders behind. This replaces a
/// hard-coded `C:\Windows\Temp\...` path, which only existed on Windows
/// and needed write access to a system directory.
let video_frame_dir_cache : @ref.Ref[String?] = @ref.new(None)

///|
/// Get (creating it on first use) the directory that holds extracted
/// video frames.
async fn video_frame_dir() -> String {
  match video_frame_dir_cache.val {
    Some(d) => d
    None => {
      let d = @fs.tmpdir(prefix="moonbit-labeler-frames")
      video_frame_dir_cache.val = Some(d)
      d
    }
  }
}

///|
/// Counter used to give each extracted frame a unique file name, so two
/// overlapping frame requests cannot race on the same path.
let video_frame_counter : @ref.Ref[Int32] = @ref.new(0)

///|
/// Mint a fresh file name for an extracted frame.
fn next_video_frame_name() -> String {
  video_frame_counter.val = video_frame_counter.val + 1
  "frame-" + video_frame_counter.val.to_string() + ".jpg"
}
