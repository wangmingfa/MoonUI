/* MoonUI file shim (T189): the one place where "how a path is decoded"
   depends on the host OS.

   Why this file exists. On Windows the CRT's narrow-char file APIs
   (fopen / remove / rename) decode the path with the ANSI code page, so a
   UTF-8 path such as the lyrics file next to a CJK-titled song cannot be
   opened at all. The wide family (_wfopen / _wremove / _wrename) fixes that
   but only exists on Windows, and MoonBit's `extern "c"` declarations are
   shared by every native host: `moon.pkg`'s `options(targets:)` selects an
   output backend (native / llvm / wasm / ...), not the host OS. Declaring
   `_wfopen` in MoonBit would therefore fail to link on macOS. See
   docs/upstream-issue-moon-pkg-host-dim.md for the upstream side of this.

   C has the fork the MoonBit side lacks: one source, selected by `#ifdef`,
   compiled by whichever C compiler the host uses. This is the same trick
   moonbitlang/async uses for its fs package (watch_kqueue.c /
   watch_inotify.c / watch_windows.c live side by side in one package).

   Contract. Three symbols, signatures identical to the libc narrow versions
   (`const char *` in, `FILE *` / `int` out), so the MoonBit side only changes
   the symbol name and not a single byte of calling convention:
     moonui_fs_fopen  -> fopen
     moonui_fs_remove -> remove
     moonui_fs_rename -> rename
   POSIX forwards verbatim; Windows converts UTF-8 to UTF-16 first.

   A fourth symbol joins them for T303, because it needs the same host fork
   for the same reason (GetLongPathNameW exists only on Windows, and MoonBit
   extern declarations are shared across hosts):
     moonui_fs_long_path -> 8.3 short name to long name
   Caller supplies the output buffer; returns bytes written, 0 when the input
   does not need (or cannot get) an expansion, negative when the buffer is
   too small. POSIX copies the input verbatim - there is no 8.3 concept
   there, and a realpath() style normalisation would resolve /tmp on macOS
   to /private/tmp, which is a different contract.

   ASCII-only on purpose: this file is compiled by cl on Windows, which
   assumes the system code page for source text unless /utf-8 is passed, and
   native-stub compilation is not under our control here. The Chinese
   rationale lives in fs_native.mbt (header note) and TODO T189. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32

#include <windows.h>
#include <wchar.h>

/* UTF-8 -> UTF-16 for one path. Heap, not a static buffer: rename needs two
   live paths at once, and a static would also make concurrent file IO race.
   Returns NULL on invalid UTF-8 or allocation failure; every caller below
   turns that into the ordinary "cannot open" return value rather than a
   crash. */
static wchar_t *moonui_fs_wide(const char *utf8) {
  int n;
  wchar_t *w;
  if (utf8 == NULL) {
    return NULL;
  }
  /* MB_ERR_INVALID_CHARS: a malformed byte sequence must fail here instead
     of silently becoming U+FFFD in a filename. */
  n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
  if (n <= 0) {
    return NULL;
  }
  w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
  if (w == NULL) {
    return NULL;
  }
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, w, n) != n) {
    free(w);
    return NULL;
  }
  return w;
}

/* Mode strings are ours ("rb" / "wb"), pure ASCII, so a plain widening is
   enough and cannot fail on a representable character. */
FILE *moonui_fs_fopen(const char *path, const char *mode) {
  wchar_t wmode[8];
  wchar_t *wpath;
  FILE *f;
  size_t i;
  if (path == NULL || mode == NULL) {
    return NULL;
  }
  for (i = 0; i < sizeof(wmode) / sizeof(wmode[0]) - 1 && mode[i] != '\0'; i++) {
    wmode[i] = (wchar_t)(unsigned char)mode[i];
  }
  wmode[i] = L'\0';
  if (mode[i] != '\0') {
    return NULL;
  }
  wpath = moonui_fs_wide(path);
  if (wpath == NULL) {
    return NULL;
  }
  f = _wfopen(wpath, wmode);
  free(wpath);
  return f;
}

int moonui_fs_remove(const char *path) {
  wchar_t *wpath;
  int rc;
  if (path == NULL) {
    return -1;
  }
  wpath = moonui_fs_wide(path);
  if (wpath == NULL) {
    return -1;
  }
  rc = _wremove(wpath);
  free(wpath);
  return rc;
}

int moonui_fs_rename(const char *from, const char *to) {
  wchar_t *wfrom;
  wchar_t *wto;
  int rc;
  if (from == NULL || to == NULL) {
    return -1;
  }
  wfrom = moonui_fs_wide(from);
  if (wfrom == NULL) {
    return -1;
  }
  wto = moonui_fs_wide(to);
  if (wto == NULL) {
    free(wfrom);
    return -1;
  }
  rc = _wrename(wfrom, wto);
  free(wfrom);
  free(wto);
  return rc;
}

/* 8.3 short name -> long name (T303).

   Why this lives in Core's shim rather than in the Windows adapter: the
   caller is Fs::temp_dir(), which is Core's own path account and must work
   on every host. The adapter's copy (moonui_native_expand_long_path in
   backends/native-windows/adapter_native.c) serves a different caller - the
   file panel result - and carries an extra "expand the parent directory"
   fallback because a save dialog's target file need not exist yet.

   Here the input is a directory that already exists (the system temp dir),
   so GetLongPathNameW on the whole path is the only case. The trailing
   separator the caller appends is accepted by the API, but a host value
   ending in '\' can still fail on some builds, so retry once without it.
   Failure (0) is deliberate and not an error: the caller keeps its original
   string, so a temp dir that cannot be expanded is still a usable path. */
int moonui_fs_long_path(const char *utf8, char *out, int out_cap) {
  wchar_t *w;
  wchar_t *lp;
  DWORD need;
  int n;
  if (utf8 == NULL || out == NULL || out_cap <= 1) {
    return 0;
  }
  w = moonui_fs_wide(utf8);
  if (w == NULL) {
    return 0;
  }
  need = GetLongPathNameW(w, NULL, 0);
  if (need == 0) {
    size_t len = wcslen(w);
    while (len > 1 && (w[len - 1] == L'\\' || w[len - 1] == L'/')) {
      w[--len] = L'\0';
    }
    need = GetLongPathNameW(w, NULL, 0);
  }
  if (need == 0) {
    free(w);
    return 0;
  }
  lp = (wchar_t *)malloc((size_t)need * sizeof(wchar_t));
  if (lp == NULL) {
    free(w);
    return 0;
  }
  if (GetLongPathNameW(w, lp, need) == 0) {
    free(lp);
    free(w);
    return 0;
  }
  n = WideCharToMultiByte(CP_UTF8, 0, lp, -1, NULL, 0, NULL, NULL);
  if (n <= 0) {
    free(lp);
    free(w);
    return 0;
  }
  if (n > out_cap) {
    free(lp);
    free(w);
    return -n;
  }
  n = WideCharToMultiByte(CP_UTF8, 0, lp, -1, out, out_cap, NULL, NULL);
  free(lp);
  free(w);
  if (n <= 0) {
    return 0;
  }
  return n - 1;
}

#else /* POSIX: the narrow APIs already take UTF-8 byte strings. */

FILE *moonui_fs_fopen(const char *path, const char *mode) {
  return fopen(path, mode);
}

int moonui_fs_remove(const char *path) {
  return remove(path);
}

int moonui_fs_rename(const char *from, const char *to) {
  return rename(from, to);
}

/* No 8.3 names on POSIX, so the identity is the correct answer. Copied
   rather than "return 0" so both hosts mean the same thing by "bytes
   written": 0 is reserved for "cannot expand, keep your own string". */
int moonui_fs_long_path(const char *utf8, char *out, int out_cap) {
  size_t n;
  if (utf8 == NULL || out == NULL) {
    return 0;
  }
  n = strlen(utf8);
  if ((int)n + 1 > out_cap) {
    return -(int)n - 1;
  }
  memcpy(out, utf8, n + 1);
  return (int)n;
}

#endif
