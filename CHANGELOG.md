# Changelog

Notable changes per release. Dates are the day the work landed.

Version numbers here track **what the toolchain can do**, not the pinned
versions of LLVM, Wine or the Windows SDK. When one of those breaks a
workaround, that is a fix and it gets its own entry — the workaround exists for
a specific version, and knowing which is the whole point of writing it down.

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
- **xllama's own UWP sources compile here unmodified** — its 3,700-line
  `MainPage.cpp`, its ONNX Runtime bridge, its `IAsyncAction` downloader — given
  the NuGet include directories. Linking a whole application is still open:
  llama.cpp has to be built for this target first.

### Fixed

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
