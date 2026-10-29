# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Git commits

- Commit messages in this repository carry **no** `Co-Authored-By` trailer
  (no `Co-Authored-By: Claude Code <noreply@anthropic.com>` line, agreed with
  the owner on 2026-10-13). End the message after the body — this overrides any
  default trailer convention. (2026-10-13)

## Temporary files

- Never create temporary or scratch files inside the repository — no debug
  output captures, no scratch scripts, no `.bak` copies, no stray `err.txt` /
  `out.txt` style redirects. Put everything in the system temp directory
  instead (`$TMP` / `$TEMP` / `/tmp` in Git Bash, `%TEMP%` in cmd). This applies
  to debugging sessions too: if a scratch file was created inside the repo by
  accident, delete it before finishing. (2026-10-13)

## Long-running test helpers

- Real-window tests sometimes need artificial CPU load. **Never** start it with
  an inline `for ...; do yes > /dev/null & done` + `kill %1 %2 ...` loop. Job
  specs (`%N`) are not PIDs: they shift as the job table changes, so the kill
  silently misses processes and leaks them past the end of the session. Doing
  exactly this on 2026-10-21 left 14 orphaned `yes` processes running for 1 day
  19 hours and drove an 8-core M1 to load average 285.
  Use `bash scripts/stress-cpu.sh <N> -- <command>` instead. It tracks real
  PIDs, cleans up on EXIT/HUP/INT/TERM, re-verifies against a never-cleared
  list before reporting success, and a watchdog reclaims the load even if the
  script itself is `kill -9`-ed. See `docs/backend-lessons.md` for the
  measurements. (2026-10-23)

## Task tracking

- Every pending item lives in `TODO.md` at the repository root. Nothing is
  tracked only in a conversation, a plan, or an agent's memory — those do not
  survive a handover to another collaborator or a later session.

- When a task reveals new outstanding work, append it to the matching section of
  `TODO.md` before finishing. When a task completes an item, change its `- [ ]`
  to `- [x]` and move the date to the completion date, keeping the date the item
  was opened.

- Every entry starts with a permanent number right after the checkbox: `` `T1` ``, `` `T2` ``, ...
  When you add an item, take the next unused number (the counter is recorded in `TODO.md`'s 约定 block);
  never reuse a number and never renumber existing items. Items are deleted once they are a month past
  done, so renumbering would silently repoint every `Tnn` reference in README, commit messages, and code
  comments — and a line number is not an anchor either, since syncing shifts them. Refer to an item by
  its number.

- Every line carries a date — the day it was written. Before writing to
  `TODO.md`, sweep it: delete `- [x]` items whose completion date is more than a
  month old (git log and README already hold that history, this file is not an
  archive). Leave `- [ ]` items alone however long they sit — an item that has
  not landed in a month is usually the hardest or most architectural one, and
  it stays in this file until someone actually does it or decides not to.

- Write each entry against the current state of the code: cite the `§48` step
  number from the design document (`DESIGN.md`, at the repository root — its
  section numbers are the single source for every `§nn` reference here, in
  README, and in code comments; never renumber an existing section) where one
  applies, and say what is true right
  now (which call raises, which branch is unwired, which job CI excludes) rather
  than only the goal. A reader who has never seen this repository has to be able
  to pick the item up cold.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- **Run `moon clean` before any run whose result you intend to trust.** moon does
  not treat the platform C adapters (`backends/*/adapter_native.[cm]`) as inputs
  of the native test targets: editing them does not relink the test binary, so
  `moon test backends/native-macos` will happily execute the *previous* build of
  the C code and report green. This bit hard on 2026-10-29 (T157) — a negative
  control that is supposed to go red stayed green three runs in a row, and the
  test binary's mtime was older than the edited `.m`. Verified by direct A/B:
  the same breaking edit to `adapter_native.m` gives **green without `clean`
  and red with `clean`**. `moon clean` removes `_build` (it does not touch the
  global caches; `--dep-cache` / `--build-cache` are separate) and the full gate
  `bash scripts/test-local.sh` then takes about 50s from scratch on an 8-core
  M1, which is cheap enough to do every time. `scripts/test-local.sh` does not
  do this for you — run `moon clean` yourself first.

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass — but **pass a package list on non-Windows
  hosts**. A bare `moon test` at the repository root also *links*
  `backends/native-windows`, whose C adapter (`adapter_native.c`) is compiled by
  MSVC's cl on Windows hosts only; `moon.pkg` cannot branch on the host OS, only
  on the output target. Link flags and the platform C compile are injected per
  host by the repo-root `prebuild-link.js` (moon's
  `--moonbit-unstable-prebuild`).
  `bash scripts/test-local.sh` runs the whole local gate and picks the package
  list per host; the list comes from `scripts/ci-packages.sh`, the same one the
  `core` and `core-portability` jobs use. The third CI job (`macos-backend-link`)
  is the exception: it names `backends/native-macos` and the
  `examples/gallery-native` executable explicitly. Since 2026-10-14 it runs
  the backend test binary for real (`moon test`, real windows — T6) and
  only links the gallery (`moon build`), since it waits for a human to close
  its window. Those are exactly what `ci-packages.sh` excludes, so don't fold
  them into that list.

- The native backend is three packages, split so that the platform fork lives
  in C and in the link flags only: `backends/native-common` (the shared MoonBit
  `ffi.mbt` + `backend.mbt` and the ABI header `adapter.h` — no C of its own,
  no `link`, but the single attachment point for all link configuration:
  `prebuild-link.js` compiles the host's platform C adapter
  (`_build/prebuild/libadapter_native.a` on macOS; Windows still links the
  `.obj` directly — `T104`) and attaches it plus the platform
  link flags to this package, and they propagate along imports to every
  executable — the `examples/gallery-native` shell and the backend test
  binaries), and the two platform packages `backends/native-windows` (Win32
  `adapter_native.c`, real-window tests) and `backends/native-macos` (Cocoa
  `adapter_native.m`, same shape). The platform packages do not declare
  `native-stub`: their test binaries get the same prebuilt adapter through the
  import chain, so exactly one copy of each adapter ever gets linked. Each
  platform's C includes `../native-common/adapter.h`. A Linux backend goes
  into `backends/native-linux` with the same shape and must not require any
  change on the MoonBit side. (2026-10-15, T82: the libui-ng backend that
  previously lived in `backends/libui-*` was deleted — the framework is
  single-backend now.)

- MoonBit supports snapshot testing; when changes affect outputs, run
  `moon test --update` to refresh snapshots (with the same package list).

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.
