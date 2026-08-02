# uwp-crossbuild

**Compile C++/WinRT for Windows, from Linux.** Companion to
[openappx](https://github.com/gianlucamazza/openappx), which packages, signs and deploys the result.

> **Status: what is built here runs on a console.** `examples/hello-uwp` has
> been launched and observed running on an Xbox Series S dev kit — and not just
> the example: an existing UWP project of 216 translation units, a large
> third-party inference library among them, compiled and linked from its own
> `.vcxproj` files **without changing a line of its source**, then packed,
> signed and installed on the same console.
> [docs/porting-a-vcxproj.md](docs/porting-a-vcxproj.md) is the recipe;
> [Known limits](#known-limits) is the honest edge (one console, one OS build).

## Install

```bash
yay -S uwp-crossbuild            # Arch, from the AUR
```

or from a checkout:

```bash
make install                    # into ~/.local; ~/.local/bin must be on PATH
sudo make install PREFIX=/usr   # system-wide
```

The scripts land under `$PREFIX/lib/uwp-crossbuild` and are exposed as
`uwp-build`, `uwp-build-app`, `uwp-check-deps` and so on. They are installed as
a tree rather than as loose files: `build.sh` reads `include/msvc-compat.h` from
beside itself. `make uninstall` removes everything.

Running from a checkout works too — every example below does — and needs no
installation at all.

## Quick start

```bash
scripts/check-deps.sh                                  # what is missing, before downloading
# xwin comes first: fetch-sdk.sh reads the C++/WinRT version out of the headers
# it installs, and pinning cppwinrt.exe to anything else fails every build.
# --cache-dir, or xwin leaves a 424 MB .xwin-cache in whatever directory you
# happened to be in — the project you are building, usually.
xwin --accept-license --arch x86_64 \
  --cache-dir ~/.cache/uwp-crossbuild/xwin-download \
  splat --output ~/.cache/uwp-crossbuild/xwin
scripts/fix-header-case.sh ~/.cache/uwp-crossbuild/xwin/sdk/include/cppwinrt/winrt --canonical
scripts/fetch-sdk.sh                                   # SDK tools, ~1.1 GB, cached

# a console program, to check the toolchain end to end
scripts/build.sh --out hello.exe examples/hello-winrt/app.cpp
wine hello.exe
#   domain=example.com path=/path
#   vector size=3

# a real UWP application: idl -> winmd -> projection -> PE -> pri -> layout
scripts/build-app.sh --project examples/hello-uwp --out /tmp/hello-layout

# an existing Visual Studio project, read rather than reconstructed
scripts/build-project.sh --project uwp/app.vcxproj --out /tmp/layout

# onto the console: packed, signed, installed, launched (openappx does the wire)
scripts/run-on-device.sh --layout /tmp/hello-layout
```

`run-on-device.sh` reads the device half of its configuration from
`~/.config/uwp-crossbuild/device-env` — `UWP_DEVICE_URL`, `UWP_DEVICE_USER` and
`OPENAPPX_DEVICE_PASSWORD`, as shown in Dev Home → Remote Access — and signs
with `~/.config/uwp-crossbuild/dev.pfx`, whose subject must equal the
manifest's `Publisher` and whose `.cer` the console must trust once
(`openappx deploy … --install-cert`). Neither file belongs in a repository.
It requires openappx **0.6.3 or newer** (`pipx install 'openappx>=0.6.3'`):
earlier releases build the launch request wrong and every start fails as an
opaque `0x8D160120`, so the script refuses them up front.

## What works

| Step                          | Tool                                                  | Status                         |
| ----------------------------- | ----------------------------------------------------- | ------------------------------ |
| Compile + link C++/WinRT      | `clang-cl` + `lld-link`                               | ✅ PE32+ that runs             |
| `.idl` → `.winmd`             | `midlrt.exe` under Wine                               | ✅ valid metadata              |
| `.winmd` → projection headers | `cppwinrt.exe` under Wine                             | ✅ `App.g.h`+`module.g.cpp`    |
| resources → `resources.pri`   | `makepri.exe` (32-bit) under Wine                     | ✅ (optional — see below)      |
| App-container executable      | `lld-link /appcontainer`                              | ✅ `DllCharacteristics` 0x1000 |
| An unmodified VS source tree  | `include/msvc-compat.h`, force-included               | ✅ 216/216 of a real project   |
| C and C++ in one project      | `build.sh`, one pass                                  | ✅ per-language standards      |
| Reading a `.vcxproj`          | `read-vcxproj.py`, an MSBuild subset                  | ✅ or a refusal, never a guess |
| ARM64                         | `--platform ARM64`, same pipeline                     | ✅ ARM64 PE — see Known limits |
| Link a whole application      | `lld-link`                                            | ✅ 7.5 MB PE32+                |
| Package, sign, deploy         | [openappx](https://github.com/gianlucamazza/openappx) | ✅ installed on an Xbox        |
| Launch, on the console        | `run-on-device.sh`, Device Portal                     | ✅ observed running (Series S) |

## Known limits

- **Runs, on one console.** `examples/hello-uwp`, built by `build-project.sh`
  and deployed by `run-on-device.sh`, has been launched and observed running on
  an Xbox Series S (OS 26100.8866) — process in the task list, text on the
  screen. The earlier record here said the console refused to launch _every_
  sideloaded package with `0x8D160120`, Microsoft Edge included; that turned
  out to be two bugs in openappx's Device Portal client (an AUMID built with a
  double underscore, and a missing `package` parameter), and it never said
  anything about the console or the packages. One console is not a matrix:
  other OS builds and devices remain untried.
- **`resources.pri` turns out to be optional for install.** Packaged with and
  without it, both variants installed. Kept in `build-app.sh` by default because
  localised resources need it at runtime, which is not testable while launching
  is; `--no-pri` skips the step, and with it the only reason makepri exists here.
- **ARM64 builds, and has never executed.** With the aarch64 libraries splatted
  (`xwin --arch x86_64 --arch aarch64 …`), `build-project.sh --platform ARM64`
  — or `UWP_TARGET=aarch64-pc-windows-msvc UWP_ARCH_DIR=aarch64` for the other
  scripts — produces an `IMAGE_FILE_MACHINE_ARM64` image with the app-container
  bit, through the same midlrt/cppwinrt/makepri pipeline. Verified by reading
  the PE header; per the first limit, no device has run it. Re-run
  `fix-header-case.sh --canonical` after any re-splat: xwin rewrites the
  cppwinrt headers and undoes the aliases.
- **No `.xaml` files, ever.** The XAML compiler has no Linux equivalent and does
  not run under Wine. Build the UI in code, as `examples/hello-uwp` does.
- **The PCH is ~190 MB** per project, in the object directory.

## Build times

Measured on this example (3 translation units, LLVM 22.1.8). The XAML projection
is what costs: every translation unit that includes it pays ~30 s.

|             | without `--pch` | with `--pch` |
| ----------- | --------------- | ------------ |
| first build | 98 s            | 41 s         |
| rebuild     | 98 s            | **1.3 s**    |

`build-app.sh` passes `--pch` whenever the project has a `pch.h`. The
precompiled header is ~190 MB and is reused until the header itself changes.

## Requirements

| Dependency                                    | Why                                        | Verified with |
| --------------------------------------------- | ------------------------------------------ | ------------- |
| `clang-cl`, `lld-link`                        | compiling and linking for the MSVC ABI     | LLVM 22.1.8   |
| `wine`                                        | running midlrt / makepri / cppwinrt        | 11.14         |
| `winetricks` → `msxml6`                       | makepri validates its schema through MSXML | 20260125      |
| [`xwin`](https://github.com/Jake-Shadle/xwin) | CRT and SDK headers/libraries              | 0.9.0         |
| `p7zip`, `curl`                               | unpacking the NuGet and SDK payloads       | —             |
| `python3`                                     | `fix-header-case.sh --canonical`           | 3.14          |

Nothing from Microsoft is redistributed: both `fetch-sdk.sh` and `xwin` download
from Microsoft's CDN at run time under the SDK licence. CI must re-run them
rather than cache the result in an artefact store.

## Environment

Every location, version and target the scripts assume can be overridden:

| Variable                   | Default                                   | What it changes                                               |
| -------------------------- | ----------------------------------------- | ------------------------------------------------------------- |
| `UWP_XWIN_ROOT`            | `~/.cache/uwp-crossbuild/xwin`            | where `xwin splat` put the CRT and SDK headers and libraries  |
| `UWP_SDK_ROOT`             | `~/.cache/uwp-crossbuild/sdk`             | where `fetch-sdk.sh` extracts the SDK tools and metadata      |
| `UWP_SDK_WORK`             | `~/.cache/uwp-crossbuild/work`            | the installer download and layout cache                       |
| `UWP_SDK_VERSION`          | `10.0.22621.0`                            | the version directory the tools and metadata live under       |
| `UWP_SDK_URL`              | Microsoft's fwlink for that SDK           | the web installer `fetch-sdk.sh` downloads                    |
| `UWP_CPPWINRT_VERSION`     | read from xwin's `base.h`                 | the cppwinrt.exe pin — must match the `winrt/` headers (n°13) |
| `UWP_CPPWINRT_EXE`         | `$UWP_SDK_ROOT/cppwinrt/bin/…`            | the cppwinrt.exe Wine runs (`CPPWINRT_EXE` still works)       |
| `UWP_TARGET`               | `x86_64-pc-windows-msvc`                  | clang's `-target`; `build-project.sh --platform` sets it      |
| `UWP_ARCH_DIR`             | `x86_64`                                  | the architecture subdirectory of the CRT and SDK libraries    |
| `UWP_CXX_STD`              | `c++20`                                   | `/std:` for C++ — c++17 cannot work (n°1)                     |
| `UWP_C_STD`                | `c17`                                     | `/std:` for `.c` sources                                      |
| `UWP_OBJ_DIR`              | `<out>.objs` (`<out>.build` for a layout) | objects, PCH and generated files                              |
| `UWP_NUGET_FEED`           | `https://www.nuget.org/api/v2/package`    | where `restore-nuget.sh` downloads from                       |
| `UWP_DEVICE_ENV`           | `~/.config/uwp-crossbuild/device-env`     | the file `run-on-device.sh` sources for the device variables  |
| `UWP_DEVICE_URL` / `_USER` | from that file                            | the Device Portal, as in Dev Home → Remote Access             |
| `UWP_DEVICE_PFX`           | `~/.config/uwp-crossbuild/dev.pfx`        | the signing certificate; subject must equal the Publisher     |

`OPENAPPX_DEVICE_PASSWORD` belongs to openappx and completes the device trio;
`wine-tool.sh` also honours `WINEDEBUG`, defaulting it to `-all`.

## Eighteen things that will waste your afternoon

Every one of these fails while pointing somewhere else. The scripts handle them;
this is the record of why they exist.

### Compiling

1. **`/std:c++17` cannot work.** C++/WinRT falls back to
   `<experimental/coroutine>`, whose first line is an `#error` refusing clang.
   Use `/std:c++20`, where `<coroutine>` is standard. A `.vcxproj` saying
   `<LanguageStandard>stdcpp17` has to be overridden, not honoured.

2. **Projection header casing cannot be guessed.** `#include
<winrt/Windows.ApplicationModel.Activation.h>` meets a file named
   `windows.applicationmodel.activation.h`, and capitalising each segment gives
   `Applicationmodel`. `fix-header-case.sh --canonical` reads the namespace out
   of each header instead, where it is spelled correctly — but only to fix
   _that_ file's own casing. Let a header claim any namespace it declares and
   `base.h`, which forward-declares half of them and sorts first, takes
   `Windows.Foundation.h` for itself. The real one holds `box_value`, so the
   symptom is a missing function.

3. **`WindowsApp.lib` is not optional.** Without it the link fails on
   `WINRT_IMPL_CoInitializeEx` and friends, which reads like a broken toolchain
   rather than a missing library.

4. **`-mcx16`, or an undefined `__atomic_compare_exchange_16`.** MSVC assumes
   cmpxchg16b on x64; clang does not. C++/WinRT's factory cache needs it. The
   link error names no header and no source line.

5. **`#undef GetCurrentTime` after `<windows.h>`.** `winbase.h` defines it as a
   macro, XAML's `Timeline` declares a method by that name, and the projection
   header stops parsing. The error blames the header.

6. **An STL header must precede `winrt/base.h`.** base.h enables coroutines with
   `#ifdef __cpp_lib_coroutine` _before_ including `<coroutine>`. Under MSVC the
   macro is already there from whichever STL header came first; a `pch.h`
   opening with `<windows.h>` leaves clang without it, and coroutine support
   compiles out silently. An ordinary `IAsyncAction` is then reported as "this
   function cannot be a coroutine", pointing at your code.

   Handled for you: `include/msvc-compat.h` is force-included ahead of every
   translation unit, so a source tree written for Visual Studio compiles
   unmodified. That is where this and `GetCurrentTime` live.

7. **`/DWINAPI_FAMILY=WINAPI_FAMILY_APP` breaks `<cstdlib>`.** The header
   partition hides `system` and `getenv` outside the desktop family while the
   MSVC STL still writes `using _CSTD system;` unconditionally. `--uwp`
   deliberately leaves it out; the app container is set at link time instead.

### The SDK tools

8. **midlrt shells out to `cl.exe`**, reporting `MIDL1005: cannot find C
preprocessor`. Pass `/no_cpp`; a normal UWP `.idl` has no directives.

9. **`WinRTBase.idl` vs `winrtbase.idl`.** Same file on NTFS, two files here.
   `fix-header-case.sh --lower` handles the include directories.

10. **MAX_PATH, silently.** A `.winmd` path over 260 characters arrives truncated
    — `...UniversalApiContract.w?` — and is rejected as "not a winmd". Nothing
    mentions length. Build from a short directory.

11. **`Windows.winmd` ships in its own MSI** (_Windows SDK Facade Windows WinMD
    Versioned_), separate from the tools and the contracts. Without
    `/metadata_dir` pointing at `UnionMetadata/`, midlrt fails with `MIDL4034`.

12. **midlrt's `/out` rejects a Unix path** with `MIDL1012: argument illegal for
switch`. `gen-projection.sh` runs it from the destination directory instead.
    Its lexer also refuses a backtick anywhere in the file, comments included:
    `MIDL2025: Illegal character (0x60)`.

13. **cppwinrt.exe and the `winrt/` headers must be the same version.** The
    generated projection carries a `static_assert` on it, so the newest NuGet
    against xwin's headers fails every build with "Mismatched C++/WinRT
    headers". `fetch-sdk.sh` reads the version out of `base.h`.

14. **makepri needs MSXML6, then only its 32-bit build survives.** Without MSXML:
    `PRI175: Initializing Indexer / Schema Validation Failed`. With it, the x64
    build page-faults inside MSXML while the x86 one works. Same `.pri` either
    way; `wine-tool.sh` picks the right one. It also reads the manifest strictly:
    a `--` inside an XML comment gets `PRI191: Appx manifest not found or is
invalid`, which is true — that is not legal XML — but says nothing about
    comments.

15. **GDI collides with every shape XAML draws.** `wingdi.h` declares
    `Polyline`, `Rectangle`, `Ellipse`, `Polygon` and `Path`; XAML has a class
    for each. A page that says `Polyline{}` after `using namespace
…Xaml::Shapes` stops on "reference to 'Polyline' is ambiguous", pointing at
    the application, which compiles in Visual Studio. It does because those
    declarations are simply absent there: `wingdi.h` puts them behind
    `WINAPI_FAMILY_PARTITION(WINAPI_PARTITION_DESKTOP)`, and a UWP project
    compiles as the app family — which n°7 explains why we cannot. `--uwp`
    passes `/DNOGDI` instead: the app container has no GDI, so the only thing
    those declarations can do here is collide.

16. **`msiexec /a` takes a Windows path for the package, not just for
    TARGETDIR.** An administrative install copies the package into TARGETDIR by
    appending the path it was given, so a Unix path sends it to
    `TARGETDIR\home\you\…`, which does not exist. It fails on its first file
    with `ERROR_PATH_NOT_FOUND`, then rolls back and deletes TARGETDIR — so the
    next attempt starts by finding nothing and reads as a broken Wine prefix.
    `WINEDEBUG=+msi,+file` is what shows the path it tried.

### Running on the console

17. **XAML wants its first Application access from the MTA.** `wWinMain` calls
    `winrt::init_apartment()` — the multi-threaded default — before
    `Application::Start`, and it is not a nicety: with no apartment, or with a
    single-threaded one, the factory call inside `Start` throws
    `winrt::hresult_wrong_thread`, nothing catches it, and the process dies in
    `terminate -> abort` before any window exists. The activation manager
    reports that as `0x8027025B`, which names nothing; the actual origination
    message — "The Application Object must initially be accessed from the
    multi-thread apartment" — surfaces only in a crash dump
    (`/api/debug/dump/usermode/crashcontrol`, then read the dump). The same
    source built by Visual Studio behaves identically; the difference is only
    who wrote the entry point. Observed on Xbox OS 26100.8866.

18. **`EncodePointer` lives in an apiset the app container does not have.**
    xwin's `kernel32.lib` imports `EncodePointer`/`DecodePointer` from
    `api-ms-win-core-util-l1-1-0.dll`; on the Xbox that apiset is absent, the
    loader fails the launch, and the Device Portal reports `0x80070002` "file
    not found" without saying which file. No application code is involved: the
    static CRT reaches for the pair in its `/O2` initialisation paths, so the
    same project can launch as a debug build and die as a release one. `--uwp`
    links `include/appcontainer-pointers.def` (as an import library, generated
    at build time) ahead of `kernel32.lib`, rerouting exactly those two names
    to `KERNELBASE.dll`, which exports them and is present in every
    app-container process.

## Layout

```
scripts/check-deps.sh        what is installed and what is not
scripts/fetch-sdk.sh         SDK tools + metadata, via the official installer under Wine
scripts/wine-tool.sh         midlrt / makepri / cppwinrt with the flags they need
scripts/fix-header-case.sh   case aliases for a case-sensitive filesystem
scripts/gen-projection.sh    .idl -> .winmd -> App.g.h + module.g.cpp + winrt/
scripts/gen-resources.sh     a layout -> resources.pri
scripts/build.sh             clang-cl + lld-link, with PCH and parallel compiles
scripts/build-app.sh         all of the above: a project directory -> a layout
scripts/read-vcxproj.py      a Visual Studio project -> what it builds, as JSON
scripts/restore-nuget.sh     packages.config -> packages/, from nuget.org
scripts/build-project.sh     a .vcxproj -> a layout, references and DLLs included
scripts/run-on-device.sh     a layout -> the console: packed, signed, installed, launched
scripts/common.sh            sourced by all of them: errors, downloads, layout rules
include/msvc-compat.h        force-included: what clang needs that MSVC assumes
include/appcontainer-pointers.def  EncodePointer/DecodePointer from KERNELBASE (n°18)
Makefile                     install / uninstall / check
packaging/PKGBUILD           Arch package
packaging/publish-aur.sh     update and publish it, by hand or from CI
examples/hello-winrt/        C++/WinRT console program that exercises real APIs
examples/hello-uwp/          a UWP application in the shape that cross-compiles
tests/run-tests.sh           everything checkable without downloading the SDK
docs/porting-a-vcxproj.md    taking a real Visual Studio project through all of it
```

Every script takes `--help` and prints its own usage; installed, that is
`uwp-build --help` and so on.

## Releasing

The CHANGELOG's newest version and `packaging/PKGBUILD`'s `pkgver` have to
agree — CI checks it — so both move in the same commit, before the tag:

```bash
# 1. CHANGELOG.md: close the section, date it
# 2. packaging/PKGBUILD: pkgver=0.1.1, then `makepkg --printsrcinfo > .SRCINFO`
git commit -am "Release 0.1.1"
git tag -a v0.1.1 -m "…" && git push origin main v0.1.1
```

`aur.yml` then updates the AUR package by running `packaging/publish-aur.sh`,
which is also the manual path:

```bash
packaging/publish-aur.sh --version 0.1.1 --dry-run   # build and check only
packaging/publish-aur.sh --version 0.1.1             # and push to the AUR
```

It rewrites `pkgver`, downloads the release tarball to compute its checksum,
regenerates `.SRCINFO` and builds the package with its tests before pushing, so
a hand-edited checksum can never describe a different tarball. That is also why
`sha256sums` reads `SKIP` in this repository between releases: the tarball for
the next version does not exist yet, a checksum kept from the previous one would
describe the wrong file, and the script refuses to publish while it still says
SKIP. The published AUR package always carries a real one. Only a local run
copies the result back into `packaging/`; after a tag-triggered publication the
files here stay as committed.

Without the `AUR_SSH_KEY` secret the workflow does a dry run instead of failing —
a release should not go red because a downstream package is not set up yet.

## Licensing

The scripts are MIT ([LICENSE](LICENSE)). **Nothing from Microsoft is
redistributed**: `fetch-sdk.sh` and `xwin` fetch the SDK and CRT from Microsoft's
CDN at run time, under the Windows SDK licence, into a cache this repository
never touches. `restore-nuget.sh` fetches NuGet packages from nuget.org the same
way, under their own licences. No `.winmd`, `.pri`, header, library or package
from any of those downloads belongs in a commit.

## Next

- **More of MSBuild, as projects need it.** `read-vcxproj.py` refuses what it
  cannot evaluate rather than guessing, so a project that stops it names exactly
  what is missing: a compiler setting with no entry in the mapping table, a
  property only Visual Studio supplies, a target that generates sources. Each is
  a table row and a fixture, not an investigation.
- **A second device.** Everything observed running has run on one Xbox Series S
  and one OS build. Another console — or another device family entirely — is
  what would turn two header-level verifications into real ones: the ARM64
  image, and whether the loader accepts what `makepri` writes at runtime.
