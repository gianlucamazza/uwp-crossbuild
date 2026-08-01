# hello-uwp

A UWP application in the shape that cross-compiles: `App` derives from
`Windows.UI.Xaml.Application`, `MainPage` is a plain C++ class, and there is no
`.xaml` file anywhere. The UI is built in code.

That last point is the whole trick. A `.xaml` file would need the XAML compiler
(MarkupCompilePass1/2), which has no Linux equivalent and does not run under
Wine. Declaring `MainPage` as a runtimeclass would pull in
`IXamlMetadataProvider` and land in the same place. Building the tree
programmatically avoids both, and it is how xllama is written.

```bash
scripts/build-app.sh --project examples/hello-uwp --out /tmp/hello-layout

# then, from the openappx checkout
./scripts/pack.sh --root /tmp/hello-layout --out /tmp/hello.msix
```

## Files

| File               | Role                                                           |
| ------------------ | -------------------------------------------------------------- |
| `app.idl`          | declares `App` only — the one runtimeclass the manifest names  |
| `pch.h`            | precompiled: ~30 s per translation unit becomes ~1 s           |
| `App.h/.cpp`       | the application class, plus `wWinMain`                         |
| `MainPage.h/.cpp`  | the visual tree, in code                                       |
| `module.cpp`       | compiles `module.g.cpp`, the activation-factory aggregator     |
| `AppxManifest.xml` | `EntryPoint="hello.App"`, resolved against the generated winmd |

`App.g.h`, `module.g.cpp` and `hello.winmd` are generated into a scratch
directory at build time and never committed.

## Three things this example encodes

- **`#undef GetCurrentTime` right after `<windows.h>`.** `winbase.h` defines it
  as a macro; XAML's `Timeline` declares a method by that name, so the projection
  header stops parsing. The error blames the header, not the macro.
- **`<winrt/Windows.Foundation.Collections.h>` even though no collection is named
  here.** `UIElementCollection` is an `IVector`, and its `Append` has a deduced
  return type — unusable before the definition is visible.
- **The winmd ships in the package.** `EntryPoint="hello.App"` is resolved
  against it at activation. Without it the package installs and then refuses to
  start, which reads like an application bug.
