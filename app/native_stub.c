// Stub for moonbitlang/x@0.4.43 missing native implementation.
// `sys/internal/ffi/sys_native.mbt` declares:
//
//     fn internal_get_cli_args() -> FixedArray[Bytes] = "$moonbit.get_cli_args"
//
// which lowers to a C ABI call for `moonbit_get_cli_args` (return
// `moonbit_bytes_t *` — a ref array of moonbit_bytes_t).  The x package's
// `native_stub.c` does not implement this symbol, so on native targets the
// link step fails with LNK2019.  This file provides the missing definition
// for Windows and POSIX.
//
// Implementation: read process command line at runtime (Windows:
// CommandLineToArgvW + WideCharToMultiByte for proper UTF-8; POSIX:
// argv) and wrap each arg in a moonbit_bytes_t via moonbit_make_bytes.

#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#pragma comment(lib, "shell32.lib")
#else
#include <unistd.h>
extern char **environ;
#endif

// Build one moonbit_bytes_t holding a UTF-8 copy of the arg.
static moonbit_bytes_t arg_to_mb_bytes(const char *s) {
  if (s == NULL) {
    return moonbit_make_bytes(0, 0);
  }
  size_t n = strlen(s);
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)n, 0);
  if (n > 0) {
    memcpy(b, s, n);
  }
  return b;
}

MOONBIT_EXPORT moonbit_bytes_t *moonbit_get_cli_args(void) {
#ifdef _WIN32
  int argc = 0;
  LPWSTR *wargv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (wargv == NULL || argc <= 0) {
    if (wargv) {
      LocalFree(wargv);
    }
    return (moonbit_bytes_t *)moonbit_make_ref_array(0, NULL);
  }
  moonbit_bytes_t *out =
      (moonbit_bytes_t *)moonbit_make_ref_array(argc, NULL);
  for (int i = 0; i < argc; i++) {
    if (wargv[i] == NULL) {
      out[i] = moonbit_make_bytes(0, 0);
      continue;
    }
    int needed =
        WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, NULL, 0, NULL, NULL);
    if (needed <= 0) {
      out[i] = moonbit_make_bytes(0, 0);
      continue;
    }
    char *utf8 = (char *)malloc((size_t)needed);
    WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, utf8, needed, NULL, NULL);
    size_t len = (size_t)needed - 1;  // drop trailing NUL
    moonbit_bytes_t b = moonbit_make_bytes((int32_t)len, 0);
    if (len > 0) {
      memcpy(b, utf8, len);
    }
    free(utf8);
    out[i] = b;
  }
  LocalFree(wargv);
  return out;
#else
  // POSIX: use the standard argv captured at process start.
  extern char **__argv;
  int argc = 0;
  while (__argv != NULL && __argv[argc] != NULL) {
    argc++;
  }
  moonbit_bytes_t *out =
      (moonbit_bytes_t *)moonbit_make_ref_array(argc, NULL);
  for (int i = 0; i < argc; i++) {
    out[i] = arg_to_mb_bytes(__argv != NULL ? __argv[i] : NULL);
  }
  return out;
#endif
}
