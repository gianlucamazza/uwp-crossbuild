# Changelog

Notable changes per release. Dates are the day the work landed.

Version numbers here track **what the toolchain can do**, not the pinned
versions of LLVM, Wine or the Windows SDK. When one of those breaks a
workaround, that is a fix and it gets its own entry — the workaround exists for
a specific version, and knowing which is the whole point of writing it down.

## 0.2.0 — 2026-08-01

An existing Visual Studio project builds here without being described a second
time: the `.vcxproj` is read, not reconstructed.

### Added

- **`scripts/read-vcxproj.py`** — enough MSBuild to say what a project builds:
  properties with conditions and `Exists()`, per-configuration
  `ItemDefinitionGroup`s, `%(Name)` continuations, `*` and `**` globs with
  `Exclude`, NuGet `.props` imports, `ProjectReference`, `DeploymentContent`.
  `--json` for all of it, `--field` for one line at a time, `--property` for
  MSBuild's `/p:` — which matters more than it looks, because a project switch
  can decide whether a `ProjectReference` exists at all.

  Conditions compare with `<`, `<=`, `>` and `>=` as MSBuild does — numerically,
  or as versions, because `10.0.17134.0` is not a number and a project gates real
  settings on it — and `and`/`or` short-circuit. That last one is not a nicety:
  the C++/WinRT package guards a comparison that has no answer with a string test
  beside it, and evaluating both sides refuses a project Microsoft ships and that
  builds. `$(MSBuildToolsVersion)` comes from the project's own `ToolsVersion`
  attribute, and `$(TargetPlatformVersion)` from its
  `WindowsTargetPlatformVersion`, as `Microsoft.Cpp.props` derives it — left
  empty, either one silently sends a version test down the wrong branch.

  A `.targets` is **not** evaluated, deliberately: MSBuild's own convention
  separates `.props`, which say what to compile, from `.targets`, which say what
  MSBuild should do about it — and this toolchain does none of what MSBuild does,
  it runs the SDK's tools itself. Every one skipped is listed under `skipped`
  and named on stderr, because what is not read has to be visible rather than
  assumed.

  **It refuses rather than guesses.** A compiler setting outside its mapping
  table, a property only Visual Studio supplies, a target that generates files:
  each stops the build by name. A build that silently differs from the one
  MSBuild produces is worse than no build — the difference does not surface
  until the link, or until the application misbehaves on a device.

  It also checks what nobody else does: that the executable the manifest starts
  is the one the project builds. They can drift apart, and the package installs
  either way and then refuses to launch — which reads as an application bug, not
  as a build that wrote its output under another name.

  First Python file in `scripts/`: 500 lines of evaluator do not belong in a
  heredoc. Installed and exposed as `uwp-read-vcxproj` like the rest.

- **`scripts/build-project.sh`** — a `.vcxproj` in, a package layout out.
  Restores the NuGet packages, builds every `ProjectReference` depth-first and
  once each, generates the projection from the project's own `.idl`, compiles,
  links, and copies each deployed file to the `TargetPath` the project gives it.
  `build-app.sh` is unchanged and remains the shorter road for a project in the
  shape of `examples/hello-uwp`.
- **`scripts/restore-nuget.sh`** — `packages.config` or `PackageReference` to
  `packages/<Id>.<Version>/`, the directory Visual Studio would create and the
  one a project's `<Import>` lines name. Until it has run, a project's include
  paths point at directories that are not there.
- **`build.sh --static-lib`** — archives objects with `llvm-lib` instead of
  linking an image, which is what a `ConfigurationType=StaticLibrary` project
  produces and what the application referencing it links against. Exclusive with
  `--uwp`: `/appcontainer` is a property of an image, and an archive is not one.
- `tests/fixtures/`, and 30-odd cases over them: every property of the evaluator,
  and every refusal, pinned by a fixture distilled from what real projects do.

### Fixed

- `msvc-compat.h` is force-included into every translation unit, C ones
  included, and it opened with `<version>` — a C++ header. A C source stopped on
  `fatal error: 'version' file not found`, blaming a file the project never
  included. Guarded by `__cplusplus`, verified both ways.
- The documented `xwin` invocation left a 424 MB `.xwin-cache` in whatever
  directory it was run from — the project being built, usually, or the checkout
  in CI. `--cache-dir` now points it at the same cache as everything else, and
  `.gitignore` covers the case where someone runs it without.
- **`--uwp` passes `/DNOGDI`.** `wingdi.h` declares `Polyline`, `Rectangle`,
  `Ellipse`, `Polygon` and `Path`; XAML has a class for each, and a page that
  draws shapes stopped on "reference to 'Polyline' is ambiguous", pointing at
  code that compiles in Visual Studio. It compiles there because those
  declarations are absent: `wingdi.h` puts them behind the desktop partition,
  which a UWP project excludes by compiling as the app family — the thing n°7
  explains why this cannot do. The app container has no GDI, so the only thing
  they can do here is collide.
- **`fetch-sdk.sh` handed msiexec a Unix path for the package**, while
  converting `TARGETDIR` properly — the one place here that gave a Windows tool
  anything but a Windows path. An administrative install copies the package into
  `TARGETDIR` by appending the path it was given, so it tried to create
  `TARGETDIR\layout/Installers/…`, failed on its first file with
  `ERROR_PATH_NOT_FOUND`, and rolled back — deleting `TARGETDIR`, so the next
  run began by finding nothing and looked like a fresh environment problem. The
  log kept by the entry above is what made it findable at all; `WINEDEBUG=+msi`
  named the path. Observed with Wine 11.14 and SDK 10.0.22621.

## 0.1.1 — 2026-08-01

### Added

- `packaging/publish-aur.sh` and `aur.yml`: the AUR package updates itself on a
  release tag, running the same script a maintainer runs by hand.
- `build-app.sh` clears a stale layout before assembling a new one, and refuses
  an `--out` inside `--project` or a non-empty directory holding neither an
  `AppxManifest.xml` nor the executable it is about to build. A layout is the
  package's contents: whatever survives from an earlier build — an executable
  under a name the project no longer uses — ships with it.
- **`build-app.sh --copy DIR`**, repeatable: the contents of DIR go into the
  layout. Precompiled third-party DLLs — a native NuGet package's
  `runtimes/win-x64/native` — are copied, not built, and until now the recipe
  said so while no script did it.
- **C and C++ compile in one pass.** `build.sh` gives a `.c` source `UWP_C_STD`
  (c17) and everything else `UWP_CXX_STD` (c++20), and applies the precompiled
  header only to the C++ ones; `build-app.sh` picks up `.c` files too. What made
  this impossible before was `msvc-compat.h`, force-included into every
  translation unit: it opens with `<version>`, and a C source stopped on `fatal
error: 'version' file not found`, blaming a file the project never included.
  That include is now guarded by `__cplusplus`.
- **`--help` on every script**, printing the comment block at the top of the
  file, which is the only documentation an installed `uwp-build` has. One
  description, so it cannot drift from the flags.
- The `full-build` job runs monthly as well as on request, and without the SDK
  cache. Every workaround here is tied to a version of LLVM, Wine, xwin or the
  SDK; nothing else notices when one of them moves — or when one is fixed and
  the workaround could go.

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
  config, and refuses an empty `resources.pri` — makepri can exit 0 having
  written one, and a package with it installs.
- **`curl` without `--fail` saved the server's error page as the download and
  exited 0.** A 404 from NuGet — the wrong C++/WinRT version, say — became a
  200-byte "package" that failed inside 7z, and an interrupted download stayed
  in the cache for every later run to reuse. `fetch-sdk.sh` downloads to a
  temporary name and renames on success; CI passes `--fail` for xwin and shfmt
  too.
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
  page built in code, a native inference library behind a C++/WinRT wrapper, an
  `IAsyncAction` downloader — given its NuGet include directories.

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
