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
  `backends/libui-windows` and `examples/hello-native`, whose `moon.pkg` link
  flags are MSVC-only (`/utf-8` plus a `-link /LIBPATH…` list of `.lib`s);
  `moon.pkg` cannot branch on the host OS, only on the output target, so on
  macOS/Linux clang reads those as file names and fails with
  `no such file or directory: '/utf-8'`. `bash scripts/test-local.sh` runs
  the whole local gate and picks the package list per host; the list comes from
  `scripts/ci-packages.sh`, the same one the `core` and `core-portability` jobs
  use. The third CI job (`macos-backend-link`) is the exception: it names
  `backends/libui-macos` and the five `examples/*-native-macos` executables
  explicitly and only links them (`moon test --build-only`, `moon build`) — never
  runs them, since each of those five waits for a human to close its window. Those
  six are exactly what `ci-packages.sh` excludes, so don't fold them into that
  list.

- The libui-ng backend is three packages, split so that the platform fork lives
  in C and in the link flags only: `backends/libui-common` (the shared MoonBit
  `ffi.mbt` + `backend.mbt` and the ABI header `adapter.h` — no C, no `link`),
  `backends/libui-windows` (Win32 `adapter.c`, libui-ng's vendored headers, the
  real-window tests, MSVC link), `backends/libui-macos` (Cocoa `adapter_macos.m`
  and its own link). Each platform's C includes `../libui-common/adapter.h`. A
  GTK3 backend goes into `backends/libui-linux` with the same shape and must not
  require any change on the MoonBit side. Both test packages link against
  libui-ng built fresh on that host, so neither is in the CI package lists.

- MoonBit supports snapshot testing; when changes affect outputs, run
  `moon test --update` to refresh snapshots (with the same package list).

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.
