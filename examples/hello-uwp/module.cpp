// Compiles the cppwinrt 2.x factory aggregator. It is what answers
// WINRT_GetActivationFactory for "hello.App", which is how the OS instantiates
// the class named by EntryPoint in AppxManifest.xml.
//
// module.g.cpp is an implementation unit: it needs factory_implementation::App
// already in scope, so App.h comes first.
#include "pch.h"

#include "App.h"

#include "module.g.cpp"
