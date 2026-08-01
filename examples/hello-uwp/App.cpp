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

// The OS starts this executable and XAML calls back into App. Application::Start
// creates the single-threaded apartment itself, so do not init_apartment first.
int __stdcall wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    Application::Start([](auto&&) { winrt::make<winrt::hello::implementation::App>(); });
    return 0;
}
