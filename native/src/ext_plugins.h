// Cadmium — plugins that live in their own shared libraries.
//
// A file in the plugin folder that exports cd_plugin_entry_v1() is opened and
// its processors join the stock table. They are not VST3 and are not hosted:
// they speak Cadmium's own interface, so they get Cadmium's knobs, automation,
// undo and project saving with nothing in between -- and a plugin that
// publishes a panel description gets a panel drawn in Cadmium's own style.
#pragma once

#include "plugin.h"

#include <string>
#include <vector>

namespace cd {

/// Where external plugins are looked for.
std::vector<std::string> ext_plugin_dirs();

/// Opens everything in those folders once and adds what it finds. Called by
/// registry() while it is building the table.
void register_external(std::vector<PlugDesc> &out);

/// Creates one. The stock table's `make` takes no arguments and so cannot
/// carry which library a descriptor came from; external descriptors are
/// created through here instead.
Plug *make_external(const std::string &id, double sr, int block);

struct ExtProblem {
	std::string path;
	std::string error;
};
/// Libraries that would not open, and why. Shown rather than swallowed: a
/// plugin that is installed and silently missing is the thing nobody can
/// debug.
const std::vector<ExtProblem> &ext_problems();

} // namespace cd
