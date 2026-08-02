#!/usr/bin/env python3
"""read-vcxproj.py — read a Visual Studio C++ project, without MSBuild.

    read-vcxproj.py PROJECT.vcxproj [--config Release] [--platform x64]
                    [--json | --flags]

Evaluates enough of MSBuild to describe what a project builds: which sources,
with which defines, include directories and standards, what it links against,
what it deploys into the package. `--json` prints that description; `--flags`
prints it as the clang-cl and lld-link arguments build.sh takes.

It is deliberately incomplete, and says so out loud. Anything it cannot
evaluate — a property MSBuild itself would supply, a condition it cannot decide,
a compiler setting with no equivalent here — is refused by name rather than
ignored. A build that silently differs from the one MSBuild would produce is
worse than no build: the difference does not show up until the link, or until
the application misbehaves on a device.

What it evaluates:

  properties      PropertyGroup in document order, last definition wins, with
                  Condition. A property nobody defines expands to empty, which
                  is MSBuild's rule and the whole point of the common idiom
                  <Foo Condition="'$(Bar)' == 'x'">…</Foo> — those are listed
                  under "undefined" rather than refused.
  conditions      '$(A)' == 'B', !=, <, <=, >, >= (numeric, or version, as
                  MSBuild compares them), Exists('p'), and, or, !, parentheses.
                  and/or short-circuit, which is not a nicety: packages guard a
                  numeric comparison with a string one and rely on it.
  imports         A NuGet .props is evaluated recursively when it exists. Two
                  kinds are not: anything under $(VCTargetsPath), which is
                  MSBuild's own C++ build system, and any .targets, which is a
                  description of the actions MSBuild would take — and this
                  toolchain takes its own. Those are listed under "skipped".
  items           ClCompile, ClInclude, Midl, None, Image, AppxManifest,
                  ProjectReference, PackageReference; * and ** globs, Exclude.
  item metadata   ItemDefinitionGroup for ClCompile and Link, merged in order,
                  where %(Name) means "whatever came before"; per-item metadata
                  overrides it.
"""

import argparse
import json
import os
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

NS = "{http://schemas.microsoft.com/developer/msbuild/2003}"


class Refusal(Exception):
    """Something the evaluator will not guess at. The message names it."""


# Properties MSBuild supplies from the Visual Studio installation. Expanding one
# to empty would silently drop a real include or library path, so a project that
# needs one is refused rather than mis-built. (Imports *under* $(VCTargetsPath)
# are a different matter: those are skipped deliberately, see _import.)
RESERVED = {
    "VCTargetsPath",
    "VCInstallDir",
    "VSInstallDir",
    "WindowsSdkDir",
    "WindowsSDK_IncludePath",
    "WindowsSDK_LibraryPath",
    "UniversalCRT_IncludePath",
    "UCRTContentRoot",
    "MSBuildExtensionsPath",
    "MSBuildExtensionsPath32",
    "MSBuildToolsPath",
    "NuGetPackageRoot",
}

# Properties Microsoft.Cpp.props computes from ones the project sets itself.
DERIVED = {
    "TargetPlatformVersion": "WindowsTargetPlatformVersion",
    "TargetPlatformMinVersion": "WindowsTargetPlatformMinVersion",
}

# ---------------------------------------------------------------------------
# ClCompile metadata -> clang-cl. Every entry is a claim about equivalence, so
# every entry that is not obvious says why. Anything absent from this table is
# refused: an unrecognised setting is a difference from the MSBuild build, and
# the whole value of this tool is that there is none.
# ---------------------------------------------------------------------------
OPTIMIZATION = {"Disabled": "/Od", "MinSpace": "/O1", "MaxSpeed": "/O2", "Full": "/Ox"}
RUNTIME_LIBRARY = {
    "MultiThreaded": "/MT",
    "MultiThreadedDebug": "/MTd",
    "MultiThreadedDLL": "/MD",
    "MultiThreadedDebugDLL": "/MDd",
}
EXCEPTION_HANDLING = {
    "Sync": "/EHsc",
    "Async": "/EHa",  # SEH translated into C++ exceptions
    "SyncCThrow": "/EHs",
    "false": "",
}
FAVOR = {"Speed": "/Ot", "Size": "/Os", "Neither": ""}
# What Identity/@ProcessorArchitecture must say for the platform being built.
# "neutral" is legal under any platform and an absent attribute is not checked;
# a platform outside this table (Win32 evaluates, it just cannot be built) is
# not checked either — build-project.sh refuses it before anything installs.
MANIFEST_ARCHITECTURE = {"x64": "x64", "arm64": "arm64"}
BASIC_RUNTIME_CHECKS = {
    "Default": "",
    "StackFrameRuntimeCheck": "/RTCs",
    "UninitializedLocalUsageCheck": "/RTCu",
    "EnableFastChecks": "/RTC1",
}

# Settings that describe how MSBuild drives the compiler rather than how the
# code is compiled. build.sh already does the equivalent, so they are dropped —
# but named here, because "not in the table" means refusal and these are not
# refusals.
IGNORED_CLCOMPILE = {
    # build.sh names every object after its whole source path already, which is
    # what ObjectFileName with %(RelativeDir) is for.
    "ObjectFileName",
    # build.sh compiles in parallel with --jobs.
    "MultiProcessorCompilation",
    # No .pdb is produced: lld-link is not given /debug, and nothing downstream
    # reads one. A project asking for debug info still builds, without it.
    "DebugInformationFormat",
    "ProgramDataBaseFileName",
    "GenerateDebugInformation",
    # Whole-program optimisation is an MSVC code-generation strategy with no
    # clang-cl equivalent that lld-link consumes; dropping it changes speed,
    # not behaviour.
    "WholeProgramOptimization",
    "LinkTimeCodeGeneration",
    # Editor and IDE bookkeeping.
    "SubType",
    "FunctionLevelLinking",
    "StringPooling",
    "MinimalRebuild",
    "SDLCheck",
    "UseFullPaths",
    "DiagnosticsFormat",
    "SupportJustMyCode",
    "AssemblerListingLocation",
}


def ordinal(text):
    """What MSBuild's <, <=, > and >= compare: a number, or a version.

    `'$(TargetPlatformVersion)' >= '10.0.17134.0'` is the shape a project
    actually uses, and 10.0.17134.0 is not a number. Returns None for anything
    that is neither, which the caller refuses rather than ordering by accident.
    """
    try:
        return (float(text),)
    except ValueError:
        pass
    parts = text.split(".")
    if len(parts) > 1 and all(part.isdigit() for part in parts):
        return tuple(int(part) for part in parts)
    return None


def tag(element):
    """The element name without the MSBuild namespace, which not every file has."""
    return element.tag[len(NS) :] if element.tag.startswith(NS) else element.tag


def windows_path(text):
    return text.replace("\\", "/")


class Evaluator:
    def __init__(self, project, config, platform, globals_=None):
        self.project = project.resolve()
        if not self.project.is_file():
            raise Refusal(f"no such project: {project}")
        self.directory = self.project.parent
        # MSBuild's /p:Name=Value. A global property wins over every assignment
        # in the file, which is what makes a project's own switches reachable —
        # a backend selector, a SKU flag — including the ones that decide
        # whether a ProjectReference exists at all.
        self.globals = dict(globals_ or {})
        self.undefined = set()
        self.skipped = set()
        self.items = {}
        self.clcompile = {}  # merged ItemDefinitionGroup metadata
        self.link = {}
        self.properties = {
            "Configuration": config,
            "Platform": platform,
            "ProjectDir": f"{self.directory}/",
            "MSBuildProjectDirectory": str(self.directory),
            "ProjectFileName": self.project.name,
            "ProjectName": self.project.stem,
            "MSBuildProjectName": self.project.stem,
            "SolutionDir": self._solution_dir(),
            # Where MSBuild would put objects and the executable. Nothing here
            # uses them for output — build.sh decides that — but projects
            # mention them in include paths (a "Generated Files" directory,
            # typically), so they have to expand to something.
            "IntDir": f"{self.directory}/build/{platform}/{config}/",
            "OutDir": f"{self.directory}/build/{platform}/{config}/",
        }
        self.properties.update(self.globals)
        self._read(self.project)
        # A property referenced before the file got round to defining it is not
        # undefined — every project opens with the idiom
        # <Foo Condition="'$(Foo)' == ''">default</Foo>, which reads Foo first.
        self.undefined -= set(self.properties)

    def _solution_dir(self):
        """The nearest ancestor holding a .sln, as MSBuild would define it."""
        for directory in [self.directory, *self.directory.parents]:
            if any(directory.glob("*.sln")):
                return f"{directory}/"
        return f"{self.directory}/"

    # -- expansion ---------------------------------------------------------

    PROPERTY = re.compile(r"\$\(([^)]*)\)")

    def expand(self, text, where):
        if text is None:
            return ""

        def replace(match):
            name = match.group(1)
            if not name.isidentifier():
                # $([MSBuild]::Add(…)), $(Foo.Replace(…)) and friends: MSBuild
                # property functions. Evaluating them by halves would be worse
                # than not evaluating them.
                raise Refusal(
                    f"{where}: property function $({name}) is not evaluated here"
                )
            if name in self.properties:
                return self.properties[name]
            # Microsoft.Cpp.props derives these from the project's own
            # properties, and that file is skipped here on purpose. A NuGet
            # package's conditions read them, so they are derived the same way
            # rather than left empty — an empty one silently changes which
            # branch of a version test is taken.
            if name in DERIVED and DERIVED[name] in self.properties:
                return self.properties[DERIVED[name]]
            if name in RESERVED:
                raise Refusal(
                    f"{where}: $({name}) is supplied by Visual Studio, not by the "
                    f"project, and there is nothing here to supply it. A path that "
                    f"depends on it cannot be reproduced."
                )
            # MSBuild's own rule: a property nobody defined is empty. Recorded
            # so that it is visible rather than silent.
            self.undefined.add(name)
            return ""

        return self.PROPERTY.sub(replace, text)

    # -- conditions --------------------------------------------------------

    TOKEN = re.compile(
        r"""\s*(?:
            (?P<string>'[^']*')
          | (?P<op><=|>=|==|!=|<|>|\(|\)|!)
          | (?P<word>[A-Za-z_][A-Za-z0-9_]*)
          | (?P<bare>[^\s()'!=<>]+)
        )""",
        re.X,
    )

    def condition(self, text, where):
        """True if this Condition holds. Refuses any syntax it does not know."""
        if text is None:
            return True
        expanded = self.expand(text, where)
        tokens, position = [], 0
        while position < len(expanded):
            match = self.TOKEN.match(expanded, position)
            if not match:
                raise Refusal(f"{where}: cannot read condition {text!r}")
            position = match.end()
            kind = match.lastgroup
            value = match.group(kind)
            tokens.append((kind, value[1:-1] if kind == "string" else value))
        if not tokens:
            return True
        result, rest = self._or(tokens, text, where)
        if rest:
            raise Refusal(f"{where}: trailing {rest[0][1]!r} in condition {text!r}")
        return result

    # and/or short-circuit, as they do in MSBuild — and this is not a detail.
    # The C++/WinRT package guards a numeric comparison with a string one:
    #
    #   ('$(MSBuildToolsVersion)' == 'Current') Or ('$(MSBuildToolsVersion)' >= '15')
    #
    # 'Current' is not a number, so the right-hand side has no answer; MSBuild
    # never asks for one, because the left is already true. Evaluating both
    # sides would refuse a condition that Microsoft ships and that works.
    # `skip` means "parse this, do not ask what it means": the operand is on the
    # far side of a short circuit. It has to reach all the way down, including
    # through parentheses — the guarded comparison a package writes is
    # parenthesised, so a flag that stops at the bracket stops where it matters.
    def _or(self, tokens, text, where, skip=False):
        left, tokens = self._and(tokens, text, where, skip)
        while tokens and tokens[0][0] == "word" and tokens[0][1].lower() == "or":
            if left or skip:
                _, tokens = self._and(tokens[1:], text, where, skip=True)
            else:
                left, tokens = self._and(tokens[1:], text, where)
        return left, tokens

    def _and(self, tokens, text, where, skip=False):
        left, tokens = self._unary(tokens, text, where, skip)
        while tokens and tokens[0][0] == "word" and tokens[0][1].lower() == "and":
            if not left or skip:
                _, tokens = self._unary(tokens[1:], text, where, skip=True)
            else:
                left, tokens = self._unary(tokens[1:], text, where)
        return left, tokens

    def _unary(self, tokens, text, where, skip=False):
        if not tokens:
            raise Refusal(f"{where}: condition {text!r} ends early")
        kind, value = tokens[0]
        if kind == "op" and value == "!":
            result, tokens = self._unary(tokens[1:], text, where, skip)
            return not result, tokens
        if kind == "op" and value == "(":
            result, tokens = self._or(tokens[1:], text, where, skip)
            if not tokens or tokens[0][1] != ")":
                raise Refusal(f"{where}: unbalanced ( in condition {text!r}")
            return result, tokens[1:]
        return self._comparison(tokens, text, where, skip)

    RELATIONAL = {
        "<": lambda a, b: a < b,
        "<=": lambda a, b: a <= b,
        ">": lambda a, b: a > b,
        ">=": lambda a, b: a >= b,
    }

    def _comparison(self, tokens, text, where, skip=False):
        kind, value = tokens[0]
        rest = tokens[1:]
        # Exists('path'), the one function projects here actually use.
        if kind == "word" and value.lower() == "exists":
            if len(rest) < 3 or rest[0][1] != "(" or rest[2][1] != ")":
                raise Refusal(f"{where}: cannot read Exists(…) in {text!r}")
            path = rest[1][1]
            return (self.directory / windows_path(path)).exists(), rest[3:]
        if rest and rest[0][0] == "op" and rest[0][1] in ("==", "!="):
            if len(rest) < 2:
                raise Refusal(f"{where}: condition {text!r} ends after {rest[0][1]}")
            right = rest[1][1]
            # MSBuild compares strings case-insensitively.
            equal = value.lower() == right.lower()
            return (equal if rest[0][1] == "==" else not equal), rest[2:]
        if rest and rest[0][0] == "op" and rest[0][1] in self.RELATIONAL:
            if len(rest) < 2:
                raise Refusal(f"{where}: condition {text!r} ends after {rest[0][1]}")
            operator, right = rest[0][1], rest[1][1]
            if skip:
                # Short-circuited away: MSBuild would not ask, so neither does
                # this — and the operands may well have no ordering at all.
                return False, rest[2:]
            left_number, right_number = ordinal(value), ordinal(right)
            if left_number is None or right_number is None:
                raise Refusal(
                    f"{where}: {value!r} {operator} {right!r} in condition {text!r} "
                    f"compares something that is neither a number nor a version"
                )
            return self.RELATIONAL[operator](left_number, right_number), rest[2:]
        if kind in ("string", "bare", "word") and value.lower() in ("true", "false"):
            return value.lower() == "true", rest
        raise Refusal(
            f"{where}: condition {text!r} is not a comparison this evaluator knows"
        )

    # -- reading -----------------------------------------------------------

    def _read(self, path, importer=None):
        where = path.name
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as error:
            raise Refusal(f"{where}: not readable as XML: {error}") from error
        # The project's own ToolsVersion attribute is where $(MSBuildToolsVersion)
        # comes from, and packages compare it: the C++/WinRT one asks whether it
        # is at most 15. Left undefined it would be empty, and an empty string
        # has no place in a numeric comparison — the branch would not be wrong,
        # it would be unanswerable.
        if path == self.project and root.get("ToolsVersion"):
            self.properties.setdefault("MSBuildToolsVersion", root.get("ToolsVersion"))
        # Per-file, and restored afterwards: an imported .props uses it to point
        # at its own package directory, not at the project's.
        outer = self.properties.get("MSBuildThisFileDirectory")
        self.properties["MSBuildThisFileDirectory"] = f"{path.parent}/"
        for element in root:
            name = tag(element)
            if name == "PropertyGroup":
                self._property_group(element, where)
            elif name == "ItemGroup":
                self._item_group(element, where)
            elif name == "ItemDefinitionGroup":
                self._item_definitions(element, where)
            elif name == "Import":
                self._import(element, where)
            elif name in ("ImportGroup",):
                for child in element:
                    if tag(child) == "Import" and self.condition(
                        element.get("Condition"), where
                    ):
                        self._import(child, where)
            elif name == "Target":
                self._target(element, where)
            elif name in ("UsingTask", "PropertyPageSchema", "ProjectExtensions"):
                pass  # IDE bookkeeping; nothing that reaches the compiler
            else:
                raise Refusal(f"{where}: <{name}> is not understood")
        if outer is None:
            del self.properties["MSBuildThisFileDirectory"]
        else:
            self.properties["MSBuildThisFileDirectory"] = outer
        _ = importer

    # A Target is an MSBuild program, and one that generates a source or copies
    # a file changes what gets built. The exception is the guard Visual Studio
    # writes into every project that uses NuGet — EnsureNuGetPackageBuildImports
    # — which does nothing but raise an error when a .props is missing. Its
    # elements are the tell: PropertyGroup holding the message, and Error. A
    # target that can produce a file is refused, by the name of what it runs.
    DIAGNOSTIC_ONLY = {"Target", "PropertyGroup", "Error", "Warning", "Message"}

    def _target(self, element, where):
        used = {tag(child) for child in element.iter()}
        # A PropertyGroup inside a Target is evaluated when the target runs, not
        # now, so its children are neither taken into the project's properties
        # nor counted as tasks.
        used -= {
            tag(child)
            for group in element.iter()
            if tag(group) == "PropertyGroup"
            for child in group
        }
        beyond = used - self.DIAGNOSTIC_ONLY
        if beyond:
            raise Refusal(
                f"{where}: <Target Name={element.get('Name')!r}> runs "
                f"{', '.join('<' + name + '>' for name in sorted(beyond))}, whose effect "
                f"on the build cannot be reproduced here"
            )

    def _property_group(self, group, where):
        if not self.condition(group.get("Condition"), where):
            return
        for element in group:
            if not self.condition(element.get("Condition"), where):
                continue
            name = tag(element)
            if name in self.globals:
                continue  # a global property is not overridable, as in MSBuild
            self.properties[name] = self.expand(
                "".join(element.itertext()), where
            ).strip()

    def _import(self, element, where):
        raw = element.get("Project", "")
        if "$(VCTargetsPath)" in raw or "$(MSBuildToolsPath)" in raw:
            # Microsoft.Cpp.props / .targets: MSBuild's own C++ build system.
            # Skipped on purpose — this tool replaces it rather than reading it.
            return
        if not self.condition(element.get("Condition"), where):
            return
        target = self.directory / windows_path(self.expand(raw, where))
        if not target.is_file():
            raise Refusal(
                f"{where}: <Import Project={raw!r}> has no Condition and no file. "
                f"If it is a NuGet package, restore it first: restore-nuget.sh"
            )
        # A .props says what to compile; a .targets says what MSBuild should do
        # about it. MSBuild's own convention separates them, which is why every
        # NuGet package ships both and why a project imports the first at the
        # top and the second at the bottom.
        #
        # This tool reproduces none of MSBuild's actions — gen-projection.sh,
        # build.sh and build-project.sh *are* the actions, and they run the
        # SDK's own cppwinrt.exe rather than the one a package would invoke, for
        # the version reason in README §13. So a .targets is not evaluated, and
        # it is listed rather than passed over quietly: if one of them were the
        # only place a project defined something, that has to be visible.
        if target.suffix.lower() == ".targets":
            self.skipped.add(target.name)
            return
        self._read(target, importer=where)

    def _item_group(self, group, where):
        if not self.condition(group.get("Condition"), where):
            return
        for element in group:
            if not self.condition(element.get("Condition"), where):
                continue
            if element.get("Remove") or element.get("Update"):
                raise Refusal(
                    f"{where}: <{tag(element)} Remove/Update> is not understood"
                )
            metadata = {
                tag(child): self.expand("".join(child.itertext()), where).strip()
                for child in element
                if self.condition(child.get("Condition"), where)
            }
            include = self.expand(element.get("Include", ""), where)
            excluded = {
                str(p)
                for pattern in self.expand(element.get("Exclude", ""), where).split(";")
                if pattern.strip()
                for p in self._glob(pattern.strip(), where)
            }
            entries = self.items.setdefault(tag(element), [])
            for pattern in include.split(";"):
                if not pattern.strip():
                    continue
                for path in self._glob(pattern.strip(), where):
                    if str(path) not in excluded:
                        entries.append({"path": path, "metadata": metadata})

    def _glob(self, pattern, where):
        pattern = windows_path(pattern)
        if "*" not in pattern:
            return [(self.directory / pattern)]
        # ** is MSBuild's recursive wildcard and pathlib's too.
        try:
            return sorted(self.directory.glob(pattern))
        except (ValueError, IndexError) as error:
            raise Refusal(f"{where}: cannot expand {pattern!r}: {error}") from error

    # ItemDefinitionGroup sections this does not take its settings from, and why.
    # A section maps to the metadata that is inert *within* it; None means the
    # whole section is, because this toolchain drives that tool itself. Metadata
    # outside the set is refused by name rather than dropped: the point of the
    # table is that nothing is skipped without somebody having said it may be.
    INERT_SECTIONS = {
        # gen-projection.sh runs midlrt with the flags the SDK needs, which are
        # not the ones a Visual Studio project suggests. Same for the resource
        # compiler, which has no part in a layout, and for the librarian:
        # build.sh --static-lib archives objects and nothing else.
        "Midl": None,
        "ResourceCompile": None,
        "Lib": None,
        # A reference here becomes a .lib that is linked, never a file copied
        # beside the executable, so Private — "copy the reference's output to
        # the output directory" — has nothing to act on. Anything that says
        # whether to link it at all would, and is not in this set.
        "ProjectReference": {"Private"},
        "Reference": {"Private"},
    }

    def _item_definitions(self, group, where):
        if not self.condition(group.get("Condition"), where):
            return
        for element in group:
            name = tag(element)
            if name == "ClCompile":
                self._merge(self.clcompile, element, where)
            elif name == "Link":
                self._merge(self.link, element, where)
            elif name in ("PreBuildEvent", "PostBuildEvent"):
                # A shell command MSBuild runs as part of the build. What it
                # produces cannot be reproduced by reading the project.
                if "".join(element.itertext()).strip():
                    raise Refusal(
                        f"{where}: <{name}> runs a command as part of the build, "
                        f"which is not reproduced here"
                    )
            elif name in self.INERT_SECTIONS:
                inert = self.INERT_SECTIONS[name]
                if inert is not None:
                    for child in element:
                        if tag(child) not in inert:
                            raise Refusal(
                                f"{where}: <ItemDefinitionGroup><{name}><{tag(child)}> "
                                f"changes how a reference is consumed, and this builds "
                                f"every reference the same way"
                            )
            else:
                raise Refusal(
                    f"{where}: <ItemDefinitionGroup><{name}> is not understood"
                )

    METADATA = re.compile(r"%\(([^)]*)\)")

    def _merge(self, into, element, where):
        """Merge one ItemDefinitionGroup section, resolving %(Name) as "so far"."""
        for child in element:
            if not self.condition(child.get("Condition"), where):
                continue
            name = tag(child)
            value = self.expand("".join(child.itertext()), where)
            value = self.METADATA.sub(
                lambda m: into.get(m.group(1), "") if m.group(1) == name else "", value
            )
            into[name] = " ".join(value.split())


def semicolon_list(value):
    return unique(
        [part.strip() for part in value.replace("\n", ";").split(";") if part.strip()]
    )


def unique(values):
    """Order preserved, repeats dropped."""
    return list(dict.fromkeys(values))


class Description:
    """The evaluated project, in the terms build.sh and build-project.sh use."""

    def __init__(self, evaluator):
        self.evaluator = evaluator
        self.directory = evaluator.directory
        properties = evaluator.properties
        self.type = properties.get("ConfigurationType", "Application")
        if self.type not in ("Application", "StaticLibrary"):
            raise Refusal(
                f"ConfigurationType {self.type!r}: only Application and StaticLibrary "
                f"are built here"
            )
        self.name = (
            properties.get("TargetName")
            or properties.get("RootNamespace")
            or evaluator.project.stem
        )
        self.sources = {"cpp": [], "c": []}
        for item in evaluator.items.get("ClCompile", []):
            language = "c" if item["path"].suffix.lower() == ".c" else "cpp"
            self.sources[language].append(self._relative(item["path"]))
        self.compile_flags, self.includes, self.defines, self.std, self.pch = (
            self._clcompile()
        )
        self.link = self._link()
        self.references = [
            self._relative(item["path"])
            for item in evaluator.items.get("ProjectReference", [])
        ]
        self.idl = next(
            (self._relative(item["path"]) for item in evaluator.items.get("Midl", [])),
            None,
        )
        self.manifest = next(
            (
                self._relative(item["path"])
                for item in evaluator.items.get("AppxManifest", [])
            ),
            None,
        )
        self.executable = self._executable()
        self._check_architecture()
        self.deploy = self._deploy()
        self.packages = self._packages()
        self.undefined = sorted(evaluator.undefined)
        self.skipped = sorted(evaluator.skipped)

    def _manifest_root(self):
        path = self.directory / self.manifest
        try:
            return ET.parse(path).getroot()
        except (ET.ParseError, OSError) as error:
            raise Refusal(f"{self.manifest}: not readable as XML: {error}") from error

    def _executable(self):
        """The name the OS will look for, taken from the manifest and checked
        against the one the project builds.

        They have to agree: the package installs either way and then fails to
        launch, which reads as an application bug rather than as a build that
        wrote its executable under another name."""
        if self.type != "Application" or not self.manifest:
            return f"{self.name}.exe"
        root = self._manifest_root()
        declared = next(
            (
                element.get("Executable")
                for element in root.iter()
                if tag(element).endswith("Application") and element.get("Executable")
            ),
            None,
        )
        if not declared:
            raise Refusal(
                f"{self.manifest} declares no <Application Executable=…>, so nothing "
                f"says what the package should start"
            )
        if declared != f"{self.name}.exe":
            raise Refusal(
                f"{self.manifest} starts {declared!r}, the project builds "
                f"{self.name + '.exe'!r}. The package would install and fail to "
                f"launch; set the project's TargetName or the manifest's Executable "
                f"so that they agree."
            )
        return declared

    def _check_architecture(self):
        """Identity/@ProcessorArchitecture has to agree with the platform.

        The manifest is copied into the layout verbatim, so a --platform ARM64
        build would otherwise ship its ARM64 executable under an identity still
        claiming x64 — a mismatch nothing reports until a device is asked to
        install it."""
        if self.type != "Application" or not self.manifest:
            return
        expected = MANIFEST_ARCHITECTURE.get(
            self.evaluator.properties.get("Platform", "").lower()
        )
        if expected is None:
            return
        # tag() strips the MSBuild namespace; the manifest carries the appx one,
        # so split on the brace ElementTree leaves in front of the local name.
        identity = next(
            (
                element.get("ProcessorArchitecture")
                for element in self._manifest_root().iter()
                if element.tag.split("}")[-1] == "Identity"
            ),
            None,
        )
        if identity is None or identity.lower() in ("neutral", expected):
            return
        raise Refusal(
            f"{self.manifest} declares ProcessorArchitecture={identity!r}, and "
            f"this is an {expected} build. The layout would carry an {expected} "
            f"executable under an identity claiming {identity!r}; set the "
            f"manifest's Identity/@ProcessorArchitecture to {expected!r}, or "
            f"build with the platform the manifest names."
        )

    def _relative(self, path):
        try:
            return os.path.relpath(path, self.directory)
        except ValueError:
            return str(path)

    def _clcompile(self):
        settings = dict(self.evaluator.clcompile)
        flags, includes, defines = [], [], []
        std = {"cxx": "c++20", "c": None}
        pch = None

        includes = [
            self._relative(self.directory / windows_path(entry))
            for entry in semicolon_list(
                settings.pop("AdditionalIncludeDirectories", "")
            )
        ]
        defines = semicolon_list(settings.pop("PreprocessorDefinitions", ""))

        for name, value in list(settings.items()):
            if name in IGNORED_CLCOMPILE:
                continue
            if name == "LanguageStandard":
                # stdcpp17 is overridden, not honoured: C++/WinRT below C++20
                # reaches for <experimental/coroutine>, whose first line is an
                # #error refusing clang. See the README's gotcha list, item 1.
                if value in ("stdcpp17", "stdcpp14", "Default", ""):
                    std["cxx"] = "c++20"
                elif value == "stdcpp20":
                    std["cxx"] = "c++20"
                elif value == "stdcpplatest":
                    std["cxx"] = "c++23"
                else:
                    raise Refusal(f"LanguageStandard {value!r} is not understood")
            elif name == "LanguageStandard_C":
                std["c"] = {"stdc11": "c11", "stdc17": "c17", "Default": None}.get(
                    value, "refuse"
                )
                if std["c"] == "refuse":
                    raise Refusal(f"LanguageStandard_C {value!r} is not understood")
            elif name == "PrecompiledHeader":
                if value == "Use":
                    pch = settings.get("PrecompiledHeaderFile", "pch.h")
                elif value not in ("NotUsing", "", "Create"):
                    raise Refusal(f"PrecompiledHeader {value!r} is not understood")
            elif name == "PrecompiledHeaderFile":
                continue
            elif name == "Optimization":
                flags.append(self._lookup(OPTIMIZATION, name, value))
            elif name == "RuntimeLibrary":
                # In an app container the DLL runtimes are overridden to their
                # static counterparts, not honoured: xwin carries no store CRT
                # import libraries, so /MD would import the desktop
                # VCRUNTIME140.dll and activation fails as 0x80270300 (Xbox
                # Series S, OS 26100.8866; statically linked, the same
                # application launches). The whole story is the README's
                # gotcha list, item 19. This is the one place the evaluator
                # changes MSBuild's answer instead of mirroring or refusing it.
                container = (
                    self.evaluator.properties.get("AppContainerApplication", "")
                    == "true"
                )
                if container and value.endswith("DLL"):
                    value = value[: -len("DLL")]
                flags.append(self._lookup(RUNTIME_LIBRARY, name, value))
            elif name == "ExceptionHandling":
                flags.append(self._lookup(EXCEPTION_HANDLING, name, value))
            elif name == "FavorSizeOrSpeed":
                flags.append(self._lookup(FAVOR, name, value))
            elif name == "BasicRuntimeChecks":
                flags.append(self._lookup(BASIC_RUNTIME_CHECKS, name, value))
            elif name == "ConformanceMode":
                flags.append("/permissive-" if value == "true" else "/permissive")
            elif name == "IntrinsicFunctions":
                flags.append("/Oi" if value == "true" else "")
            elif name == "InlineFunctionExpansion":
                flags.append(
                    {
                        "Disabled": "/Ob0",
                        "OnlyExplicitInline": "/Ob1",
                        "AnySuitable": "/Ob2",
                    }.get(value, "")
                )
            elif name == "WarningLevel":
                flags.append(
                    {
                        "TurnOffAllWarnings": "/W0",
                        "Level1": "/W1",
                        "Level2": "/W2",
                        "Level3": "/W3",
                        "Level4": "/W4",
                        "EnableAllWarnings": "/Wall",
                    }.get(value, "/W3")
                )
            elif name == "TreatWarningAsError":
                flags.append("/WX" if value == "true" else "")
            elif name == "DisableSpecificWarnings":
                flags += [f"/wd{w}" for w in semicolon_list(value)]
            elif name == "CompileAsWinRT":
                if value != "false":
                    raise Refusal(
                        "CompileAsWinRT is true: that is C++/CX (/ZW), a different "
                        "language from the C++/WinRT this builds"
                    )
            elif name == "AdditionalOptions":
                flags += [
                    option for option in value.split() if not option.startswith("%")
                ]
            else:
                raise Refusal(
                    f"ClCompile <{name}>{value}</{name}> has no equivalent here. "
                    f"Add one to the table in read-vcxproj.py, or remove the setting."
                )
        # The same flag can arrive twice — /Oi from IntrinsicFunctions and again
        # from an AdditionalOptions that spells it out, or an AdditionalOptions
        # repeated in the base and per-configuration groups. MSBuild passes both
        # and so could this, but identical flags say nothing twice.
        return unique([flag for flag in flags if flag]), includes, defines, std, pch

    @staticmethod
    def _lookup(table, name, value):
        if value not in table:
            raise Refusal(f"{name} {value!r} is not understood")
        return table[value]

    def _link(self):
        settings = dict(self.evaluator.link)
        libpath = [
            self._relative(self.directory / windows_path(entry))
            for entry in semicolon_list(
                settings.pop("AdditionalLibraryDirectories", "")
            )
        ]
        libs = semicolon_list(settings.pop("AdditionalDependencies", ""))
        options = []
        for name, value in settings.items():
            if name in IGNORED_CLCOMPILE:
                continue
            if name == "SubSystem":
                continue  # build.sh --uwp sets /subsystem:windows
            if name == "AdditionalOptions":
                options += [o for o in value.split() if not o.startswith("%")]
            elif name in ("IgnoreSpecificDefaultLibraries",):
                options += [f"/nodefaultlib:{lib}" for lib in semicolon_list(value)]
            else:
                raise Refusal(
                    f"Link <{name}>{value}</{name}> has no equivalent here. "
                    f"Add one to the table in read-vcxproj.py, or remove the setting."
                )
        return {"libpath": libpath, "libs": libs, "options": options}

    def _deploy(self):
        """What ships inside the package besides the executable and the winmd.

        An <Image> or <Content> item is packaged unless it says otherwise —
        that is how a project's assets get in without every one of them
        repeating DeploymentContent. A <None> item is not, unless it asks:
        that is where a DLL from a NuGet package's runtimes/win-x64/native is
        declared, next to the TargetPath it needs beside the executable.
        """
        deployed = []
        for kind, by_default in (("None", False), ("Image", True), ("Content", True)):
            for item in self.evaluator.items.get(kind, []):
                metadata = item["metadata"]
                asked = metadata.get("DeploymentContent", "").lower()
                if asked not in ("true", "false", ""):
                    raise Refusal(
                        f"DeploymentContent {asked!r} is neither true nor false"
                    )
                if not (asked == "true" or (asked == "" and by_default)):
                    continue
                source = self._relative(item["path"])
                # TargetPath is where the file goes inside the package, written
                # with Windows separators; the layout is built on this side.
                target = windows_path(metadata.get("TargetPath") or source)
                deployed.append({"source": source, "target": target})
        return deployed

    def _packages(self):
        packages = [
            {"id": item["path"].name, "version": item["metadata"].get("Version", "")}
            for item in self.evaluator.items.get("PackageReference", [])
        ]
        config = self.directory / "packages.config"
        if config.is_file():
            try:
                for element in ET.parse(config).getroot():
                    packages.append(
                        {"id": element.get("id"), "version": element.get("version")}
                    )
            except ET.ParseError as error:
                raise Refusal(
                    f"packages.config: not readable as XML: {error}"
                ) from error
        return packages

    def as_dict(self):
        return {
            "project": str(self.evaluator.project),
            "directory": str(self.directory),
            "name": self.name,
            "executable": self.executable,
            "type": self.type,
            "sources": self.sources,
            "includes": self.includes,
            "defines": self.defines,
            "std": self.std,
            "pch": self.pch,
            "options": self.compile_flags,
            "link": self.link,
            "references": self.references,
            "idl": self.idl,
            "manifest": self.manifest,
            "deploy": self.deploy,
            "packages": self.packages,
            "undefined": self.undefined,
            "skipped": self.skipped,
        }

    def as_flags(self):
        """The whole project as build.sh arguments, one per line so that bash
        can read them without splitting on the spaces inside a path.

        Everything build.sh takes itself comes before the `--`, which consumes
        the rest for the compiler. Paths are relative to the project directory,
        as everywhere else here; build-project.sh is what makes them absolute.
        """
        lines = []
        for directory in self.includes:
            lines += ["-I", directory]
        if self.pch:
            lines += ["--pch", self.pch]
        if self.type == "StaticLibrary":
            lines.append("--static-lib")
        else:
            lines.append("--uwp")
            for directory in self.link["libpath"]:
                lines += ["--link-arg", f"/libpath:{directory}"]
            for library in self.link["libs"]:
                lines += ["--link-arg", library]
            for option in self.link["options"]:
                lines += ["--link-arg", option]
        lines.append("--")
        lines += [f"/D{define}" for define in self.defines]
        lines += self.compile_flags
        return lines

    def field(self, path):
        """One dotted field, one value per line — so bash can `mapfile` it
        without a JSON parser on the far side. `sources.cpp`, `link.libs`,
        `std.cxx`, `deploy` (as source<TAB>target)."""
        value = self.as_dict()
        for step in path.split("."):
            if not isinstance(value, dict) or step not in value:
                raise Refusal(f"no such field: {path}")
            value = value[step]
        if value is None:
            return []
        if isinstance(value, list):
            return [
                "\t".join(str(v) for v in item.values())
                if isinstance(item, dict)
                else str(item)
                for item in value
            ]
        if isinstance(value, dict):
            return [f"{k}\t{v}" for k, v in value.items()]
        return [str(value)]


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[1],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("project", type=pathlib.Path)
    parser.add_argument("--config", default="Release")
    parser.add_argument("--platform", default="x64")
    parser.add_argument(
        "--property",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="MSBuild's /p:. Wins over the file, as a global property does, and "
        "so reaches a project's own switches — including one that decides "
        "whether a ProjectReference exists.",
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_const", const="json", dest="output")
    output.add_argument("--flags", action="store_const", const="flags", dest="output")
    output.add_argument(
        "--field",
        metavar="PATH",
        help="one dotted field, one value per line: sources.cpp, link.libs, "
        "std.cxx, type, deploy",
    )
    arguments = parser.parse_args()

    globals_ = {}
    for assignment in arguments.property:
        name, separator, value = assignment.partition("=")
        if not separator or not name:
            print(
                f"error: --property wants NAME=VALUE, got {assignment!r}",
                file=sys.stderr,
            )
            return 1
        globals_[name] = value

    try:
        description = Description(
            Evaluator(arguments.project, arguments.config, arguments.platform, globals_)
        )
    except Refusal as refusal:
        print(f"error: {refusal}", file=sys.stderr)
        return 1

    try:
        if arguments.field:
            lines = description.field(arguments.field)
            if lines:
                print("\n".join(lines))
        elif arguments.output == "flags":
            print("\n".join(description.as_flags()))
        else:
            print(json.dumps(description.as_dict(), indent=2))
    except Refusal as refusal:
        print(f"error: {refusal}", file=sys.stderr)
        return 1
    if description.undefined and not arguments.field:
        print(
            "note: no value anywhere for "
            + ", ".join(f"$({name})" for name in description.undefined)
            + " — empty, as MSBuild would have them",
            file=sys.stderr,
        )
    if description.skipped and not arguments.field:
        print(
            "note: not evaluated: "
            + ", ".join(description.skipped)
            + " — a .targets is MSBuild's actions, and this toolchain is its own",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
