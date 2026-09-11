// FLARE — SoundFont 2 reader.
//
// Parses an sfbk RIFF into its record tables and resolves a preset into the
// zones FLARE plays, with every generator already merged the way the spec
// says: instrument level absolute, preset level added on top.
#pragma once

#include "sample.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace flare {

struct Sf2PresetInfo {
	std::string name;
	int bank = 0;
	int program = 0;
};

class Sf2 {
public:
	bool load(const std::string &path);
	/// True once the file has been read. The samples move into the shared
	/// buffer the first time a preset is built, so this must not test pcm_.
	bool loaded() const { return !presets_.empty() && (!pcm_.empty() || shared_); }
	const std::vector<Sf2PresetInfo> &presets() const { return info_; }
	const std::string &name() const { return name_; }
	const std::string &path() const { return path_; }

	/// Builds a playable multisample from one preset. Every zone points into
	/// one shared buffer, so a 300 MB soundfont costs its size once however
	/// many presets are drawn from it.
	bool build(int preset_index, MultiSample &out);

private:
	struct Sample {
		std::string name;
		uint32_t start = 0, end = 0, loop_start = 0, loop_end = 0, rate = 44100;
		uint8_t root = 60;
		int8_t correction = 0;
		uint16_t link = 0, type = 1;
	};
	struct Preset { std::string name; int bank = 0, program = 0, bag_start = 0, bag_end = 0; };
	struct Inst { std::string name; int bag_start = 0, bag_end = 0; };
	struct Bag { uint16_t gen = 0, mod = 0; };

	std::string path_, name_;
	std::vector<float> pcm_;            // the whole sdta block, mono, normalised
	std::vector<Sample> samples_;
	std::vector<Preset> presets_;
	std::vector<Sf2PresetInfo> info_;
	std::vector<Inst> insts_;
	std::vector<Bag> pbag_, ibag_;
	std::vector<std::pair<uint16_t, int16_t>> pgen_, igen_;
	std::shared_ptr<SampleData> shared_;
};

/// One reader per file, shared by everything that asks for it.
///
/// A General MIDI soundfont is a hundred and fifty megabytes on disk and twice
/// that once its samples are floats. Four instances of the plugin each holding
/// their own copy is a gigabyte of the same bytes, so they hold the same one.
/// Dropped when the last user lets go.
std::shared_ptr<Sf2> sf2_get(const std::string &path);
/// Forgets any that nothing is using any more.
void sf2_forget_unused();

/// Seconds from a SoundFont timecent value.
float sf2_timecents(int16_t tc);
/// Hz from absolute cents.
float sf2_abs_cents_hz(float cents);

} // namespace flare
