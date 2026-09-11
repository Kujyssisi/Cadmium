// Cadmium — a second bank of stock instruments.
//
// These fill the gaps the first bank left: a monophonic acid bass that slides
// and accents, a drawbar organ with a rotary cabinet, a struck-resonator voice
// for bells and mallets, and a formant ensemble for choir pads.
#include "plugin.h"

#include <algorithm>
#include <cmath>

namespace cd {

// ---------------------------------------------------------------------------
// Acid — one voice, always. The point of a 303 is what happens between notes:
// overlapping notes slide instead of retriggering, and an accented note opens
// the filter and hits harder.
// ---------------------------------------------------------------------------
class Acid : public Plug {
	enum { P_WAVE, P_TUNE, P_CUT, P_RES, P_ENVMOD, P_DECAY, P_ACCENT, P_GLIDE,
		P_DRIVE, P_SUB, P_ATTACK, P_VOL };

	Osc osc, sub;
	Ladder filt;
	DCBlock dc;
	float note_hz = 55.0f, target_hz = 55.0f;
	float glide_coef = 0.0f;
	float env = 0.0f, amp = 0.0f;
	float accent = 0.0f;
	/// Acid has one voice; this carries that voice's pan and detune.
	VoiceHead note_head;
	bool gate = false;
	int held_key = -1, held_id = -1;
	float vis_env = 0.0f, vis_cut = 0.0f;

public:
	void prepare() override {
		filt.reset();
		dc = DCBlock();
		env = amp = 0.0f;
	}
	void reset() override { prepare(); }

	void note_on(int key, float vel, int id) override {
		// One voice, so the note's own pan and detune are kept here.
		note_head.key = key;
		take_expr(note_head);
		target_hz = note_to_hz(note_head.pitch() + p(P_TUNE));
		// Anything above about three quarters is an accent, the way a 303's
		// accent track works.
		accent = vel > 0.75f ? (vel - 0.75f) * 4.0f : 0.0f;
		if (!gate) {
			note_hz = target_hz;
			env = 1.0f;
			osc.phase = 0.0f;
			sub.phase = 0.0f;
		} else if (p(P_GLIDE) <= 0.001f) {
			note_hz = target_hz;
		}
		// A slide is a note started while the last one is still held: the
		// envelope carries on rather than starting again.
		if (!gate) env = 1.0f;
		gate = true;
		held_key = key;
		held_id = id;
	}
	void note_off(int key, int id) override {
		if (key != held_key && id != held_id && held_key >= 0) return;
		gate = false;
		held_key = -1;
		held_id = -1;
	}
	void all_notes_off() override { gate = false; held_key = -1; env = 0.0f; }

	int active_voices() const override { return (gate || amp > 0.001f) ? 1 : 0; }
	float tail() const override { return 0.5f; }

	int aux(int what, float *out, int max) override {
		if (what != 0 || max < 2) return 0;
		out[0] = vis_env;
		out[1] = vis_cut;
		return 2;
	}

	void process(float *L, float *R, int n) override {
		const int wave = pi(P_WAVE);
		const float base = p(P_CUT);
		const float res = p(P_RES);
		const float envmod = p(P_ENVMOD);
		const float drive = 1.0f + p(P_DRIVE) * 12.0f;
		const float sublev = p(P_SUB);
		const float vol = p(P_VOL);
		// Glide is a time constant over the note's whole pitch distance.
		const float gl = p(P_GLIDE);
		glide_coef = gl <= 0.001f ? 1.0f
				: 1.0f - std::exp(-1.0f / (float)(sr * gl * 0.35));
		const float dec = ADSR::rate(sr, p(P_DECAY));
		const float atk = ADSR::rate(sr, p(P_ATTACK));
		const float amp_rel = ADSR::rate(sr, 0.008f);
		const float acc = p(P_ACCENT) * accent;

		for (int i = 0; i < n; i++) {
			note_hz += (target_hz - note_hz) * glide_coef;
			if (gate) {
				amp += (1.0f - amp) * atk;
			} else {
				amp += (0.0f - amp) * amp_rel;
			}
			// The filter envelope decays whether or not the note is held; that
			// is what gives the sound its bite.
			env += (0.0f - env) * dec;

			const float inc = note_hz / (float)sr;
			float x = osc.next(wave == 0 ? 2 : 3, inc);
			if (sublev > 0.0001f) x += sub.next(3, inc * 0.5f) * sublev;
			x *= (0.7f + acc * 0.5f) * amp;

			const float cut = clampf(base * std::pow(2.0f,
					(env * (envmod + acc * 1.5f)) * 4.0f), 20.0f, (float)sr * 0.45f);
			filt.set(sr, cut, clampf(res + acc * 0.15f, 0.0f, 0.98f));
			float y = filt(x * drive);
			y = tanh_fast(y * 0.8f);
			y = dc(y) * vol;
			L[i] = y * note_head.gl;
			R[i] = y * note_head.gr;
			if ((i & 63) == 0) {
				vis_env = env;
				vis_cut = cut;
			}
		}
	}
};

// ---------------------------------------------------------------------------
// Organ — nine drawbars of sine, a percussion tap, key click, and a rotary
// cabinet. The drawbar ratios are the real ones, including the slightly odd
// 5 1/3 and 1 3/5.
// ---------------------------------------------------------------------------
static const float DRAWBAR_RATIO[9] = {
	0.5f, 1.5f, 1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f, 8.0f
};

struct OrganVoice {
	VoiceHead h;
	float phase[9] = {0};
	float amp = 0.0f;
	float perc = 0.0f;
	float click = 0.0f;
	OnePole click_lp;
};

class Organ : public Plug {
	enum { P_D1, P_D2, P_D3, P_D4, P_D5, P_D6, P_D7, P_D8, P_D9,
		P_PERC, P_PERC_HARM, P_PERC_DECAY, P_CLICK, P_ATTACK, P_RELEASE,
		P_ROTARY, P_ROT_SPEED, P_ROT_DEPTH, P_DRIVE, P_VOL };
	static const int VOICES = 16;
	OrganVoice v[VOICES];
	uint64_t age = 0;
	// Rotary: a horn that sweeps in pitch and level, and a drum that mostly
	// changes level. One phase each, with the speed ramping like a real motor.
	float horn_phase = 0.0f, drum_phase = 0.0f, rot_speed = 0.0f;
	Delay rot_l, rot_r;
	OnePole horn_lp[2], drum_lp[2];
	DCBlock dcl, dcr;
	float vis_rot = 0.0f;

public:
	void prepare() override {
		for (auto &x : v) { x = OrganVoice(); x.click_lp.set(sr, 2200.0f); }
		rot_l.prepare((int)(sr * 0.02) + 8);
		rot_r.prepare((int)(sr * 0.02) + 8);
		for (int i = 0; i < 2; i++) { horn_lp[i].set(sr, 5200.0f); drum_lp[i].set(sr, 700.0f); }
		rot_speed = 0.8f;
	}
	void reset() override { prepare(); }

	void note_on(int key, float vel, int id) override {
		const int i = alloc_voice(v, VOICES, age);
		OrganVoice &x = v[i];
		x.h.active = true; x.h.held = true; x.h.key = key; x.h.id = id;
		x.h.vel = vel; x.h.age = age++;
		take_expr(x.h);
		for (int d = 0; d < 9; d++) x.phase[d] = 0.0f;
		x.perc = 1.0f;
		x.click = p(P_CLICK) * (0.4f + vel * 0.6f);
	}
	void note_off(int key, int id) override {
		for (auto &x : v) {
			if (x.h.active && x.h.held && x.h.key == key && (id < 0 || x.h.id == id)) x.h.held = false;
		}
	}
	void all_notes_off() override { for (auto &x : v) x = OrganVoice(); }
	int active_voices() const override {
		int n = 0;
		for (const auto &x : v) if (x.h.active) n++;
		return n;
	}

	int aux(int what, float *out, int max) override {
		if (what == 0 && max >= 10) {
			for (int i = 0; i < 9; i++) out[i] = p(P_D1 + i);
			out[9] = vis_rot;
			return 10;
		}
		return 0;
	}

	void process(float *L, float *R, int n) override {
		const float atk = ADSR::rate(sr, p(P_ATTACK));
		const float rel = ADSR::rate(sr, p(P_RELEASE));
		const float perc_dec = ADSR::rate(sr, p(P_PERC_DECAY));
		const float perc_amt = p(P_PERC);
		const int perc_h = pi(P_PERC_HARM) == 0 ? 3 : 5;   // 2nd or 3rd drawbar ratio
		const float drive = 1.0f + p(P_DRIVE) * 6.0f;
		const float vol = p(P_VOL);
		float bars[9];
		for (int i = 0; i < 9; i++) bars[i] = p(P_D1 + i);

		const bool rotary = pb(P_ROTARY);
		const float want_speed = pi(P_ROT_SPEED) == 0 ? 0.8f : 6.6f;
		const float rot_depth = p(P_ROT_DEPTH);
		const float ramp = 1.0f - std::exp(-1.0f / (float)(sr * 0.9));

		for (int i = 0; i < n; i++) {
			float dry = 0.0f, dryL = 0.0f, dryR = 0.0f;
			for (auto &x : v) {
				if (!x.h.active) continue;
				const float hz = note_to_hz(x.h.pitch());
				float s = 0.0f;
				for (int d = 0; d < 9; d++) {
					if (bars[d] < 0.001f) continue;
					const float inc = hz * DRAWBAR_RATIO[d] / (float)sr;
					if (inc > 0.48f) continue;
					x.phase[d] += inc;
					if (x.phase[d] >= 1.0f) x.phase[d] -= 1.0f;
					s += std::sin((float)TAU * x.phase[d]) * bars[d];
				}
				// Percussion is a single decaying tap on one harmonic, and it
				// does not retrigger while other keys are held -- as on the
				// instrument this borrows from.
				if (perc_amt > 0.001f && x.perc > 0.0005f) {
					const float inc = hz * DRAWBAR_RATIO[perc_h] / (float)sr;
					x.phase[perc_h] += 0.0f;   // shares the drawbar phase
					s += std::sin((float)TAU * x.phase[perc_h]) * x.perc * perc_amt * 2.0f;
					x.perc += (0.0f - x.perc) * perc_dec;
				}
				if (x.click > 0.0005f) {
					s += x.click_lp.lp(x.h.vel * 0.6f * (x.click > 0.0f ? 1.0f : 0.0f)) * x.click;
					x.click *= 0.86f;
				}
				const float want = x.h.held ? 1.0f : 0.0f;
				x.amp += (want - x.amp) * (x.h.held ? atk : rel);
				if (!x.h.held && x.amp < 0.0008f) { x.h.active = false; x.amp = 0.0f; }
				const float a = s * x.amp * (0.25f + x.h.vel * 0.35f);
				dryL += a * x.h.gl;
				dryR += a * x.h.gr;
			}
			// A rotary cabinet is one speaker in a box; a note cannot be placed
			// inside it, so the two sides are summed before it and the note's
			// own pan only applies to the straight output.
			dry = tanh_fast((dryL + dryR) * 0.5f * drive) * vol;

			if (!rotary) {
				L[i] = tanh_fast(dryL * drive) * vol;
				R[i] = tanh_fast(dryR * drive) * vol;
				continue;
			}
			rot_speed += (want_speed - rot_speed) * ramp;
			const float inc = rot_speed / (float)sr;
			horn_phase += inc;
			if (horn_phase >= 1.0f) horn_phase -= 1.0f;
			drum_phase += inc * 0.78f;
			if (drum_phase >= 1.0f) drum_phase -= 1.0f;
			const float hs = std::sin((float)TAU * horn_phase);
			const float hc = std::cos((float)TAU * horn_phase);
			const float ds = std::sin((float)TAU * drum_phase);
			vis_rot = horn_phase;

			// Doppler: the horn's distance to each ear changes as it turns.
			rot_l.write(dry);
			rot_r.write(dry);
			const float base_d = (float)(sr * 0.004);
			const float sweep = (float)(sr * 0.0016) * rot_depth;
			const float hl = horn_lp[0].lp(rot_l.read(base_d + sweep * (1.0f + hs)));
			const float hr = horn_lp[1].lp(rot_r.read(base_d + sweep * (1.0f - hs)));
			const float dl = drum_lp[0].lp(dry);
			const float dr = drum_lp[1].lp(dry);
			const float ha = 1.0f + rot_depth * 0.5f * hc;
			const float da = 1.0f + rot_depth * 0.35f * ds;
			L[i] = dcl(hl * ha * 0.7f + dl * da * 0.5f);
			R[i] = dcr(hr * (2.0f - ha) * 0.7f + dr * (2.0f - da) * 0.5f);
		}
	}
};

// ---------------------------------------------------------------------------
// Modal — a bank of ringing resonators struck by a short burst. Change the
// ratios between the modes and the same code is a bell, a marimba or a glass.
// ---------------------------------------------------------------------------
static const int MODES = 8;
struct Material { const char *name; float ratio[MODES]; float amp[MODES]; float decay[MODES]; };
static const Material MATERIALS[5] = {
	// Bell: inharmonic, long, with the minor-third hum that makes it a bell.
	{"Bell", {0.5f, 1.0f, 1.19f, 1.56f, 2.0f, 2.51f, 2.66f, 3.01f},
			{0.6f, 1.0f, 0.7f, 0.5f, 0.45f, 0.3f, 0.25f, 0.2f},
			{1.0f, 0.9f, 0.7f, 0.55f, 0.45f, 0.3f, 0.25f, 0.2f}},
	// Marimba: the classic 1 : 4 : 10 bar tuning, short and woody.
	{"Marimba", {1.0f, 3.99f, 10.65f, 17.9f, 26.0f, 34.0f, 44.0f, 55.0f},
			{1.0f, 0.4f, 0.18f, 0.08f, 0.04f, 0.02f, 0.01f, 0.008f},
			{0.5f, 0.28f, 0.16f, 0.1f, 0.07f, 0.05f, 0.04f, 0.03f}},
	{"Glass", {1.0f, 2.32f, 4.25f, 6.63f, 9.38f, 12.4f, 15.7f, 19.2f},
			{1.0f, 0.6f, 0.4f, 0.28f, 0.2f, 0.14f, 0.1f, 0.07f},
			{0.9f, 0.75f, 0.6f, 0.5f, 0.4f, 0.32f, 0.26f, 0.2f}},
	{"Metal", {1.0f, 1.41f, 1.73f, 2.0f, 2.24f, 2.45f, 2.65f, 2.83f},
			{1.0f, 0.8f, 0.7f, 0.6f, 0.5f, 0.42f, 0.35f, 0.3f},
			{1.0f, 0.95f, 0.9f, 0.85f, 0.8f, 0.75f, 0.7f, 0.65f}},
	{"Tube", {1.0f, 3.0f, 5.0f, 7.0f, 9.0f, 11.0f, 13.0f, 15.0f},
			{1.0f, 0.5f, 0.3f, 0.2f, 0.14f, 0.1f, 0.07f, 0.05f},
			{0.8f, 0.6f, 0.45f, 0.35f, 0.28f, 0.22f, 0.18f, 0.14f}},
};

struct ModalVoice {
	VoiceHead h;
	// Each mode is a two-pole resonator run as a rotating phasor with a decay,
	// which is cheap and never blows up.
	float re[MODES] = {0}, im[MODES] = {0};
	float cs[MODES] = {0}, sn[MODES] = {0}, dec[MODES] = {0};
	float burst = 0.0f;
	OnePole burst_lp;
	Rng rng;
	float pan = 0.0f;
};

class Modal : public Plug {
	enum { P_MAT, P_BRIGHT, P_DECAY, P_STRIKE, P_INHARM, P_SPREAD, P_TONE,
		P_VEL_BRIGHT, P_RELEASE, P_VOL };
	static const int VOICES = 12;
	ModalVoice v[VOICES];
	uint64_t age = 0;
	float vis[MODES] = {0};

public:
	void prepare() override {
		for (auto &x : v) { x = ModalVoice(); x.burst_lp.set(sr, 6000.0f); }
	}
	void reset() override { prepare(); }

	void note_on(int key, float vel, int id) override {
		const int i = alloc_voice(v, VOICES, age);
		ModalVoice &x = v[i];
		x.h.active = true; x.h.held = true; x.h.key = key; x.h.id = id;
		x.h.vel = vel; x.h.age = age++;
		take_expr(x.h);
		const Material &m = MATERIALS[std::max(0, std::min(4, pi(P_MAT)))];
		const float hz = note_to_hz(x.h.pitch());
		const float inh = p(P_INHARM);
		const float decay = p(P_DECAY);
		const float bright = clampf(p(P_BRIGHT) + (vel - 0.7f) * p(P_VEL_BRIGHT), 0.0f, 1.5f);
		const float strike = p(P_STRIKE);
		for (int k = 0; k < MODES; k++) {
			float ratio = m.ratio[k];
			// Inharmonicity stretches the partials the way a struck bar's are.
			ratio *= 1.0f + inh * 0.06f * (float)(k * k);
			const float f = clampf(hz * ratio, 10.0f, (float)sr * 0.47f);
			const float w = (float)TAU * f / (float)sr;
			x.cs[k] = std::cos(w);
			x.sn[k] = std::sin(w);
			const float t = std::max(0.02f, m.decay[k] * decay * 6.0f);
			x.dec[k] = std::exp(-1.0f / (float)(sr * t));
			// Where the bar is struck decides which modes are excited: a node
			// gets nothing, an antinode gets everything.
			const float pos = std::sin((float)PI * strike * (float)(k + 1));
			const float a = m.amp[k] * std::pow(bright + 0.001f, (float)k * 0.35f) * std::fabs(pos);
			x.re[k] = a * vel;
			x.im[k] = 0.0f;
		}
		x.burst = 1.0f;
		x.burst_lp.set(sr, 800.0f + p(P_TONE) * 9000.0f);
		x.pan = (x.rng.bi()) * p(P_SPREAD);
	}
	void note_off(int key, int id) override {
		for (auto &x : v) {
			if (x.h.active && x.h.held && x.h.key == key && (id < 0 || x.h.id == id)) x.h.held = false;
		}
	}
	void all_notes_off() override { for (auto &x : v) x = ModalVoice(); }
	int active_voices() const override {
		int n = 0;
		for (const auto &x : v) if (x.h.active) n++;
		return n;
	}
	float tail() const override { return 8.0f; }

	int aux(int what, float *out, int max) override {
		if (what != 0) return 0;
		const int n = std::min(max, MODES);
		for (int i = 0; i < n; i++) out[i] = vis[i];
		return n;
	}

	void process(float *L, float *R, int n) override {
		const float vol = p(P_VOL);
		const float rel = ADSR::rate(sr, p(P_RELEASE));
		float peak[MODES] = {0};
		for (int i = 0; i < n; i++) {
			float l = 0.0f, r = 0.0f;
			for (auto &x : v) {
				if (!x.h.active) continue;
				float s = 0.0f;
				// The burst is what strikes the bank: a short filtered click.
				float exc = 0.0f;
				if (x.burst > 0.0005f) {
					exc = x.burst_lp.lp(x.rng.bi()) * x.burst;
					x.burst *= 0.55f;
				}
				float loud = 0.0f;
				for (int k = 0; k < MODES; k++) {
					const float re = x.re[k] * x.cs[k] - x.im[k] * x.sn[k];
					const float im = x.re[k] * x.sn[k] + x.im[k] * x.cs[k];
					x.re[k] = flush((re + exc * 0.25f) * x.dec[k]);
					x.im[k] = flush(im * x.dec[k]);
					s += x.re[k];
					const float a = std::fabs(x.re[k]);
					loud += a;
					if (a > peak[k]) peak[k] = a;
				}
				// Letting go damps the bar rather than cutting it.
				if (!x.h.held) {
					for (int k = 0; k < MODES; k++) { x.re[k] *= 1.0f - rel; x.im[k] *= 1.0f - rel; }
				}
				if (loud < 0.00015f && x.burst < 0.001f) { x.h.active = false; continue; }
				const float pl = std::sqrt(0.5f * (1.0f - x.pan));
				const float pr = std::sqrt(0.5f * (1.0f + x.pan));
				l += s * pl * x.h.gl;
				r += s * pr * x.h.gr;
			}
			L[i] = tanh_fast(l * vol);
			R[i] = tanh_fast(r * vol);
		}
		for (int k = 0; k < MODES; k++) vis[k] = std::max(peak[k], vis[k] * 0.9f);
	}
};

// ---------------------------------------------------------------------------
// Vox — a saw through three formant filters, several detuned copies wide apart.
// Sweeping the vowel is the whole instrument.
// ---------------------------------------------------------------------------
struct Formant { float f[3]; float a[3]; float bw[3]; };
// A, E, I, O, U as sung, near enough for a pad.
static const Formant VOWELS[5] = {
	{{ 730, 1090, 2440}, {1.0f, 0.5f, 0.25f}, {80, 90, 120}},
	{{ 530, 1840, 2480}, {1.0f, 0.4f, 0.2f}, {70, 100, 120}},
	{{ 270, 2290, 3010}, {1.0f, 0.3f, 0.2f}, {60, 100, 120}},
	{{ 570,  840, 2410}, {1.0f, 0.55f, 0.15f}, {70, 80, 110}},
	{{ 300,  870, 2240}, {1.0f, 0.35f, 0.1f}, {60, 80, 110}},
};

struct VoxVoice {
	VoiceHead h;
	Osc osc[3];
	SVF form[3][3];      // [unison copy][formant]
	ADSR env;
	float detune[3] = {0, 0, 0};
	float pan[3] = {0, 0, 0};
	Rng rng;
	float breath_lp = 0.0f;
};

class Vox : public Plug {
	enum { P_VOWEL, P_MORPH, P_UNISON, P_DETUNE, P_WIDTH, P_BREATH, P_GROWL,
		P_ATTACK, P_DECAY, P_SUSTAIN, P_RELEASE, P_TREM_RATE, P_TREM_DEPTH,
		P_OCTAVE, P_VOL };
	static const int VOICES = 10;
	VoxVoice v[VOICES];
	uint64_t age = 0;
	LFO trem;
	float vis_f[3] = {0, 0, 0};

public:
	void prepare() override {
		for (auto &x : v) {
			x = VoxVoice();
			x.env.prepare(sr);
		}
		trem.shape = 0;
	}
	void reset() override { prepare(); }

	void note_on(int key, float vel, int id) override {
		const int i = alloc_voice(v, VOICES, age);
		VoxVoice &x = v[i];
		x.h.active = true; x.h.held = true; x.h.key = key; x.h.id = id;
		x.h.vel = vel; x.h.age = age++;
		take_expr(x.h);
		x.env.prepare(sr);
		x.env.set(p(P_ATTACK), p(P_DECAY), p(P_SUSTAIN), p(P_RELEASE));
		x.env.gate_on();
		const int uni = std::max(1, pi(P_UNISON));
		for (int u = 0; u < 3; u++) {
			x.osc[u].phase = x.rng.uni();
			x.detune[u] = uni <= 1 ? 0.0f : ((float)u / (float)(uni - 1) * 2.0f - 1.0f);
			x.pan[u] = x.detune[u];
		}
	}
	void note_off(int key, int id) override {
		for (auto &x : v) {
			if (x.h.active && x.h.held && x.h.key == key && (id < 0 || x.h.id == id)) {
				x.h.held = false;
				x.env.gate_off();
			}
		}
	}
	void all_notes_off() override { for (auto &x : v) x = VoxVoice(); }
	int active_voices() const override {
		int n = 0;
		for (const auto &x : v) if (x.h.active) n++;
		return n;
	}

	int aux(int what, float *out, int max) override {
		if (what != 0 || max < 3) return 0;
		for (int i = 0; i < 3; i++) out[i] = vis_f[i];
		return 3;
	}

	void process(float *L, float *R, int n) override {
		// The vowel control is continuous: morph blends between neighbours.
		const float pos = clampf(p(P_VOWEL) + p(P_MORPH), 0.0f, 3.999f);
		const int a = (int)pos;
		const int b = std::min(4, a + 1);
		const float t = pos - (float)a;
		Formant f{};
		for (int k = 0; k < 3; k++) {
			f.f[k] = lerp(VOWELS[a].f[k], VOWELS[b].f[k], t);
			f.a[k] = lerp(VOWELS[a].a[k], VOWELS[b].a[k], t);
			f.bw[k] = lerp(VOWELS[a].bw[k], VOWELS[b].bw[k], t);
			vis_f[k] = f.f[k];
		}
		const int uni = std::max(1, std::min(3, pi(P_UNISON)));
		const float det = p(P_DETUNE);
		const float width = p(P_WIDTH);
		const float breath = p(P_BREATH);
		const float growl = p(P_GROWL);
		const float oct = (float)(pi(P_OCTAVE) * 12);
		const float vol = p(P_VOL) / std::sqrt((float)uni);
		trem.set(sr, p(P_TREM_RATE));
		const float trem_depth = p(P_TREM_DEPTH);

		for (int i = 0; i < n; i++) {
			const float tr = 1.0f - trem_depth * 0.5f * (1.0f - trem.next());
			float l = 0.0f, r = 0.0f;
			for (auto &x : v) {
				if (!x.h.active) continue;
				const float e = x.env.next();
				if (!x.env.active()) { x.h.active = false; continue; }
				const float hz = note_to_hz(x.h.pitch() + oct);
				for (int u = 0; u < uni; u++) {
					const float inc = hz * std::pow(2.0f, x.detune[u] * det / 1200.0f) / (float)sr;
					float s = x.osc[u].next(2, inc);
					// Growl is a touch of the raw saw let past the formants.
					const float raw = s * growl;
					if (breath > 0.0001f) {
						x.breath_lp = lerp(x.breath_lp, x.rng.bi(), 0.4f);
						s += x.breath_lp * breath;
					}
					float y = 0.0f;
					for (int k = 0; k < 3; k++) {
						x.form[u][k].set(sr, f.f[k], std::max(1.0f, f.f[k] / f.bw[k]));
						x.form[u][k].process(s);
						y += x.form[u][k].bp * f.a[k];
					}
					y = (y * 1.6f + raw) * e * (0.3f + x.h.vel * 0.5f);
					const float pan = x.pan[u] * width;
					l += y * std::sqrt(0.5f * (1.0f - pan)) * x.h.gl;
					r += y * std::sqrt(0.5f * (1.0f + pan)) * x.h.gr;
				}
			}
			L[i] = tanh_fast(l * vol * tr);
			R[i] = tanh_fast(r * vol * tr);
		}
	}
};

static Plug *make_acid() { return new Acid(); }
static Plug *make_organ() { return new Organ(); }
static Plug *make_modal() { return new Modal(); }
static Plug *make_vox() { return new Vox(); }

void register_synths2(std::vector<PlugDesc> &out) {
	out.push_back({"cd.acid", "Acid", "Cadmium", "Synth", true, UI_ACID, {
		{"wave", "Wave", 0, 1, 0, P_CHOICE, "Osc", "Saw|Square", 1},
		{"tune", "Tune", -24, 24, -12, P_SEMI, "Osc", nullptr, 1},
		{"cut", "Cutoff", 40, 8000, 320, P_HZ, "Filter", nullptr, 0.3f},
		{"res", "Reso", 0, 0.98f, 0.72f, P_PCT, "Filter", nullptr, 1},
		{"envmod", "Env Mod", 0, 3, 1.4f, P_PCT, "Filter", nullptr, 1},
		{"decay", "Decay", 0.03f, 2.5f, 0.35f, P_SEC, "Filter", nullptr, 0.4f},
		{"accent", "Accent", 0, 1, 0.6f, P_PCT, "Filter", nullptr, 1},
		{"glide", "Glide", 0, 0.4f, 0.06f, P_SEC, "Osc", nullptr, 0.5f},
		{"drive", "Drive", 0, 1, 0.25f, P_PCT, "Output", nullptr, 1},
		{"sub", "Sub", 0, 1, 0, P_PCT, "Osc", nullptr, 1},
		{"attack", "Attack", 0.0005f, 0.2f, 0.003f, P_SEC, "Amp", nullptr, 0.4f},
		{"vol", "Volume", 0, 1.5f, 0.8f, P_PCT, "Output", nullptr, 1},
	}, make_acid});

	out.push_back({"cd.organ", "Organ", "Cadmium", "Synth", true, UI_ORGAN, {
		{"d1", "16'", 0, 1, 0.8f, P_PCT, "Drawbars", nullptr, 1},
		{"d2", "5 1/3'", 0, 1, 0.3f, P_PCT, "Drawbars", nullptr, 1},
		{"d3", "8'", 0, 1, 1.0f, P_PCT, "Drawbars", nullptr, 1},
		{"d4", "4'", 0, 1, 0.55f, P_PCT, "Drawbars", nullptr, 1},
		{"d5", "2 2/3'", 0, 1, 0.2f, P_PCT, "Drawbars", nullptr, 1},
		{"d6", "2'", 0, 1, 0.35f, P_PCT, "Drawbars", nullptr, 1},
		{"d7", "1 3/5'", 0, 1, 0.1f, P_PCT, "Drawbars", nullptr, 1},
		{"d8", "1 1/3'", 0, 1, 0.1f, P_PCT, "Drawbars", nullptr, 1},
		{"d9", "1'", 0, 1, 0.25f, P_PCT, "Drawbars", nullptr, 1},
		{"perc", "Percussion", 0, 1, 0.35f, P_PCT, "Percussion", nullptr, 1},
		{"perc_harm", "Harmonic", 0, 1, 1, P_CHOICE, "Percussion", "Second|Third", 1},
		{"perc_decay", "Decay", 0.05f, 1.5f, 0.28f, P_SEC, "Percussion", nullptr, 0.5f},
		{"click", "Key Click", 0, 1, 0.25f, P_PCT, "Percussion", nullptr, 1},
		{"attack", "Attack", 0.0005f, 0.1f, 0.004f, P_SEC, "Envelope", nullptr, 0.4f},
		{"release", "Release", 0.005f, 1.0f, 0.09f, P_SEC, "Envelope", nullptr, 0.4f},
		{"rotary", "Rotary", 0, 1, 1, P_BOOL, "Cabinet", nullptr, 1},
		{"rot_speed", "Speed", 0, 1, 0, P_CHOICE, "Cabinet", "Slow|Fast", 1},
		{"rot_depth", "Depth", 0, 1, 0.7f, P_PCT, "Cabinet", nullptr, 1},
		{"drive", "Drive", 0, 1, 0.3f, P_PCT, "Output", nullptr, 1},
		{"vol", "Volume", 0, 1.5f, 0.75f, P_PCT, "Output", nullptr, 1},
	}, make_organ});

	out.push_back({"cd.modal", "Modal", "Cadmium", "Synth", true, UI_MODAL, {
		{"material", "Material", 0, 4, 0, P_CHOICE, "Body", "Bell|Marimba|Glass|Metal|Tube", 1},
		{"bright", "Brightness", 0.05f, 1.5f, 0.75f, P_PCT, "Body", nullptr, 1},
		{"decay", "Decay", 0.05f, 2.0f, 0.6f, P_PCT, "Body", nullptr, 1},
		{"strike", "Strike", 0.02f, 0.5f, 0.16f, P_PCT, "Body", nullptr, 1},
		{"inharm", "Inharmonic", 0, 1, 0.12f, P_PCT, "Body", nullptr, 1},
		{"spread", "Spread", 0, 1, 0.4f, P_PCT, "Output", nullptr, 1},
		{"tone", "Mallet Tone", 0, 1, 0.5f, P_PCT, "Strike", nullptr, 1},
		{"vel_bright", "Vel to Tone", 0, 1, 0.5f, P_PCT, "Strike", nullptr, 1},
		{"release", "Damping", 0.00002f, 0.01f, 0.0008f, P_PCT, "Body", nullptr, 0.4f},
		{"vol", "Volume", 0, 1.5f, 0.7f, P_PCT, "Output", nullptr, 1},
	}, make_modal});

	out.push_back({"cd.vox", "Vox", "Cadmium", "Synth", true, UI_VOX, {
		{"vowel", "Vowel", 0, 4, 0, P_CHOICE, "Formants", "A|E|I|O|U", 1},
		{"morph", "Morph", 0, 1, 0, P_PCT, "Formants", nullptr, 1},
		{"unison", "Voices", 1, 3, 3, P_SEMI, "Ensemble", nullptr, 1},
		{"detune", "Detune", 0, 60, 16, P_SEMI, "Ensemble", nullptr, 1},
		{"width", "Width", 0, 1, 0.8f, P_PCT, "Ensemble", nullptr, 1},
		{"breath", "Breath", 0, 1, 0.12f, P_PCT, "Formants", nullptr, 1},
		{"growl", "Growl", 0, 1, 0.08f, P_PCT, "Formants", nullptr, 1},
		{"attack", "Attack", 0.002f, 4, 0.35f, P_SEC, "Envelope", nullptr, 0.4f},
		{"decay", "Decay", 0.005f, 4, 0.8f, P_SEC, "Envelope", nullptr, 0.4f},
		{"sustain", "Sustain", 0, 1, 0.8f, P_PCT, "Envelope", nullptr, 1},
		{"release", "Release", 0.005f, 6, 0.9f, P_SEC, "Envelope", nullptr, 0.4f},
		{"trem_rate", "Vibrato Rate", 0.05f, 12, 4.5f, P_HZ, "Vibrato", nullptr, 0.4f},
		{"trem_depth", "Vibrato", 0, 1, 0.15f, P_PCT, "Vibrato", nullptr, 1},
		{"octave", "Octave", -2, 2, 0, P_SEMI, "Ensemble", nullptr, 1},
		{"vol", "Volume", 0, 1.5f, 0.8f, P_PCT, "Output", nullptr, 1},
	}, make_vox});
}

} // namespace cd
