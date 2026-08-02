#include "pch.h"

#include "App.h"
#include "MainPage.h"

using namespace winrt;
using namespace winrt::Windows::UI::Xaml;

namespace winrt::hello::implementation {

App::App() = default;

void App::OnLaunched(
    winrt::Windows::ApplicationModel::Activation::LaunchActivatedEventArgs const&) {
    m_page = std::make_shared<::hello::MainPage>();
    Window window = Window::Current();
    window.Content(m_page->Root());
    window.Activate();
}

} // namespace winrt::hello::implementation

// The OS starts this executable and XAML calls back into App.
//
// init_apartment() — the multi-threaded default — before Application::Start,
// and it is not optional: XAML requires the *first* access to the Application
// object to come from the MTA, and it owns creating its own UI thread from
// there. With no apartment, or with a single-threaded one, the factory call
// inside Start throws winrt::hresult_wrong_thread -> std::terminate -> abort,
// which the activation manager reports only as 0x8027025B; the origination
// message — "The Application Object must initially be accessed from the
// multi-thread apartment" — is visible only in a crash dump. Observed on an
// Xbox Series S, OS 26100.8866; README gotcha 17.
int __stdcall wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    winrt::init_apartment();
    Application::Start([](auto&&) { winrt::make<winrt::hello::implementation::App>(); });
    return 0;
}
