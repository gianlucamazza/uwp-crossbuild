# uwp-crossbuild

**Compile C++/WinRT for Windows, from Linux.** Companion to
[openappx](https://github.com/gianlucamazza/openappx), which packages, signs and deploys the result.

> **Status: a real application built here installs on a console.** Not just the
> example — an existing UWP project of 216 translation units, a large
> third-party inference library among them, compiled and linked from its own
> `.vcxproj` files **without changing a line of its source**, then packed,
> signed and installed on an Xbox One dev kit.
> [docs/porting-a-vcxproj.md](docs/porting-a-vcxproj.md) is the recipe.
>
> Nothing built here has been seen to _run_, for a reason that is not about the
> build: see [Known limits](#known-limits).

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
xwin --accept-license --arch x86_64 splat --output ~/.cache/uwp-crossbuild/xwin
scripts/fix-header-case.sh ~/.cache/uwp-crossbuild/xwin/sdk/include/cppwinrt/winrt --canonical
scripts/fetch-sdk.sh                                   # SDK tools, ~1.1 GB, cached

# a console program, to check the toolchain end to end
scripts/build.sh --out hello.exe examples/hello-winrt/app.cpp
wine hello.exe
#   domain=example.com path=/path
#   vector size=3

# a real UWP application: idl -> winmd -> projection -> PE -> pri -> layout
scripts/build-app.sh --project examples/hello-uwp --out /tmp/hello-layout
```

## What works

| Step                          | Tool                                                  | Status                         |
| ----------------------------- | ----------------------------------------------------- | ------------------------------ |
| Compile + link C++/WinRT      | `clang-cl` + `lld-link`                               | ✅ PE32+ that runs             |
| `.idl` → `.winmd`             | `midlrt.exe` under Wine                               | ✅ valid metadata              |
| `.winmd` → projection headers | `cppwinrt.exe` under Wine                             | ✅ `App.g.h`+`module.g.cpp`    |
| resources → `resources.pri`   | `makepri.exe` (32-bit) under Wine                     | ✅ (optional — see below)      |
| App-container executable      | `lld-link /appcontainer`                              | ✅ `DllCharacteristics` 0x1000 |
| An unmodified VS source tree  | `include/msvc-compat.h`, force-included               | ✅ 216/216 of a real project   |
| Link a whole application      | `lld-link`                                            | ✅ 7.5 MB PE32+                |
| Package, sign, deploy         | [openappx](https://github.com/gianlucamazza/openappx) | ✅ installed on an Xbox        |

## Known limits

- **Never seen to run.** It installs; `/api/taskmanager/app` then answers
  `0x8D160120`. That turns out to be the console: it refuses to launch **every**
  sideloaded package, including Microsoft Edge as Microsoft signed and shipped
  it. So the failure says nothing about the cross-build — and equally, nothing
  here has ever been observed executing on a device. Treat running as untested,
  not as broken.
- **`resources.pri` turns out to be optional for install.** Packaged with and
  without it, both variants installed. Kept in `build-app.sh` by default because
  localised resources need it at runtime, which is not testable while launching
  is; `--no-pri` skips the step, and with it the only reason makepri exists here.
- **x64 only.** ARM64 has never been tried.
- **No `.xaml` files, ever.** The XAML compiler has no Linux equivalent and does
  not run under Wine. Build the UI in code, as `examples/hello-uwp` does.
- **The UWP API partition is not enforced at compile time.** A call to a
  desktop-only win32 API compiles and links cleanly here and surfaces only at
  certification or at runtime, because `/DWINAPI_FAMILY=WINAPI_FAMILY_APP` is
  deliberately left out — item 7 of
  [the list below](#fourteen-things-that-will-waste-your-afternoon) is why it
  cannot be on by default.
  The app container is applied at link time only; to audit a translation unit,
  pass the define yourself via `--`.
- **`build-app.sh` builds exactly one shape of project.** The idl must be named
  `app.idl`, sources are the top-level `*.cpp` of the project directory — no
  subdirectories, no `.c` — and the manifest is read with a `sed` regex, not an
  XML parser. Anything larger is driven by hand through `build.sh`, which is
  what [docs/porting-a-vcxproj.md](docs/porting-a-vcxproj.md) does; the missing
  `.vcxproj` reader is under [Next](#next).
- **One language standard per invocation.** `build.sh` passes a single `/std:`,
  so a project mixing C and C++ needs two passes — `/std:c17` for the C sources,
  `/std:c++20` for the rest — and the link at the end.
- **The PCH is ~190 MB** per project, in the object directory. It is rebuilt
  only when `pch.h` itself changes: editing a header it *includes* goes
  unnoticed, deliberately — everything below it is SDK-stable — and the remedy
  when that assumption fails is deleting the `.pch`.

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

## Fourteen things that will waste your afternoon

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
include/msvc-compat.h        force-included: what clang needs that MSVC assumes
Makefile                     install / uninstall / check
packaging/PKGBUILD           Arch package
packaging/publish-aur.sh     update and publish it, by hand or from CI
examples/hello-winrt/        C++/WinRT console program that exercises real APIs
examples/hello-uwp/          a UWP application in the shape that cross-compiles
tests/run-tests.sh           everything checkable without downloading the SDK
docs/porting-a-vcxproj.md    taking a real Visual Studio project through all of it
```

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
never touches. No `.winmd`, `.pri`, header or library from that download belongs
in a commit.

## Next

- **A `build-project.sh`** that reads a `.vcxproj` the way
  [docs/porting-a-vcxproj.md](docs/porting-a-vcxproj.md) does by hand. Nothing
  in that recipe is hard; it is just not automated, and the source list has to
  come from the project rather than from a person.
- **A device that can actually launch a sideloaded app.** This one cannot — not
  even Microsoft Edge — so nothing built here has been seen to run. That needs
  different hardware, not a different package.
- **ARM64**, if a target ever needs it.
