// Cadmium — Pulse (drum synth) and Pluck (physically modelled string).
#include "plugin.h"

namespace cd {

// ===========================================================================
// Pulse — one synthesised drum per channel, chosen by Mode.
// ===========================================================================
enum {
	PU_MODE, PU_TUNE, PU_PITCH_ENV, PU_PITCH_DEC,
	PU_BODY_DEC, PU_BODY_LEVEL, PU_BEND,
	PU_NOISE_LEVEL, PU_NOISE_DEC, PU_NOISE_TONE, PU_NOISE_RES,
	PU_CLICK, PU_DRIVE, PU_LEVEL, PU_PAN, PU_KEY_TRACK,
	PU_COUNT
};

struct PulseVoice {
	bool active = false;
	float vel = 1.0f;
	float key_ratio = 1.0f;
	// The note's own pan, as a gain each side, and its detune folded into the
	// key ratio below.
	float gl = 1.0f, gr = 1.0f;
	float phase = 0.0f;
	float body_env = 0.0f, noise_env = 0.0f, pitch_env = 0.0f;
	float click_env = 0.0f;
	SVF nf;
	Rng rng;
	int burst = 0;
	float clap_t = 0.0f;
	int clap_n = 0;
};

class Pulse : public Plug {
public:
	static const int MAXV = 8;
	PulseVoice v[MAXV];
	int rr = 0;
	DCBlock dcl, dcr;

	void prepare() override {
		dcl.set(sr); dcr.set(sr);
		for (int i = 0; i < MAXV; i++) { v[i].active = false; v[i].nf.reset(); }
	}
	void note_on(int key, float vel, int) override {
		PulseVoice &vv = v[rr];
		rr = (rr + 1) % MAXV;
		vv.active = true;
		vv.vel = vel;
		// A drum keeps its tuning whatever key triggers it, unless Key Track is
		// dialled up -- otherwise a step on C2 drops a kick to 13 Hz.
		VoiceHead h;
		h.key = key;
		take_expr(h);
		vv.gl = h.gl;
		vv.gr = h.gr;
		vv.key_ratio = std::pow(2.0f, (h.pitch() - 60.0f) * p(PU_KEY_TRACK) / 12.0f);
		vv.phase = 0.0f;
		vv.body_env = 1.0f;
		vv.noise_env = 1.0f;
		vv.pitch_env = 1.0f;
		vv.click_env = 1.0f;
		vv.burst = (int)(sr * 0.002);
		vv.clap_t = 0.0f;
		vv.clap_n = 0;
		vv.nf.reset();
	}
	void all_notes_off() override { for (int i = 0; i < MAXV; i++) v[i].active = false; }
	int active_voices() const override {
		int n = 0; for (int i = 0; i < MAXV; i++) if (v[i].active) n++; return n;
	}
	float tail() const override { return 3.0f; }

	void process(float *L, float *R, int n) override {
		const int mode = pi(PU_MODE);   // 0 kick 1 snare 2 clap 3 hat 4 tom 5 rim 6 cymbal
		const float tune = p(PU_TUNE);
		const float base = note_to_hz(tune);
		const float bd = ADSR::rate(sr, p(PU_BODY_DEC));
		const float nd = ADSR::rate(sr, p(PU_NOISE_DEC));
		const float pd = ADSR::rate(sr, p(PU_PITCH_DEC));
		const float cd_ = ADSR::rate(sr, 0.004f);
		const float drive = 1.0f + p(PU_DRIVE) * 12.0f;
		const float out = db_to_gain(p(PU_LEVEL));
		const float pan = p(PU_PAN);
		const float pl = std::cos((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
		const float pr = std::sin((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
		const bool metallic = (mode == 3 || mode == 6);

		for (int s = 0; s < n; s++) {
			float accL = 0.0f, accR = 0.0f;
			for (int i = 0; i < MAXV; i++) {
				PulseVoice &vv = v[i];
				if (!vv.active) continue;
				vv.body_env -= vv.body_env * bd;
				vv.noise_env -= vv.noise_env * nd;
				vv.pitch_env -= vv.pitch_env * pd;
				vv.click_env -= vv.click_env * cd_;
				if (vv.body_env < 0.0002f && vv.noise_env < 0.0002f) { vv.active = false; continue; }

				const float f = base * vv.key_ratio
						* (1.0f + vv.pitch_env * p(PU_PITCH_ENV))
						* (1.0f - (1.0f - vv.body_env) * p(PU_BEND) * 0.4f);
				float body = 0.0f;
				if (metallic) {
					// Six detuned squares, the classic 808 metal cluster.
					static const float rat[6] = {1.0f, 1.4471f, 1.6170f, 1.9265f, 2.5028f, 2.6637f};
					for (int k = 0; k < 6; k++) {
						const float ph = vv.phase * rat[k];
						body += ((ph - std::floor(ph)) < 0.5f ? 1.0f : -1.0f);
					}
					body *= 0.16f;
				} else {
					body = std::sin((float)TAU * vv.phase);
					if (mode == 1 || mode == 4) body += 0.4f * std::sin((float)TAU * vv.phase * 1.593f);
					if (mode == 5) body = soft_clip(body * 3.0f);
				}
				vv.phase += f / (float)sr;
				if (vv.phase >= 1.0f) vv.phase -= std::floor(vv.phase);

				float noise = vv.rng.bi();
				if (mode == 2) {
					// Clap: four bursts a few ms apart, then a tail.
					vv.clap_t += 1.0f / (float)sr;
					if (vv.clap_n < 4 && vv.clap_t > 0.011f) { vv.clap_t = 0.0f; vv.clap_n++; vv.noise_env = 1.0f; }
					if (vv.clap_n >= 4) noise *= 0.7f;
				}
				vv.nf.set(sr, clampf(p(PU_NOISE_TONE) * (metallic ? 1.0f : 1.0f), 40.0f, (float)sr * 0.45f),
						0.5f + p(PU_NOISE_RES) * 12.0f);
				vv.nf.process(noise);
				const float nsig = (mode == 0 || mode == 4) ? vv.nf.lp : vv.nf.bp;

				float x = body * vv.body_env * p(PU_BODY_LEVEL)
						+ nsig * vv.noise_env * p(PU_NOISE_LEVEL)
						+ (vv.burst > 0 ? vv.click_env * p(PU_CLICK) : 0.0f);
				if (vv.burst > 0) vv.burst--;
				const float y = soft_clip(x * drive * vv.vel) / std::sqrt(drive);
				accL += y * vv.gl;
				accR += y * vv.gr;
			}
			L[s] = dcl(accL * out * pl);
			R[s] = dcr(accR * out * pr);
		}
	}
};

static Plug *make_pulse() { return new Pulse(); }

// ===========================================================================
// Pluck — Karplus-Strong with a tuned all-pass and a body resonator.
// ===========================================================================
enum {
	PL_DAMP, PL_BRIGHT, PL_POSITION, PL_DECAY, PL_EXCITE, PL_NOISE_TONE,
	PL_BODY, PL_BODY_FREQ, PL_SPREAD, PL_VOICES, PL_VEL, PL_LEVEL, PL_PAN,
	PL_COUNT
};

struct PluckVoice {
	VoiceHead h;
	Delay line;
	OnePole damp;
	Biquad pos;
	float len = 100.0f;
	float energy = 0.0f;
	int excite = 0;
	float pan = 0.0f;
	Rng rng;
	float last = 0.0f;
};

class Pluck : public Plug {
public:
	static const int MAXV = 12;
	PluckVoice v[MAXV];
	uint64_t counter = 0;
	Biquad bodyL, bodyR;
	Rng rng;

	void prepare() override {
		for (int i = 0; i < MAXV; i++) {
			v[i].line.prepare((int)(sr / 18.0) + 8);
			v[i].h.active = false;
			v[i].last = 0.0f;
		}
	}
	void note_on(int key, float vel, int id) override {
		const int nv = std::max(1, std::min(MAXV, pi(PL_VOICES)));
		const int i = alloc_voice(v, nv, counter);
		PluckVoice &vv = v[i];
		vv.h.active = vv.h.held = true;
		vv.h.key = key; vv.h.id = id; vv.h.vel = vel; vv.h.age = counter++;
		take_expr(vv.h);
		vv.len = (float)sr / std::max(20.0f, note_to_hz(vv.h.pitch()));
		vv.line.clear();
		vv.energy = 1.0f;
		vv.excite = (int)std::max(2.0f, vv.len * p(PL_EXCITE));
		vv.pan = rng.bi() * p(PL_SPREAD);
		vv.damp.set(sr, clampf(400.0f + p(PL_BRIGHT) * 9000.0f, 200.0f, (float)sr * 0.45f));
		vv.pos.notch(sr, clampf(note_to_hz(vv.h.pitch()) / std::max(0.05f, p(PL_POSITION)), 60.0f, (float)sr * 0.45f), 1.2f);
	}
	void note_off(int key, int id) override {
		for (int i = 0; i < MAXV; i++) {
			if (v[i].h.active && v[i].h.held && v[i].h.key == key && (id < 0 || v[i].h.id == id)) {
				v[i].h.held = false;
				return;
			}
		}
	}
	void all_notes_off() override { for (int i = 0; i < MAXV; i++) v[i].h.held = false; }
	int active_voices() const override {
		int n = 0; for (int i = 0; i < MAXV; i++) if (v[i].h.active) n++; return n;
	}

	void process(float *L, float *R, int n) override {
		const int nv = std::max(1, std::min(MAXV, pi(PL_VOICES)));
		const float damp = clampf(p(PL_DAMP), 0.0f, 1.0f);
		const float decay = 0.985f + p(PL_DECAY) * 0.0149f;
		const float out = db_to_gain(p(PL_LEVEL));
		const float pan = p(PL_PAN);
		bodyL.peaking(sr, p(PL_BODY_FREQ), 1.4f, p(PL_BODY) * 9.0f);
		bodyR.peaking(sr, p(PL_BODY_FREQ) * 1.06f, 1.4f, p(PL_BODY) * 9.0f);

		for (int s = 0; s < n; s++) {
			float accL = 0.0f, accR = 0.0f;
			for (int i = 0; i < nv; i++) {
				PluckVoice &vv = v[i];
				if (!vv.h.active) continue;
				float x = 0.0f;
				if (vv.excite > 0) {
					// Filtered noise burst, the "pick".
					x = vv.rng.bi() * vv.h.vel;
					x = lerp(x, vv.last, clampf(1.0f - p(PL_NOISE_TONE), 0.0f, 0.95f));
					vv.last = x;
					vv.excite--;
				}
				float y = vv.line.read(vv.len);
				y = vv.damp.lp(y) * (damp * 0.35f + 0.65f);
				y = vv.pos(y);
				y *= vv.h.held ? decay : (decay * 0.995f);
				vv.line.write(x + y);
				const float amp = std::fabs(y);
				vv.energy = std::max(amp, vv.energy * 0.99995f);
				if (vv.energy < 1e-5f && vv.excite <= 0) { vv.h.active = false; continue; }
				const float g = lerp(1.0f, vv.h.vel, p(PL_VEL));
				accL += y * g * (0.5f - vv.pan * 0.5f) * vv.h.gl;
				accR += y * g * (0.5f + vv.pan * 0.5f) * vv.h.gr;
			}
			const float pl = std::cos((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
			const float pr = std::sin((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
			L[s] = bodyL(accL) * out * pl;
			R[s] = bodyR(accR) * out * pr;
		}
	}
};

static Plug *make_pluck() { return new Pluck(); }

void register_drums(std::vector<PlugDesc> &out) {
	out.push_back({
		"cd.pulse", "Pulse", "Cadmium", "Drum", true, UI_DRUM, {
			{"mode", "Mode", 0, 6, 0, P_CHOICE, "Drum", "Kick|Snare|Clap|Hi-Hat|Tom|Rim|Cymbal", 1},
			{"tune", "Tune", 12, 96, 33, P_SEMI, "Drum", nullptr, 1},
			{"pitch_env", "Pitch Env", 0, 8, 2.2f, P_PCT, "Drum", nullptr, 1},
			{"pitch_dec", "Pitch Dec", 0.002f, 1, 0.045f, P_SEC, "Drum", nullptr, 0.3f},
			{"body_dec", "Body Dec", 0.005f, 4, 0.42f, P_SEC, "Body", nullptr, 0.3f},
			{"body_level", "Body", 0, 1.5f, 1.0f, P_PCT, "Body", nullptr, 1},
			{"bend", "Bend", 0, 1, 0.2f, P_PCT, "Body", nullptr, 1},
			{"noise_level", "Noise", 0, 1.5f, 0.12f, P_PCT, "Noise", nullptr, 1},
			{"noise_dec", "Noise Dec", 0.002f, 3, 0.08f, P_SEC, "Noise", nullptr, 0.3f},
			{"noise_tone", "Tone", 60, 16000, 3000, P_HZ, "Noise", nullptr, 0.3f},
			{"noise_res", "Reso", 0, 1, 0.2f, P_PCT, "Noise", nullptr, 1},
			{"click", "Click", 0, 1, 0.25f, P_PCT, "Shape", nullptr, 1},
			{"drive", "Drive", 0, 1, 0.25f, P_PCT, "Shape", nullptr, 1},
			{"level", "Level", -60, 12, -3, P_DB, "Output", nullptr, 1},
			{"pan", "Pan", -1, 1, 0, P_FLOAT, "Output", nullptr, 1},
			{"key_track", "Key Track", 0, 1, 0, P_PCT, "Drum", nullptr, 1},
		}, make_pulse });

	out.push_back({
		"cd.pluck", "Pluck", "Cadmium", "Synth", true, UI_SYNTH, {
			{"damp", "Damping", 0, 1, 0.4f, P_PCT, "String", nullptr, 1},
			{"bright", "Brightness", 0, 1, 0.55f, P_PCT, "String", nullptr, 1},
			{"position", "Pick Pos", 0.05f, 0.95f, 0.28f, P_PCT, "String", nullptr, 1},
			{"decay", "Sustain", 0, 1, 0.75f, P_PCT, "String", nullptr, 1},
			{"excite", "Pick Width", 0.05f, 2, 0.5f, P_PCT, "Pick", nullptr, 1},
			{"noise_tone", "Pick Tone", 0, 1, 0.6f, P_PCT, "Pick", nullptr, 1},
			{"body", "Body", 0, 1, 0.35f, P_PCT, "Body", nullptr, 1},
			{"body_freq", "Body Freq", 60, 2000, 220, P_HZ, "Body", nullptr, 0.4f},
			{"spread", "Spread", 0, 1, 0.35f, P_PCT, "Body", nullptr, 1},
			{"voices", "Polyphony", 1, 12, 8, P_SEMI, "Voice", nullptr, 1},
			{"vel", "Velocity", 0, 1, 0.8f, P_PCT, "Voice", nullptr, 1},
			{"level", "Level", -60, 12, -3, P_DB, "Output", nullptr, 1},
			{"pan", "Pan", -1, 1, 0, P_FLOAT, "Output", nullptr, 1},
		}, make_pluck });
}

} // namespace cd
