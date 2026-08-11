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

/// Open the system folder picker. Resolves to `{ path, cancelled }`
/// where `path` is the chosen folder's absolute path (empty string
/// when cancelled).
export function pickFolder() {
  return new Promise((resolve) => {
    const input = makeInput({ webkitdirectory: true });
    let done = false;
    const finish = (result) => {
      if (done) return;
      done = true;
      if (input.parentNode) input.parentNode.removeChild(input);
      window.removeEventListener("focus", onFocus);
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
    input.addEventListener("change", () => {
      const f = input.files && input.files[0];
      if (!f) {
        finish({ path: "", cancelled: true });
        return;
      }
      // For webkitdirectory picks, the first file's `path` is a file
      // inside the chosen folder. Strip back to the directory.
      const full = fileToPath(f, "");
      const sepIdx = Math.max(full.lastIndexOf("\\"), full.lastIndexOf("/"));
      const folder = sepIdx > 0 ? full.slice(0, sepIdx) : full;
      finish({ path: folder, cancelled: false });
    });
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
