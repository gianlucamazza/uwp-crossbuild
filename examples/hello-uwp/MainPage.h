#pragma once

#include "pch.h"

#include <memory>

namespace hello {

// A plain C++ class owning the visual tree — not a runtimeclass. Declaring it in
// the .idl would drag in IXamlMetadataProvider and MarkupCompilePass2, which is
// exactly the part of the UWP build that has no Linux equivalent. Building the
// tree in code avoids all of it. Real applications that cross-compile are
// structured this way for the same reason.
class MainPage {
  public:
    MainPage();
    winrt::Windows::UI::Xaml::Controls::Page Root() const {
        return m_root;
    }

  private:
    winrt::Windows::UI::Xaml::Controls::Page m_root{nullptr};
};

} // namespace hello
