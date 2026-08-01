# uwp-crossbuild

**Build UWP applications from Linux.** Companion to
[openappx](../openappx), which packages and signs them.

> **Status: feasibility established, build not yet implemented.** The four
> Windows-only tools a UWP build needs have been made to run on Linux under Wine,
> and both generate correct output. Compiling with clang-cl is next.

## What works today

| Tool           | Purpose                       | Status                            |
| -------------- | ----------------------------- | --------------------------------- |
| `midlrt.exe`   | `.idl` → `.winmd` metadata    | ✅ produces a valid 2.5 KB winmd  |
| `makepri.exe`  | resources → `resources.pri`   | ✅ **32-bit build only**          |
| `cppwinrt.exe` | `.winmd` → projection headers | ✅ runs                           |
| `makeappx.exe` | package the layout            | ✅ runs — but use `openappx pack` |

```bash
scripts/fetch-sdk.sh                       # ~1.1 GB from Microsoft's CDN, cached
scripts/wine-tool.sh midlrt  /winmd App.winmd App.idl
scripts/wine-tool.sh makepri new /pr . /cf priconfig.xml /of resources.pri /o
```

## Five things that will waste your afternoon

Each of these fails in a way that points somewhere else entirely. They are all
handled by `scripts/wine-tool.sh`; this is the record of why.

1. **midlrt shells out to `cl.exe`.** It reports `MIDL1005: cannot find C
preprocessor`. Pass `/no_cpp` — a normal UWP `.idl` has no preprocessor
   directives, so nothing is lost.

2. **Filename casing.** midlrt asks for `winrtbase.idl`; the SDK ships
   `WinRTBase.idl`. Identical on NTFS, different here. `fetch-sdk.sh` adds ~220
   lowercase symlinks, the same fix [xwin](https://github.com/Jake-Shadle/xwin)
   applies to the headers.

3. **MAX_PATH, silently.** A `.winmd` path over 260 characters arrives at the
   tool truncated — `...UniversalApiContract.w?` — and is rejected as "not a
   winmd". Nothing says the path was too long. Work from a short directory.

4. **`Windows.winmd` lives in its own MSI.** Without `/metadata_dir` pointing at
   `UnionMetadata/`, midlrt fails with `MIDL4034`. That file is in _Windows SDK
   Facade Windows WinMD Versioned_, not in the tools or contracts packages.

5. **makepri needs MSXML6, and only the 32-bit build survives it.** Without it:
   `PRI175: Initializing Indexer / Schema Validation Failed`. Install it with
   `winetricks -q msxml6` — after which the **x64** makepri dies in a page fault
   inside MSXML while the **x86** one works. Both emit the same `.pri`.

## Requirements

`wine`, `p7zip`, `curl`, and `winetricks` (for `msxml6`). Verified with
wine 11.14 and Windows SDK 10.0.22621 on Arch Linux.

## Licensing

The SDK is downloaded from Microsoft at run time under its own licence and is
**never redistributed**. `fetch-sdk.sh` caches it outside the repo; CI must
re-run it rather than restore it from an artefact store.

## Next

- `xwin` for CRT and SDK headers/libs, then a hello-world compiled with
  `clang-cl -target x86_64-pc-windows-msvc` and linked with `lld-link`.
- The open risk is whether the C++/WinRT headers compile under clang-cl. cppwinrt
  names clang as a supported target, but this has not been tried here yet.
- Then `openappx pack | sign | deploy`, with installation on a device as the
  proof — the same bar used to validate openappx itself.
