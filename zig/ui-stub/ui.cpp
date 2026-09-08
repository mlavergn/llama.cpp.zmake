// Stand-in for the generated tools/ui/ui.cpp. See ui.h for why.

#include "ui.h"

static const std::array<llama_ui_asset, 0> g_assets = {};

const llama_ui_asset * llama_ui_find_asset(const std::string & name) {
    (void) name;
    return nullptr;
}

bool llama_ui_use_gzip() {
    return false;
}

const std::array<llama_ui_asset, 0> & llama_ui_get_assets() {
    return g_assets;
}
