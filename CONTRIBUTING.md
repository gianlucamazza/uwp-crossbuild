# Contributing

## Before opening a pull request

```bash
make check                            # shellcheck, shfmt, py_compile and the tests
```

or, one at a time — `packaging/` included, because publish-aur.sh is a script
like any other:

```bash
shellcheck scripts/*.sh tests/*.sh packaging/*.sh
shfmt -d scripts/*.sh tests/*.sh packaging/*.sh   # tabs, as shfmt writes them
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

A record of nineteen ways the Windows SDK and its device fail on Linux, with a
script wrapped around each. That framing decides most questions:

- **Every workaround says which failure it avoids.** A flag whose purpose is not
  written down will be removed by someone who cannot see why it is there — and
  every one of these looks unnecessary until you hit the failure. Put the
  reasoning next to the code and the summary in the README.
- **Say which version you observed.** `midlrt` shelling out to `cl.exe` is true
  of SDK 10.0.22621; MSXML6 faulting under Wine is true of Wine 11.14. A
  workaround with no version attached cannot ever be retired. The monthly
  `full-build` run exists to find out when one has been: it builds without the
  SDK cache, so it exercises the download too.
- **Four versions are pinned by hand**, because dependabot watches the actions
  and nothing else: `XWIN_VERSION` and `SHFMT_VERSION` in `ci.yml`,
  `UWP_SDK_VERSION_DEFAULT` in `common.sh` — one copy, because `fetch-sdk.sh`
  writes the layout at that version and `gen-projection.sh`/`wine-tool.sh` read
  it back; the installer URL stays in `fetch-sdk.sh` beside its cross-check —
  and `CPPWINRT_FALLBACK`, used only when xwin's headers are not there to be
  read.
- **Nothing from Microsoft is redistributed.** `fetch-sdk.sh` and `xwin`
  download at run time under the SDK licence. Do not commit the result, do not
  cache it in an artefact store, do not check in a `.winmd` or a `.pri`.

## What can be tested

`tests/run-tests.sh` covers what needs no SDK: argument handling, the guards
that turn a confusing failure into a clear one, and the two pieces that are pure
parsing — `fix-header-case.sh` and `read-vcxproj.py`. It is plain bash on
purpose — the repository has no package manifest and should not acquire one to
run its tests.

The `.vcxproj` fixtures under `tests/fixtures/` are distilled from what real
Visual Studio projects do; none of it is invented, and none of it is copied from
anyone's source tree. A refusal that a real project provokes belongs there as a
fixture, next to the table row that names it.

**The acceptance test is a corpus, and it is manual**, because the projects live
outside this repository: `read-vcxproj.py --json` has to complete without a
refusal on every real `.vcxproj` you have. What it refuses is either a gap in
the mapping table or a deliberate limit — decide which, and write down the one
you chose.

Anything needing the real toolchain is verified by hand, and the outcome goes in
the CHANGELOG rather than into a test that cannot run.

## Conventions

- Scripts are bash with `set -euo pipefail`, formatted by `shfmt`. One is
  Python, because 500 lines of MSBuild evaluator do not belong in a heredoc; it
  uses the standard library only, like everything else here.
- **`scripts/common.sh` holds what must not be written twice**, and nothing
  else: the shape of an error, a download that can fail, and the layout
  doctrine. It is sourced, never run — no symlink, not executable. The test for
  whether something belongs there is not "it appears twice" but "two copies
  could disagree and one of them would be wrong": `build-app.sh` and
  `build-project.sh` each had a copy of "clear a stale layout only when it is
  recognisably one" and disagreed within a day about what counts as
  recognisable. Anything whose reasons live in one script stays in that script.
- **`read-vcxproj.py` is one file on purpose**: an evaluator, a description in
  this toolchain's terms, and a command line. One entry point, one installed
  symlink. If a fourth responsibility turns up, that is when it becomes a
  package.
- **`read-vcxproj.py` refuses rather than guesses.** Its table of MSBuild
  settings to clang-cl flags is a contract: a setting that is not in it is not
  quietly dropped, because a build that silently differs from MSBuild's is worse
  than no build — the difference shows up at the link, or on a device. Adding a
  row means claiming an equivalence, so say why next to it.
- A process substitution's exit status is not the pipeline's. `mapfile -t x <
<(cmd)` succeeds when `cmd` fails, which turns a refusal into an empty list;
  read through a command substitution and check.
- A script that takes arguments validates them before doing any work, and its
  error names the fix (`run fetch-sdk.sh`, `pass --name`). A flag declared to
  take a value checks that it has one — `value "$1" $#` in every parser — rather
  than failing on an unbound `$2`.
- Generated files — `.winmd`, `.pri`, projection headers, objects, the
  precompiled header — never land in a package layout. They go in a build
  directory beside it: `makepri new` indexes everything under `/ProjectRoot`,
  so anything left in a layout is both shipped and described in `resources.pri`.
- Output that is only interesting when something fails still goes somewhere. A
  tool run under Wine gets its output kept in a log and quoted on failure; it is
  usually the only diagnosis there is.
