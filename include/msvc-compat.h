// msvc-compat.h — force-included by build.sh before every translation unit.
//
// Things MSVC arranges for you and clang does not. Properties of compiling
// MSVC-targeted C++/WinRT (and UWP) with clang, not of any particular project,
// so they belong here rather than in each pch.h — a source tree written for
// Visual Studio has to compile unmodified.
//
// Order matters: <version> must come before anything that includes winrt/base.h.
//
// Not here: anything that papers over a CRT whose version does not match the
// SDK. Under WINAPI_FAMILY_APP the SDK's own UCRT declares getenv, system and
// _putenv_s; a newer UCRT does not, and build.sh refuses that pairing instead
// (sdk_problem in common.sh).

// 1. Coroutines. base.h enables its coroutine support with
//
//        #ifdef __cpp_lib_coroutine
//        #include <coroutine>
//
//    — testing the macro *before* the header that would define it. Under MSVC
//    it is already there, because yvals_core.h arrives with whichever STL
//    header came first. A pch.h that opens with <windows.h> gives clang no such
//    luck, and coroutine support is silently compiled out. The symptom is a
//    perfectly ordinary IAsyncAction reported as "this function cannot be a
//    coroutine: ... has no member named 'promise_type'", pointing at your code.
//
//    Guarded because this header is force-included into every translation unit,
//    and a project that mixes C with C++ — a UWP application wrapping a C
//    library — has some that are C. <version> is a C++ header, and a C
//    translation unit stops on it with `fatal error: 'version' file not found`,
//    blaming a file the project never included. <windows.h> below is C too, and
//    the GetCurrentTime clash is worth undoing in both languages.
#ifdef __cplusplus
    #include <version>
#endif

// 2. GetCurrentTime. winbase.h defines it as a macro; XAML's Timeline declares
//    a method by that name, so a projection header stops parsing partway
//    through. The error blames the header. WIN32_LEAN_AND_MEAN and NOMINMAX are
//    set first because <windows.h> is being pulled in early either way, and
//    both are what a UWP project wants.
#ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
    #define NOMINMAX
#endif
#include <windows.h>
#undef GetCurrentTime
