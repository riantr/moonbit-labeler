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
    console.log("[fileToPath] using file.path =", file.path);
    return file.path;
  }
  const rel = file.webkitRelativePath || file.name;
  console.log("[fileToPath] file.path empty; using rel =", rel,
              " basePath =", basePath);
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

/// Open a dialog that lets the user pick a folder (via the
/// file-picker trick: pick any file inside the target folder, we
/// derive the parent directory), then resolves to `{ path, cancelled }`
/// where `path` is the chosen folder's absolute path (empty string
/// when cancelled).
///
/// `accept` is the file picker filter:
///   - `"image/*"` (the default) — the "Open Image" menu item. The
///     dialog only shows image files, so the user can navigate to
///     any image inside their target folder and confirm.
///   - `""` — the "Open Folder" menu item. No filter, so the user
///     can pick any file in the target folder (useful when the
///     folder is empty, has no images yet, or contains sub-folders
///     you want to drill into).
///
/// Strategy (revised for CEF 150 — the 0.1.12 webkitdirectory tree
/// picker still strips `File.path` down to a bare folder name, so we
/// cannot recover an absolute path from the directory pick itself):
///   1. Open a regular file picker (`<input type=file">` with the
///      requested accept filter).
///   2. User picks any file *inside* the folder they want to load.
///   3. CEF populates `File.path` with the absolute file path.
///   4. We strip the filename to land on the absolute parent
///      directory and return that.
///
/// The UX is "pick a file in your folder" — clear and works in one
/// step on every CEF version we ship. The downstream caller
/// (`browseFolder()` in main.js) fills the absolute path into the
/// top-right text input and dispatches the form submit.
export function pickFolder(accept = "image/*") {
  return new Promise((resolve) => {
    const input = makeInput({ accept });
    let done = false;
    const finish = (result) => {
      if (done) return;
      done = true;
      if (input.parentNode) input.parentNode.removeChild(input);
      window.removeEventListener("focus", onFocus);
      console.log("[pickFolder] result:", JSON.stringify(result));
      resolve(result);
    };
    const onFocus = () => {
      // CEF / WebKit2 may not fire a `cancel` event when the user
      // dismisses the dialog with Escape. Detect dismissal via the
      // window focus returning to us without a file selection.
      setTimeout(() => {
        if (done) return;
        if (!input.files || input.files.length === 0) {
          finish({ path: "", cancelled: true });
        }
      }, 600);
    };
    const onChange = () => {
      const f = input.files && input.files[0];
      console.log("[pickFolder] onChange: input.files.length=",
                  input.files ? input.files.length : 0,
                  " first file:",
                  f ? { name: f.name, path: f.path,
                        rel: f.webkitRelativePath } : null);
      if (!f) {
        finish({ path: "", cancelled: true });
        return;
      }
      const full = fileToPath(f, "");
      if (!isAbsolutePath(full)) {
        // Defensive: the file picker should always give us an
        // absolute path on CEF 150, but if some future CEF change
        // strips it, surface a clear error rather than a relative
        // name in the input.
        finish({ path: "", cancelled: false });
        return;
      }
      const sepIdx = Math.max(full.lastIndexOf("\\"), full.lastIndexOf("/"));
      const folder = sepIdx > 0 ? full.slice(0, sepIdx) : full;
      console.log("[pickFolder] derived folder:", folder);
      finish({ path: folder, cancelled: false });
    };
    input.addEventListener("change", onChange);
    input.addEventListener("cancel", () => {
      finish({ path: "", cancelled: true });
    });
    window.addEventListener("focus", onFocus, { once: true });
    input.click();
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
