// Stand-in for the generated tools/ui/ui.h.
//
// The real header is produced by the CMake build from a SvelteKit bundle: it
// runs npm, then compiles a host tool to turn the output into a C++ array of
// assets. Reproducing that in build.zig would make the build depend on npm.
//
// LLAMA_UI_HAS_ASSETS is deliberately NOT defined here, which switches
// server-http.cpp to its no-assets path. The declarations below are still
// required, because server-http.cpp calls llama_ui_get_assets() outside that
// guard.
//
// Consequence: llama-server builds and runs but serves no web UI. llama-cli is
// unaffected -- it never serves one.

#pragma once

#include <array>
#include <cstddef>
#include <string>

struct llama_ui_asset {
    std::string           name;
    const unsigned char * data;
    std::size_t           size;
    std::string           etag;
    std::string           type;
};

const llama_ui_asset * llama_ui_find_asset(const std::string & name);
bool llama_ui_use_gzip();
const std::array<llama_ui_asset, 0> & llama_ui_get_assets();
