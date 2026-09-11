// Cadmium — SoundFont 2 reader.
//
// Parses the RIFF sfbk chunks into flat record tables and resolves a preset +
// key + velocity into the list of sample zones that should sound, with every
// generator already merged (instrument level absolute, preset level offset, as
// the spec requires).
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace cd {

// Generator operators this player understands.
enum Sf2Gen {
	GEN_START_OFS = 0, GEN_END_OFS = 1, GEN_STARTLOOP_OFS = 2, GEN_ENDLOOP_OFS = 3,
	GEN_START_COARSE = 4, GEN_MODLFO_PITCH = 5, GEN_VIBLFO_PITCH = 6, GEN_MODENV_PITCH = 7,
	GEN_FILTER_FC = 8, GEN_FILTER_Q = 9, GEN_MODLFO_FC = 10, GEN_MODENV_FC = 11,
	GEN_END_COARSE = 12, GEN_MODLFO_VOL = 13, GEN_CHORUS = 15, GEN_REVERB = 16, GEN_PAN = 17,
	GEN_DELAY_MODLFO = 21, GEN_FREQ_MODLFO = 22, GEN_DELAY_VIBLFO = 23, GEN_FREQ_VIBLFO = 24,
	GEN_DELAY_MODENV = 25, GEN_ATTACK_MODENV = 26, GEN_HOLD_MODENV = 27, GEN_DECAY_MODENV = 28,
	GEN_SUSTAIN_MODENV = 29, GEN_RELEASE_MODENV = 30, GEN_KEY_MODENV_HOLD = 31, GEN_KEY_MODENV_DECAY = 32,
	GEN_DELAY_VOLENV = 33, GEN_ATTACK_VOLENV = 34, GEN_HOLD_VOLENV = 35, GEN_DECAY_VOLENV = 36,
	GEN_SUSTAIN_VOLENV = 37, GEN_RELEASE_VOLENV = 38, GEN_KEY_VOLENV_HOLD = 39, GEN_KEY_VOLENV_DECAY = 40,
	GEN_INSTRUMENT = 41, GEN_KEY_RANGE = 43, GEN_VEL_RANGE = 44, GEN_STARTLOOP_COARSE = 45,
	GEN_KEYNUM = 46, GEN_VELOCITY = 47, GEN_ATTENUATION = 48, GEN_ENDLOOP_COARSE = 50,
	GEN_COARSE_TUNE = 51, GEN_FINE_TUNE = 52, GEN_SAMPLE_ID = 53, GEN_SAMPLE_MODES = 54,
	GEN_SCALE_TUNING = 56, GEN_EXCLUSIVE = 57, GEN_ROOT_KEY = 58,
	GEN_COUNT = 60
};

struct Sf2Sample {
	std::string name;
	uint32_t start = 0, end = 0, loop_start = 0, loop_end = 0, rate = 44100;
	uint8_t root = 60;
	int8_t correction = 0;
	uint16_t link = 0, type = 1;
};

struct Sf2Preset {
	std::string name;
	int bank = 0, program = 0;
	int bag_start = 0, bag_end = 0;
};

// One resolved zone: everything a voice needs, no lookups left.
struct Sf2Zone {
	int sample = -1;
	int16_t gen[GEN_COUNT];
	bool has[GEN_COUNT];
};

class Sf2File {
public:
	std::string path;
	std::vector<int16_t> pcm;          // the whole sdta block
	std::vector<Sf2Sample> samples;
	std::vector<Sf2Preset> presets;
	std::string name;

	bool load(const std::string &file);
	// Zones that should sound for this note, in playing order.
	void zones_for(int preset_index, int key, int vel, std::vector<Sf2Zone> &out) const;
	int preset_count() const { return (int)presets.size(); }

private:
	struct Bag { uint16_t gen, mod; };
	struct Inst { std::string name; int bag_start = 0, bag_end = 0; };
	std::vector<Bag> pbag, ibag;
	std::vector<std::pair<uint16_t, int16_t>> pgen, igen;
	std::vector<Inst> insts;
	void apply_zone(const std::vector<std::pair<uint16_t, int16_t>> &gens, int from, int to,
			Sf2Zone &z, bool preset_level) const;
};

// Loading a 30 MB soundfont per channel would be absurd; instances share.
std::shared_ptr<Sf2File> sf2_get(const std::string &path);
void sf2_forget_unused();

// Unit conversions from the spec.
float sf2_timecents(int16_t tc);
float sf2_abs_cents_hz(float cents);

} // namespace cd
