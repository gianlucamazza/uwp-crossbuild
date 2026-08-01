#pragma once

// <windows.h> comes first because wWinMain needs HINSTANCE and PWSTR. Written
// the way a Visual Studio project would write it: build.sh force-includes
// include/msvc-compat.h ahead of this, which is where the two clang-specific
// adjustments live.
#ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
    #define NOMINMAX
#endif
#include <windows.h>

// WIN32_LEAN_AND_MEAN drops objbase.h, and with it unknwn.h. winrt/base.h has a
// static_assert requiring IUnknown to already exist, so include it by hand
// before any C++/WinRT header.
#include <unknwn.h>

#include <winrt/Windows.ApplicationModel.Activation.h>
// Needed even though nothing here names a collection type: UIElementCollection
// is an IVector, whose Append has a deduced return type and cannot be called
// before its definition is visible.
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Text.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Xaml.Controls.h>
#include <winrt/Windows.UI.Xaml.Media.h>
#include <winrt/Windows.UI.Xaml.h>
#include <winrt/base.h>
