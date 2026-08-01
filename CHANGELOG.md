# Changelog

Notable changes per release. Dates are the day the work landed.

Version numbers here track **what the toolchain can do**, not the pinned
versions of LLVM, Wine or the Windows SDK. When one of those breaks a
workaround, that is a fix and it gets its own entry — the workaround exists for
a specific version, and knowing which is the whole point of writing it down.

## 0.1.1 — 2026-08-01

### Added

- `packaging/publish-aur.sh` and `aur.yml`: the AUR package updates itself on a
  release tag, running the same script a maintainer runs by hand.
- `build-app.sh` clears a stale layout before assembling a new one, and refuses
  an `--out` inside `--project` or a non-empty directory that holds no
  `AppxManifest.xml`. A layout is the package's contents: whatever survives from
  an earlier build — an executable under a name the project no longer uses —
  ships with it.

### Fixed

- **`build-app.sh` generated the projection into `$out/.gen`, inside the
  layout.** makepri indexes what is under `/ProjectRoot`, so `resources.pri`
  described `App.g.h`, `module.g.cpp` and a winmd that were deleted seconds
  later. Everything generated now goes in the build directory beside the layout,
  which is where the objects and the precompiled header already were.
- **The documented order ran `fetch-sdk.sh` before `xwin`**, which is exactly
  what stops `fetch-sdk.sh` reading the C++/WinRT version out of the headers:
  the pin fell back to a hardcoded version every time, the case the version
  detection exists to prevent. README and CI now run xwin first, and the script
  says so when it has to guess.
- **`make lint` reported a shfmt _diff_ as "shfmt not installed" and exited 0**
  (`cmd -v shfmt && shfmt -d … || echo …`), so `make check` — which is what the
  PKGBUILD runs — passed on unformatted scripts.
- `packaging/publish-aur.sh` was the one bash file in the tree that nothing
  checked: no shellcheck, no shfmt, no syntax pass, no tests. All four now cover
  `packaging/*.sh`.
- Sources sharing a basename in different directories compiled to the same
  object, in parallel; the link took whichever finished last. Objects are named
  after the whole path now.
- A failed compile aborted at the first `wait`, hiding the other translation
  units' errors and leaving their compilers running. All of them are waited for,
  then the build stops with one message.
- `wine-tool.sh` checks that midlrt and makepri exist for `UWP_SDK_VERSION`, and
  lists the versions that are installed instead of leaving Wine to complain.
- `fetch-sdk.sh` keeps msiexec's output in a log and quotes it on failure — it
  was the only diagnosis available and went to `/dev/null` — and verifies that
  the extracted SDK is the version it was asked for.
- `build.sh` rejects a source file that does not exist, a flag with no value and
  a non-numeric `--jobs`, instead of passing `-I/path` to clang-cl as a file or
  failing on an unbound variable. Every script validates its flags the same way.
- `check-deps.sh` reports `python3`, which `fix-header-case.sh --canonical`
  needs, counts a missing MSXML6 as missing, and prints 7-Zip's version (it has
  no `--version`, so the field was blank).
- `gen-resources.sh` removes the temporary directory it creates for makepri's
  config.
- CI's uninstall check looked only for leftover files, and what `uninstall`
  removes is symlinks.
- `aur.yml` creates the private key file at 0600 rather than narrowing it after
  writing the key into it.

## 0.1.0 — 2026-08-01

The first version where the chain is complete: an `.idl` becomes a `.msix` a
console installs, with no Windows anywhere.

### Added

- `scripts/build.sh` — clang-cl and lld-link with the include and library paths
  xwin produces. `--uwp` links for the app container, `--pch` precompiles a
  header, `--jobs` compiles in parallel.
- `scripts/gen-projection.sh` — `.idl` → `.winmd` → `App.g.h`, `module.g.cpp`
  and the projection headers, via midlrt and cppwinrt under Wine.
- `scripts/gen-resources.sh` — a finished layout → `resources.pri`, via makepri.
- `scripts/build-app.sh` — all of the above: a project directory → a layout
  [openappx](https://github.com/gianlucamazza/openappx) can pack.
- `scripts/fetch-sdk.sh`, `scripts/wine-tool.sh`, `scripts/fix-header-case.sh`,
  `scripts/check-deps.sh`.
- `include/msvc-compat.h`, force-included before every translation unit: the two
  things MSVC arranges and clang does not. A source tree written for Visual
  Studio compiles unmodified, with no per-project shim.
- `build.sh -I DIR` for third-party headers, so a project with NuGet native
  dependencies needs no bespoke wrapper.
- `examples/hello-winrt` — a console program that drives real WinRT APIs.
- `examples/hello-uwp` — a UWP application in the shape that cross-compiles.
- `make install` / `make uninstall`, and `packaging/PKGBUILD` for Arch. The
  scripts install as a tree with `uwp-*` symlinks on PATH.

### Established

- **A UWP application built here installs on an Xbox One dev kit.** It has never
  been seen to run: the console refuses to launch every sideloaded package,
  Microsoft Edge included, with `0x8D160120`. That clears the cross-build of the
  failure without demonstrating anything positive — running remains untested.
- **`resources.pri` is not required to install.** Packaged with and without,
  both went on. makepri stays on by default because localised resources need the
  file at runtime — untestable while launching is.
- Precompiled headers turn ~30 s per translation unit into ~1 s. A rebuild of
  `hello-uwp` goes from 98 s to 1.3 s.
- **An existing project's UWP sources compile here unmodified** — a 3,700-line
  page built in code, an ONNX Runtime bridge, an `IAsyncAction` downloader —
  given its NuGet include directories.

### Fixed

- The scripts resolved `include/msvc-compat.h` and each other against
  `${BASH_SOURCE[0]}` without following symlinks, so anything on PATH pointed at
  the wrong directory and `build.sh` died. They could not have been packaged
  before this.
- `fix-header-case.sh --canonical` reads each header's namespace instead of
  capitalising filename segments, which produced `Applicationmodel` and silently
  aliased nothing usable. It now uses that namespace only to fix the file's own
  casing: otherwise `base.h` claims `Windows.Foundation.h`, because it
  forward-declares that namespace and sorts first, and the real header — the one
  holding `box_value` — never gets an alias. The symptom is a missing function.
- `fetch-sdk.sh` pins cppwinrt.exe to the version of the `winrt/` headers xwin
  installs. Taking the newest from NuGet fails every build on a `static_assert`.
- `wine-tool.sh` validates the tool name before looking for the SDK, so a typo
  does not read as "download 1.1 GB first".
