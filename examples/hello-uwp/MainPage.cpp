#include "pch.h"

#include "MainPage.h"

using namespace winrt;
using namespace winrt::Windows::UI::Xaml;
using namespace winrt::Windows::UI::Xaml::Controls;
using namespace winrt::Windows::UI::Xaml::Media;

namespace hello {

MainPage::MainPage() {
    TextBlock title;
    title.Text(L"Built on Linux");
    title.FontSize(48);
    title.HorizontalAlignment(HorizontalAlignment::Center);
    title.Foreground(SolidColorBrush{winrt::Windows::UI::Colors::White()});

    TextBlock subtitle;
    subtitle.Text(L"clang-cl + lld-link, packaged and signed by openappx");
    subtitle.FontSize(20);
    subtitle.HorizontalAlignment(HorizontalAlignment::Center);
    subtitle.Foreground(SolidColorBrush{winrt::Windows::UI::Colors::Gray()});

    StackPanel panel;
    panel.VerticalAlignment(VerticalAlignment::Center);
    panel.Spacing(16);
    panel.Children().Append(title);
    panel.Children().Append(subtitle);

    Grid root;
    root.Background(SolidColorBrush{winrt::Windows::UI::ColorHelper::FromArgb(255, 14, 17, 22)});
    root.Children().Append(panel);

    m_root = Page{};
    m_root.Content(root);
}

} // namespace hello
