# Changelog

Notable changes per release. Dates are the day the work landed.

Version numbers here track **what the toolchain can do**, not the pinned
versions of LLVM, Wine or the Windows SDK. When one of those breaks a
workaround, that is a fix and it gets its own entry — the workaround exists for
a specific version, and knowing which is the whole point of writing it down.

## Unreleased

### Added

- **`/MD` works in the app container, through the store CRT.** The new
  `fetch-vclibs.sh` generates the import libraries modern MSVC no longer
  ships, out of the `Microsoft.VCLibs` framework appx itself (a file you
  point it at, or a download it refuses without an explicit
  `--accept-license`): export tables read with `llvm-readobj`, `.def`
  written, `.lib` generated with `llvm-dlltool`. With them in place the
  evaluator honours `MultiThreadedDLL` instead of overriding it, and
  `build.sh --store-crt` links the `*_app` set — `libcpmt.lib` last, for the
  STL's static helpers the VCLibs DLLs do not export — producing imports
  identical to a Visual Studio build's, per the recipe proven on hardware in
  issue #7. Without them the static override stands unchanged.
  `build-project.sh` refuses a store-CRT build whose manifest does not
  declare the `Microsoft.VCLibs.140.00` dependency, printing the element to
  paste, and `run-on-device.sh` warns after install when the device does not
  list a framework the manifest names — the Device Portal registers a
  package with unmet dependencies without complaint, and the loader then
  fails the launch as `0x80070002`, naming nothing. The gotcha list grows
  that entry and becomes "Twenty things".

- **Four settings the default Visual Studio template emits are now understood**
  instead of refused: `RuntimeTypeInfo` (`/GR`, `/GR-`), the Release linker's
  `OptimizeReferences`/`EnableCOMDATFolding` pair (`/opt:ref`, `/opt:icf` —
  lld-link implements both), and `GenerateWindowsMetadata`, where `false` is
  accepted as the truth it already is (the winmd comes from
  `gen-projection.sh`) and `true` is refused by name. The manual corpus of
  real projects remains the driver for further rows.
- **`build-app.sh` takes `--platform x64|ARM64`**, like `build-project.sh`
  already did. The platform table — which values can be built, what
  `UWP_TARGET`/`UWP_ARCH_DIR` each means — moves to `common.sh` so the two
  front doors cannot disagree about it. A `--platform` left at its default
  yields to `UWP_TARGET`/`UWP_ARCH_DIR` from the environment — the workflow
  that predates the flag — while one actually typed refuses an environment
  that contradicts it, naming both sides; a third architecture is one row
  there plus the dlltool machine case in `build.sh`.
- **A manifest whose `ProcessorArchitecture` is not the platform's is refused.**
  The manifest is copied into the layout verbatim, so a `--platform ARM64`
  build of an x64 manifest would ship its ARM64 executable under an identity
  still claiming x64, and nothing would say so until a device was asked to
  install it. Same shape as the executable cross-check: refuse and name the
  one-attribute fix, never rewrite the project's manifest. `neutral` and an
  absent attribute stay legal.

### Changed

- **The `/MD → /MT` app-container override is now tested, and is gotcha 19.**
  It is the one place `read-vcxproj.py` changes MSBuild's answer instead of
  mirroring or refusing it, and neither branch was covered: the evaluation
  fixture never set `AppContainerApplication`. The fixture now sets it — every
  Visual Studio UWP template does — and pins the override for both runtimes
  plus the passthrough via `--property AppContainerApplication=false`. The
  story behind it (no store CRT import libraries exist to link against;
  observed as 0x80270300) moves from a code comment into the README's gotcha
  list, which becomes "Nineteen things".
- **The default SDK version is pinned once, in `common.sh`.** It was three
  literal copies — `fetch-sdk.sh`, `gen-projection.sh`, `wine-tool.sh` — and
  fetch-sdk.sh *writes* the layout at that version while the other two *read*
  it back, so a copy that drifted would fail as "tool not found", naming
  neither copy. `UWP_SDK_VERSION` still overrides it everywhere; a test now
  holds the literal to one file.

### Fixed

- **Two citations still said `README, "Fourteen things"`** — the list has been
  "Eighteen things" since 0.3.0, and the number will keep moving. The comment
  in `read-vcxproj.py` and its twin in `tests/run-tests.sh` now cite the list
  by role ("the README's gotcha list") instead of by a count that rots.

## 0.4.0 — 2026-08-02

The day the toolchain's output was first observed _running_: hello-uwp, built
by `build-project.sh` and deployed by `run-on-device.sh`, launched on an Xbox
Series S (OS 26100.8866) — process in the task list, text on the screen. What
stood between the existing builds and that screen was never the compiler: two
Device Portal client bugs in openappx (fixed there: an AUMID built with a
double underscore, a missing `package` parameter), a missing
`winrt::init_apartment()` in the example (gotcha 17), and one absent apiset
(gotcha 18).

### Added

- **`scripts/run-on-device.sh`** — a layout onto the console, installed and
  launched: packs, signs, uninstalls the previous registration (a same-name
  Add otherwise fails with 0x80070057), installs, resolves the
  PackageFullName the device assigned, and starts the app. openappx does every
  wire operation; the machine-local half — device URL, user, password — lives
  in `~/.config/uwp-crossbuild/device-env` and is never committed, like the
  signing `dev.pfx` beside it.
- **`include/appcontainer-pointers.def`** — `EncodePointer`/`DecodePointer`
  rerouted to KERNELBASE.dll. xwin's `kernel32.lib` imports the pair from
  `api-ms-win-core-util-l1-1-0.dll`, which the Xbox app container does not
  provide; the loader then fails the launch as 0x80070002 without naming the
  file. The static CRT reaches for them in its /O2 paths, so a release build
  could die where the debug build launched. `--uwp` links the generated import
  library ahead of kernel32.lib (gotcha 18).

### Fixed

- **Harvested from PR #3**, a parallel review that had drifted eighteen
  releases behind main; re-derived against the current tree rather than
  merged, each with its test:
  - a value that is itself a flag is refused by every parser (`--out --uwp`
    wrote an executable named `--uwp`, without the app container);
  - the layout-clearing guards compare physical paths, in both directions —
    a project under `--out`, or reached through a symlinked parent, was
    deleted with the stale layout, sources and all;
  - object names carry a checksum of the source path (`src/util.cpp` and
    `src_util.cpp` met in one object, and a source named `pch.cpp` collided
    with the PCH's own);
  - `fix-header-case.sh --canonical` deletes only aliases of its own shape,
    not `--lower`'s nor a user's own symlinks;
  - a relative `gen-projection.sh --stubs` is resolved before the cd into
    `--out`; midlrt with no contract winmds dies naming the References
    directory instead of failing later on unresolved metadata;
  - `build-app.sh --jobs` and `--language` pass through to the tools that own
    them; `UWP_CPPWINRT_EXE` joins the prefix (`CPPWINRT_EXE` still works);
  - `make install`/`uninstall` quote every path, arrays that can be empty are
    expanded the way bash before 4.4 accepts, and the README gained an
    Environment table for every `UWP_*` override.

- **`examples/hello-uwp` initialises the MTA before `Application::Start`.**
  XAML requires the first access to the Application object to come from the
  multi-threaded apartment; without it the factory call throws
  `winrt::hresult_wrong_thread` into `terminate` before any window exists,
  reported by the activation manager only as 0x8027025B. The example's old
  comment claimed Start wanted no apartment at all — plausible, documented,
  and wrong; four symbolised crash dumps say otherwise (gotcha 17).
- **`run-on-device.sh` refuses openappx before 0.6.3** — the first release
  whose deploy builds the launch request right. Older ones fail every start as
  an opaque 0x8D160120; the script now says why and names the version, instead
  of letting the console take the blame again.

## 0.3.1 — 2026-08-02

0.3.0 never reached the AUR: its own tests stopped `makepkg check()` in the
publish chroot. The tag stands, the package starts here.

### Fixed

- **Usage errors no longer depend on what is installed.** `build.sh` checked
  for clang-cl before noticing that `--static-lib` and `--uwp` contradict each
  other; `restore-nuget.sh` demanded curl and 7z before reading a single
  argument. Found by the first machine that had neither: the AUR chroot, where
  `makepkg` runs the tests. Argument validation now comes first — the
  convention already said so — and the suite passes with clang-cl, llvm-lib
  and 7z all absent from `PATH`.

## 0.3.0 — 2026-08-02

The three gaps 0.2.0 left tracked, closed: the `.vcxproj` path is exercised in
CI, ARM64 has now been tried, and `resources.pri` is checked as a container
rather than as a byte count.

### Added

- **`examples/hello-uwp/hello-uwp.vcxproj`** — the same example in the shape
  Visual Studio keeps a project (#4). `build-app.sh` still reads the directory
  and ignores it; `build-project.sh` reads it, and the `full-build` workflow now
  builds both and validates both layouts. The tests pin the two forms to each
  other — a source listed in one and not the other builds two different
  applications under the same name.
- **ARM64** (#5). With the aarch64 libraries splatted, `build-project.sh
--platform ARM64` — or `UWP_TARGET`/`UWP_ARCH_DIR` for the other scripts —
  drives the same pipeline to an `IMAGE_FILE_MACHINE_ARM64` image with the
  app-container bit. Verified by reading the PE header on both examples; no
  device has run it, which the README's first Known limit already covers.
  `--platform` now also refuses what it cannot compile for: it selects the
  compiler target along with the MSBuild conditions, because answering only
  the conditions would build x64 objects under ARM64 settings without a word.

### Fixed

- **The winmd is named after the namespace the `.idl` declares, not after the
  `.idl` file.** `build-project.sh` used the file name; the manifest's
  `EntryPoint` is resolved against `<namespace>.winmd`, so an `app.idl`
  declaring `namespace hello` shipped an `app.winmd` the loader would never
  consult — a package that installs and fails to launch. Found by giving the
  in-repo example a `.vcxproj`: its `app.idl` is exactly that shape, and the
  corpus projects all happened to name the file after the namespace. An `.idl`
  declaring no namespace is refused before any SDK tool runs.
- **`resources.pri` is validated as a container, not as a byte count** (#6).
  The PRI format frames itself — `mrm_pri2` in the first and last 8 bytes, the
  total size declared at offset 0xc (SDK 10.0.22621 output) — so a truncated or
  unrecognisable file now stops `gen-resources.sh`, where before anything
  non-empty passed. Whether the _contents_ are right still needs a loader.

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

- **A UWP application built here installs on an Xbox Series S dev kit.** It has never
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
