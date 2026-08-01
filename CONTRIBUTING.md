# Contributing

## Before opening a pull request

```bash
shellcheck scripts/*.sh tests/*.sh
shfmt -d scripts/*.sh tests/*.sh      # tabs, as shfmt writes them
tests/run-tests.sh
```

CI runs exactly these. It does **not** build anything: a real build downloads
~1.1 GB from Microsoft's CDN, which the SDK licence permits but which has no
business running on every push. The `full-build` job does the whole thing and is
triggered manually.

If your change touches the toolchain itself, run the real build too:

```bash
scripts/check-deps.sh
scripts/build-app.sh --project examples/hello-uwp --out /tmp/hello-layout
```

## What this repository is

A record of thirteen ways the Windows SDK fails on Linux, with a script wrapped
around each. That framing decides most questions:

- **Every workaround says which failure it avoids.** A flag whose purpose is not
  written down will be removed by someone who cannot see why it is there — and
  every one of these looks unnecessary until you hit the failure. Put the
  reasoning next to the code and the summary in the README.
- **Say which version you observed.** `midlrt` shelling out to `cl.exe` is true
  of SDK 10.0.22621; MSXML6 faulting under Wine is true of Wine 11.14. A
  workaround with no version attached cannot ever be retired.
- **Nothing from Microsoft is redistributed.** `fetch-sdk.sh` and `xwin`
  download at run time under the SDK licence. Do not commit the result, do not
  cache it in an artefact store, do not check in a `.winmd` or a `.pri`.

## What can be tested

`tests/run-tests.sh` covers what needs no SDK: argument handling, the guards
that turn a confusing failure into a clear one, and `fix-header-case.sh`, which
is pure parsing. It is plain bash on purpose — the repository has no package
manifest and should not acquire one to run its tests.

Anything needing the real toolchain is verified by hand, and the outcome goes in
the CHANGELOG rather than into a test that cannot run.

## Conventions

- Scripts are bash with `set -euo pipefail`, formatted by `shfmt`.
- A script that takes arguments validates them before doing any work, and its
  error names the fix (`run fetch-sdk.sh`, `pass --name`).
- Generated files — `.winmd`, `.pri`, projection headers, objects, the
  precompiled header — never land in a package layout. They go in a build
  directory beside it.
