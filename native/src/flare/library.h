// FLARE — the browser's view of what is installed.
//
// Presets, soundfonts, sample folders, wavetables and packs, found once and
// handed to whichever interface is asking as JSON. Both hosts show the same
// list because both read it from here.
#pragma once

#include "preset.h"

#include <string>
#include <vector>

namespace flare {

struct ContentItem {
	std::string name;
	std::string path;
	std::string kind;    // "soundfont" | "sample" | "folder" | "wavetable" | "pack"
	int sub_count = 0;   // soundfont presets, samples in a folder
};

class Library {
public:
	/// Walks the preset and content folders. Cheap enough to call when a
	/// window opens; nothing is loaded, only listed.
	void scan();
	bool scanned() const { return scanned_; }

	const std::vector<PresetMeta> &presets() const { return presets_; }
	const std::vector<ContentItem> &content() const { return content_; }
	const std::vector<std::string> &packs() const { return packs_; }

	/// The distinct values found, for the filter rows.
	std::vector<std::string> pack_names() const;

	/// The whole listing as JSON, which is what an interface actually wants.
	std::string presets_json() const;
	std::string content_json() const;

	/// Every preset of a soundfont, listed without keeping the file open.
	static std::string soundfont_presets_json(const std::string &path);

private:
	bool scanned_ = false;
	std::vector<PresetMeta> presets_;
	std::vector<ContentItem> content_;
	std::vector<std::string> packs_;
};

/// One shared library per process: a dozen instances of the plugin should not
/// each walk the disk.
Library &library();

} // namespace flare
