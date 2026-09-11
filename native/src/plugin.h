// Cadmium — the interface every processor in the engine speaks, stock or hosted.
//
// A Plug is plain C++: it knows nothing about Godot. The engine owns instances
// and calls them from the audio thread; the UI only ever sees the descriptor
// table (names, ranges, groups) and talks in parameter indices.
#pragma once

#include "dsp.h"

#include <cstdint>
#include <string>
#include <vector>

namespace cd {

enum ParamKind {
	P_FLOAT = 0,   // plain 0..1-ish number
	P_DB,          // decibels
	P_HZ,          // frequency, displayed with k suffix
	P_PCT,         // 0..1 shown as percent
	P_CHOICE,      // integer index into `choices`
	P_BOOL,
	P_SEMI,        // semitones / cents / integer
	P_MS,          // milliseconds
	P_SEC,
	P_BEATS,       // tempo-synced division index
	P_Q,
};

struct ParamDesc {
	const char *id;
	const char *name;
	float min, max, def;
	int kind;
	const char *group;    // panel heading, "" for ungrouped
	const char *choices;  // "Sine|Triangle|Saw" for P_CHOICE
	float skew;           // 1 linear; <1 packs resolution at the low end
	/// How many steps between min and max, 0 for continuous. A hosted plugin
	/// snaps a stepped parameter to its nearest step, so a control that does
	/// not know about the steps looks like one that is being ignored.
	int steps;
	/// The plugin reports this one but will not be told it: a latency readout,
	/// a meter. A knob that turns and springs back reads as a broken knob.
	bool readonly;
};

// What the UI draws instead of / on top of the generic knob grid.
enum PlugUI {
	UI_GENERIC = 0,
	UI_EQ,
	UI_COMP,
	UI_SAMPLER,
	UI_SOUNDFONT,
	UI_SYNTH,
	UI_DRUM,
	UI_ACID,
	UI_ORGAN,
	UI_MODAL,
	UI_VOX,
	UI_MULTIBAND,
	UI_TAPE,
	UI_IMAGER,
	UI_GATE,
	UI_PRISM,
	UI_CLIP,
	UI_DEESS,
	UI_DUCK,
	UI_SPAN,
	UI_TUNER,
	UI_MOD,
	UI_DELAY,
	UI_VERB,
	UI_FILTER,
	UI_SHAPE,
	UI_EXCITE,
	UI_GATEDYN,
	UI_TRANSIENT,
	UI_LEVEL,
	UI_VOCODER,
	UI_PITCH,
	UI_CONV,
	UI_OSC,
	UI_LOUD,
	UI_AMP,
	UI_WAVETABLE,
	/// The plugin describes its own panel and Cadmium draws it: the layout
	/// comes back from get_string("ui") and is built out of Cadmium's widgets.
	/// This is how a plugin that lives in its own library gets a designed
	/// interface without Cadmium knowing anything about it in particular.
	UI_DECLARED,
	UI_FLARE,
};


// Voice bookkeeping shared by every polyphonic stock instrument.
struct VoiceHead {
	bool active = false;
	bool held = false;
	int key = 0;
	int id = -1;
	float vel = 1.0f;
	uint64_t age = 0;
	// Per-note expression, carried from the note in the pattern. `fine` is in
	// semitones and is added to the key when the pitch is worked out; `gl`/`gr`
	// are the pan gains, one each side, and are 1 for a note in the middle.
	float fine = 0.0f;
	float gl = 1.0f, gr = 1.0f;

	void set_pan(float pan) {
		const float t = (clampf(pan, -1.0f, 1.0f) * 0.5f + 0.5f) * (float)PI * 0.5f;
		gl = std::cos(t) * 1.41421356f;
		gr = std::sin(t) * 1.41421356f;
	}
	/// The key this voice should sound at, detune included.
	float pitch() const { return (float)key + fine; }
};

// Picks a free voice, else the oldest released one, else the oldest held one.
template <typename V>
inline int alloc_voice(V *v, int n, uint64_t /*now*/) {
	for (int i = 0; i < n; i++) {
		if (!v[i].h.active) return i;
	}
	int best = -1;
	uint64_t oldest = ~0ull;
	for (int i = 0; i < n; i++) {
		if (!v[i].h.held && v[i].h.age < oldest) { oldest = v[i].h.age; best = i; }
	}
	if (best >= 0) return best;
	oldest = ~0ull;
	for (int i = 0; i < n; i++) {
		if (v[i].h.age < oldest) { oldest = v[i].h.age; best = i; }
	}
	return best < 0 ? 0 : best;
}

class Plug;

struct PlugDesc {
	const char *id;
	const char *name;
	const char *vendor;
	const char *category;   // Synth / Drum / EQ / Dynamics / Delay / Reverb / Distortion / Modulation / Utility
	bool instrument;
	int ui;
	std::vector<ParamDesc> params;
	Plug *(*make)();
};

class Plug {
public:
	virtual ~Plug() {}

	const PlugDesc *desc = nullptr;
	double sr = 48000.0;
	int block = 512;
	// Host transport, refreshed once per block.
	double bpm = 140.0, song_beat = 0.0;
	bool playing = false;

	std::vector<float> pv;   // current parameter values, indexed like desc->params

	void init(const PlugDesc *d, double rate, int blk) {
		desc = d;
		sr = rate;
		block = blk;
		pv.resize(d->params.size());
		for (size_t i = 0; i < d->params.size(); i++) pv[i] = d->params[i].def;
		prepare();
	}

	virtual void prepare() {}
	virtual void reset() {}

	// Voice input. `id` distinguishes overlapping notes of the same key.
	virtual void note_on(int key, float vel, int /*id*/) { (void)key; (void)vel; }
	virtual void note_off(int key, int /*id*/) { (void)key; }
	virtual void all_notes_off() {}
	virtual void pitch_bend(float /*semitones*/) {}
	virtual void mod_wheel(float /*v01*/) {}
	virtual void aftertouch(float /*v01*/) {}

	// Stereo, non-interleaved, in place. Instruments overwrite; effects read.
	virtual void process(float *L, float *R, int n) = 0;

	// Sidechain feed (set by the engine before process when a send routes here).
	virtual void sidechain(const float * /*L*/, const float * /*R*/, int /*n*/) {}
	virtual bool wants_sidechain() const { return false; }

	virtual void set_param(int i, float v) {
		if (i >= 0 && i < (int)pv.size()) pv[(size_t)i] = v;
		on_param(i);
	}
	virtual void on_param(int /*i*/) {}
	float p(int i) const { return pv[(size_t)i]; }
	int pi(int i) const { return (int)std::lround(pv[(size_t)i]); }
	bool pb(int i) const { return pv[(size_t)i] > 0.5f; }

	// Non-numeric settings (sample paths, soundfont presets...).
	virtual bool set_string(const std::string & /*key*/, const std::string & /*value*/) { return false; }
	virtual std::string get_string(const std::string & /*key*/) const { return std::string(); }

	/// Bulk data from the host: a decoded picture, a wavetable, an impulse.
	/// The host has the file readers, so anything that needs one arrives here
	/// already decoded rather than being parsed on the audio side.
	virtual bool set_data(const std::string & /*key*/, const float * /*data*/, int /*n*/) { return false; }

	// Extra data for the plugin's custom panel: spectra, curves, gain reduction.
	// Returns how many floats were written.
	virtual int aux(int /*what*/, float * /*out*/, int /*max*/) { return 0; }

	/// How the plugin itself spells a value. Empty means "no opinion", and the
	/// panel falls back to formatting it from the parameter's kind. A plugin
	/// that has units Cadmium does not -- cents, a named division, a ratio --
	/// is otherwise read out wrongly on its own controls.
	virtual std::string param_text(int /*index*/, float /*value*/) const { return std::string(); }

	/// Set by the sequencer immediately before note_on, so the voice being
	/// allocated can pick up the note's own pan and detune as it starts. A
	/// parameter rather than an argument because every instrument implements
	/// note_on and only some of them care.
	float next_pan = 0.0f;
	float next_fine = 0.0f;
	/// Takes the pending expression and clears it, so a note played live -- or
	/// by an instrument that ignores it -- is not detuned by the last one.
	void take_expr(VoiceHead &h) {
		h.fine = next_fine;
		h.set_pan(next_pan);
		next_pan = 0.0f;
		next_fine = 0.0f;
	}

	// --- what this processor last put out, for the panel to draw
	//
	// Every stock plugin gets a picture of its own output for nothing: the
	// engine drops a decimated copy in here after each block, and any panel can
	// draw it. Without this only the handful of processors that build their own
	// analysis have anything to show.
	static const int SCOPE_LEN = 1024;
	float scope[SCOPE_LEN * 2] = {0};
	int scope_w = 0;
	float out_peak = 0.0f;

	/// Called by the engine with whatever this plugin just wrote.
	void capture(const float *L, const float *R, int n) {
		float peak = 0.0f;
		for (int i = 0; i < n; i++) peak = std::max(peak, std::max(std::fabs(L[i]), std::fabs(R[i])));
		out_peak = std::max(peak, out_peak * 0.85f);
		// Sample for sample, keeping the tail of the block. A display that
		// draws a waveform or works out a spectrum needs consecutive samples;
		// one in every few would fold the top of the band back over the rest.
		const int start = std::max(0, n - SCOPE_LEN);
		for (int i = start; i < n; i++) {
			scope[(size_t)scope_w * 2] = L[i];
			scope[(size_t)scope_w * 2 + 1] = R[i];
			scope_w = (scope_w + 1) % SCOPE_LEN;
		}
	}

	virtual int active_voices() const { return 0; }
	// Tail in seconds after the last note ends, so the engine can idle a channel.
	virtual float tail() const { return 2.0f; }

	// --- the plugin's own interface, when it has one
	//
	// A hosted VST3 has always had these; a plugin out of the plugin folder
	// can have them too, and the window that shows one should not have to know
	// which kind it is holding. The defaults are what a processor with no
	// interface of its own does, which is nothing.
	virtual bool has_editor() { return false; }
	virtual bool open_editor(uint64_t /*parent*/, int /*x*/, int /*y*/, int /*w*/, int /*h*/) {
		return false;
	}
	virtual void close_editor() {}
	virtual void editor_idle() {}
	virtual bool editor_open() const { return false; }
	virtual void editor_size(int &w, int &h) { w = 0; h = 0; }
	virtual void editor_move(int /*x*/, int /*y*/, int /*w*/, int /*h*/) {}
	virtual bool editor_take_resize(int & /*w*/, int & /*h*/) { return false; }
	virtual bool editor_can_resize() const { return false; }
	virtual void editor_constrain(int & /*w*/, int & /*h*/) const {}
	virtual void editor_focus() {}
	virtual void editor_unfocus() {}
	virtual bool editor_has_keys() const { return false; }
	virtual bool editor_ready() const { return false; }
	virtual bool editor_started() const { return false; }
	virtual void editor_show() {}
	virtual bool editor_showing() const { return false; }
	virtual void editor_set_scale(float /*factor*/) {}
	virtual bool editor_grab(std::vector<unsigned char> & /*rgb*/, int & /*w*/, int & /*h*/) const {
		return false;
	}
	virtual std::string editor_debug() { return std::string(); }
	/// Moves the plugin's own interface made, as "index:value" lines. Drained
	/// rather than pushed: the thread drawing the interface and the one that
	/// records undo are not the same one.
	virtual std::string drain_edits() { return std::string(); }
	virtual bool take_restart() { return false; }
};

// A synced-division table shared by every tempo-aware effect.
static const int SYNC_DIV_COUNT = 13;
inline float sync_beats(int i) {
	static const float table[SYNC_DIV_COUNT] = {
		0.0625f, 0.125f, 0.1875f, 0.25f, 0.375f, 0.5f, 0.75f,
		1.0f, 1.5f, 2.0f, 3.0f, 4.0f, 8.0f
	};
	return table[std::max(0, std::min(SYNC_DIV_COUNT - 1, i))];
}
static const char *SYNC_NAMES = "1/64|1/32|1/32.|1/16|1/16.|1/8|1/8.|1/4|1/4.|1/2|1/2.|1 bar|2 bars";

// Registry — filled by the stock plugin translation units.
const std::vector<PlugDesc> &registry();
const PlugDesc *find_desc(const std::string &id);
Plug *make_plug(const std::string &id, double sr, int block);

void register_synths(std::vector<PlugDesc> &out);
void register_effects(std::vector<PlugDesc> &out);
void register_samplers(std::vector<PlugDesc> &out);
void register_effects2(std::vector<PlugDesc> &out);
void register_effects3(std::vector<PlugDesc> &out);
void register_drums(std::vector<PlugDesc> &out);
void register_synths2(std::vector<PlugDesc> &out);
void register_spectral(std::vector<PlugDesc> &out);
void register_effects4(std::vector<PlugDesc> &out);
void register_effects5(std::vector<PlugDesc> &out);
void register_flare(std::vector<PlugDesc> &out);

} // namespace cd
