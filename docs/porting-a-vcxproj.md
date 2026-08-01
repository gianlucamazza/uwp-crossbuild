# Building an existing Visual Studio project here

A recipe for taking a UWP application that already builds with MSBuild and
building it on Linux instead, without changing its source.

It is written as an order of operations because that, and the reasons behind
each step, is the part that is hard to rediscover. The numbers at the end come
from doing it to a real application: 216 translation units, a large third-party
inference library among them, packaged and installed on a device.

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

## 1. Read the source list out of the project, do not retype it

```bash
grep -oP '(?<=ClCompile Include=")[^"]+' path/to/project.vcxproj | sed 's|\\|/|g'
```

MSBuild accepts globs. A project can list `..\lib\src\models\*.cpp` and mean a
hundred and thirty-eight files; a list transcribed by hand will be missing them,
and the omission surfaces only at link time, as undefined symbols with no
obvious origin.

The same goes for `<PreprocessorDefinitions>` and
`<AdditionalIncludeDirectories>`: read them out, do not reconstruct them. Some
defines carry values the build system computes — a version string, a commit
hash — and a source file that uses one does not compile without it.

## 2. Restore the NuGet dependencies

Native NuGet packages are ordinary zip files:

```bash
curl -sSL -o pkg.nupkg https://www.nuget.org/api/v2/package/<Id>/<Version>
7z x -opkg pkg.nupkg
```

Headers live under `build/native/include`, import libraries and DLLs under
`runtimes/win-x64/native`. Pass the include directories with `build.sh -I` and
the library directories with `--link-arg /libpath:…`.

Third-party DLLs are **copied into the package, not rebuilt**. They are already
compiled for Windows, which is the reason for depending on them.

## 3. Generate the projection from the project's own `.idl`

```bash
uwp-gen-projection --idl app.idl --name myapp --out gen
```

This produces `myapp.winmd`, `App.g.h`, `module.g.cpp` and the `winrt/`
headers. The sources implementing the application class do not compile without
them, and **the winmd has to ship inside the package**: the manifest's
`EntryPoint="myapp.App"` is resolved against it at activation.

## 4. Compile

`build.sh` force-includes `include/msvc-compat.h`, which is what lets a source
tree written for MSVC compile unchanged.

```bash
uwp-build --uwp --pch pch.h --out myapp.exe \
  -I gen -I src -I include \
  -I pkg/build/native/include \
  <every source from step 1> \
  -- /DMY_DEFINE=1 /D_CRT_SECURE_NO_WARNINGS
```

A project that mixes C and C++ needs two passes: C sources want `/std:c17`, C++
sources `/std:c++20`. `--pch` is worth it wherever the XAML projection is
included — around 30 seconds per translation unit becomes around one.

## 5. Link, package, install

`--uwp` sets `/appcontainer` and the windows subsystem. Check it landed:

```
$ objdump -p myapp.exe | grep DllCharacteristics
DllCharacteristics	00009160        # 0x1000 present
```

Then [openappx](https://github.com/gianlucamazza/openappx) takes over: assemble
the layout (executable, winmd, assets, the copied DLLs, `AppxManifest.xml`),
`pack`, `sign`, `deploy`.

`Identity/@Publisher` in the manifest must equal the signing certificate's
subject exactly, so a project's own manifest usually needs that one attribute
changed for a development build.

## What it cost, measured

|                                 |                                 |
| ------------------------------- | ------------------------------- |
| Sources compiled                | 216 of 216                      |
| Executable                      | 7.5 MB, PE32+, app container    |
| Pack                            | 4.5 s → a 20.8 MB `.msix`       |
| Install                         | accepted by an Xbox One dev kit |
| Changes to the project's source | none                            |

## What it did not prove

The application has never been seen to run. The test console refuses to launch
every sideloaded package, Microsoft Edge included, so it cannot answer that
question — see [Known limits](../README.md#known-limits). A build that installs
is not a build that works, and nothing here should be read as claiming
otherwise.
