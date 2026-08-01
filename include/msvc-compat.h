// msvc-compat.h — force-included by build.sh before every translation unit.
//
// Two things MSVC arranges for you and clang does not. Both are properties of
// compiling MSVC-targeted C++/WinRT with clang, not of any particular project,
// so they belong here rather than in each pch.h — a source tree written for
// Visual Studio has to compile unmodified.
//
// Order matters: <version> must come before anything that includes winrt/base.h.

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
#include <version>

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
