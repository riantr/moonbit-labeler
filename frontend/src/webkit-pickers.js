// Native folder / file pickers via the browser's own <input type="file">
// elements. Replaces the previous PowerShell `FolderBrowserDialog` /
// `OpenFileDialog` calls from the MoonBit backend, which required
// running `powershell.exe` on every pick. The Chromium-based CEF
// webview exposes file paths on the `File.path` property when running
// outside the strict sandbox, so the picked path round-trips straight
// to the caller — no temp file handoff needed.
//
// The dialog is shown by creating a hidden <input type="file"> and
// calling `.click()`. We listen for `change` (selection) and
// `cancel` (dismissed) and resolve a `{ path, cancelled }` shape
// matching the old `op_pick_folder` / `op_pick_file` reply so the
// call sites can switch with no shape changes.

function makeInput({ webkitdirectory = false, accept = "" } = {}) {
  const input = document.createElement("input");
  input.type = "file";
  // Keep the input off-screen but still click()-able.
  input.style.position = "fixed";
  input.style.left = "-9999px";
  input.style.top = "0";
  input.style.opacity = "0";
  if (webkitdirectory) {
    input.webkitdirectory = true;
  }
  if (accept) {
    input.accept = accept;
  }
  document.body.appendChild(input);
  return input;
}

/// Pull a usable filesystem path out of a `File`. Chromium used to
/// expose `File.path` for the file picker; CEF preserves that for
/// compatibility. As a defensive fallback we derive a path from
/// `webkitRelativePath` joined to a base directory passed in by the
/// caller (`basePath` argument).
function fileToPath(file, basePath) {
  if (file.path && file.path.length > 0) {
    return file.path;
  }
  const rel = file.webkitRelativePath || file.name;
  if (basePath && rel) {
    const sep = basePath.includes("\\") ? "\\" : "/";
    const trimmed = basePath.endsWith(sep)
      ? basePath
      : basePath + sep;
    return trimmed + rel;
  }
  return rel || "";
}

/// True when `p` looks like an absolute filesystem path on Windows
/// (i.e. starts with a drive letter) or on POSIX (i.e. starts with
/// the path separator). webkitdirectory picks on CEF 147 strip
/// `file.path` down to a relative folder name, so this is how we
/// detect "we got a usable absolute path" vs. "we need a fallback".
function isAbsolutePath(p) {
  if (!p) return false;
  if (/^[a-zA-Z]:[\\/]/.test(p)) return true;            // Windows: C:\ or D:/
  if (p.startsWith("/") || p.startsWith("\\\\")) return true; // POSIX / UNC
  return false;
}

/// Open the system folder picker. Resolves to `{ path, cancelled }`
/// where `path` is the chosen folder's absolute path (empty string
/// when cancelled).
///
/// Strategy:
///   1. Try `webkitdirectory` first (folder tree UX — user can
///      navigate a tree, not just drill into a file).
///   2. If the resulting path is absolute (Chromium / most browsers
///      populate `file.path` correctly), use it.
///   3. Otherwise (CEF 147 strips `file.path` in webkitdirectory
///      mode — we only get a bare folder name like "data"), fall
///      back to a single-file pick. CEF populates `file.path`
///      reliably for a single-file pick, so we strip the filename
///      to land on the absolute parent folder.
///
/// The fallback is one extra dialog tap for CEF users but keeps the
/// function semantically a "folder picker" (the answer is always a
/// folder, never a file).
export function pickFolder() {
  return new Promise((resolve) => {
    // `active` tracks whichever input is currently mounted: the
    // initial webkitdirectory input, or the single-file fallback
    // we open when webkitdirectory strips `file.path` (CEF 147).
    // The change / cancel / focus handlers all reference `active`
    // instead of capturing specific inputs in their closures, so
    // the cleanup logic doesn't have to be re-wired per dialog.
    let active = makeInput({ webkitdirectory: true });
    let done = false;
    const finish = (result) => {
      if (done) return;
      done = true;
      if (active.parentNode) active.parentNode.removeChild(active);
      window.removeEventListener("focus", onFocus);
      resolve(result);
    };
    const onFocus = () => {
      // CEF / WebKit2 may not fire a `cancel` event when the user
      // dismisses the dialog with Escape. Detect dismissal via the
      // window focus returning to us without a file selection.
      setTimeout(() => {
        if (done) return;
        if (!active.files || active.files.length === 0) {
          finish({ path: "", cancelled: true });
        }
      }, 600);
    };
    const onChange = () => {
      const f = active.files && active.files[0];
      if (!f) {
        finish({ path: "", cancelled: true });
        return;
      }
      const full = fileToPath(f, "");
      const sepIdx = Math.max(full.lastIndexOf("\\"), full.lastIndexOf("/"));
      const folder = sepIdx > 0 ? full.slice(0, sepIdx) : full;
      if (isAbsolutePath(folder)) {
        // Chromium path: webkitdirectory gave us an absolute path.
        finish({ path: folder, cancelled: false });
        return;
      }
      // CEF 147 path: webkitdirectory stripped `file.path`; the
      // folder is just a relative name. Swap in a single-file
      // input so we can recover the absolute parent directory.
      if (active.parentNode) active.parentNode.removeChild(active);
      active = makeInput({});
      active.addEventListener("change", onChange);
      active.addEventListener("cancel", () =>
        finish({ path: "", cancelled: true }),
      );
      window.addEventListener("focus", onFocus, { once: true });
      active.click();
    };
    active.addEventListener("change", onChange);
    active.addEventListener("cancel", () =>
      finish({ path: "", cancelled: true }),
    );
    window.addEventListener("focus", onFocus, { once: true });
    active.click();
  });
}

/// Open the system file picker. `accept` is an `accept` string
/// ("image/*", ".json", ...). Resolves to `{ path, cancelled }`.
export function pickFile(accept = "") {
  return new Promise((resolve) => {
    const input = makeInput({ accept });
    let done = false;
    const finish = (result) => {
      if (done) return;
      done = true;
      if (input.parentNode) input.parentNode.removeChild(input);
      window.removeEventListener("focus", onFocus);
      resolve(result);
    };
    const onFocus = () => {
      setTimeout(() => {
        if (done) return;
        if (!input.files || input.files.length === 0) {
          finish({ path: "", cancelled: true });
        }
      }, 600);
    };
    input.addEventListener("change", () => {
      const f = input.files && input.files[0];
      if (!f) {
        finish({ path: "", cancelled: true });
        return;
      }
      finish({ path: fileToPath(f, ""), cancelled: false });
    });
    input.addEventListener("cancel", () => {
      finish({ path: "", cancelled: true });
    });
    window.addEventListener("focus", onFocus, { once: true });
    input.click();
  });
}
