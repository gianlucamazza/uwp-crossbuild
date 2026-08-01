// Minimal C++/WinRT compile test: the headers, not a full app.
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <cstdio>

int main()
{
    winrt::init_apartment();
    winrt::Windows::Foundation::Uri uri(L"https://example.com/path?q=1");
    std::printf("domain=%ls path=%ls\n", uri.Domain().c_str(), uri.Path().c_str());

    winrt::Windows::Foundation::Collections::IVector<int32_t> v =
        winrt::single_threaded_vector<int32_t>({1, 2, 3});
    std::printf("vector size=%u\n", v.Size());
    return 0;
}
