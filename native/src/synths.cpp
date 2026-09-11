// Cadmium — stock synthesizers.
//
//   Ember   3-source subtractive poly synth with unison and a ladder filter
//   Kilo    4-operator FM with eight algorithms
//   Vector  dual wavetable synth with morphing tables
#include "plugin.h"

#include <cstdio>

namespace cd {

static const char *SHAPES = "Sine|Triangle|Saw|Square|Pulse|Noise";
static const char *LFO_SHAPES = "Sine|Triangle|Saw Down|Saw Up|Square|S&H|Noise";

// ===========================================================================
// Ember — subtractive
// ===========================================================================
enum {
	EM_O1_SHAPE, EM_O1_COARSE, EM_O1_FINE, EM_O1_LEVEL, EM_O1_PW, EM_O1_UNISON, EM_O1_DETUNE, EM_O1_WIDTH,
	EM_O2_SHAPE, EM_O2_COARSE, EM_O2_FINE, EM_O2_LEVEL, EM_O2_PW, EM_O2_SYNC, EM_O2_RING,
	EM_SUB_LEVEL, EM_SUB_SHAPE, EM_SUB_OCT,
	EM_NOISE_LEVEL, EM_NOISE_COLOR,
	EM_FLT_TYPE, EM_FLT_CUT, EM_FLT_RES, EM_FLT_ENV, EM_FLT_KEY, EM_FLT_DRIVE,
	EM_AMP_A, EM_AMP_D, EM_AMP_S, EM_AMP_R,
	EM_MOD_A, EM_MOD_D, EM_MOD_S, EM_MOD_R,
	EM_LFO_SHAPE, EM_LFO_RATE, EM_LFO_SYNC, EM_LFO_DIV, EM_LFO_PITCH, EM_LFO_CUT, EM_LFO_AMP, EM_LFO_PW, EM_LFO_RETRIG,
	EM_VOICES, EM_GLIDE, EM_MONO, EM_DRIFT, EM_VEL_AMP, EM_VEL_CUT, EM_BEND_RANGE,
	EM_LEVEL, EM_PAN, EM_WIDTH,
	EM_COUNT
};

struct EmberVoice {
	VoiceHead h;
	Osc o1[7], o2[7], sub;
	Rng rng;
	Ladder lad;
	ADSR amp, mod;
	float freq = 440.0f, glide_from = 440.0f, glide_t = 1.0f;
	float drift = 0.0f;
	float noise_z = 0.0f;
	float last_o2 = 0.0f;
};

class Ember : public Plug {
public:
	static const int MAXV = 16;
	EmberVoice v[MAXV];
	LFO lfo;
	uint64_t counter = 0;
	float bend = 0.0f, mod_wheel_v = 0.0f;
	int mono_last = -1;
	DCBlock dcl, dcr;
	Rng rng;

	void prepare() override {
		for (int i = 0; i < MAXV; i++) {
			v[i].amp.prepare(sr);
			v[i].mod.prepare(sr);
			v[i].lad.reset();
			v[i].h.active = false;
			v[i].drift = rng.bi() * 0.5f;
		}
		dcl.set(sr); dcr.set(sr);
	}
	void reset() override { all_notes_off(); for (int i = 0; i < MAXV; i++) { v[i].amp.kill(); v[i].lad.reset(); v[i].h.active = false; } }

	void note_on(int key, float vel, int id) override {
		const int nv = std::max(1, std::min(MAXV, pi(EM_VOICES)));
		if (pb(EM_MONO)) {
			// Mono: reuse voice 0, glide from whatever was sounding.
			EmberVoice &vv = v[0];
			const bool was_active = vv.h.active;
			const bool retrig = !vv.h.active || !vv.h.held;
			vv.h.key = key;
			take_expr(vv.h);
			const float target = note_to_hz(vv.h.pitch());
			vv.glide_from = was_active ? vv.freq : target;
			vv.freq = target;
			vv.glide_t = p(EM_GLIDE) > 0.001f && was_active ? 0.0f : 1.0f;
			vv.h.active = vv.h.held = true;
			vv.h.id = id; vv.h.vel = vel; vv.h.age = counter++;
			if (retrig) {
				vv.amp.gate_on(); vv.mod.gate_on();
				if (pb(EM_LFO_RETRIG)) lfo.reset();
			}
			mono_last = key;
			return;
		}
		const int i = alloc_voice(v, nv, counter);
		EmberVoice &vv = v[i];
		const bool was_active = vv.h.active;
		vv.h.key = key;
		take_expr(vv.h);
		const float target = note_to_hz(vv.h.pitch());
		vv.glide_from = was_active ? vv.freq : target;
		vv.freq = target;
		vv.glide_t = p(EM_GLIDE) > 0.001f ? 0.0f : 1.0f;
		vv.h.active = vv.h.held = true;
		vv.h.id = id; vv.h.vel = vel; vv.h.age = counter++;
		vv.amp.gate_on(); vv.mod.gate_on();
		vv.drift = rng.bi() * 0.5f;
		for (int u = 0; u < 7; u++) {
			// Free-running phases stay put; a fresh voice gets scattered ones so
			// stacked unison does not start as one loud click.
			vv.o1[u].phase = rng.uni();
			vv.o2[u].phase = rng.uni();
		}
		if (pb(EM_LFO_RETRIG)) lfo.reset();
	}
	void note_off(int key, int id) override {
		for (int i = 0; i < MAXV; i++) {
			if (v[i].h.active && v[i].h.held && v[i].h.key == key && (id < 0 || v[i].h.id == id)) {
				v[i].h.held = false;
				v[i].amp.gate_off();
				v[i].mod.gate_off();
				if (!pb(EM_MONO)) return;
			}
		}
	}
	void all_notes_off() override {
		for (int i = 0; i < MAXV; i++) {
			if (v[i].h.active) { v[i].h.held = false; v[i].amp.gate_off(); v[i].mod.gate_off(); }
		}
	}
	void pitch_bend(float semis) override { bend = semis; }
	void mod_wheel(float x) override { mod_wheel_v = x; }
	int active_voices() const override {
		int n = 0;
		for (int i = 0; i < MAXV; i++) if (v[i].h.active) n++;
		return n;
	}

	void process(float *L, float *R, int n) override {
		const int nv = std::max(1, std::min(MAXV, pi(EM_VOICES)));
		const int uni = std::max(1, std::min(7, pi(EM_O1_UNISON)));
		const float det = p(EM_O1_DETUNE);
		const float uwidth = p(EM_O1_WIDTH);
		const float lvl1 = p(EM_O1_LEVEL), lvl2 = p(EM_O2_LEVEL);
		const float subl = p(EM_SUB_LEVEL), noil = p(EM_NOISE_LEVEL);
		const int s1 = pi(EM_O1_SHAPE), s2 = pi(EM_O2_SHAPE);
		const float o1r = std::pow(2.0f, (p(EM_O1_COARSE) + p(EM_O1_FINE) * 0.01f) / 12.0f);
		const float o2r = std::pow(2.0f, (p(EM_O2_COARSE) + p(EM_O2_FINE) * 0.01f) / 12.0f);
		const float subr = std::pow(2.0f, -(float)std::max(1, pi(EM_SUB_OCT)));
		const float drive = p(EM_FLT_DRIVE);
		const float out = db_to_gain(p(EM_LEVEL));
		const float pan = p(EM_PAN);
		const float glide_rate = p(EM_GLIDE) > 0.0005f
				? 1.0f / (float)(sr * p(EM_GLIDE)) : 1.0f;
		const float bend_semi = bend * p(EM_BEND_RANGE);
		const float bendr = std::pow(2.0f, bend_semi / 12.0f);

		if (pb(EM_LFO_SYNC)) {
			lfo.set(sr, (float)(bpm / 60.0) / std::max(0.01f, sync_beats(pi(EM_LFO_DIV))));
		} else {
			lfo.set(sr, p(EM_LFO_RATE));
		}
		lfo.shape = pi(EM_LFO_SHAPE);

		for (int i = 0; i < MAXV; i++) {
			v[i].amp.set(p(EM_AMP_A), p(EM_AMP_D), p(EM_AMP_S), p(EM_AMP_R));
			v[i].mod.set(p(EM_MOD_A), p(EM_MOD_D), p(EM_MOD_S), p(EM_MOD_R));
			v[i].lad.mode = pi(EM_FLT_TYPE);
		}

		for (int s = 0; s < n; s++) {
			const float lf = lfo.next();
			float accL = 0.0f, accR = 0.0f;
			for (int i = 0; i < nv; i++) {
				EmberVoice &vv = v[i];
				if (!vv.h.active) continue;
				const float amp_env = vv.amp.next();
				if (!vv.amp.active()) { vv.h.active = false; continue; }
				const float mod_env = vv.mod.next();

				if (vv.glide_t < 1.0f) vv.glide_t = std::min(1.0f, vv.glide_t + glide_rate);
				const float base = lerp(vv.glide_from, vv.freq, vv.glide_t)
						* bendr
						* (1.0f + vv.drift * p(EM_DRIFT) * 0.01f)
						* std::pow(2.0f, lf * p(EM_LFO_PITCH) / 12.0f);

				float sig = 0.0f, sigR = 0.0f;
				const float pwm = clampf(p(EM_O1_PW) + lf * p(EM_LFO_PW), 0.02f, 0.98f);
				if (lvl1 > 0.0001f) {
					for (int u = 0; u < uni; u++) {
						const float sp = (uni == 1) ? 0.0f : ((float)u / (float)(uni - 1) * 2.0f - 1.0f);
						const float f = base * o1r * std::pow(2.0f, sp * det / 1200.0f);
						const float x = vv.o1[u].next(s1, f / (float)sr, pwm) * lvl1 / std::sqrt((float)uni);
						const float pl = 0.5f - sp * uwidth * 0.5f;
						sig += x * pl;
						sigR += x * (1.0f - pl);
					}
				}
				if (lvl2 > 0.0001f) {
					const float f2 = base * o2r;
					float x = vv.o2[0].next(s2, f2 / (float)sr, p(EM_O2_PW));
					if (pb(EM_O2_SYNC) && vv.o1[0].phase < (base * o1r / (float)sr)) vv.o2[0].phase = 0.0f;
					if (pb(EM_O2_RING)) x *= (sig + sigR);
					vv.last_o2 = x;
					sig += x * lvl2 * 0.5f;
					sigR += x * lvl2 * 0.5f;
				}
				if (subl > 0.0001f) {
					const float x = vv.sub.next(pb(EM_SUB_SHAPE) ? 3 : 0, base * subr / (float)sr) * subl;
					sig += x * 0.5f; sigR += x * 0.5f;
				}
				if (noil > 0.0001f) {
					float nz = vv.rng.bi();
					// "Colour" tilts white toward pink by low-passing.
					vv.noise_z += (nz - vv.noise_z) * clampf(1.0f - p(EM_NOISE_COLOR), 0.02f, 1.0f);
					nz = lerp(nz, vv.noise_z * 2.0f, p(EM_NOISE_COLOR));
					sig += nz * noil * 0.5f; sigR += nz * noil * 0.5f;
				}

				const float keytrack = (float)(vv.h.key - 60) * p(EM_FLT_KEY);
				const float cut = clampf(
						p(EM_FLT_CUT)
								* std::pow(2.0f, mod_env * p(EM_FLT_ENV) / 12.0f)
								* std::pow(2.0f, lf * p(EM_LFO_CUT) / 12.0f)
								* std::pow(2.0f, keytrack / 12.0f)
								* std::pow(2.0f, vv.h.vel * p(EM_VEL_CUT) / 12.0f),
						20.0f, (float)sr * 0.47f);
				vv.lad.set(sr, cut, p(EM_FLT_RES));
				const float pre = 1.0f + drive * 6.0f;
				float mono = (sig + sigR) * 0.5f;
				float fl = vv.lad(sig * pre) / (1.0f + drive * 2.0f);
				// Only the unison spread is genuinely stereo; one filter per side
				// would double the cost for no audible gain, so the second side
				// reuses the same coefficients through a cheap difference.
				float fr = fl + (sigR - sig) * 0.5f;
				(void)mono;
				const float g = amp_env * lerp(1.0f, vv.h.vel, p(EM_VEL_AMP))
						* (1.0f + lf * p(EM_LFO_AMP));
				accL += fl * g * vv.h.gl;
				accR += fr * g * vv.h.gr;
			}
			const float pl = std::cos((pan * 0.5f + 0.5f) * (float)PI * 0.5f);
			const float pr = std::sin((pan * 0.5f + 0.5f) * (float)PI * 0.5f);
			const float w = p(EM_WIDTH);
			const float mid = (accL + accR) * 0.5f, side = (accL - accR) * 0.5f * w;
			L[s] = dcl((mid + side) * out * pl * 1.41f);
			R[s] = dcr((mid - side) * out * pr * 1.41f);
		}
	}
};

static Plug *make_ember() { return new Ember(); }

// ===========================================================================
// Kilo — 4-operator FM
// ===========================================================================
// Algorithms as a modulation matrix: mod[i] = which op feeds op i (-1 none),
// plus which ops reach the output.
struct FmAlgo { int mod[4]; float out[4]; };
static const FmAlgo FM_ALGOS[8] = {
	{{-1, 0, 1, 2}, {0, 0, 0, 1}},        // 1: chain 1>2>3>4
	{{-1, 0, 1, 1}, {0, 0, 1, 1}},        // 2: 1>2>(3,4)
	{{-1, 0, -1, 2}, {0, 1, 0, 1}},       // 3: two stacks
	{{-1, 0, 0, 0}, {0, 1, 1, 1}},        // 4: 1 modulates 2,3,4
	{{-1, -1, 1, 2}, {1, 0, 0, 1}},       // 5: 1 out, 2>3>4
	{{-1, 0, -1, -1}, {0, 1, 1, 1}},      // 6: 1>2, 3 and 4 free
	{{-1, -1, -1, 2}, {1, 1, 0, 1}},      // 7
	{{-1, -1, -1, -1}, {1, 1, 1, 1}},     // 8: additive
};

enum {
	KI_ALGO, KI_FEEDBACK,
	KI_R1, KI_L1, KI_A1, KI_D1, KI_S1, KI_RE1, KI_FIX1, KI_FINE1,
	KI_R2, KI_L2, KI_A2, KI_D2, KI_S2, KI_RE2, KI_FIX2, KI_FINE2,
	KI_R3, KI_L3, KI_A3, KI_D3, KI_S3, KI_RE3, KI_FIX3, KI_FINE3,
	KI_R4, KI_L4, KI_A4, KI_D4, KI_S4, KI_RE4, KI_FIX4, KI_FINE4,
	KI_LFO_SHAPE, KI_LFO_RATE, KI_LFO_PITCH, KI_LFO_INDEX,
	KI_VOICES, KI_GLIDE, KI_VEL, KI_BEND_RANGE, KI_LEVEL, KI_PAN,
	KI_COUNT
};

struct KiloVoice {
	VoiceHead h;
	float phase[4] = {0, 0, 0, 0};
	float last[4] = {0, 0, 0, 0};
	float fb = 0.0f;
	ADSR env[4];
	float freq = 440.0f, glide_from = 440.0f, glide_t = 1.0f;
};

class Kilo : public Plug {
public:
	static const int MAXV = 16;
	KiloVoice v[MAXV];
	LFO lfo;
	uint64_t counter = 0;
	float bend = 0.0f;
	Rng rng;

	void prepare() override {
		for (int i = 0; i < MAXV; i++) {
			for (int o = 0; o < 4; o++) v[i].env[o].prepare(sr);
			v[i].h.active = false;
		}
	}
	void note_on(int key, float vel, int id) override {
		const int nv = std::max(1, std::min(MAXV, pi(KI_VOICES)));
		const int i = alloc_voice(v, nv, counter);
		KiloVoice &vv = v[i];
		const bool was_active = vv.h.active;
		vv.h.key = key;
		take_expr(vv.h);
		const float target = note_to_hz(vv.h.pitch());
		vv.glide_from = was_active ? vv.freq : target;
		vv.freq = target;
		vv.glide_t = p(KI_GLIDE) > 0.0005f ? 0.0f : 1.0f;
		vv.h.active = vv.h.held = true;
		vv.h.id = id; vv.h.vel = vel; vv.h.age = counter++;
		for (int o = 0; o < 4; o++) { vv.env[o].gate_on(); vv.phase[o] = 0.0f; }
		vv.fb = 0.0f;
	}
	void note_off(int key, int id) override {
		for (int i = 0; i < MAXV; i++) {
			if (v[i].h.active && v[i].h.held && v[i].h.key == key && (id < 0 || v[i].h.id == id)) {
				v[i].h.held = false;
				for (int o = 0; o < 4; o++) v[i].env[o].gate_off();
				return;
			}
		}
	}
	void all_notes_off() override {
		for (int i = 0; i < MAXV; i++) if (v[i].h.active) {
			v[i].h.held = false;
			for (int o = 0; o < 4; o++) v[i].env[o].gate_off();
		}
	}
	void pitch_bend(float s) override { bend = s; }
	int active_voices() const override {
		int n = 0;
		for (int i = 0; i < MAXV; i++) if (v[i].h.active) n++;
		return n;
	}

	void process(float *L, float *R, int n) override {
		const FmAlgo &alg = FM_ALGOS[std::max(0, std::min(7, pi(KI_ALGO)))];
		const int nv = std::max(1, std::min(MAXV, pi(KI_VOICES)));
		const float fb_amt = p(KI_FEEDBACK);
		const float out = db_to_gain(p(KI_LEVEL));
		const float pan = p(KI_PAN);
		const float bendr = std::pow(2.0f, bend * p(KI_BEND_RANGE) / 12.0f);
		const float glide_rate = p(KI_GLIDE) > 0.0005f ? 1.0f / (float)(sr * p(KI_GLIDE)) : 1.0f;
		float ratio[4], level[4], fine[4];
		bool fixed[4];
		for (int o = 0; o < 4; o++) {
			ratio[o] = p(KI_R1 + o * 8);
			level[o] = p(KI_L1 + o * 8);
			fine[o] = p(KI_FINE1 + o * 8);
			fixed[o] = pv[(size_t)(KI_FIX1 + o * 8)] > 0.5f;
		}
		lfo.shape = pi(KI_LFO_SHAPE);
		lfo.set(sr, p(KI_LFO_RATE));
		for (int i = 0; i < MAXV; i++) {
			for (int o = 0; o < 4; o++) {
				v[i].env[o].set(p(KI_A1 + o * 8), p(KI_D1 + o * 8), p(KI_S1 + o * 8), p(KI_RE1 + o * 8));
			}
		}

		for (int s = 0; s < n; s++) {
			const float lf = lfo.next();
			float accL = 0.0f, accR = 0.0f;
			for (int i = 0; i < nv; i++) {
				KiloVoice &vv = v[i];
				if (!vv.h.active) continue;
				if (vv.glide_t < 1.0f) vv.glide_t = std::min(1.0f, vv.glide_t + glide_rate);
				const float f0 = lerp(vv.glide_from, vv.freq, vv.glide_t) * bendr
						* std::pow(2.0f, lf * p(KI_LFO_PITCH) / 12.0f);
				float o[4];
				bool any = false;
				const float idx_mod = 1.0f + lf * p(KI_LFO_INDEX);
				for (int k = 0; k < 4; k++) {
					const float e = vv.env[k].next();
					if (vv.env[k].active()) any = true;
					const float f = fixed[k] ? (ratio[k] * 55.0f) : (f0 * ratio[k]);
					float mod = 0.0f;
					if (alg.mod[k] >= 0) mod = vv.last[alg.mod[k]];
					if (k == 0 && fb_amt > 0.0001f) mod += vv.fb * fb_amt * 2.0f;
					vv.phase[k] += (f + fine[k]) / (float)sr;
					if (vv.phase[k] >= 1.0f) vv.phase[k] -= std::floor(vv.phase[k]);
					const float x = std::sin((float)TAU * (vv.phase[k] + mod * 2.0f * idx_mod));
					o[k] = x * e * level[k];
					if (k == 0) vv.fb = 0.5f * (vv.fb + o[0]);
				}
				for (int k = 0; k < 4; k++) vv.last[k] = o[k];
				if (!any) { vv.h.active = false; continue; }
				float mix = 0.0f;
				for (int k = 0; k < 4; k++) mix += o[k] * alg.out[k];
				const float amp = mix * lerp(1.0f, vv.h.vel, p(KI_VEL)) * 0.4f;
				accL += amp * vv.h.gl;
				accR += amp * vv.h.gr;
			}
			const float pl = std::cos((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
			const float pr = std::sin((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
			L[s] = accL * out * pl;
			R[s] = accR * out * pr;
		}
	}
};

static Plug *make_kilo() { return new Kilo(); }

// ===========================================================================
// Vector — dual wavetable
// ===========================================================================
// Tables are generated once, band-limited by construction (built from a bounded
// harmonic series), 8 frames of 2048 samples each so morph interpolates.
static const int WT_LEN = 2048;
static const int WT_FRAMES = 8;
static const int WT_BANKS = 6;

struct WaveBank {
	float f[WT_FRAMES][WT_LEN];
};

static WaveBank *wt_banks() {
	static WaveBank *banks = nullptr;
	if (banks) return banks;
	banks = new WaveBank[WT_BANKS];
	for (int b = 0; b < WT_BANKS; b++) {
		for (int fr = 0; fr < WT_FRAMES; fr++) {
			const float m = (float)fr / (float)(WT_FRAMES - 1);
			for (int i = 0; i < WT_LEN; i++) {
				const float t = (float)i / (float)WT_LEN;
				float x = 0.0f;
				switch (b) {
					case 0: {   // Basic: sine -> triangle -> saw -> square
						const int harm = 1 + (int)(m * 31.0f);
						for (int k = 1; k <= harm; k++) x += std::sin((float)TAU * t * k) / (float)k;
						x *= 0.6f;
					} break;
					case 1: {   // Harmonics: odd-only, brightening
						const int harm = 1 + (int)(m * 23.0f);
						for (int k = 1; k <= harm; k += 2) x += std::sin((float)TAU * t * k) / (float)k;
						x *= 0.8f;
					} break;
					case 2: {   // Formant: a moving resonant peak
						const float peak = 1.0f + m * 12.0f;
						for (int k = 1; k <= 24; k++) {
							const float w = std::exp(-std::pow(((float)k - peak) / 3.0f, 2.0f));
							x += w * std::sin((float)TAU * t * k);
						}
					} break;
					case 3: {   // Bell: inharmonic partials
						static const float ratios[6] = {1.0f, 2.76f, 5.4f, 8.93f, 13.34f, 18.64f};
						for (int k = 0; k < 6; k++) {
							x += std::sin((float)TAU * t * ratios[k]) * std::pow(0.6f + m * 0.35f, (float)k);
						}
						x *= 0.5f;
					} break;
					case 4: {   // Vox: two formants sliding apart
						const float f1 = 3.0f + m * 5.0f, f2 = 9.0f + m * 14.0f;
						for (int k = 1; k <= 32; k++) {
							const float w = std::exp(-std::pow(((float)k - f1) / 2.2f, 2.0f))
									+ 0.6f * std::exp(-std::pow(((float)k - f2) / 3.5f, 2.0f));
							x += w * std::sin((float)TAU * t * k) / std::sqrt((float)k);
						}
					} break;
					default: {  // Digital: folded / phase-distorted
						const float d = 1.0f + m * 6.0f;
						x = std::sin((float)TAU * (t + 0.25f * std::sin((float)TAU * t * d)));
					} break;
				}
				banks[b].f[fr][i] = x;
			}
			// Normalise each frame so morphing does not jump in level.
			float peak = 1e-6f;
			for (int i = 0; i < WT_LEN; i++) peak = std::max(peak, std::fabs(banks[b].f[fr][i]));
			for (int i = 0; i < WT_LEN; i++) banks[b].f[fr][i] /= peak;
		}
	}
	return banks;
}

static inline float wt_read(const WaveBank &bank, float morph, float phase) {
	const float fp = clampf(morph, 0.0f, 0.999f) * (float)(WT_FRAMES - 1);
	const int f0 = (int)fp;
	const int f1 = std::min(WT_FRAMES - 1, f0 + 1);
	const float ff = fp - (float)f0;
	const float xp = phase * (float)WT_LEN;
	const int i0 = ((int)xp) & (WT_LEN - 1);
	const int i1 = (i0 + 1) & (WT_LEN - 1);
	const float xf = xp - std::floor(xp);
	const float a = lerp(bank.f[f0][i0], bank.f[f0][i1], xf);
	const float b = lerp(bank.f[f1][i0], bank.f[f1][i1], xf);
	return lerp(a, b, ff);
}

enum {
	VE_A_BANK, VE_A_MORPH, VE_A_LEVEL, VE_A_COARSE, VE_A_FINE, VE_A_UNISON, VE_A_DETUNE,
	VE_B_BANK, VE_B_MORPH, VE_B_LEVEL, VE_B_COARSE, VE_B_FINE,
	VE_MORPH_ENV, VE_MORPH_LFO,
	VE_FLT_TYPE, VE_FLT_CUT, VE_FLT_RES, VE_FLT_ENV, VE_FLT_KEY,
	VE_AMP_A, VE_AMP_D, VE_AMP_S, VE_AMP_R,
	VE_MOD_A, VE_MOD_D, VE_MOD_S, VE_MOD_R,
	VE_LFO_SHAPE, VE_LFO_RATE,
	VE_VOICES, VE_VEL, VE_BEND_RANGE, VE_LEVEL, VE_PAN, VE_WIDTH,
	VE_COUNT
};

struct VectorVoice {
	VoiceHead h;
	float pa[7] = {0, 0, 0, 0, 0, 0, 0};
	float pb = 0.0f;
	ADSR amp, mod;
	SVF filt;
	float freq = 440.0f;
};

class Vector : public Plug {
public:
	static const int MAXV = 16;
	VectorVoice v[MAXV];
	LFO lfo;
	uint64_t counter = 0;
	float bend = 0.0f;
	Rng rng;

	void prepare() override {
		wt_banks();
		for (int i = 0; i < MAXV; i++) {
			v[i].amp.prepare(sr); v[i].mod.prepare(sr);
			v[i].h.active = false;
			v[i].filt.reset();
		}
	}
	void note_on(int key, float vel, int id) override {
		const int nv = std::max(1, std::min(MAXV, pi(VE_VOICES)));
		const int i = alloc_voice(v, nv, counter);
		VectorVoice &vv = v[i];
		vv.h.key = key;
		take_expr(vv.h);
		vv.freq = note_to_hz(vv.h.pitch());
		vv.h.active = vv.h.held = true;
		vv.h.id = id; vv.h.vel = vel; vv.h.age = counter++;
		vv.amp.gate_on(); vv.mod.gate_on();
		for (int u = 0; u < 7; u++) vv.pa[u] = rng.uni();
		vv.pb = 0.0f;
	}
	void note_off(int key, int id) override {
		for (int i = 0; i < MAXV; i++) {
			if (v[i].h.active && v[i].h.held && v[i].h.key == key && (id < 0 || v[i].h.id == id)) {
				v[i].h.held = false; v[i].amp.gate_off(); v[i].mod.gate_off(); return;
			}
		}
	}
	void all_notes_off() override {
		for (int i = 0; i < MAXV; i++) if (v[i].h.active) { v[i].h.held = false; v[i].amp.gate_off(); v[i].mod.gate_off(); }
	}
	void pitch_bend(float s) override { bend = s; }
	int active_voices() const override {
		int n = 0; for (int i = 0; i < MAXV; i++) if (v[i].h.active) n++; return n;
	}

	// what 0: one cycle of oscillator A's current wave, then one of B, 128
	// points each, so the panel can show what the morph knob is picking.
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 256) return 0;
		WaveBank *banks = wt_banks();
		const WaveBank &ba = banks[std::max(0, std::min(WT_BANKS - 1, pi(VE_A_BANK)))];
		const WaveBank &bb = banks[std::max(0, std::min(WT_BANKS - 1, pi(VE_B_BANK)))];
		for (int i = 0; i < 128; i++) {
			const float ph = (float)i / 128.0f;
			o[i] = wt_read(ba, p(VE_A_MORPH), ph);
			o[128 + i] = wt_read(bb, p(VE_B_MORPH), ph);
		}
		return 256;
	}

	void process(float *L, float *R, int n) override {
		WaveBank *banks = wt_banks();
		const WaveBank &ba = banks[std::max(0, std::min(WT_BANKS - 1, pi(VE_A_BANK)))];
		const WaveBank &bb = banks[std::max(0, std::min(WT_BANKS - 1, pi(VE_B_BANK)))];
		const int nv = std::max(1, std::min(MAXV, pi(VE_VOICES)));
		const int uni = std::max(1, std::min(7, pi(VE_A_UNISON)));
		const float ar = std::pow(2.0f, (p(VE_A_COARSE) + p(VE_A_FINE) * 0.01f) / 12.0f);
		const float br = std::pow(2.0f, (p(VE_B_COARSE) + p(VE_B_FINE) * 0.01f) / 12.0f);
		const float bendr = std::pow(2.0f, bend * p(VE_BEND_RANGE) / 12.0f);
		const float out = db_to_gain(p(VE_LEVEL));
		lfo.shape = pi(VE_LFO_SHAPE);
		lfo.set(sr, p(VE_LFO_RATE));
		for (int i = 0; i < MAXV; i++) {
			v[i].amp.set(p(VE_AMP_A), p(VE_AMP_D), p(VE_AMP_S), p(VE_AMP_R));
			v[i].mod.set(p(VE_MOD_A), p(VE_MOD_D), p(VE_MOD_S), p(VE_MOD_R));
		}

		for (int s = 0; s < n; s++) {
			const float lf = lfo.next();
			float accL = 0.0f, accR = 0.0f;
			for (int i = 0; i < nv; i++) {
				VectorVoice &vv = v[i];
				if (!vv.h.active) continue;
				const float ae = vv.amp.next();
				if (!vv.amp.active()) { vv.h.active = false; continue; }
				const float me = vv.mod.next();
				const float f0 = vv.freq * bendr;
				const float morph_a = clampf(p(VE_A_MORPH) + me * p(VE_MORPH_ENV) + lf * p(VE_MORPH_LFO), 0.0f, 1.0f);
				const float morph_b = clampf(p(VE_B_MORPH) + me * p(VE_MORPH_ENV) * 0.5f, 0.0f, 1.0f);
				float l = 0.0f, r = 0.0f;
				for (int u = 0; u < uni; u++) {
					const float sp = (uni == 1) ? 0.0f : ((float)u / (float)(uni - 1) * 2.0f - 1.0f);
					const float f = f0 * ar * std::pow(2.0f, sp * p(VE_A_DETUNE) / 1200.0f);
					vv.pa[u] += f / (float)sr;
					if (vv.pa[u] >= 1.0f) vv.pa[u] -= std::floor(vv.pa[u]);
					const float x = wt_read(ba, morph_a, vv.pa[u]) * p(VE_A_LEVEL) / std::sqrt((float)uni);
					l += x * (0.5f - sp * 0.35f);
					r += x * (0.5f + sp * 0.35f);
				}
				vv.pb += f0 * br / (float)sr;
				if (vv.pb >= 1.0f) vv.pb -= std::floor(vv.pb);
				const float xb = wt_read(bb, morph_b, vv.pb) * p(VE_B_LEVEL) * 0.5f;
				l += xb; r += xb;

				const float cut = clampf(p(VE_FLT_CUT)
						* std::pow(2.0f, me * p(VE_FLT_ENV) / 12.0f)
						* std::pow(2.0f, (float)(vv.h.key - 60) * p(VE_FLT_KEY) / 12.0f), 20.0f, (float)sr * 0.47f);
				vv.filt.set(sr, cut, 0.7f + p(VE_FLT_RES) * 12.0f);
				const float g = ae * lerp(1.0f, vv.h.vel, p(VE_VEL));
				vv.filt.process((l + r) * 0.5f);
				const float ft = pi(VE_FLT_TYPE);
				const float fo = ft == 0 ? vv.filt.lp : (ft == 1 ? vv.filt.bp : vv.filt.hp);
				const float mid = fo, side = (l - r) * 0.5f;
				accL += (mid + side) * g * vv.h.gl;
				accR += (mid - side) * g * vv.h.gr;
			}
			const float pan = p(VE_PAN);
			const float w = p(VE_WIDTH);
			const float mid = (accL + accR) * 0.5f, side = (accL - accR) * 0.5f * w;
			const float pl = std::cos((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
			const float pr = std::sin((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
			L[s] = (mid + side) * out * pl;
			R[s] = (mid - side) * out * pr;
		}
	}
};

static Plug *make_vector() { return new Vector(); }

// ---------------------------------------------------------------------------
// Descriptors
// ---------------------------------------------------------------------------
void register_synths(std::vector<PlugDesc> &out) {
	out.push_back({
		"cd.ember", "Ember", "Cadmium", "Synth", true, UI_SYNTH, {
			{"o1_shape", "Shape", 0, 5, 2, P_CHOICE, "Osc 1", SHAPES, 1},
			{"o1_coarse", "Coarse", -24, 24, 0, P_SEMI, "Osc 1", nullptr, 1},
			{"o1_fine", "Fine", -100, 100, 0, P_SEMI, "Osc 1", nullptr, 1},
			{"o1_level", "Level", 0, 1, 0.8f, P_PCT, "Osc 1", nullptr, 1},
			{"o1_pw", "Pulse W", 0.02f, 0.98f, 0.5f, P_PCT, "Osc 1", nullptr, 1},
			{"o1_unison", "Unison", 1, 7, 1, P_SEMI, "Osc 1", nullptr, 1},
			{"o1_detune", "Detune", 0, 100, 18, P_SEMI, "Osc 1", nullptr, 1},
			{"o1_width", "Spread", 0, 1, 0.6f, P_PCT, "Osc 1", nullptr, 1},

			{"o2_shape", "Shape", 0, 5, 3, P_CHOICE, "Osc 2", SHAPES, 1},
			{"o2_coarse", "Coarse", -24, 24, -12, P_SEMI, "Osc 2", nullptr, 1},
			{"o2_fine", "Fine", -100, 100, 6, P_SEMI, "Osc 2", nullptr, 1},
			{"o2_level", "Level", 0, 1, 0.35f, P_PCT, "Osc 2", nullptr, 1},
			{"o2_pw", "Pulse W", 0.02f, 0.98f, 0.5f, P_PCT, "Osc 2", nullptr, 1},
			{"o2_sync", "Sync", 0, 1, 0, P_BOOL, "Osc 2", nullptr, 1},
			{"o2_ring", "Ring Mod", 0, 1, 0, P_BOOL, "Osc 2", nullptr, 1},

			{"sub_level", "Sub", 0, 1, 0.25f, P_PCT, "Sub / Noise", nullptr, 1},
			{"sub_shape", "Sub Square", 0, 1, 0, P_BOOL, "Sub / Noise", nullptr, 1},
			{"sub_oct", "Sub Oct", 1, 3, 1, P_SEMI, "Sub / Noise", nullptr, 1},
			{"noise_level", "Noise", 0, 1, 0.0f, P_PCT, "Sub / Noise", nullptr, 1},
			{"noise_color", "Colour", 0, 1, 0.3f, P_PCT, "Sub / Noise", nullptr, 1},

			{"flt_type", "Type", 0, 3, 0, P_CHOICE, "Filter", "Low 24|Low 12|Band|High", 1},
			{"flt_cut", "Cutoff", 20, 20000, 2400, P_HZ, "Filter", nullptr, 0.3f},
			{"flt_res", "Reso", 0, 1, 0.25f, P_PCT, "Filter", nullptr, 1},
			{"flt_env", "Env Amt", -60, 60, 22, P_SEMI, "Filter", nullptr, 1},
			{"flt_key", "Key Trk", 0, 1, 0.3f, P_PCT, "Filter", nullptr, 1},
			{"flt_drive", "Drive", 0, 1, 0.15f, P_PCT, "Filter", nullptr, 1},

			{"amp_a", "Attack", 0.0005f, 8, 0.004f, P_SEC, "Amp Env", nullptr, 0.3f},
			{"amp_d", "Decay", 0.001f, 8, 0.35f, P_SEC, "Amp Env", nullptr, 0.3f},
			{"amp_s", "Sustain", 0, 1, 0.7f, P_PCT, "Amp Env", nullptr, 1},
			{"amp_r", "Release", 0.002f, 12, 0.25f, P_SEC, "Amp Env", nullptr, 0.3f},

			{"mod_a", "Attack", 0.0005f, 8, 0.002f, P_SEC, "Mod Env", nullptr, 0.3f},
			{"mod_d", "Decay", 0.001f, 8, 0.4f, P_SEC, "Mod Env", nullptr, 0.3f},
			{"mod_s", "Sustain", 0, 1, 0.0f, P_PCT, "Mod Env", nullptr, 1},
			{"mod_r", "Release", 0.002f, 12, 0.3f, P_SEC, "Mod Env", nullptr, 0.3f},

			{"lfo_shape", "Shape", 0, 6, 0, P_CHOICE, "LFO", LFO_SHAPES, 1},
			{"lfo_rate", "Rate", 0.01f, 40, 5, P_HZ, "LFO", nullptr, 0.4f},
			{"lfo_sync", "Sync", 0, 1, 0, P_BOOL, "LFO", nullptr, 1},
			{"lfo_div", "Division", 0, 12, 5, P_CHOICE, "LFO", SYNC_NAMES, 1},
			{"lfo_pitch", "To Pitch", -12, 12, 0, P_SEMI, "LFO", nullptr, 1},
			{"lfo_cut", "To Cutoff", -48, 48, 0, P_SEMI, "LFO", nullptr, 1},
			{"lfo_amp", "To Amp", 0, 1, 0, P_PCT, "LFO", nullptr, 1},
			{"lfo_pw", "To PW", -0.5f, 0.5f, 0, P_PCT, "LFO", nullptr, 1},
			{"lfo_retrig", "Retrig", 0, 1, 0, P_BOOL, "LFO", nullptr, 1},

			{"voices", "Polyphony", 1, 16, 12, P_SEMI, "Voice", nullptr, 1},
			{"glide", "Glide", 0, 2, 0, P_SEC, "Voice", nullptr, 0.4f},
			{"mono", "Mono", 0, 1, 0, P_BOOL, "Voice", nullptr, 1},
			{"drift", "Drift", 0, 1, 0.12f, P_PCT, "Voice", nullptr, 1},
			{"vel_amp", "Vel > Amp", 0, 1, 0.7f, P_PCT, "Voice", nullptr, 1},
			{"vel_cut", "Vel > Cut", 0, 48, 8, P_SEMI, "Voice", nullptr, 1},
			{"bend_range", "Bend", 0, 24, 2, P_SEMI, "Voice", nullptr, 1},

			{"level", "Level", -60, 12, -6, P_DB, "Output", nullptr, 1},
			{"pan", "Pan", -1, 1, 0, P_FLOAT, "Output", nullptr, 1},
			{"width", "Width", 0, 2, 1, P_PCT, "Output", nullptr, 1},
		}, make_ember });

	std::vector<ParamDesc> kp = {
		{"algo", "Algorithm", 0, 7, 0, P_CHOICE, "Matrix", "1 chain|2 split|3 stacks|4 fan|5 lead|6 pair|7 duo|8 additive", 1},
		{"feedback", "Feedback", 0, 1, 0.1f, P_PCT, "Matrix", nullptr, 1},
	};
	static const char *opg[4] = {"Op 1", "Op 2", "Op 3", "Op 4"};
	static const char *opid[4][8] = {
		{"r1", "l1", "a1", "d1", "s1", "re1", "fix1", "fine1"},
		{"r2", "l2", "a2", "d2", "s2", "re2", "fix2", "fine2"},
		{"r3", "l3", "a3", "d3", "s3", "re3", "fix3", "fine3"},
		{"r4", "l4", "a4", "d4", "s4", "re4", "fix4", "fine4"},
	};
	static const float deflv[4] = {1.0f, 0.7f, 0.5f, 0.9f};
	for (int o = 0; o < 4; o++) {
		kp.push_back({opid[o][0], "Ratio", 0.25f, 16, o == 0 ? 1.0f : (float)(o + 1), P_FLOAT, opg[o], nullptr, 1});
		kp.push_back({opid[o][1], "Level", 0, 1, deflv[o], P_PCT, opg[o], nullptr, 1});
		kp.push_back({opid[o][2], "Attack", 0.0005f, 8, 0.003f, P_SEC, opg[o], nullptr, 0.3f});
		kp.push_back({opid[o][3], "Decay", 0.001f, 8, 0.5f, P_SEC, opg[o], nullptr, 0.3f});
		kp.push_back({opid[o][4], "Sustain", 0, 1, o == 3 ? 0.7f : 0.4f, P_PCT, opg[o], nullptr, 1});
		kp.push_back({opid[o][5], "Release", 0.002f, 12, 0.3f, P_SEC, opg[o], nullptr, 0.3f});
		kp.push_back({opid[o][6], "Fixed", 0, 1, 0, P_BOOL, opg[o], nullptr, 1});
		kp.push_back({opid[o][7], "Fine", -20, 20, 0, P_FLOAT, opg[o], nullptr, 1});
	}
	kp.push_back({"lfo_shape", "Shape", 0, 6, 0, P_CHOICE, "LFO", LFO_SHAPES, 1});
	kp.push_back({"lfo_rate", "Rate", 0.01f, 40, 4, P_HZ, "LFO", nullptr, 0.4f});
	kp.push_back({"lfo_pitch", "To Pitch", -12, 12, 0, P_SEMI, "LFO", nullptr, 1});
	kp.push_back({"lfo_index", "To Index", 0, 2, 0, P_PCT, "LFO", nullptr, 1});
	kp.push_back({"voices", "Polyphony", 1, 16, 10, P_SEMI, "Voice", nullptr, 1});
	kp.push_back({"glide", "Glide", 0, 2, 0, P_SEC, "Voice", nullptr, 0.4f});
	kp.push_back({"vel", "Velocity", 0, 1, 0.8f, P_PCT, "Voice", nullptr, 1});
	kp.push_back({"bend_range", "Bend", 0, 24, 2, P_SEMI, "Voice", nullptr, 1});
	kp.push_back({"level", "Level", -60, 12, -4, P_DB, "Output", nullptr, 1});
	kp.push_back({"pan", "Pan", -1, 1, 0, P_FLOAT, "Output", nullptr, 1});
	out.push_back({"cd.kilo", "Kilo FM", "Cadmium", "Synth", true, UI_SYNTH, kp, make_kilo});

	out.push_back({
		"cd.vector", "Vector", "Cadmium", "Synth", true, UI_WAVETABLE, {
			{"a_bank", "Table", 0, 5, 0, P_CHOICE, "Osc A", "Basic|Harmonics|Formant|Bell|Vox|Digital", 1},
			{"a_morph", "Morph", 0, 1, 0.25f, P_PCT, "Osc A", nullptr, 1},
			{"a_level", "Level", 0, 1, 0.85f, P_PCT, "Osc A", nullptr, 1},
			{"a_coarse", "Coarse", -24, 24, 0, P_SEMI, "Osc A", nullptr, 1},
			{"a_fine", "Fine", -100, 100, 0, P_SEMI, "Osc A", nullptr, 1},
			{"a_unison", "Unison", 1, 7, 3, P_SEMI, "Osc A", nullptr, 1},
			{"a_detune", "Detune", 0, 100, 14, P_SEMI, "Osc A", nullptr, 1},
			{"b_bank", "Table", 0, 5, 2, P_CHOICE, "Osc B", "Basic|Harmonics|Formant|Bell|Vox|Digital", 1},
			{"b_morph", "Morph", 0, 1, 0.5f, P_PCT, "Osc B", nullptr, 1},
			{"b_level", "Level", 0, 1, 0.4f, P_PCT, "Osc B", nullptr, 1},
			{"b_coarse", "Coarse", -24, 24, -12, P_SEMI, "Osc B", nullptr, 1},
			{"b_fine", "Fine", -100, 100, 0, P_SEMI, "Osc B", nullptr, 1},
			{"morph_env", "Env > Morph", -1, 1, 0.3f, P_PCT, "Morph", nullptr, 1},
			{"morph_lfo", "LFO > Morph", -1, 1, 0.15f, P_PCT, "Morph", nullptr, 1},
			{"flt_type", "Type", 0, 2, 0, P_CHOICE, "Filter", "Low|Band|High", 1},
			{"flt_cut", "Cutoff", 20, 20000, 4200, P_HZ, "Filter", nullptr, 0.3f},
			{"flt_res", "Reso", 0, 1, 0.2f, P_PCT, "Filter", nullptr, 1},
			{"flt_env", "Env Amt", -60, 60, 12, P_SEMI, "Filter", nullptr, 1},
			{"flt_key", "Key Trk", 0, 1, 0.25f, P_PCT, "Filter", nullptr, 1},
			{"amp_a", "Attack", 0.0005f, 8, 0.006f, P_SEC, "Amp Env", nullptr, 0.3f},
			{"amp_d", "Decay", 0.001f, 8, 0.5f, P_SEC, "Amp Env", nullptr, 0.3f},
			{"amp_s", "Sustain", 0, 1, 0.75f, P_PCT, "Amp Env", nullptr, 1},
			{"amp_r", "Release", 0.002f, 12, 0.4f, P_SEC, "Amp Env", nullptr, 0.3f},
			{"mod_a", "Attack", 0.0005f, 8, 0.01f, P_SEC, "Mod Env", nullptr, 0.3f},
			{"mod_d", "Decay", 0.001f, 8, 0.8f, P_SEC, "Mod Env", nullptr, 0.3f},
			{"mod_s", "Sustain", 0, 1, 0.2f, P_PCT, "Mod Env", nullptr, 1},
			{"mod_r", "Release", 0.002f, 12, 0.5f, P_SEC, "Mod Env", nullptr, 0.3f},
			{"lfo_shape", "Shape", 0, 6, 0, P_CHOICE, "LFO", LFO_SHAPES, 1},
			{"lfo_rate", "Rate", 0.01f, 40, 0.6f, P_HZ, "LFO", nullptr, 0.4f},
			{"voices", "Polyphony", 1, 16, 10, P_SEMI, "Voice", nullptr, 1},
			{"vel", "Velocity", 0, 1, 0.6f, P_PCT, "Voice", nullptr, 1},
			{"bend_range", "Bend", 0, 24, 2, P_SEMI, "Voice", nullptr, 1},
			{"level", "Level", -60, 12, -6, P_DB, "Output", nullptr, 1},
			{"pan", "Pan", -1, 1, 0, P_FLOAT, "Output", nullptr, 1},
			{"width", "Width", 0, 2, 1.1f, P_PCT, "Output", nullptr, 1},
		}, make_vector });
}

} // namespace cd
