# uwp-crossbuild

**Compile C++/WinRT for Windows, from Linux.** Companion to
[openappx](../openappx), which packages, signs and deploys the result.

> **Status: a full UWP application builds and packages.** `examples/hello-uwp`
> goes from `.idl` to a signed `.msix` without touching Windows: metadata,
> projection, an app-container PE and `resources.pri`. Not yet done: installing
> that package on a device, and xllama itself.

## Quick start

```bash
scripts/check-deps.sh                                  # what is missing, before downloading
scripts/fetch-sdk.sh                                   # SDK tools, ~1.1 GB, cached
xwin --accept-license --arch x86_64 splat --output ~/.cache/uwp-crossbuild/xwin
scripts/fix-header-case.sh ~/.cache/uwp-crossbuild/xwin/sdk/include/cppwinrt/winrt --canonical

# a console program, to check the toolchain end to end
scripts/build.sh --out hello.exe examples/hello-winrt/app.cpp
wine hello.exe
#   domain=example.com path=/path
#   vector size=3

# a real UWP application: idl -> winmd -> projection -> PE -> pri -> layout
scripts/build-app.sh --project examples/hello-uwp --out /tmp/hello-layout
```

## What works

| Step                          | Tool                              | Status                         |
| ----------------------------- | --------------------------------- | ------------------------------ |
| Compile + link C++/WinRT      | `clang-cl` + `lld-link`           | ✅ PE32+ that runs             |
| `.idl` → `.winmd`             | `midlrt.exe` under Wine           | ✅ valid metadata              |
| `.winmd` → projection headers | `cppwinrt.exe` under Wine         | ✅ `App.g.h`+`module.g.cpp`    |
| resources → `resources.pri`   | `makepri.exe` (32-bit) under Wine | ✅                             |
| App-container executable      | `lld-link /appcontainer`          | ✅ `DllCharacteristics` 0x1000 |
| Package, sign, deploy         | [openappx](../openappx)           | ✅ verified on an Xbox         |

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

Nothing from Microsoft is redistributed: both `fetch-sdk.sh` and `xwin` download
from Microsoft's CDN at run time under the SDK licence. CI must re-run them
rather than cache the result in an artefact store.

## Thirteen things that will waste your afternoon

Every one of these fails while pointing somewhere else. The scripts handle them;
this is the record of why they exist.

### Compiling

1. **`/std:c++17` cannot work.** C++/WinRT falls back to
   `<experimental/coroutine>`, whose first line is an `#error` refusing clang.
   Use `/std:c++20`, where `<coroutine>` is standard. _(Note for xllama: its
   vcxproj specifies `stdcpp17`.)_

2. **Projection header casing cannot be guessed.** `#include
<winrt/Windows.ApplicationModel.Activation.h>` meets a file named
   `windows.applicationmodel.activation.h`, and capitalising each segment gives
   `Applicationmodel`. `fix-header-case.sh --canonical` reads the namespace out
   of each header instead, where it is spelled correctly.

3. **`WindowsApp.lib` is not optional.** Without it the link fails on
   `WINRT_IMPL_CoInitializeEx` and friends, which reads like a broken toolchain
   rather than a missing library.

4. **`-mcx16`, or an undefined `__atomic_compare_exchange_16`.** MSVC assumes
   cmpxchg16b on x64; clang does not. C++/WinRT's factory cache needs it. The
   link error names no header and no source line.

5. **`#undef GetCurrentTime` after `<windows.h>`.** `winbase.h` defines it as a
   macro, XAML's `Timeline` declares a method by that name, and the projection
   header stops parsing. The error blames the header.

6. **`/DWINAPI_FAMILY=WINAPI_FAMILY_APP` breaks `<cstdlib>`.** The header
   partition hides `system` and `getenv` outside the desktop family while the
   MSVC STL still writes `using _CSTD system;` unconditionally. `--uwp`
   deliberately leaves it out; the app container is set at link time instead.

### The SDK tools

7. **midlrt shells out to `cl.exe`**, reporting `MIDL1005: cannot find C
preprocessor`. Pass `/no_cpp`; a normal UWP `.idl` has no directives.

8. **`WinRTBase.idl` vs `winrtbase.idl`.** Same file on NTFS, two files here.
   `fix-header-case.sh --lower` handles the include directories.

9. **MAX_PATH, silently.** A `.winmd` path over 260 characters arrives truncated
   — `...UniversalApiContract.w?` — and is rejected as "not a winmd". Nothing
   mentions length. Build from a short directory.

10. **`Windows.winmd` ships in its own MSI** (_Windows SDK Facade Windows WinMD
    Versioned_), separate from the tools and the contracts. Without
    `/metadata_dir` pointing at `UnionMetadata/`, midlrt fails with `MIDL4034`.

11. **midlrt's `/out` rejects a Unix path** with `MIDL1012: argument illegal for
switch`. `gen-projection.sh` runs it from the destination directory instead.
    Its lexer also refuses a backtick anywhere in the file, comments included:
    `MIDL2025: Illegal character (0x60)`.

12. **cppwinrt.exe and the `winrt/` headers must be the same version.** The
    generated projection carries a `static_assert` on it, so the newest NuGet
    against xwin's headers fails every build with "Mismatched C++/WinRT
    headers". `fetch-sdk.sh` reads the version out of `base.h`.

13. **makepri needs MSXML6, then only its 32-bit build survives.** Without MSXML:
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
examples/hello-winrt/        C++/WinRT console program that exercises real APIs
examples/hello-uwp/          a UWP application in the shape that cross-compiles
```

## Next

- **Install `hello-uwp` on a device.** It packs and signs; nothing yet proves a
  console accepts it.
- Then xllama itself, comparing the result against its official release with
  `openappx inspect`.
- Open question: is `resources.pri` actually required? Microsoft's own reference
  package does not carry one, and openappx's `resource-only` example installs
  without it. `build-app.sh --no-pri` exists to settle this on hardware.
