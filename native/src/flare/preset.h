// FLARE — presets.
//
// A preset is JSON holding only what differs from the defaults, so a file
// stays small and a parameter added in a later version arrives at its default
// in an older preset rather than at whatever happened to be at that index.
#pragma once

#include "json.h"

#include <string>
#include <vector>

namespace flare {

class Synth;

/// The tag vocabularies the browser filters on.
extern const char *TYPE_TAGS;
extern const char *STYLE_TAGS;

struct PresetMeta {
	std::string name, author, type, style, pack, comment;
	std::string path;
	/// Eight macro labels, empty where the preset does not name one.
	std::string macros[8];
	bool favourite = false;
};

/// Everything about a preset, read without touching the synth. The browser
/// wants this for hundreds of files, so it stops at the metadata.
bool preset_read_meta(const std::string &path, PresetMeta &out);

bool preset_save(const Synth &s, const std::string &path);
bool preset_load(Synth &s, const std::string &path);

/// The same state as a string, for a host that keeps its own chunk.
std::string preset_to_string(const Synth &s);
bool preset_from_string(Synth &s, const std::string &text);

/// Where presets live. The first is the bank that ships with the plugin; the
/// second is where the user's own are written.
std::vector<std::string> preset_dirs();
std::string user_preset_dir();
/// Where FLARE looks for content the user has dropped in: wavetables, samples,
/// soundfonts, and packs.
std::vector<std::string> content_dirs();

} // namespace flare
