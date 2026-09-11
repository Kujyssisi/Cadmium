// FLARE — the synthesiser.
#include "engine.h"

#include "preset.h"
#include "sf2.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <sys/stat.h>

namespace flare {

namespace {

/// A modulation amount bent by the slot's curve control. Negative is
/// logarithmic (quick off the mark), positive exponential (slow).
inline float bend_curve(float x, float c) {
	if (std::fabs(c) < 0.002f) return x;
	const float s = x < 0.0f ? -1.0f : 1.0f;
	const float a = std::fabs(x);
	return s * (c > 0.0f ? std::pow(a, 1.0f + c * 3.0f)
			: 1.0f - std::pow(1.0f - a, 1.0f - c * 3.0f));
}

/// Equal-power pan gains.
inline void pan_gains(float pan, float &gl, float &gr) {
	const float t = (clampf(pan, -1.0f, 1.0f) * 0.5f + 0.5f) * PI_F * 0.5f;
	gl = std::cos(t) * 1.41421356f;
	gr = std::sin(t) * 1.41421356f;
}

bool is_directory(const std::string &path) {
	struct stat st;
	return ::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool ends_with_ci(const std::string &s, const char *suffix) {
	const size_t n = std::strlen(suffix);
	if (s.size() < n) return false;
	for (size_t i = 0; i < n; i++)
		if (std::tolower((unsigned char)s[s.size() - n + i]) != std::tolower((unsigned char)suffix[i]))
			return false;
	return true;
}

} // namespace

Synth::Synth() {
	pv_.resize((size_t)param_count());
	set_all_default();
	held_.reserve(32);
}

Synth::~Synth() {}

void Synth::set_all_default() {
	const std::vector<ParamInfo> &d = params();
	for (size_t i = 0; i < d.size(); i++) pv_[i] = d[i].def;
	for (int i = 0; i < PART_N; i++) resolve_source(i);
}

void Synth::prepare(double sample_rate, int max_block) {
	sr_ = sample_rate > 0 ? sample_rate : 48000.0;
	block_ = std::max(16, max_block);
	mix_l_.assign((size_t)block_ + 16, 0.0f);
	mix_r_.assign((size_t)block_ + 16, 0.0f);
	fx_.prepare(sr_);
	// Long enough for a comb down to about 12 Hz, which is below where one
	// still sounds like a comb rather than a delay.
	const int comb_len = std::max(1024, std::min(1 << 16, (int)(sr_ / 12.0)));
	for (Voice &v : v_) {
		for (int e = 0; e < ENV_N; e++) v.env[e].sr = sr_;
		v.amp_smooth.set_time(3.0f, sr_);
		v.noise_lp.set_hz(12000.0f, sr_);
		v.noise_col.set_hz(20000.0f, sr_);
		for (int f = 0; f < FILTER_N; f++) v.comb[f].alloc(comb_len);
	}
	reset();
}

void Synth::reset() {
	for (Voice &v : v_) {
		v.active = v.held = false;
		for (int e = 0; e < ENV_N; e++) v.env[e].kill();
		for (int f = 0; f < FILTER_N; f++) {
			v.svf[f][0].reset(); v.svf[f][1].reset();
			v.ladder[f].reset();
			v.comb[f].clear();
			for (int k = 0; k < 3; k++) v.formant[f][k].reset();
			v.formant_hz[f] = -1.0f;
		}
		v.dc[0] = DCBlock();
		v.dc[1] = DCBlock();
	}
	fx_.reset();
	held_.clear();
	latch_.clear();
	bend_ = wheel_ = touch_ = 0.0f;
	expr_ = 1.0f;
	sustain_ = false;
	arp_step_ = 0;
	arp_last_ = -1;
	arp_dir_ = 1;
	arp_next_beat_ = 0.0;
	free_beat_ = 0.0;
	gate_level_ = 1.0f;
	peak_ = 0.0f;
}

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
void Synth::set_param(int index, float value) {
	if (index < 0 || index >= (int)pv_.size()) return;
	const ParamInfo &d = params()[(size_t)index];
	float v = clampf(value, d.min, d.max);
	if (d.steps > 0) {
		// A stepped control that is not snapped looks, from the outside, like
		// one that is being ignored.
		const float span = d.max - d.min;
		if (span > 0.0f) v = d.min + std::round((v - d.min) / span * (float)d.steps) * (span / (float)d.steps);
	}
	pv_[(size_t)index] = v;

	const Layout &L = layout();
	for (int i = 0; i < PART_N; i++) {
		const int base = L.part + i * PRT_COUNT;
		if (index == base + PRT_SRC || index == base + PRT_WAVE) resolve_source(i);
	}
}

float Synth::get_param(int index) const {
	if (index < 0 || index >= (int)pv_.size()) return 0.0f;
	return pv_[(size_t)index];
}

const std::string &Synth::macro_name(int i) const {
	static const std::string empty;
	if (i < 0 || i >= MACRO_N) return empty;
	return macro_names_[i];
}

void Synth::set_macro_name(int i, const std::string &name) {
	if (i >= 0 && i < MACRO_N) macro_names_[i] = name;
}

void Synth::resolve_source(int part) {
	if (part < 0 || part >= PART_N) return;
	const Layout &L = layout();
	const int base = L.part + part * PRT_COUNT;
	PartSource &s = src_[part];
	s.mode = (int)std::lround(pv_[(size_t)(base + PRT_SRC)]);
	s.wave_index = (int)std::lround(pv_[(size_t)(base + PRT_WAVE)]);
	const WaveBank &b = WaveBank::get();
	if (s.mode != SRC_WAVE) {
		s.table = nullptr;
	} else if (s.user_table >= 0) {
		// A table the preset loaded from a file takes the place of the bank.
		s.table = b.user(s.user_table);
	} else if (s.wave_index < WAVE_ANALOG_COUNT) {
		s.table = &b.analog(s.wave_index);
	} else {
		s.table = &b.table(s.wave_index - WAVE_ANALOG_COUNT);
	}
}

// ---------------------------------------------------------------------------
// Content
// ---------------------------------------------------------------------------
bool Synth::load_sample(int part, const std::string &spec) {
	if (part < 0 || part >= PART_N || spec.empty()) return false;
	auto ms = std::make_shared<MultiSample>();

	std::string path = spec;
	int sf_preset = 0;
	const size_t bar = spec.find_last_of('|');
	if (bar != std::string::npos) {
		path = spec.substr(0, bar);
		sf_preset = std::atoi(spec.c_str() + bar + 1);
	}
	// A preset that names its content by file name rather than by where that
	// file happened to be when it was saved works on somebody else's machine.
	// An absolute path is still honoured, so nothing that used to load stops.
	if (path.find('/') == std::string::npos) {
		for (const std::string &dir : content_dirs()) {
			struct stat st;
			const std::string candidate = dir + "/" + path;
			if (::stat(candidate.c_str(), &st) == 0) { path = candidate; break; }
		}
	}

	bool ok = false;
	if (ends_with_ci(path, ".sf2") || ends_with_ci(path, ".sf3")) {
		if (std::shared_ptr<Sf2> sf = sf2_get(path)) {
			ok = sf->build(sf_preset, *ms);
			// Held, so the reader's cache entry stays valid and the next
			// instance to ask for this font gets this copy of it.
			ms->source = sf;
		}
	} else if (is_directory(path)) {
		ok = multisample_from_folder(path, *ms);
	} else {
		ok = multisample_from_wav(path, *ms);
	}
	if (!ok) return false;

	src_[part].ms = ms;
	src_[part].sample_path = spec;
	return true;
}

bool Synth::load_wavetable(int part, const std::string &path) {
	if (part < 0 || part >= PART_N) return false;
	const int idx = WaveBank::get().load_wav(path);
	if (idx < 0) return false;
	src_[part].user_table = idx;
	src_[part].wavetable_path = path;
	resolve_source(part);
	return true;
}

void Synth::clear_sample(int part) {
	if (part < 0 || part >= PART_N) return;
	src_[part].ms.reset();
	src_[part].sample_path.clear();
}

// ---------------------------------------------------------------------------
// Notes
// ---------------------------------------------------------------------------
void Synth::set_next_expression(float pan, float fine) {
	next_pan_ = pan;
	next_fine_ = fine;
}

int Synth::alloc_voice(int key) {
	const int limit = std::min(MAX_VOICES, std::max(1, pi(layout().master + MST_POLY)));
	// A repeat of a note already sounding takes that voice back, so a fast
	// trill does not eat the whole allocation.
	for (int i = 0; i < limit; i++)
		if (v_[i].active && v_[i].key == key && v_[i].held) return i;
	for (int i = 0; i < limit; i++)
		if (!v_[i].active) return i;
	int best = -1;
	uint64_t oldest = ~0ull;
	for (int i = 0; i < limit; i++)
		if (!v_[i].held && v_[i].age < oldest) { oldest = v_[i].age; best = i; }
	if (best >= 0) return best;
	oldest = ~0ull;
	for (int i = 0; i < limit; i++)
		if (v_[i].age < oldest) { oldest = v_[i].age; best = i; }
	return best < 0 ? 0 : best;
}

void Synth::start_voice(Voice &v, int key, float vel, int id) {
	const Layout &L = layout();
	const int mode = pi(L.master + MST_VOICE_MODE);
	const bool was_active = v.active;

	v.active = true;
	v.held = true;
	v.key = key;
	v.id = id;
	v.vel = clampf(vel, 0.0f, 1.0f);
	v.age = clock_++;
	v.pan = next_pan_;
	v.pitch_target = (float)key + next_fine_;
	v.note_order = clampf((float)held_.size() / 8.0f, 0.0f, 1.0f);
	next_pan_ = 0.0f;
	next_fine_ = 0.0f;

	// Glide. "Legato only" slides just when a note was already sounding, which
	// is the behaviour that makes a lead playable.
	const float glide_ms = p(L.master + MST_GLIDE);
	const int glide_mode = pi(L.master + MST_GLIDE_MODE);
	const bool slide = glide_ms > 0.5f && glide_mode != 2
			&& (glide_mode == 0 || (mode != 0 && was_active));
	if (!slide || !was_active) v.pitch = v.pitch_target;
	v.glide_rate = slide ? 1000.0f / (glide_ms * (float)sr_) : 1e9f;

	v.rng_state = (uint32_t)(key * 2654435761u + clock_ * 40503u + 1u);
	Rng r(v.rng_state);
	v.random_bi = r.bi();
	v.random_uni = r.uni();
	v.rng_state = r.s;
	for (int i = 0; i < PART_N; i++) v.drift[i] = r.bi();

	// --- oscillator parts
	for (int i = 0; i < PART_N; i++) {
		PartVoice &pv = v.part[i];
		const int un = std::max(1, std::min(MAX_UNISON, piblk(L.part, i, PRT_COUNT, PRT_UNISON)));
		pv.n = un;
		const float spread = pblk(L.part, i, PRT_COUNT, PRT_SPREAD);
		const float phase = pblk(L.part, i, PRT_COUNT, PRT_PHASE);
		const float rand = pblk(L.part, i, PRT_COUNT, PRT_PHASE_RAND);
		for (int u = 0; u < un; u++) {
			// Detune runs symmetrically about the centre; with one voice it is
			// zero, which is what makes unison=1 identical to no unison.
			const float t = un == 1 ? 0.0f : ((float)u / (float)(un - 1)) * 2.0f - 1.0f;
			pv.u[u].detune = t;
			pan_gains(t * spread, pv.u[u].gl, pv.u[u].gr);
			pv.u[u].phase = (double)phase + (double)(r.uni() * rand);
			pv.u[u].phase -= std::floor(pv.u[u].phase);
			pv.u[u].last = 0.0f;
		}
		pv.layers = 0;
		pv.mono = 0.0f;

		const bool sampled = (src_[i].mode == SRC_SAMPLE || src_[i].mode == SRC_MULTISAMPLE);
		if (sampled && src_[i].ms && !src_[i].ms->empty()) {
			std::vector<const Zone *> hits;
			src_[i].ms->select(key, (int)std::lround(v.vel * 127.0f), hits);
			const int loop_mode = piblk(L.part, i, PRT_COUNT, PRT_LOOP_MODE);
			const float start = pblk(L.part, i, PRT_COUNT, PRT_START);
			for (const Zone *z : hits) {
				if (pv.layers >= MAX_LAYERS) break;
				const int k = pv.layers++;
				pv.zone[k] = *z;
				// The preset's own loop setting sits on top of the content's.
				if (loop_mode == 0) pv.zone[k].loop_mode = 0;
				else if (loop_mode == 2) pv.zone[k].loop_mode = 2;
				else if (loop_mode == 3) pv.zone[k].loop_mode = 3;
				else if (pv.zone[k].loop_mode == 0 && pv.zone[k].loop_start >= 0) pv.zone[k].loop_mode = 1;
				pv.rd[k].start(&pv.zone[k], sr_, start);
				pv.zone_has_filter[k] = pv.zone[k].has_filter;
				if (pv.zone_has_filter[k]) {
					pv.zone_filter[k].reset();
					pv.zone_filter[k].set(pv.zone[k].filter_hz,
							clampf((pv.zone[k].filter_q - 0.7f) / 8.0f, 0.0f, 0.9f), sr_);
				}
				if (pv.zone[k].has_env) {
					Env &e = pv.zone_env[k];
					e.sr = sr_;
					e.delay_s = pv.zone[k].delay;
					e.attack_s = pv.zone[k].attack;
					e.hold_s = pv.zone[k].hold;
					e.decay_s = pv.zone[k].decay;
					e.sustain = pv.zone[k].sustain;
					e.release_s = pv.zone[k].release;
					e.atk_curve = 0.0f;
					e.dec_curve = -0.6f;
					e.rel_curve = -0.6f;
					e.loop = false;
					e.gate_on();
				}
				if (pv.zone[k].exclusive) v.exclusive = pv.zone[k].exclusive;
			}
		}
	}

	// --- sub
	{
		const float ph = 0.0f;
		v.sub.phase = ph;
	}
	v.brown = 0.0f;

	// --- envelopes
	for (int e = 0; e < ENV_N; e++) {
		const int b = L.env + e * ENV_COUNT;
		Env &en = v.env[e];
		en.sr = sr_;
		const float keytrk = p(b + ENV_KEYTRK);
		// Key tracking shortens the envelope as you go up the keyboard, which
		// is what every sampled instrument that decays does.
		const float ks = std::pow(2.0f, -keytrk * ((float)key - 60.0f) / 24.0f);
		en.delay_s = p(b + ENV_DELAY) * 0.001f;
		en.attack_s = p(b + ENV_ATTACK) * 0.001f * ks;
		en.hold_s = p(b + ENV_HOLD) * 0.001f;
		en.decay_s = p(b + ENV_DECAY) * 0.001f * ks;
		en.sustain = p(b + ENV_SUSTAIN);
		en.release_s = p(b + ENV_RELEASE) * 0.001f * ks;
		en.atk_curve = p(b + ENV_ATK_C);
		en.dec_curve = p(b + ENV_DEC_C);
		en.rel_curve = p(b + ENV_REL_C);
		en.loop = pb(b + ENV_LOOP);
		if (!was_active || mode == 0 || pb(L.master + MST_MONO_RETRIG)) en.gate_on();
		else if (!en.active()) en.gate_on();
	}

	// --- per-voice LFOs
	for (int l = 0; l < LFO_N; l++) {
		const int b = L.lfo + l * LFO_COUNT;
		const int lmode = pi(b + LFO_MODE);
		if (lmode == 0 || lmode == 3 || lmode == 4) {
			v.lfo[l].phase = (double)p(b + LFO_PHASE);
			v.lfo[l].age = 0.0f;
			v.lfo[l].seed = v.rng_state + (uint32_t)l * 7919u;
			v.lfo[l].smooth = 0.0f;
		}
	}

	v.amp_smooth.snap(0.0f);
	v.last_amp = 0.0f;
}

void Synth::note_on(int key, float vel, int id) {
	if (key < 0 || key > 127) return;
	const Layout &L = layout();

	held_.push_back({key, vel, id});
	if (pb(L.arp + ARP_ON)) {
		if (pb(L.arp + ARP_LATCH)) {
			if (std::find(latch_.begin(), latch_.end(), key) == latch_.end()) latch_.push_back(key);
		}
		return;   // the arpeggiator plays the notes, not the keyboard
	}

	const int mode = pi(L.master + MST_VOICE_MODE);
	if (mode == 1 || mode == 2 || mode == 3) {
		// Mono: one voice, retaken. Legato holds the envelopes.
		Voice &v = v_[0];
		start_voice(v, key, vel, id);
		if (mode == 3) {
			// Unison mono: the extra voices are detuned copies of the same note.
			const int extra = std::min(MAX_VOICES - 1, 3);
			for (int i = 1; i <= extra; i++) {
				start_voice(v_[i], key, vel, id);
				v_[i].pitch += ((float)i - 2.0f) * 0.06f;
				v_[i].pitch_target = v_[i].pitch;
				v_[i].pan = ((float)i - 2.0f) * 0.4f;
			}
		}
		return;
	}

	const int slot = alloc_voice(key);
	Voice &v = v_[slot];
	if (v.active && v.held) stop_voice(v);
	start_voice(v, key, vel, id);

	// A soundfont exclusive class -- the closed hat that cuts the open one.
	if (v.exclusive) {
		for (Voice &o : v_) {
			if (&o != &v && o.active && o.exclusive == v.exclusive) {
				for (int e = 0; e < ENV_N; e++) o.env[e].release_s = std::min(o.env[e].release_s, 0.02f);
				stop_voice(o);
			}
		}
	}
}

void Synth::stop_voice(Voice &v) {
	v.held = false;
	for (int e = 0; e < ENV_N; e++) v.env[e].gate_off();
	for (int i = 0; i < PART_N; i++) {
		PartVoice &pv = v.part[i];
		for (int k = 0; k < pv.layers; k++) {
			pv.rd[k].release();
			if (pv.zone[k].has_env) pv.zone_env[k].gate_off();
		}
	}
}

void Synth::note_off(int key, int id) {
	for (size_t i = 0; i < held_.size(); i++) {
		if (held_[i].key == key && (id < 0 || held_[i].id == id)) {
			held_.erase(held_.begin() + (long)i);
			break;
		}
	}
	const Layout &L = layout();
	if (pb(L.arp + ARP_ON) && pb(L.arp + ARP_LATCH)) return;
	if (sustain_) return;

	const int mode = pi(L.master + MST_VOICE_MODE);
	if (mode != 0 && !pb(L.arp + ARP_ON)) {
		if (!held_.empty()) {
			// Fall back to whatever is still down, the way a mono synth does.
			const Held &h = held_.back();
			start_voice(v_[0], h.key, h.vel, h.id);
			return;
		}
		for (int i = 0; i < MAX_VOICES; i++) if (v_[i].active) stop_voice(v_[i]);
		return;
	}
	for (Voice &v : v_) {
		if (v.active && v.held && v.key == key && (id < 0 || v.id == id)) stop_voice(v);
	}
}

void Synth::all_notes_off() {
	held_.clear();
	latch_.clear();
	for (Voice &v : v_) if (v.active) stop_voice(v);
	arp_last_ = -1;
}

void Synth::pitch_bend(float semitones) { bend_ = semitones; }
void Synth::mod_wheel(float v) { wheel_ = clampf(v, 0.0f, 1.0f); }
void Synth::aftertouch(float v) { touch_ = clampf(v, 0.0f, 1.0f); }
void Synth::expression(float v) { expr_ = clampf(v, 0.0f, 1.0f); }

void Synth::sustain_pedal(bool down) {
	sustain_ = down;
	if (down) return;
	for (Voice &v : v_) {
		if (!v.active || !v.held) continue;
		bool still = false;
		for (const Held &h : held_) if (h.key == v.key) still = true;
		if (!still) stop_voice(v);
	}
}

void Synth::set_transport(double bpm, double beat, bool playing) {
	bpm_ = bpm > 20.0 ? bpm : 140.0;
	beat_ = beat;
	playing_ = playing;
}

int Synth::active_voices() const {
	int n = 0;
	for (const Voice &v : v_) if (v.active) n++;
	return n;
}

// ---------------------------------------------------------------------------
// Modulation
// ---------------------------------------------------------------------------
float Synth::mod_source(const Voice &v, int src) const {
	switch (src) {
		case MS_NONE: return 0.0f;
		case MS_ENV1: return v.env[0].level;
		case MS_ENV2: return v.env[1].level;
		case MS_ENV3: return v.env[2].level;
		case MS_ENV4: return v.env[3].level;
		case MS_LFO1: return v.lfo[0].value;
		case MS_LFO2: return v.lfo[1].value;
		case MS_LFO3: return v.lfo[2].value;
		case MS_VEL: return v.vel;
		case MS_KEY: return clampf(((float)v.key - 60.0f) / 48.0f, -1.0f, 1.0f);
		case MS_MODWHEEL: return wheel_;
		case MS_AFTERTOUCH: return touch_;
		case MS_BEND: return clampf(bend_ / 12.0f, -1.0f, 1.0f);
		case MS_EXPRESSION: return expr_;
		case MS_RANDOM: return v.random_bi;
		case MS_RANDOM_UNI: return v.random_uni;
		case MS_GATE: return gate_level_;
		case MS_NOTE_ON_ORDER: return v.note_order;
		default: break;
	}
	if (src >= MS_MACRO1 && src <= MS_MACRO8) return p(layout().macro + (src - MS_MACRO1));
	return 0.0f;
}

float Synth::run_lfo(LfoVoice &l, int which, float dt, bool /*voice_level*/) {
	const Layout &L = layout();
	const int b = L.lfo + which * LFO_COUNT;
	const int shape = pi(b + LFO_SHAPE);
	const bool sync = pb(b + LFO_SYNC);
	float hz;
	if (sync) {
		const float beats = sync_beats(pi(b + LFO_DIV));
		hz = (float)(bpm_ / 60.0) / std::max(0.01f, beats);
	} else {
		hz = p(b + LFO_RATE);
	}
	const int mode = pi(b + LFO_MODE);
	l.age += dt;

	const double before = l.phase;
	l.phase += (double)(hz * dt);
	const bool wrapped = l.phase >= 1.0;
	if (wrapped) l.phase -= std::floor(l.phase);
	if (mode == 3 && before + (double)(hz * dt) >= 1.0) {
		// One shot: stop at the end of the first cycle.
		l.phase = 0.9999;
	}

	const float ph = (float)l.phase;
	float raw;
	switch (shape) {
		case 0: raw = std::sin(TWO_PI_F * ph); break;
		case 1: raw = 4.0f * std::fabs(ph - 0.5f) - 1.0f; break;
		case 2: raw = ph * 2.0f - 1.0f; break;
		case 3: raw = 1.0f - ph * 2.0f; break;
		case 4: raw = ph < 0.5f ? 1.0f : -1.0f; break;
		case 5: raw = ph < 0.25f ? 1.0f : -1.0f; break;
		case 6: {
			if (wrapped) {
				Rng r(l.seed);
				l.held = r.bi();
				l.seed = r.s;
			}
			raw = l.held;
			break;
		}
		case 7: {
			if (wrapped) {
				Rng r(l.seed);
				l.target = r.bi();
				l.seed = r.s;
			}
			l.held += (l.target - l.held) * clampf(hz * dt * 6.0f, 0.0f, 1.0f);
			raw = l.held;
			break;
		}
		case 8: {
			// Steps: the gate sequencer's own pattern, read as an LFO.
			const int step = std::min(STEP_N - 1, (int)(ph * (float)STEP_N));
			raw = p(L.step + step) * 2.0f - 1.0f;
			break;
		}
		case 9: raw = std::pow(ph, 3.0f) * 2.0f - 1.0f; break;
		case 10: raw = std::pow(1.0f - ph, 3.0f) * 2.0f - 1.0f; break;
		case 11: {
			// Chaos: a logistic map stepped once a cycle. Wanders without ever
			// settling, which is what "organic" drift wants.
			if (wrapped) {
				l.smooth = l.smooth <= 0.0f || l.smooth >= 1.0f ? 0.4f : l.smooth;
				l.smooth = 3.94f * l.smooth * (1.0f - l.smooth);
				l.target = l.smooth * 2.0f - 1.0f;
			}
			l.held += (l.target - l.held) * clampf(hz * dt * 4.0f, 0.0f, 1.0f);
			raw = l.held;
			break;
		}
		default: raw = clampf((std::fabs(ph - 0.5f) * 4.0f - 1.0f) * 1.8f, -1.0f, 1.0f); break;
	}

	// Smoothing, then delay and fade-in, then depth.
	const float sm = p(b + LFO_SMOOTH);
	if (sm > 0.001f) {
		const float a = clampf(1.0f - sm * 0.999f, 0.001f, 1.0f);
		l.smooth += (raw - l.smooth) * a;
		raw = l.smooth;
	}
	const float delay_s = p(b + LFO_DELAY) * 0.001f;
	const float fade_s = p(b + LFO_FADE) * 0.001f;
	float env = 1.0f;
	if (l.age < delay_s) env = 0.0f;
	else if (fade_s > 0.0f) env = clampf((l.age - delay_s) / fade_s, 0.0f, 1.0f);
	if (mode == 4) {
		// Envelope mode: one rise, no cycling. The shape is the curve.
		env *= 1.0f;
		raw = raw * 0.5f + 0.5f;
	}
	l.value = raw * env * p(b + LFO_DEPTH);
	return l.value;
}

// ---------------------------------------------------------------------------
// One voice
// ---------------------------------------------------------------------------
void Synth::render_voice(Voice &v, float *L, float *R, int n) {
	const Layout &LY = layout();
	const float dt = 1.0f / (float)sr_;
	const int quality = pi(LY.master + MST_QUALITY);
	const float drift_amt = p(LY.master + MST_DRIFT);

	// Everything read per sample, hoisted.
	const float bend_up = p(LY.master + MST_BEND_UP);
	const float bend_dn = p(LY.master + MST_BEND_DN);
	const float master_semi = p(LY.master + MST_OCT) * 12.0f + p(LY.master + MST_SEMI)
			+ p(LY.master + MST_TUNE) * 0.01f;
	const float vel_vol = p(LY.master + MST_VEL_VOL);

	struct PartCache {
		bool on;
		int mode;
		float level, pan, tune, detune, blend, pos, warp, fm, rm, vel_sens;
		int warp_mode, filter, unison;
		bool keytrack;
		const WaveTable *table;
	} pc[PART_N];

	for (int i = 0; i < PART_N; i++) {
		const int b = LY.part + i * PRT_COUNT;
		pc[i].on = pb(b + PRT_ON);
		pc[i].mode = src_[i].mode;
		pc[i].level = db_to_gain(p(b + PRT_LEVEL));
		pc[i].pan = p(b + PRT_PAN);
		pc[i].tune = p(b + PRT_OCT) * 12.0f + p(b + PRT_SEMI) + p(b + PRT_FINE) * 0.01f;
		pc[i].detune = p(b + PRT_DETUNE);
		pc[i].blend = p(b + PRT_BLEND);
		pc[i].pos = p(b + PRT_POS);
		pc[i].warp = p(b + PRT_WARP);
		pc[i].warp_mode = pi(b + PRT_WARP_MODE);
		pc[i].fm = p(b + PRT_FM);
		pc[i].rm = p(b + PRT_RM);
		pc[i].filter = pi(b + PRT_FILTER);
		pc[i].unison = v.part[i].n;
		pc[i].keytrack = pb(b + PRT_KEYTRACK);
		pc[i].vel_sens = p(b + PRT_VEL);
		pc[i].table = src_[i].table;
	}

	const bool sub_on = pb(LY.sub + SUB_ON);
	const float sub_gain = db_to_gain(p(LY.sub + SUB_LEVEL));
	const int sub_wave = pi(LY.sub + SUB_WAVE);
	const float sub_oct = p(LY.sub + SUB_OCT) * 12.0f;
	float sub_gl, sub_gr;
	pan_gains(p(LY.sub + SUB_PAN), sub_gl, sub_gr);

	const bool noise_on = pb(LY.noise + NOI_ON);
	const int noise_type = pi(LY.noise + NOI_TYPE);
	const float noise_gain = db_to_gain(p(LY.noise + NOI_LEVEL));
	float noise_gl, noise_gr;
	pan_gains(p(LY.noise + NOI_PAN), noise_gl, noise_gr);
	v.noise_col.set_hz(p(LY.noise + NOI_CUT), sr_);

	struct FilterCache {
		bool on;
		int type, env_src, lfo_src;
		float cut, res, drive, keytrk, env_amt, lfo_amt, mix, spread;
	} fc[FILTER_N];
	for (int f = 0; f < FILTER_N; f++) {
		const int b = LY.filter + f * FLT_COUNT;
		fc[f].on = pb(b + FLT_ON);
		fc[f].type = pi(b + FLT_TYPE);
		fc[f].cut = p(b + FLT_CUT);
		fc[f].res = p(b + FLT_RES);
		fc[f].drive = db_to_gain(p(b + FLT_DRIVE));
		fc[f].keytrk = p(b + FLT_KEYTRK);
		fc[f].env_amt = p(b + FLT_ENV);
		fc[f].env_src = pi(b + FLT_ENV_SRC);
		fc[f].lfo_amt = p(b + FLT_LFO);
		fc[f].lfo_src = pi(b + FLT_LFO_SRC);
		fc[f].mix = p(b + FLT_MIX);
		fc[f].spread = p(b + FLT_PAN_SPREAD);
	}
	const int routing = pi(LY.filter_route);

	// Every destination is read every sample whether or not anything drives
	// it, so the whole array starts at zero; the per-sample clear below only
	// has to touch the ones the matrix actually writes.
	float md[MD_COUNT];
	std::memset(md, 0, sizeof(md));
	Rng vr(v.rng_state);

	for (int s = 0; s < n; s++) {
		// --- envelopes
		for (int e = 0; e < ENV_N; e++) v.env[e].next();
		// Velocity on an envelope scales its output, not its times.
		float envv[ENV_N];
		for (int e = 0; e < ENV_N; e++) {
			const float ve = p(LY.env + e * ENV_COUNT + ENV_VEL);
			envv[e] = v.env[e].level * lerpf(1.0f, v.vel, ve);
		}

		// --- LFOs. Free and mono ones were advanced once for the instrument.
		for (int l = 0; l < LFO_N; l++) {
			const int mode = pi(LY.lfo + l * LFO_COUNT + LFO_MODE);
			if (mode == 1 || mode == 2) v.lfo[l].value = glfo_[l].value;
			else run_lfo(v.lfo[l], l, dt, true);
		}

		// --- matrix
		for (int d : dirty_dst_) md[d] = 0.0f;
		for (const ModSlot &m : slots_) {
			const float x = bend_curve(mod_source(v, m.src), m.curve);
			md[m.dst] += x * m.amt;
		}
		if (global_mod_used_) {
			for (const ModSlot &m : slots_) {
				if (!mod_dst_is_global(m.dst)) continue;
				global_mod_[m.dst] += bend_curve(mod_source(v, m.src), m.curve) * m.amt / (float)n;
			}
		}

		// --- pitch
		if (v.pitch != v.pitch_target) {
			const float step = v.glide_rate * 24.0f;
			if (std::fabs(v.pitch_target - v.pitch) <= step) v.pitch = v.pitch_target;
			else v.pitch += v.pitch_target > v.pitch ? step : -step;
		}
		const float bend_semi = bend_ >= 0.0f ? bend_ * bend_up * 0.5f : bend_ * bend_dn * 0.5f;
		const float base_note = v.pitch + master_semi + bend_semi + md[MD_PITCH] * 24.0f;

		// --- oscillators, back to front so a modulator is fresh
		float dry_l[2] = {0.0f, 0.0f}, dry_r[2] = {0.0f, 0.0f};
		float bypass_l = 0.0f, bypass_r = 0.0f;

		for (int i = PART_N - 1; i >= 0; i--) {
			PartVoice &pv = v.part[i];
			if (!pc[i].on) { pv.out_l = pv.out_r = pv.mono = 0.0f; continue; }

			float l = 0.0f, r = 0.0f;
			const float pitch_mod = md[MD_A_PITCH + i] * 24.0f + md[MD_A_FINE + i] * 1.0f;
			const float note = (pc[i].keytrack ? base_note : 60.0f) + pc[i].tune + pitch_mod
					+ v.drift[i] * drift_amt * 0.06f;

			if (pc[i].mode == SRC_SAMPLE || pc[i].mode == SRC_MULTISAMPLE) {
				// Sampled.
				for (int k = 0; k < pv.layers; k++) {
					if (pv.rd[k].finished()) continue;
					const float off = zone_pitch_offset(pv.zone[k], note)
							+ (pc[i].keytrack ? 0.0f : 0.0f);
					const double step = std::pow(2.0, (double)off / 12.0);
					float zl, zr;
					pv.rd[k].next(step, zl, zr);
					float g = pv.zone[k].gain;
					if (pv.zone[k].has_env) g *= pv.zone_env[k].next();
					if (pv.zone_has_filter[k]) {
						float lp, bp, hp;
						pv.zone_filter[k].tick(zl, lp, bp, hp);
						zl = lp;
						pv.zone_filter[k].tick(zr, lp, bp, hp);
						zr = lp;
					}
					float gl, gr;
					pan_gains(pv.zone[k].pan, gl, gr);
					l += zl * g * gl;
					r += zr * g * gr;
				}
				pv.mono = (l + r) * 0.5f;
			} else if (pc[i].mode == SRC_NOISE) {
				// A noise part: unpitched, but it still runs through the filters.
				const float x = vr.bi() * 0.5f;
				l = r = x;
				pv.mono = x;
			} else if (pc[i].table) {
				const float hz = note_to_hz(note);
				const float det = pc[i].detune * (1.0f + md[MD_A_UNISON_DETUNE] * (i == 0 ? 1.0f : 0.0f));
				// The modulator is the next part round, so A<-B, B<-C, C<-A.
				const float fm_in = v.part[(i + 1) % PART_N].mono;
				const float fm_amt = (pc[i].fm + md[MD_FM]) * 4.0f;
				const float pos = clampf(pc[i].pos + md[MD_A_POS + i], 0.0f, 1.0f);
				const float warp = clampf(pc[i].warp + md[MD_A_WARP + i], -1.0f, 1.0f);
				const int un = pc[i].unison;
				const float norm = 1.0f / std::sqrt((float)un);

				for (int u = 0; u < un; u++) {
					OscUnit &o = pv.u[u];
					const float uhz = hz * std::pow(2.0f, o.detune * det * 0.5f / 12.0f);
					const float inc = uhz / (float)sr_;
					o.phase += (double)inc;
					if (o.phase >= 1.0) o.phase -= std::floor(o.phase);
					const int mip = mip_for(uhz * (quality >= 2 ? 1.0f : 1.4f), sr_);

					float ph = (float)o.phase + fm_in * fm_amt;
					ph -= std::floor(ph);
					float x;
					switch (pc[i].warp_mode) {
						case 1: {
							// Pulse width: the shape against a shifted copy.
							const float d = 0.5f + warp * 0.48f;
							float p2 = ph + d;
							p2 -= std::floor(p2);
							x = pc[i].table->read(pos, ph, mip) - pc[i].table->read(pos, p2, mip);
							x *= 0.7f;
							break;
						}
						case 2: {
							// Hard sync: the slave runs faster and is reset by
							// the master's own wrap, which is what ph already is.
							const float ratio = 1.0f + warp * 3.0f;
							float sp = ph * ratio;
							sp -= std::floor(sp);
							x = pc[i].table->read(pos, sp, std::max(0, mip - 1));
							break;
						}
						case 3: {
							// Bend: time inside the cycle is squeezed one way.
							const float k = std::pow(2.0f, warp * 2.0f);
							x = pc[i].table->read(pos, std::pow(ph, k), mip);
							break;
						}
						case 4: {
							float m = ph * (1.0f + std::fabs(warp));
							m = m > 1.0f ? 2.0f - m : m;
							x = pc[i].table->read(pos, clampf(m, 0.0f, 1.0f), mip);
							break;
						}
						case 5:
							x = pc[i].table->read(pos, ph, mip);
							x = std::sin(x * (1.0f + std::fabs(warp) * 5.0f) * 1.5f);
							break;
						case 6: {
							x = pc[i].table->read(pos, ph, mip);
							const float steps = lerpf(64.0f, 3.0f, std::fabs(warp));
							x = std::round(x * steps) / steps;
							break;
						}
						case 7: {
							// Casio-style phase distortion.
							const float k = clampf(0.5f + warp * 0.49f, 0.01f, 0.99f);
							const float d = ph < k ? ph / k * 0.5f : 0.5f + (ph - k) / (1.0f - k) * 0.5f;
							x = pc[i].table->read(pos, d, mip);
							break;
						}
						default: x = pc[i].table->read(pos, ph, mip); break;
					}
					if (pc[i].rm > 0.001f || md[MD_RM] != 0.0f) {
						const float amt = clampf(pc[i].rm + md[MD_RM], 0.0f, 1.0f);
						x = lerpf(x, x * v.part[(i + 1) % PART_N].mono * 2.0f, amt);
					}
					o.last = x;
					// The centre unison voice keeps its full level; the ones
					// either side come up with Blend, which is what makes a
					// supersaw go from one oscillator to seven on one knob.
					const float w = un == 1 ? 1.0f
							: lerpf(std::fabs(o.detune) < 0.001f ? 1.0f : 0.0f, 1.0f, pc[i].blend);
					l += x * o.gl * w;
					r += x * o.gr * w;
				}
				l *= norm;
				r *= norm;
				pv.mono = (l + r) * 0.5f;
			} else {
				pv.mono = 0.0f;
			}

			float gl, gr;
			pan_gains(clampf(pc[i].pan + md[MD_A_PAN + i], -1.0f, 1.0f), gl, gr);
			const float lvl = pc[i].level * db_to_gain(md[MD_A_LEVEL + i] * 24.0f)
					* lerpf(1.0f, v.vel, pc[i].vel_sens);
			l *= lvl * gl;
			r *= lvl * gr;
			pv.out_l = l;
			pv.out_r = r;

			switch (pc[i].filter) {
				case 0: dry_l[0] += l; dry_r[0] += r; break;
				case 1: dry_l[1] += l; dry_r[1] += r; break;
				case 2: dry_l[0] += l; dry_r[0] += r; dry_l[1] += l; dry_r[1] += r; break;
				default: bypass_l += l; bypass_r += r; break;
			}
		}

		// --- sub
		if (sub_on) {
			const float hz = note_to_hz(base_note + sub_oct);
			v.sub.phase += (double)(hz / (float)sr_);
			if (v.sub.phase >= 1.0) v.sub.phase -= std::floor(v.sub.phase);
			const float ph = (float)v.sub.phase;
			float x;
			switch (sub_wave) {
				case 1: x = 4.0f * std::fabs(ph - 0.5f) - 1.0f; break;
				case 2: x = WaveBank::get().analog(3).read_frame(0, ph, mip_for(hz, sr_)); break;
				case 3: x = WaveBank::get().analog(2).read_frame(0, ph, mip_for(hz, sr_)); break;
				case 4: x = WaveBank::get().analog(4).read_frame(0, ph, mip_for(hz, sr_)); break;
				default: x = std::sin(TWO_PI_F * ph); break;
			}
			const float g = sub_gain * db_to_gain(md[MD_SUB_LEVEL] * 24.0f);
			dry_l[0] += x * g * sub_gl;
			dry_r[0] += x * g * sub_gr;
		}

		// --- noise
		if (noise_on) {
			float x;
			switch (noise_type) {
				case 1: x = v.pink.next(vr); break;
				case 2: v.brown = clampf(v.brown + vr.bi() * 0.04f, -1.0f, 1.0f); x = v.brown * 3.0f; break;
				case 3: { const float w = vr.bi(); x = w - v.noise_lp.lp(w); break; }
				case 4: {
					// Vinyl: pink with the odd tick in it.
					x = v.pink.next(vr) * 0.7f;
					if (vr.uni() > 0.9994f) x += vr.bi() * 2.0f;
					break;
				}
				case 5: x = (vr.uni() > 0.5f ? 1.0f : -1.0f) * 0.6f; break;
				default: x = vr.bi(); break;
			}
			x = v.noise_col.lp(x);
			const float g = noise_gain * db_to_gain(md[MD_NOISE_LEVEL] * 24.0f);
			dry_l[0] += x * g * noise_gl;
			dry_r[0] += x * g * noise_gr;
		}

		// --- filters
		float out_l = bypass_l, out_r = bypass_r;
		float chain_l = dry_l[0], chain_r = dry_r[0];

		for (int f = 0; f < FILTER_N; f++) {
			if (routing == 0 && f == 1) {
				// Serial: filter 2 takes filter 1's output plus anything aimed
				// straight at it.
				chain_l += dry_l[1];
				chain_r += dry_r[1];
			} else if (routing != 0 && f == 1) {
				chain_l = dry_l[1];
				chain_r = dry_r[1];
			}
			if (!fc[f].on || fc[f].type == 15) {
				if (routing != 0 && f == 1) { out_l += chain_l; out_r += chain_r; }
				else if (f == FILTER_N - 1) { out_l += chain_l; out_r += chain_r; }
				continue;
			}

			const float env_amt = fc[f].env_amt * envv[fc[f].env_src];
			const float lfo_amt = fc[f].lfo_amt * v.lfo[fc[f].lfo_src].value;
			const float mod = md[f == 0 ? MD_F1_CUT : MD_F2_CUT];
			const float track = fc[f].keytrk * ((float)v.key - 60.0f) / 12.0f;
			float cut = fc[f].cut * std::pow(2.0f, (env_amt + lfo_amt + mod) * 6.0f + track);
			cut = clampf(cut, 15.0f, (float)sr_ * 0.48f);
			const float res = clampf(fc[f].res + md[f == 0 ? MD_F1_RES : MD_F2_RES], 0.0f, 1.0f);
			const float drv = fc[f].drive * db_to_gain(md[f == 0 ? MD_F1_DRIVE : MD_F2_DRIVE] * 24.0f);

			float in[2] = {chain_l * drv, chain_r * drv};
			float res_out[2];
			for (int c = 0; c < 2; c++) {
				const float spread = 1.0f + (c ? fc[f].spread : -fc[f].spread) * 0.5f;
				const float cc = clampf(cut * spread, 15.0f, (float)sr_ * 0.48f);
				float y = in[c];
				switch (fc[f].type) {
					case 2:
						v.ladder[f].set(cc, res, sr_);
						y = v.ladder[f].next(in[c], 1.0f);
						break;
					case 11:
					case 12: {
						const float d = clampf((float)sr_ / std::max(20.0f, cc), 1.0f,
								(float)(v.comb[f].size - 4));
						const float fb = res * 0.97f;
						const float t = v.comb[f].read(d);
						v.comb[f].write(in[c] + t * fb * (fc[f].type == 11 ? 1.0f : -1.0f));
						y = fc[f].type == 11 ? (in[c] + t) * 0.5f : (in[c] - t) * 0.5f;
						break;
					}
					case 13: {
						if (std::fabs(cc - v.formant_hz[f]) > 1.0f) {
							v.formant_hz[f] = cc;
							static const float FQ[3] = {8.0f, 10.0f, 12.0f};
							const float t = clampf(std::log2(cc / 20.0f) / 10.0f, 0.0f, 1.0f);
							static const float F1[5] = {730, 530, 270, 570, 300};
							static const float F2[5] = {1090, 1840, 2290, 840, 870};
							static const float F3[5] = {2440, 2480, 3010, 2410, 2240};
							const float u = t * 4.0f;
							const int a = (int)u, bb = a >= 4 ? 4 : a + 1;
							const float m = u - (float)a;
							const float hzs[3] = {lerpf(F1[a], F1[bb], m), lerpf(F2[a], F2[bb], m),
									lerpf(F3[a], F3[bb], m)};
							for (int k = 0; k < 3; k++)
								v.formant[f][k].peaking(hzs[k], 12.0f * (0.4f + res), FQ[k], sr_);
						}
						y = in[c];
						for (int k = 0; k < 3; k++) y = v.formant[f][k].next(y);
						y *= 0.6f;
						break;
					}
					default: {
						v.svf[f][0].set(cc, res, sr_);
						float lp, bp, hp;
						v.svf[f][0].tick(in[c], lp, bp, hp);
						switch (fc[f].type) {
							case 0: y = lp; break;
							case 1: {
								v.svf[f][1].set(cc, res, sr_);
								float l2, b2, h2;
								v.svf[f][1].tick(lp, l2, b2, h2);
								y = l2;
								break;
							}
							case 3: y = hp; break;
							case 4: {
								v.svf[f][1].set(cc, res, sr_);
								float l2, b2, h2;
								v.svf[f][1].tick(hp, l2, b2, h2);
								y = h2;
								break;
							}
							case 5: y = bp; break;
							case 6: {
								v.svf[f][1].set(cc, res, sr_);
								float l2, b2, h2;
								v.svf[f][1].tick(bp, l2, b2, h2);
								y = b2;
								break;
							}
							case 7: y = lp + hp; break;
							case 8: y = in[c] + bp * (1.0f + res * 8.0f); break;
							case 9: y = lp * (1.0f + res * 4.0f) + hp; break;
							case 10: y = hp * (1.0f + res * 4.0f) + lp; break;
							case 14: y = in[c] - 2.0f * bp; break;
							default: y = lp; break;
						}
						break;
					}
				}
				if (fc[f].drive > 1.001f) y = tanh_fast(y);
				res_out[c] = lerpf(in[c] / std::max(0.001f, drv), y, fc[f].mix);
			}
			chain_l = res_out[0];
			chain_r = res_out[1];
			if (routing != 0 || f == FILTER_N - 1) { out_l += chain_l; out_r += chain_r; }
		}

		// --- amp
		const float amp_env = envv[0];
		float amp = amp_env * lerpf(1.0f, v.vel, vel_vol) * db_to_gain(md[MD_AMP] * 24.0f);
		float pl, pr;
		pan_gains(clampf(v.pan + md[MD_PAN], -1.0f, 1.0f), pl, pr);
		v.amp_smooth.to(amp);
		const float a = v.amp_smooth.next();
		L[s] += v.dc[0].next(out_l * a * pl);
		R[s] += v.dc[1].next(out_r * a * pr);
		v.last_amp = a;
	}

	v.rng_state = vr.s;

	// A voice whose amplifier has closed, and whose samples have run out, is
	// done: keeping it would cost a full render for silence.
	if (!v.env[0].active() && v.amp_smooth.peek() < 1e-5f) {
		bool sampling = false;
		for (int i = 0; i < PART_N; i++)
			for (int k = 0; k < v.part[i].layers; k++)
				if (!v.part[i].rd[k].finished()) sampling = true;
		if (!sampling || !v.held) {
			v.active = false;
			v.held = false;
			for (int i = 0; i < PART_N; i++) v.part[i].layers = 0;
		}
	}
}

// ---------------------------------------------------------------------------
// Arpeggiator and gate
// ---------------------------------------------------------------------------
void Synth::run_arp(int n) {
	const Layout &L = layout();
	if (!pb(L.arp + ARP_ON)) {
		if (arp_last_ >= 0) {
			for (Voice &v : v_) if (v.active && v.held) stop_voice(v);
			arp_last_ = -1;
		}
		return;
	}
	std::vector<int> keys;
	if (pb(L.arp + ARP_LATCH)) keys = latch_;
	else for (const Held &h : held_) keys.push_back(h.key);
	if (keys.empty()) {
		if (arp_last_ >= 0) {
			for (Voice &v : v_) if (v.active && v.held) stop_voice(v);
			arp_last_ = -1;
		}
		return;
	}
	const int mode = pi(L.arp + ARP_MODE);
	if (mode != 6) std::sort(keys.begin(), keys.end());
	keys.erase(std::unique(keys.begin(), keys.end()), keys.end());

	const int octaves = std::max(1, pi(L.arp + ARP_OCT));
	const float beats = sync_beats(pi(L.arp + ARP_DIV));
	const double now = playing_ ? beat_ : free_beat_;
	const double span = (double)n / sr_ * (bpm_ / 60.0);

	if (arp_next_beat_ <= 0.0 || arp_next_beat_ > now + (double)beats * 2.0) arp_next_beat_ = now;

	while (arp_next_beat_ < now + span) {
		const int total = (int)keys.size() * octaves;
		int idx;
		switch (mode) {
			case 1: idx = total - 1 - (arp_step_ % total); break;
			case 2: {
				const int period = std::max(1, total * 2 - 2);
				const int t = arp_step_ % period;
				idx = t < total ? t : period - t;
				break;
			}
			case 3: {
				const int period = std::max(1, total * 2 - 2);
				const int t = arp_step_ % period;
				idx = total - 1 - (t < total ? t : period - t);
				break;
			}
			case 4: {
				const int period = std::max(1, total * 2);
				const int t = arp_step_ % period;
				idx = t < total ? t : period - 1 - t;
				break;
			}
			case 5: { Rng r((uint32_t)(arp_step_ * 2654435761u + 7u)); idx = (int)(r.uni() * (float)total); break; }
			case 7: idx = -1; break;   // chord: everything at once
			default: idx = arp_step_ % total; break;
		}

		if (arp_last_ >= 0) for (Voice &v : v_) if (v.active && v.held) stop_voice(v);

		const float gate = p(L.arp + ARP_GATE);
		const float vel = held_.empty() ? 0.8f : held_.back().vel;
		if (mode == 7) {
			for (int k : keys) {
				const int slot = alloc_voice(k);
				start_voice(v_[slot], k, vel, arp_voice_id_++);
			}
		} else {
			idx = idx < 0 ? 0 : (idx >= total ? total - 1 : idx);
			const int k = keys[(size_t)(idx % keys.size())] + 12 * (idx / (int)keys.size());
			const int slot = alloc_voice(k);
			start_voice(v_[slot], std::min(127, k), vel, arp_voice_id_++);
		}
		arp_last_ = 1;

		const int len = std::max(1, pi(L.arp + ARP_STEPS));
		arp_step_ = (arp_step_ + 1) % (len * 4 == 0 ? 1 : len);
		// Swing pushes every other step later.
		const float swing = p(L.arp + ARP_SWING);
		const double step_beats = (double)beats * (1.0 + ((arp_step_ & 1) ? -swing : swing) * 0.6);
		arp_next_beat_ += std::max(0.01, step_beats);
		(void)gate;
	}
}

void Synth::run_gate(float *L, float *R, int n) {
	const Layout &LY = layout();
	if (!pb(LY.gate + GAT_ON)) { gate_level_ = 1.0f; return; }
	const float beats = sync_beats(pi(LY.gate + GAT_DIV));
	const float smooth = p(LY.gate + GAT_SMOOTH);
	const double per_sample = (bpm_ / 60.0) / sr_;
	double pos = playing_ ? beat_ : free_beat_;
	// One pass of the sixteen steps spans sixteen divisions.
	const float a = clampf(1.0f - smooth * 0.999f, 0.002f, 1.0f);

	for (int i = 0; i < n; i++) {
		const double cycles = pos / std::max(0.01, (double)beats);
		const int step = ((int)std::floor(cycles)) % STEP_N;
		const float want = p(LY.step + (step < 0 ? step + STEP_N : step));
		gate_level_ += (want - gate_level_) * a;
		L[i] *= gate_level_;
		R[i] *= gate_level_;
		pos += per_sample;
	}
}

// ---------------------------------------------------------------------------
// Block
// ---------------------------------------------------------------------------
void Synth::apply_fx_params() {
	const Layout &L = layout();
	FxParams &f = fxp_;
	f.filter_on = pb(L.fx_filter + XFL_ON);
	f.filter_type = pi(L.fx_filter + XFL_TYPE);
	f.filter_cut = p(L.fx_filter + XFL_CUT) * std::pow(2.0f, global_mod_[MD_FX_FILTER_CUT] * 6.0f);
	f.filter_cut = clampf(f.filter_cut, 20.0f, 20000.0f);
	f.filter_res = p(L.fx_filter + XFL_RES);
	f.filter_mix = p(L.fx_filter + XFL_MIX);

	f.dist_on = pb(L.fx_dist + XDS_ON);
	f.dist_type = pi(L.fx_dist + XDS_TYPE);
	f.dist_drive = clampf(p(L.fx_dist + XDS_DRIVE) + global_mod_[MD_FX_DIST_DRIVE], 0.0f, 1.0f);
	f.dist_tone = p(L.fx_dist + XDS_TONE);
	f.dist_mix = p(L.fx_dist + XDS_MIX);

	f.eq_on = pb(L.fx_eq + XEQ_ON);
	f.eq_lo_g = p(L.fx_eq + XEQ_LO_G);
	f.eq_lo_f = p(L.fx_eq + XEQ_LO_F);
	f.eq_mid_g = p(L.fx_eq + XEQ_MID_G);
	f.eq_mid_f = p(L.fx_eq + XEQ_MID_F);
	f.eq_mid_q = p(L.fx_eq + XEQ_MID_Q);
	f.eq_hi_g = p(L.fx_eq + XEQ_HI_G);
	f.eq_hi_f = p(L.fx_eq + XEQ_HI_F);

	f.chorus_on = pb(L.fx_chorus + XCH_ON);
	f.chorus_rate = p(L.fx_chorus + XCH_RATE);
	f.chorus_depth = clampf(p(L.fx_chorus + XCH_DEPTH) + global_mod_[MD_FX_CHORUS_DEPTH], 0.0f, 1.0f);
	f.chorus_voices = pi(L.fx_chorus + XCH_VOICES);
	f.chorus_width = p(L.fx_chorus + XCH_WIDTH);
	f.chorus_fb = p(L.fx_chorus + XCH_FB);
	f.chorus_mix = p(L.fx_chorus + XCH_MIX);

	f.phaser_on = pb(L.fx_phaser + XPH_ON);
	f.phaser_rate = clampf(p(L.fx_phaser + XPH_RATE) * std::pow(2.0f, global_mod_[MD_FX_PHASER_RATE] * 4.0f),
			0.01f, 20.0f);
	f.phaser_depth = p(L.fx_phaser + XPH_DEPTH);
	f.phaser_centre = p(L.fx_phaser + XPH_CENTRE);
	f.phaser_fb = p(L.fx_phaser + XPH_FB);
	f.phaser_stages = pi(L.fx_phaser + XPH_STAGES);
	f.phaser_spread = p(L.fx_phaser + XPH_SPREAD);
	f.phaser_mix = p(L.fx_phaser + XPH_MIX);

	f.delay_on = pb(L.fx_delay + XDL_ON);
	f.delay_sync = pb(L.fx_delay + XDL_SYNC);
	f.delay_time = p(L.fx_delay + XDL_TIME);
	f.delay_div = pi(L.fx_delay + XDL_DIV);
	f.delay_fb = clampf(p(L.fx_delay + XDL_FB) + global_mod_[MD_FX_DELAY_FB], 0.0f, 1.1f);
	f.delay_ping = p(L.fx_delay + XDL_PING);
	f.delay_locut = p(L.fx_delay + XDL_LOCUT);
	f.delay_hicut = p(L.fx_delay + XDL_HICUT);
	f.delay_width = p(L.fx_delay + XDL_WIDTH);
	f.delay_mix = clampf(p(L.fx_delay + XDL_MIX) + global_mod_[MD_FX_DELAY_MIX], 0.0f, 1.0f);

	f.reverb_on = pb(L.fx_reverb + XRV_ON);
	f.reverb_size = p(L.fx_reverb + XRV_SIZE);
	f.reverb_damp = p(L.fx_reverb + XRV_DAMP);
	f.reverb_width = p(L.fx_reverb + XRV_WIDTH);
	f.reverb_predelay = p(L.fx_reverb + XRV_PREDELAY);
	f.reverb_locut = p(L.fx_reverb + XRV_LOCUT);
	f.reverb_diffuse = p(L.fx_reverb + XRV_DIFF);
	f.reverb_mix = clampf(p(L.fx_reverb + XRV_MIX) + global_mod_[MD_FX_REVERB_MIX], 0.0f, 1.0f);

	f.comp_on = pb(L.fx_comp + XCP_ON);
	f.comp_thresh = p(L.fx_comp + XCP_THRESH);
	f.comp_ratio = p(L.fx_comp + XCP_RATIO);
	f.comp_attack = p(L.fx_comp + XCP_ATTACK);
	f.comp_release = p(L.fx_comp + XCP_RELEASE);
	f.comp_makeup = p(L.fx_comp + XCP_MAKEUP);

	f.limit_on = pb(L.fx_limit + XLM_ON);
	f.limit_ceiling = p(L.fx_limit + XLM_CEIL);
}

void Synth::process(float *L, float *R, int n) {
	if (n <= 0) return;
	if ((int)mix_l_.size() < n) {
		mix_l_.assign((size_t)n, 0.0f);
		mix_r_.assign((size_t)n, 0.0f);
	}
	const Layout &LY = layout();

	// Compact the matrix once, so an idle slot costs nothing per sample.
	slots_.clear();
	dirty_dst_.clear();
	global_mod_used_ = false;
	for (int i = 0; i < MOD_N; i++) {
		const int b = LY.mod + i * MOD_COUNT;
		const int src = pi(b + MOD_SRC);
		const int dst = pi(b + MOD_DST);
		const float amt = p(b + MOD_AMT);
		if (src == MS_NONE || dst == MD_NONE || std::fabs(amt) < 0.0005f) continue;
		ModSlot m;
		m.src = src;
		m.dst = dst;
		m.amt = amt;
		m.curve = p(b + MOD_CURVE);
		slots_.push_back(m);
		if (std::find(dirty_dst_.begin(), dirty_dst_.end(), dst) == dirty_dst_.end())
			dirty_dst_.push_back(dst);
		if (mod_dst_is_global(dst)) global_mod_used_ = true;
	}
	for (int i = 0; i < MD_COUNT; i++) global_mod_[i] = 0.0f;

	// Instrument-level LFOs.
	const float dt_block = (float)n / (float)sr_;
	for (int l = 0; l < LFO_N; l++) {
		const int mode = pi(LY.lfo + l * LFO_COUNT + LFO_MODE);
		if (mode == 1 || mode == 2) {
			glfo_[l].age += dt_block;
			// Stepped once per block: a global LFO does not need per-sample
			// resolution, and it is read by every voice.
			run_lfo(glfo_[l], l, dt_block, false);
		}
	}

	run_arp(n);

	std::fill(mix_l_.begin(), mix_l_.begin() + n, 0.0f);
	std::fill(mix_r_.begin(), mix_r_.begin() + n, 0.0f);
	for (Voice &v : v_) {
		if (v.active) render_voice(v, mix_l_.data(), mix_r_.data(), n);
	}

	run_gate(mix_l_.data(), mix_r_.data(), n);

	apply_fx_params();
	fx_.process(mix_l_.data(), mix_r_.data(), n, fxp_, bpm_);

	const float vol = db_to_gain(p(LY.master + MST_VOL));
	float ml, mr;
	pan_gains(p(LY.master + MST_PAN), ml, mr);
	float peak = 0.0f;
	for (int i = 0; i < n; i++) {
		const float a = mix_l_[(size_t)i] * vol * ml;
		const float b = mix_r_[(size_t)i] * vol * mr;
		L[i] = a;
		R[i] = b;
		peak = std::max(peak, std::max(std::fabs(a), std::fabs(b)));
	}
	peak_ = std::max(peak, peak_ * 0.85f);

	if (!playing_) free_beat_ += (double)n / sr_ * (bpm_ / 60.0);
	else free_beat_ = beat_;
}

} // namespace flare
