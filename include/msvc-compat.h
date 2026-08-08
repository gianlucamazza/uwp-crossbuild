// msvc-compat.h — force-included by build.sh before every translation unit.
//
// Things MSVC arranges for you and clang does not. Properties of compiling
// MSVC-targeted C++/WinRT (and UWP) with clang, not of any particular project,
// so they belong here rather than in each pch.h — a source tree written for
// Visual Studio has to compile unmodified.
//
// Order matters: <version> must come before anything that includes winrt/base.h;
// the cstdlib bridge must come after <windows.h> so WINAPI_FAMILY is known.

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

// 3. cstdlib under WINAPI_FAMILY_APP. build.sh --uwp sets
//    /DWINAPI_FAMILY=WINAPI_FAMILY_APP (same as Visual Studio UWP). That is the
//    correct partition: desktop-only Win32 and CRT surface stays out of the
//    compile. The ucrt then gates getenv/system on
//    _CRT_USE_WINAPI_FAMILY_DESKTOP_APP, while the MSVC STL's <cstdlib> still
//    does `using _CSTD getenv;` / `using _CSTD system;` unconditionally — so
//    every TU that includes <cstdlib> fails with "no member named 'getenv' in
//    the global namespace". MSVC's own toolset papers over the same mismatch;
//    clang does not. Provide C declarations so the `using` resolves.
//
//    These are compile-time bridges only. They do not re-open the desktop CRT
//    partition, do not define the bodies, and do not license calling getenv or
//    system inside an AppContainer (those remain desktop APIs). If a project
//    actually references them, the linker / pe-import-audit surface that.
#if defined(WINAPI_FAMILY) && (WINAPI_FAMILY != WINAPI_FAMILY_DESKTOP_APP)
    #ifdef __cplusplus
extern "C" {
    #endif
char *__cdecl getenv(char const *);
int __cdecl system(char const *);
    #ifdef __cplusplus
}
    #endif
#endif
