# uwp-crossbuild

**Compile C++/WinRT for Windows, from Linux.** Companion to
[openappx](../openappx), which packages, signs and deploys the result.

> **Status: it compiles and it runs.** A C++/WinRT program built here with
> clang-cl produces a PE32+ binary that executes and drives real WinRT APIs.
> The Windows-only SDK tools (midlrt, makepri, cppwinrt) run under Wine.
> Not yet done: a full UWP application, packaged and installed on a device.

## Quick start

```bash
scripts/check-deps.sh                                  # what is missing, before downloading
scripts/fetch-sdk.sh                                   # SDK tools, ~1.1 GB, cached
xwin --accept-license --arch x86_64 splat --output ~/.cache/uwp-crossbuild/xwin
scripts/fix-header-case.sh ~/.cache/uwp-crossbuild/xwin/sdk/include/cppwinrt/winrt --canonical

scripts/build.sh --out hello.exe examples/hello-winrt/app.cpp
wine hello.exe
#   domain=example.com path=/path
#   vector size=3
```

## What works

| Step                          | Tool                              | Status                 |
| ----------------------------- | --------------------------------- | ---------------------- |
| Compile + link C++/WinRT      | `clang-cl` + `lld-link`           | ✅ PE32+ that runs     |
| `.idl` → `.winmd`             | `midlrt.exe` under Wine           | ✅ valid metadata      |
| resources → `resources.pri`   | `makepri.exe` (32-bit) under Wine | ✅                     |
| `.winmd` → projection headers | `cppwinrt.exe` under Wine         | ✅ runs                |
| Package, sign, deploy         | [openappx](../openappx)           | ✅ verified on an Xbox |

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

## Eight things that will waste your afternoon

Every one of these fails while pointing somewhere else. The scripts handle them;
this is the record of why they exist.

### Compiling

1. **`/std:c++17` cannot work.** C++/WinRT falls back to
   `<experimental/coroutine>`, whose first line is an `#error` refusing clang.
   Use `/std:c++20`, where `<coroutine>` is standard. _(Note for xllama: its
   vcxproj specifies `stdcpp17`.)_

2. **Projection header casing.** `#include <winrt/Windows.Foundation.Collections.h>`
   meets a file named `windows.foundation.collections.h`. xwin fixes the main SDK
   but not these — `fix-header-case.sh --canonical` adds ~290 aliases.

3. **`WindowsApp.lib` is not optional.** Without it the link fails on
   `WINRT_IMPL_CoInitializeEx` and friends, which reads like a broken toolchain
   rather than a missing library.

### The SDK tools

4. **midlrt shells out to `cl.exe`**, reporting `MIDL1005: cannot find C
preprocessor`. Pass `/no_cpp`; a normal UWP `.idl` has no directives.

5. **`WinRTBase.idl` vs `winrtbase.idl`.** Same file on NTFS, two files here.
   `fix-header-case.sh --lower` handles the include directories.

6. **MAX_PATH, silently.** A `.winmd` path over 260 characters arrives truncated
   — `...UniversalApiContract.w?` — and is rejected as "not a winmd". Nothing
   mentions length. Build from a short directory.

7. **`Windows.winmd` ships in its own MSI** (_Windows SDK Facade Windows WinMD
   Versioned_), separate from the tools and the contracts. Without
   `/metadata_dir` pointing at `UnionMetadata/`, midlrt fails with `MIDL4034`.

8. **makepri needs MSXML6, then only its 32-bit build survives.** Without MSXML:
   `PRI175: Initializing Indexer / Schema Validation Failed`. With it, the x64
   build page-faults inside MSXML while the x86 one works. Same `.pri` either
   way; `wine-tool.sh` picks the right one.

## Layout

```
scripts/check-deps.sh        what is installed and what is not
scripts/fetch-sdk.sh         SDK tools + metadata, via the official installer under Wine
scripts/wine-tool.sh         midlrt / makepri / cppwinrt with the flags they need
scripts/fix-header-case.sh   case aliases for a case-sensitive filesystem
scripts/build.sh             clang-cl + lld-link with the right paths and settings
examples/hello-winrt/        C++/WinRT program that exercises real APIs
```

## Next

- A full UWP application: `.idl` → `.winmd` → projection headers → compile →
  `resources.pri` → `openappx pack | sign | deploy`, with **installation on a
  device** as the proof.
- Then xllama itself, comparing the result against its official release with
  `openappx inspect`.
- Open question: XAML-from-code apps derive from `Windows.UI.Xaml.Application`,
  which needs a `.winmd` describing the app class. That path works in isolation
  here but has not been driven end to end.
