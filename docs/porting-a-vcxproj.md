# Building an existing Visual Studio project here

Taking a UWP application that already builds with MSBuild and building it on
Linux instead, without changing its source.

```bash
uwp-build-project --project uwp/app.vcxproj --out /tmp/layout
```

That reads the project, restores its NuGet packages, builds whatever it
references, generates the projection from its `.idl`, compiles and links, and
assembles a layout [openappx](https://github.com/gianlucamazza/openappx) can
pack. The rest of this page is what it does and why — worth reading before
trusting it, and necessary when it refuses.

**It refuses rather than guesses.** A `.vcxproj` can say things this toolchain
has no equivalent for, and a build that silently differs from the one MSBuild
produces is worse than no build: the difference does not surface until the link,
or until the application misbehaves on a device. So `read-vcxproj.py` — the
evaluator underneath — stops and names what it did not understand: a property
only Visual Studio can supply, a compiler setting outside its mapping table, a
target that generates files. Each refusal is a decision to make deliberately,
not a bug to work around.

The numbers at the end come from doing this to a real application: 216
translation units, a large third-party inference library among them, packaged
and installed on a device.

## What it evaluates

`read-vcxproj.py PROJECT.vcxproj --json` prints what it made of a project, which
is the first thing to look at when a build is not what you expected:

```bash
uwp-read-vcxproj uwp/app.vcxproj --json          # everything
uwp-read-vcxproj uwp/app.vcxproj --field defines # one field, one per line
uwp-read-vcxproj uwp/app.vcxproj --flags         # the same as build.sh arguments
uwp-read-vcxproj uwp/app.vcxproj --config Debug  # the other configuration
```

Properties with conditions, `Exists()`, per-configuration
`ItemDefinitionGroup`s, `%(Name)` continuations, `*` and `**` globs with
`Exclude`, NuGet `.props` imports, `ProjectReference`, `DeploymentContent` —
all of it, because a real project uses all of it.

`--property NAME=VALUE` is MSBuild's `/p:`, and it matters more than it looks:
a project's own switches live there, and one of them can decide whether a
`ProjectReference` exists at all. A backend selected by a property is a
different set of sources, defines and libraries.

## Whether your project can come at all

Two properties decide it. Neither is negotiable:

- **No `.xaml` files.** The XAML compiler has no Linux equivalent and does not
  run under Wine. A project qualifies only if it builds its UI in code —
  `examples/hello-uwp` shows that shape in miniature.
- **Few runtimeclasses.** Every `runtimeclass` in the `.idl` needs metadata and
  a projection. A project that declares one application class produces a winmd
  of a couple of kilobytes; a project built around WinRT components is a
  different exercise.

Everything else turned out not to matter: precompiled headers, native NuGet
packages, C and C++ mixed in one project, and a source list of several hundred
files all came across unchanged.

## 1. The source list comes out of the project, never retyped

MSBuild accepts globs. A project can list `..\lib\src\models\*.cpp` and mean a
hundred and thirty-eight files; a list transcribed by hand will be missing them,
and the omission surfaces only at link time, as undefined symbols with no
obvious origin. The same goes for `<PreprocessorDefinitions>` and
`<AdditionalIncludeDirectories>`: some defines carry values the build system
computes — a version string, a commit hash — and a source file that uses one
does not compile without it.

This is the step that makes the whole thing worth automating, and it is why
`read-vcxproj.py` evaluates properties rather than pattern-matching XML.

## 2. NuGet dependencies are restored, not assumed

```bash
uwp-restore-nuget --project uwp/app.vcxproj
```

A native NuGet package is an ordinary zip. `packages.config` or
`PackageReference` says which ones and at which versions; they land in
`packages/<Id>.<Version>/`, the directory Visual Studio would create and the one
the project's own `<Import>` lines name. Headers live under
`build/native/include`, import libraries and DLLs under
`runtimes/win-x64/native` — `runtimes/win-arm64/native` is the ARM64 spelling,
and it is the project's own `$(Platform)` conditions that select between them,
not anything hardcoded here.

Until this has run, a project's `.props` imports resolve to nothing and its
include paths point at absent directories — which is why `build-project.sh`
restores first and reads the project again afterwards.

Third-party DLLs are **copied into the package, not rebuilt**: they are already
compiled for Windows, which is the reason for depending on them. A project says
so itself, with `<None … DeploymentContent="true"><TargetPath>`, and that is
what puts each DLL beside the executable under the name the loader expects.

## 3. Generate the projection from the project's own `.idl`

```bash
uwp-gen-projection --idl app.idl --name myapp --out gen
```

This produces `myapp.winmd`, `App.g.h`, `module.g.cpp` and the `winrt/`
headers. The sources implementing the application class do not compile without
them, and **the winmd has to ship inside the package**: the manifest's
`EntryPoint="myapp.App"` is resolved against it at activation.

## 4. Everything a `ProjectReference` names is built first

A project that references another gets it built as a static library and linked
in — `build.sh --static-lib` archives the objects with `llvm-lib` rather than
linking an image, because `/appcontainer` belongs to the application, not to the
archive. Each library is built once however many projects name it.

## 5. Compile

`build.sh` force-includes `include/msvc-compat.h`, which is what lets a source
tree written for MSVC compile unchanged.

```bash
uwp-build --uwp --pch pch.h --out myapp.exe \
  -I gen -I src -I include \
  -I pkg/build/native/include \
  <every source from step 1> \
  -- /DMY_DEFINE=1 /D_CRT_SECURE_NO_WARNINGS
```

C and C++ sources go in the same command: `build.sh` compiles a `.c` with
`UWP_C_STD` and everything else with `UWP_CXX_STD` — taken from the project's
own `LanguageStandard` and `LanguageStandard_C`, except that `stdcpp17` is
overridden to C++20, because C++/WinRT below C++20 reaches for
`<experimental/coroutine>` and that header refuses clang by design. The
precompiled header, a C++ artefact, is applied only to the C++ sources. `--pch`
is worth it wherever the XAML projection is included: around 30 seconds per
translation unit becomes around one.

## 6. Link, package, install

`--uwp` sets `/appcontainer` and the windows subsystem. Check it landed:

```
$ objdump -p myapp.exe | grep DllCharacteristics
DllCharacteristics	00009160        # 0x1000 present
```

A project laid out like `examples/hello-uwp` — one `.idl`, the sources and the
manifest in one directory, no `.vcxproj` — has `build-app.sh` instead, which is
the shorter road for that shape:

```bash
uwp-build-app --project uwp --out /tmp/layout \
  --copy pkg/runtimes/win-x64/native
```

Both front doors take `--platform x64|ARM64`; for an ARM64 build, `--copy` the
`runtimes/win-arm64/native` directory instead.

Either way [openappx](https://github.com/gianlucamazza/openappx) takes over from
the finished layout (executable, winmd, assets, the copied DLLs,
`AppxManifest.xml`): `pack`, `sign`, `deploy`.

`Identity/@Publisher` in the manifest must equal the signing certificate's
subject exactly, so a project's own manifest usually needs that one attribute
changed for a development build.

A project that sets `MultiThreadedDLL` (`/MD`) has two roads through the app
container. By default the runtime is made static — that is the fallback, and
it launches. To keep `/MD`, run `fetch-vclibs.sh` once (pointing `--appx` at a
`Microsoft.VCLibs.<arch>.14.00.appx` — a Visual Studio install or a VS-built
package's `Dependencies` folder has one) and the build links the store CRT
instead; the manifest must then declare the `Microsoft.VCLibs.140.00`
`<PackageDependency>` — `build-project.sh` refuses otherwise, printing the
exact element — and the framework must be installed on the device, or the
launch fails as `0x80070002` while the install reports nothing (the README's
gotcha list tells that story).

## What it cost, measured

|                                 |                                      |
| ------------------------------- | ------------------------------------ |
| Sources compiled                | 216 of 216                           |
| Executable                      | 7.5 MB, PE32+, app container         |
| Pack                            | 4.5 s → a 20.8 MB `.msix`            |
| Install                         | accepted by an Xbox Series S dev kit |
| Changes to the project's source | none                                 |

## What it did not prove

For six days this section said the application had only been seen to install,
never to run. That gap closed on 2026-08-08: with the apiset reroutes of the
README's n°23, the crossbuilt executable was started on the console and its
own log shows `OnLaunched`, the window activated, and a GGUF model loaded
through the inference library. What remains unproven is narrower and honest:
the first-boot provisioning path (model not yet in `LocalState`) still dies in
a `fire_and_forget` coroutine — an exception there is `winrt::terminate`, not
a caught error — and a run that far outlives its launch (long inference, hours
of uptime) has not been measured. A build that starts is not yet a build that
ships, and nothing here should be read as claiming otherwise.
