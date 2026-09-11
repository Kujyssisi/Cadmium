// FLARE — the synthesiser.
//
// Host-agnostic: this class knows about samples, wavetables, envelopes and
// nothing else. Both wrappers -- the Cadmium adapter and the VST3 plugin --
// drive the same object through the same calls, so a preset made in one plays
// identically in the other.
#pragma once

#include "dsp.h"
#include "fx.h"
#include "params.h"
#include "sample.h"
#include "wavetable.h"

#include <memory>
#include <string>
#include <vector>

namespace flare {

static const int MAX_VOICES = 32;
static const int MAX_UNISON = 9;
static const int MAX_LAYERS = 4;      // sampled zones one part can stack

class Sf2;

/// What one oscillator part is set to play. Held by the synth, referenced by
/// every voice, so switching a preset's sample does not touch the voices.
struct PartSource {
	int mode = 1;                     // matches the "Source" choice list
	int wave_index = 0;
	const WaveTable *table = nullptr; // resolved from mode + wave_index
	std::shared_ptr<MultiSample> ms;  // when the part is sampled
	std::string sample_path;          // what the preset asked for
	std::string wavetable_path;
	int user_table = -1;              // index into the bank's loaded tables
};

/// One element of a part's unison stack.
struct OscUnit {
	double phase = 0.0;
	float detune = 0.0f;              // semitones
	float gl = 1.0f, gr = 1.0f;
	float last = 0.0f;
};

struct PartVoice {
	OscUnit u[MAX_UNISON];
	int n = 1;
	float out_l = 0.0f, out_r = 0.0f;
	float mono = 0.0f;                // what the next part modulates with
	SampleReader rd[MAX_LAYERS];
	/// A copy rather than a pointer: the preset's own loop mode and start
	/// offset are applied on top of what the content says, and a voice must
	/// not edit the zone every other voice is reading.
	Zone zone[MAX_LAYERS];
	int layers = 0;
	/// A sampled zone can carry its own envelope and filter; when it does,
	/// these hold them so the synth's own settings do not overwrite what the
	/// content says about itself.
	Env zone_env[MAX_LAYERS];
	SVF zone_filter[MAX_LAYERS];
	bool zone_has_filter[MAX_LAYERS] = {false};
};

struct LfoVoice {
	double phase = 0.0;
	float value = 0.0f, held = 0.0f, target = 0.0f, smooth = 0.0f;
	float age = 0.0f;
	uint32_t seed = 1;
};

struct Voice {
	bool active = false, held = false;
	int key = 60, id = -1;
	float vel = 1.0f;
	uint64_t age = 0;
	int exclusive = 0;
	/// The pitch actually sounding, which glide walks towards `key`.
	float pitch = 60.0f, pitch_target = 60.0f;
	float glide_rate = 0.0f;
	float pan = 0.0f;
	float drift[PART_N] = {0};
	uint32_t rng_state = 1;
	float random_bi = 0.0f, random_uni = 0.0f;
	float note_order = 0.0f;

	PartVoice part[PART_N];
	OscUnit sub;
	Pink pink;
	float brown = 0.0f;
	OnePole noise_lp;
	OnePole noise_col;

	Env env[ENV_N];
	LfoVoice lfo[LFO_N];

	SVF svf[FILTER_N][2];
	Ladder ladder[FILTER_N];
	Biquad formant[FILTER_N][3];
	float formant_hz[FILTER_N] = {-1.0f, -1.0f};
	/// The comb filter's line. Allocated once, at prepare, because a voice
	/// carrying a fixed buffer big enough for a low comb note is sixty
	/// kilobytes and there are thirty-two of them.
	DelayLine comb[FILTER_N];
	DCBlock dc[2];

	Smoothed amp_smooth;
	float last_amp = 0.0f;
};

class Synth {
public:
	Synth();
	~Synth();

	void prepare(double sample_rate, int max_block);
	void reset();

	// --- parameters
	void set_param(int index, float value);
	float get_param(int index) const;
	const std::vector<float> &values() const { return pv_; }
	void set_all_default();

	// --- playing
	void note_on(int key, float velocity, int id);
	void note_off(int key, int id);
	void all_notes_off();
	void pitch_bend(float semitones);
	void mod_wheel(float v01);
	void aftertouch(float v01);
	void expression(float v01);
	void sustain_pedal(bool down);
	/// Per-note detune and pan, taken by the next note_on. Cadmium's sequencer
	/// carries these on the note itself.
	void set_next_expression(float pan, float fine_semitones);

	void set_transport(double bpm, double song_beat, bool playing);
	void process(float *L, float *R, int n);

	int active_voices() const;
	float peak() const { return peak_; }

	// --- content
	/// A part's sampled source. Understands a WAV, a folder of WAVs, and
	/// "file.sf2|12" for one preset out of a soundfont.
	bool load_sample(int part, const std::string &spec);
	bool load_wavetable(int part, const std::string &path);
	void clear_sample(int part);
	const PartSource &source(int part) const { return src_[part]; }

	/// The macro labels a preset carries. Eight strings, empty when unnamed.
	const std::string &macro_name(int i) const;
	void set_macro_name(int i, const std::string &name);

	std::string preset_name;
	std::string preset_author;
	std::string preset_type;    // one of the type tags
	std::string preset_style;   // comma-separated style tags
	std::string preset_pack;

private:
	double sr_ = 48000.0;
	int block_ = 512;
	double bpm_ = 140.0, beat_ = 0.0;
	bool playing_ = false;
	double free_beat_ = 0.0;   // keeps the arp running when the host is stopped

	std::vector<float> pv_;
	PartSource src_[PART_N];
	std::string macro_names_[MACRO_N];

	Voice v_[MAX_VOICES];
	uint64_t clock_ = 0;
	Rng rng_;

	float bend_ = 0.0f, wheel_ = 0.0f, touch_ = 0.0f, expr_ = 1.0f;
	bool sustain_ = false;
	float next_pan_ = 0.0f, next_fine_ = 0.0f;
	float peak_ = 0.0f;

	/// LFOs in a free-running or mono mode advance once for the whole
	/// instrument rather than once per voice.
	LfoVoice glfo_[LFO_N];

	FxRack fx_;
	FxParams fxp_;
	/// Modulation the matrix aims at the FX rack, summed over sounding voices.
	float global_mod_[MD_COUNT] = {0};
	bool global_mod_used_ = false;

	/// The matrix, compacted once a block. Walking sixteen slots per sample
	/// when two of them are set is most of the cost of an idle voice.
	struct ModSlot { int src = 0, dst = 0; float amt = 0.0f, curve = 0.0f; };
	std::vector<ModSlot> slots_;
	std::vector<int> dirty_dst_;

	// --- held notes, for mono modes and the arpeggiator
	struct Held { int key; float vel; int id; };
	std::vector<Held> held_;
	std::vector<int> latch_;
	int arp_step_ = 0, arp_last_ = -1, arp_dir_ = 1;
	double arp_next_beat_ = 0.0;
	int arp_voice_id_ = 100000;
	float gate_level_ = 1.0f;

	// --- working buffers
	std::vector<float> mix_l_, mix_r_;

	void resolve_source(int part);
	int alloc_voice(int key);
	void start_voice(Voice &v, int key, float vel, int id);
	void stop_voice(Voice &v);
	void render_voice(Voice &v, float *L, float *R, int n);
	float run_lfo(LfoVoice &l, int which, float dt, bool voice_level);
	void apply_fx_params();
	void run_arp(int n);
	void run_gate(float *L, float *R, int n);
	float mod_source(const Voice &v, int src) const;

	float p(int i) const { return pv_[(size_t)i]; }
	int pi(int i) const { return (int)std::lround(pv_[(size_t)i]); }
	bool pb(int i) const { return pv_[(size_t)i] > 0.5f; }
	/// A parameter inside a repeated block.
	float pblk(int base, int n, int stride, int off) const { return pv_[(size_t)(base + n * stride + off)]; }
	int piblk(int base, int n, int stride, int off) const {
		return (int)std::lround(pv_[(size_t)(base + n * stride + off)]);
	}
	bool pbblk(int base, int n, int stride, int off) const {
		return pv_[(size_t)(base + n * stride + off)] > 0.5f;
	}
};

} // namespace flare
