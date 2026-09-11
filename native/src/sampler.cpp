// Cadmium — Sampler (audio files) and SoundFont (SF2 player).
#include "plugin.h"
#include "sf2.h"
#include "wav.h"

#include <memory>

namespace cd {

// ===========================================================================
// Sampler
// ===========================================================================
enum {
	SM_ROOT, SM_TUNE, SM_FINE, SM_START, SM_END, SM_LOOP_MODE, SM_LOOP_START, SM_LOOP_END,
	SM_REVERSE, SM_ATTACK, SM_DECAY, SM_SUSTAIN, SM_RELEASE,
	SM_FLT_TYPE, SM_FLT_CUT, SM_FLT_RES, SM_VEL, SM_VOICES, SM_ONESHOT,
	SM_LEVEL, SM_PAN,
	// The same section FL puts on a sampler: what to do to the file once,
	// before any of the above touches it.
	SM_STR_MODE, SM_STR_MUL, SM_STR_PITCH,
	SM_NORMALIZE, SM_REMOVE_DC, SM_POLARITY, SM_SWAP, SM_FADE_ST,
	SM_TRIM, SM_FADE_IN, SM_FADE_OUT,
	SM_COUNT
};

struct SampVoice {
	VoiceHead h;
	double pos = 0.0;
	double inc = 1.0;
	ADSR env;
	SVF filt;
	bool releasing = false;
};

class Sampler : public Plug {
public:
	static const int MAXV = 24;
	SampVoice v[MAXV];
	/// What was read off disk, and the copy that is played. Everything in the
	/// stretching and precomputed sections is applied to the first to make the
	/// second, once, rather than on every note.
	std::shared_ptr<AudioFile> source;
	std::shared_ptr<AudioFile> file;
	SampleSettings baked_with;
	bool bake_dirty = true;
	std::string sample_path;
	uint64_t counter = 0;

	/// What the stretching and precomputed sections currently say.
	SampleSettings wanted() const {
		SampleSettings s;
		s.mode = pi(SM_STR_MODE);
		s.stretch = p(SM_STR_MUL);
		s.pitch = p(SM_STR_PITCH);
		s.normalize = pb(SM_NORMALIZE);
		s.remove_dc = pb(SM_REMOVE_DC);
		s.polarity = pb(SM_POLARITY);
		s.swap_stereo = pb(SM_SWAP);
		s.fade_stereo = pb(SM_FADE_ST);
		s.trim_db = p(SM_TRIM);
		s.fade_in = p(SM_FADE_IN);
		s.fade_out = p(SM_FADE_OUT);
		return s;
	}

	/// Rebuilt when any of them has moved. Called from note_on, which is the
	/// one place a change can take effect without cutting a note in half.
	void rebake() {
		if (!source) return;
		const SampleSettings s = wanted();
		if (!bake_dirty && s == baked_with && file) return;
		auto out = std::make_shared<AudioFile>();
		bake_sample(*source, s, *out);
		file = out;
		baked_with = s;
		bake_dirty = false;
	}

	void prepare() override {
		for (int i = 0; i < MAXV; i++) { v[i].env.prepare(sr); v[i].h.active = false; }
	}
	bool set_string(const std::string &key, const std::string &value) override {
		if (key != "sample") return false;
		if (value.empty()) { file.reset(); source.reset(); sample_path.clear(); return true; }
		auto f = std::make_shared<AudioFile>();
		if (!wav_load(value, *f)) return false;
		source = f;
		file = f;
		sample_path = value;
		bake_dirty = true;
		rebake();
		return true;
	}
	std::string get_string(const std::string &key) const override {
		if (key == "sample") return sample_path;
		if (key == "info" && file) {
			char b[128];
			snprintf(b, sizeof(b), "%d|%d|%d", file->frames(), file->rate, file->channels);
			return b;
		}
		return std::string();
	}
	// what 0: waveform peaks, |out| pairs of min/max over the whole file.
	int aux(int what, float *o, int max) override {
		if (what != 0 || !file || max < 4) return 0;
		const int pairs = max / 2;
		const int frames = file->frames();
		if (frames <= 0) return 0;
		// The overview built when the file was read, boiled down to however
		// many buckets the panel asked for. Walking the samples again would be
		// tens of millions of them for anything longer than a phrase.
		const int have = (int)(file->peaks.size() / 2);
		if (have >= pairs) {
			for (int i = 0; i < pairs; i++) {
				const int a = (int)((int64_t)have * i / pairs);
				const int b = std::max(a + 1, (int)((int64_t)have * (i + 1) / pairs));
				float lo = 0.0f, hi = 0.0f;
				for (int s = a; s < b && s < have; s++) {
					lo = std::min(lo, file->peaks[(size_t)s * 2]);
					hi = std::max(hi, file->peaks[(size_t)s * 2 + 1]);
				}
				o[i * 2] = lo;
				o[i * 2 + 1] = hi;
			}
			return pairs * 2;
		}
		for (int i = 0; i < pairs; i++) {
			const int a = (int)((int64_t)frames * i / pairs);
			const int b = (int)((int64_t)frames * (i + 1) / pairs);
			float lo = 0.0f, hi = 0.0f;
			for (int s = a; s < b && s < frames; s++) {
				const float x = file->data[(size_t)s * file->channels];
				lo = std::min(lo, x);
				hi = std::max(hi, x);
			}
			o[i * 2] = lo;
			o[i * 2 + 1] = hi;
		}
		return pairs * 2;
	}

	void note_on(int key, float vel, int id) override {
		if (!file || !file->valid()) return;
		const int nv = std::max(1, std::min(MAXV, pi(SM_VOICES)));
		const int i = alloc_voice(v, nv, counter);
		SampVoice &vv = v[i];
		vv.h.active = vv.h.held = true;
		vv.h.key = key; vv.h.id = id; vv.h.vel = vel; vv.h.age = counter++;
		take_expr(vv.h);
		const float semis = vv.h.pitch() - p(SM_ROOT) + p(SM_TUNE) + p(SM_FINE) * 0.01f;
		vv.inc = std::pow(2.0, semis / 12.0) * (double)file->rate / sr;
		const int frames = file->frames();
		vv.pos = pb(SM_REVERSE) ? (double)(frames - 1) * p(SM_END) : (double)frames * p(SM_START);
		vv.env.prepare(sr);
		vv.env.set(p(SM_ATTACK), p(SM_DECAY), p(SM_SUSTAIN), p(SM_RELEASE));
		vv.env.gate_on();
		vv.filt.reset();
		vv.releasing = false;
	}
	void note_off(int key, int id) override {
		if (pb(SM_ONESHOT)) return;   // one-shots play to the end
		for (int i = 0; i < MAXV; i++) {
			if (v[i].h.active && v[i].h.held && v[i].h.key == key && (id < 0 || v[i].h.id == id)) {
				v[i].h.held = false;
				v[i].env.gate_off();
				v[i].releasing = true;
				return;
			}
		}
	}
	void all_notes_off() override {
		for (int i = 0; i < MAXV; i++) if (v[i].h.active) { v[i].h.held = false; v[i].env.gate_off(); }
	}
	int active_voices() const override {
		int n = 0; for (int i = 0; i < MAXV; i++) if (v[i].h.active) n++; return n;
	}

	void process(float *L, float *R, int n) override {
		std::memset(L, 0, sizeof(float) * (size_t)n);
		std::memset(R, 0, sizeof(float) * (size_t)n);
		if (!file || !file->valid()) return;
		const AudioFile &f = *file;
		const int frames = f.frames();
		const int ch = f.channels;
		const int loop = pi(SM_LOOP_MODE);
		const double ls = (double)frames * std::min(p(SM_LOOP_START), p(SM_LOOP_END));
		const double le = (double)frames * std::max(p(SM_LOOP_START) + 0.001f, p(SM_LOOP_END));
		const double s0 = (double)frames * p(SM_START);
		const double s1 = (double)frames * p(SM_END);
		const float out = db_to_gain(p(SM_LEVEL));
		const float pan = p(SM_PAN);
		const bool rev = pb(SM_REVERSE);
		const int ftype = pi(SM_FLT_TYPE);

		for (int i = 0; i < MAXV; i++) {
			SampVoice &vv = v[i];
			if (!vv.h.active) continue;
			vv.env.set(p(SM_ATTACK), p(SM_DECAY), p(SM_SUSTAIN), p(SM_RELEASE));
			vv.filt.set(sr, clampf(p(SM_FLT_CUT), 20.0f, (float)sr * 0.47f), 0.7f + p(SM_FLT_RES) * 14.0f);
			const float g = out * lerp(1.0f, vv.h.vel, p(SM_VEL));
			for (int s = 0; s < n; s++) {
				const float e = vv.env.next();
				if (!vv.env.active()) { vv.h.active = false; break; }
				double pos = vv.pos;
				if (pos < 0.0 || pos >= (double)(frames - 1)) { vv.h.active = false; break; }
				if (!rev && pos >= s1) {
					if (loop == 1 || (loop == 2 && vv.h.held)) pos = ls;
					else { vv.h.active = false; break; }
				}
				const int i0 = (int)pos;
				const int i1 = std::min(frames - 1, i0 + 1);
				const float fr = (float)(pos - (double)i0);
				float l = lerp(f.data[(size_t)i0 * ch], f.data[(size_t)i1 * ch], fr);
				float r = ch > 1 ? lerp(f.data[(size_t)i0 * ch + 1], f.data[(size_t)i1 * ch + 1], fr) : l;
				if (ftype > 0) {
					vv.filt.process((l + r) * 0.5f);
					const float fo = ftype == 1 ? vv.filt.lp : (ftype == 2 ? vv.filt.bp : vv.filt.hp);
					const float side = (l - r) * 0.5f;
					l = fo + side; r = fo - side;
				}
				L[s] += l * e * g * vv.h.gl;
				R[s] += r * e * g * vv.h.gr;
				vv.pos += rev ? -vv.inc : vv.inc;
				if (loop >= 1 && !rev && vv.pos >= le) vv.pos -= (le - ls);
				if (rev && vv.pos <= s0) { if (loop >= 1) vv.pos = s1; else { vv.h.active = false; break; } }
			}
		}
		const float pl = std::cos((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
		const float pr = std::sin((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
		for (int s = 0; s < n; s++) { L[s] *= pl; R[s] *= pr; }
	}
};
static Plug *make_sampler() { return new Sampler(); }

// ===========================================================================
// SoundFont player
// ===========================================================================
enum {
	SF_PRESET, SF_LEVEL, SF_PAN, SF_TUNE, SF_FINE, SF_CUT_OFS, SF_RES_OFS,
	SF_ATTACK_OFS, SF_RELEASE_OFS, SF_VEL_CURVE, SF_VOICES, SF_MONO, SF_COUNT
};

// SoundFont's DAHDSR: attack is linear in amplitude, decay and release run in
// decibels, which is what makes a sampled piano tail sound right.
struct SfEnv {
	enum St { DELAY, ATTACK, HOLD, DECAY, SUSTAIN, RELEASE, DONE } st = DELAY;
	float value = 0.0f;
	int delay_n = 0, attack_n = 0, hold_n = 0;
	float decay_per = 1.0f, release_per = 1.0f, sustain = 1.0f;
	int counter = 0;

	void configure(double sr, float delay_s, float attack_s, float hold_s, float decay_s,
			float sustain_lin, float release_s) {
		delay_n = (int)(delay_s * sr);
		attack_n = std::max(1, (int)(attack_s * sr));
		hold_n = (int)(hold_s * sr);
		sustain = clampf(sustain_lin, 0.0f, 1.0f);
		// -100 dB over the stage time, the spec's reference slope.
		decay_per = std::pow(10.0f, -100.0f / 20.0f / std::max(1.0f, (float)(decay_s * sr)));
		release_per = std::pow(10.0f, -100.0f / 20.0f / std::max(1.0f, (float)(release_s * sr)));
		st = DELAY;
		counter = 0;
		value = 0.0f;
	}
	inline float next() {
		switch (st) {
			case DELAY: if (counter++ >= delay_n) { st = ATTACK; counter = 0; } return 0.0f;
			case ATTACK:
				value = (float)counter / (float)attack_n;
				if (counter++ >= attack_n) { value = 1.0f; st = HOLD; counter = 0; }
				break;
			case HOLD: value = 1.0f; if (counter++ >= hold_n) { st = DECAY; counter = 0; } break;
			case DECAY:
				value *= decay_per;
				if (value <= sustain) { value = sustain; st = SUSTAIN; }
				if (value < 0.00002f) st = DONE;
				break;
			case SUSTAIN: value = sustain; break;
			case RELEASE:
				value *= release_per;
				if (value < 0.00002f) { value = 0.0f; st = DONE; }
				break;
			default: value = 0.0f; break;
		}
		return value;
	}
	void release() { if (st != DONE) st = RELEASE; }
	bool done() const { return st == DONE; }
};

struct SfVoice {
	VoiceHead h;
	int sample = -1;
	double pos = 0.0, inc = 1.0;
	uint32_t start = 0, end = 0, loop_start = 0, loop_end = 0;
	int loop_mode = 0;
	float gain = 1.0f, pan = 0.0f;
	SfEnv amp, mod;
	SVF filt;
	float fc = 20000.0f, q = 0.7f;
	float mod_env_fc = 0.0f, mod_env_pitch = 0.0f;
	LFO mod_lfo, vib_lfo;
	float mlfo_pitch = 0, mlfo_fc = 0, mlfo_vol = 0, vlfo_pitch = 0;
	int exclusive = 0;
	bool use_filter = false;
};

class SoundFont : public Plug {
public:
	static const int MAXV = 64;
	SfVoice v[MAXV];
	std::shared_ptr<Sf2File> sf;
	std::string sf_path;
	int preset = 0;
	uint64_t counter = 0;
	float bend = 0.0f;
	std::vector<Sf2Zone> zbuf;

	void prepare() override {
		for (int i = 0; i < MAXV; i++) v[i].h.active = false;
		zbuf.reserve(16);
	}
	bool set_string(const std::string &key, const std::string &value) override {
		if (key == "file") {
			all_notes_off();
			for (int i = 0; i < MAXV; i++) v[i].h.active = false;
			if (value.empty()) { sf.reset(); sf_path.clear(); return true; }
			auto f = sf2_get(value);
			if (!f) return false;
			sf = f;
			sf_path = value;
			preset = 0;
			return true;
		}
		if (key == "preset") {
			preset = atoi(value.c_str());
			return true;
		}
		return false;
	}
	std::string get_string(const std::string &key) const override {
		if (key == "file") return sf_path;
		if (key == "name") return sf ? sf->name : std::string();
		if (key == "preset") { char b[16]; snprintf(b, sizeof(b), "%d", preset); return b; }
		if (key == "presets" && sf) {
			// "index:bank:program:name" per line, for the UI's preset list.
			std::string s;
			for (int i = 0; i < sf->preset_count(); i++) {
				const Sf2Preset &p = sf->presets[(size_t)i];
				char b[128];
				snprintf(b, sizeof(b), "%d:%d:%d:%s\n", i, p.bank, p.program, p.name.c_str());
				s += b;
			}
			return s;
		}
		return std::string();
	}

	void note_on(int key, float vel, int id) override {
		if (!sf) return;
		const int midi_vel = std::max(1, std::min(127, (int)std::lround(vel * 127.0f)));
		sf->zones_for(preset, key, midi_vel, zbuf);
		for (const Sf2Zone &z : zbuf) {
			const int i = alloc_voice(v, std::min(MAXV, std::max(2, pi(SF_VOICES))), counter);
			SfVoice &vv = v[i];
			const Sf2Sample &smp = sf->samples[(size_t)z.sample];
			vv.h.active = vv.h.held = true;
			vv.h.key = key; vv.h.id = id; vv.h.vel = vel; vv.h.age = counter++;
			// Every zone of the note gets the same expression; taking it once
			// per zone would clear it before the second zone saw it.
			vv.h.fine = next_fine;
			vv.h.set_pan(next_pan);
			vv.sample = z.sample;
			vv.start = smp.start + (uint32_t)(z.gen[GEN_START_OFS] + z.gen[GEN_START_COARSE] * 32768);
			vv.end = smp.end + (uint32_t)(z.gen[GEN_END_OFS] + z.gen[GEN_END_COARSE] * 32768);
			vv.loop_start = smp.loop_start + (uint32_t)(z.gen[GEN_STARTLOOP_OFS] + z.gen[GEN_STARTLOOP_COARSE] * 32768);
			vv.loop_end = smp.loop_end + (uint32_t)(z.gen[GEN_ENDLOOP_OFS] + z.gen[GEN_ENDLOOP_COARSE] * 32768);
			if (vv.end > sf->pcm.size()) vv.end = (uint32_t)sf->pcm.size();
			if (vv.loop_end > vv.end) vv.loop_end = vv.end;
			if (vv.loop_start >= vv.loop_end) vv.loop_mode = 0; else vv.loop_mode = z.gen[GEN_SAMPLE_MODES] & 3;
			vv.pos = (double)vv.start;
			vv.exclusive = z.gen[GEN_EXCLUSIVE];

			const int root = z.gen[GEN_ROOT_KEY] >= 0 ? z.gen[GEN_ROOT_KEY] : (int)smp.root;
			const float scale = (float)z.gen[GEN_SCALE_TUNING] / 100.0f;
			const float cents = (vv.h.pitch() - (float)root) * 100.0f * scale
					+ (float)z.gen[GEN_COARSE_TUNE] * 100.0f + (float)z.gen[GEN_FINE_TUNE]
					+ (float)smp.correction
					+ p(SF_TUNE) * 100.0f + p(SF_FINE);
			vv.inc = std::pow(2.0, cents / 1200.0) * (double)smp.rate / sr;

			const float atten_db = (float)z.gen[GEN_ATTENUATION] / 10.0f;   // centibels
			// SoundFont velocity response is roughly -20*log10(v^2).
			const float vcurve = p(SF_VEL_CURVE);
			const float vgain = lerp(1.0f, (float)midi_vel * (float)midi_vel / (127.0f * 127.0f), vcurve);
			vv.gain = db_to_gain(-atten_db) * vgain;
			vv.pan = clampf((float)z.gen[GEN_PAN] / 500.0f, -1.0f, 1.0f);

			vv.amp.configure(sr, sf2_timecents(z.gen[GEN_DELAY_VOLENV]),
					sf2_timecents((int16_t)(z.gen[GEN_ATTACK_VOLENV] + (int)(p(SF_ATTACK_OFS) * 1200.0f))),
					sf2_timecents(z.gen[GEN_HOLD_VOLENV]),
					sf2_timecents(z.gen[GEN_DECAY_VOLENV]),
					db_to_gain(-(float)z.gen[GEN_SUSTAIN_VOLENV] / 10.0f),
					sf2_timecents((int16_t)(z.gen[GEN_RELEASE_VOLENV] + (int)(p(SF_RELEASE_OFS) * 1200.0f))));
			vv.mod.configure(sr, sf2_timecents(z.gen[GEN_DELAY_MODENV]), sf2_timecents(z.gen[GEN_ATTACK_MODENV]),
					sf2_timecents(z.gen[GEN_HOLD_MODENV]), sf2_timecents(z.gen[GEN_DECAY_MODENV]),
					1.0f - clampf((float)z.gen[GEN_SUSTAIN_MODENV] / 1000.0f, 0.0f, 1.0f),
					sf2_timecents(z.gen[GEN_RELEASE_MODENV]));

			vv.fc = sf2_abs_cents_hz((float)z.gen[GEN_FILTER_FC] + p(SF_CUT_OFS) * 1200.0f);
			vv.q = std::pow(10.0f, ((float)z.gen[GEN_FILTER_Q] / 10.0f + p(SF_RES_OFS) * 12.0f) / 20.0f);
			vv.use_filter = vv.fc < 19000.0f || z.gen[GEN_FILTER_Q] > 0 || p(SF_CUT_OFS) != 0.0f;
			vv.filt.reset();
			vv.mod_env_fc = (float)z.gen[GEN_MODENV_FC];
			vv.mod_env_pitch = (float)z.gen[GEN_MODENV_PITCH];
			vv.mod_lfo.set(sr, sf2_abs_cents_hz((float)z.gen[GEN_FREQ_MODLFO]));
			vv.vib_lfo.set(sr, sf2_abs_cents_hz((float)z.gen[GEN_FREQ_VIBLFO]));
			vv.mod_lfo.reset(); vv.vib_lfo.reset();
			vv.mlfo_pitch = (float)z.gen[GEN_MODLFO_PITCH];
			vv.mlfo_fc = (float)z.gen[GEN_MODLFO_FC];
			vv.mlfo_vol = (float)z.gen[GEN_MODLFO_VOL];
			vv.vlfo_pitch = (float)z.gen[GEN_VIBLFO_PITCH];

			// Exclusive class: a closing hi-hat cuts the open one.
			if (vv.exclusive) {
				for (int k = 0; k < MAXV; k++) {
					if (k != i && v[k].h.active && v[k].exclusive == vv.exclusive) v[k].amp.release();
				}
			}
		}
	}
	void note_off(int key, int id) override {
		for (int i = 0; i < MAXV; i++) {
			if (v[i].h.active && v[i].h.held && v[i].h.key == key && (id < 0 || v[i].h.id == id)) {
				v[i].h.held = false;
				v[i].amp.release();
				v[i].mod.release();
			}
		}
	}
	void all_notes_off() override {
		for (int i = 0; i < MAXV; i++) if (v[i].h.active) { v[i].h.held = false; v[i].amp.release(); }
	}
	void pitch_bend(float s) override { bend = s; }
	int active_voices() const override {
		int n = 0; for (int i = 0; i < MAXV; i++) if (v[i].h.active) n++; return n;
	}
	float tail() const override { return 6.0f; }

	void process(float *L, float *R, int n) override {
		std::memset(L, 0, sizeof(float) * (size_t)n);
		std::memset(R, 0, sizeof(float) * (size_t)n);
		if (!sf) return;
		const int16_t *pcm = sf->pcm.data();
		const size_t pcm_n = sf->pcm.size();
		const float out = db_to_gain(p(SF_LEVEL));
		const float gpan = p(SF_PAN);
		const double bendr = std::pow(2.0, bend * 2.0 / 12.0);

		for (int i = 0; i < MAXV; i++) {
			SfVoice &vv = v[i];
			if (!vv.h.active) continue;
			for (int s = 0; s < n; s++) {
				const float e = vv.amp.next();
				const float me = vv.mod.next();
				if (vv.amp.done()) { vv.h.active = false; break; }
				const float ml = vv.mod_lfo.next();
				const float vl = vv.vib_lfo.next();

				size_t i0 = (size_t)vv.pos;
				if (i0 + 1 >= pcm_n || i0 >= vv.end) { vv.h.active = false; break; }
				const float fr = (float)(vv.pos - (double)i0);
				const float a = (float)pcm[i0] * (1.0f / 32768.0f);
				const float b = (float)pcm[i0 + 1] * (1.0f / 32768.0f);
				float x = a + (b - a) * fr;

				if (vv.use_filter) {
					const float fc = clampf(vv.fc * std::pow(2.0f, (me * vv.mod_env_fc + ml * vv.mlfo_fc) / 1200.0f),
							20.0f, (float)sr * 0.47f);
					vv.filt.set(sr, fc, std::max(0.5f, vv.q));
					vv.filt.process(x);
					x = vv.filt.lp;
				}
				const float vol = e * vv.gain * db_to_gain(ml * vv.mlfo_vol / 10.0f);
				const float pan = clampf(vv.pan + gpan, -1.0f, 1.0f);
				L[s] += x * vol * std::cos((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * vv.h.gl;
				R[s] += x * vol * std::sin((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * vv.h.gr;

				const double pitch_mod = std::pow(2.0, (me * vv.mod_env_pitch + ml * vv.mlfo_pitch
						+ vl * vv.vlfo_pitch) / 1200.0);
				vv.pos += vv.inc * pitch_mod * bendr;
				if (vv.loop_mode == 1 || (vv.loop_mode == 3 && vv.h.held)) {
					if (vv.pos >= (double)vv.loop_end) vv.pos -= (double)(vv.loop_end - vv.loop_start);
				}
			}
		}
		const float gl = 1.41f * out, gr = 1.41f * out;
		for (int s = 0; s < n; s++) { L[s] *= gl; R[s] *= gr; }
	}
};
static Plug *make_soundfont() { return new SoundFont(); }

// ---------------------------------------------------------------------------
void register_samplers(std::vector<PlugDesc> &out) {
	out.push_back({"cd.sampler", "Sampler", "Cadmium", "Sampler", true, UI_SAMPLER, {
		{"root", "Root Key", 0, 127, 60, P_SEMI, "Pitch", nullptr, 1},
		{"tune", "Transpose", -48, 48, 0, P_SEMI, "Pitch", nullptr, 1},
		{"fine", "Fine", -100, 100, 0, P_SEMI, "Pitch", nullptr, 1},
		{"start", "Start", 0, 1, 0, P_PCT, "Region", nullptr, 1},
		{"end", "End", 0, 1, 1, P_PCT, "Region", nullptr, 1},
		{"loop_mode", "Loop", 0, 2, 0, P_CHOICE, "Region", "Off|Forward|Sustain", 1},
		{"loop_start", "Loop Start", 0, 1, 0, P_PCT, "Region", nullptr, 1},
		{"loop_end", "Loop End", 0, 1, 1, P_PCT, "Region", nullptr, 1},
		{"reverse", "Reverse", 0, 1, 0, P_BOOL, "Region", nullptr, 1},
		{"attack", "Attack", 0.0005f, 8, 0.001f, P_SEC, "Envelope", nullptr, 0.3f},
		{"decay", "Decay", 0.001f, 8, 1.0f, P_SEC, "Envelope", nullptr, 0.3f},
		{"sustain", "Sustain", 0, 1, 1, P_PCT, "Envelope", nullptr, 1},
		{"release", "Release", 0.002f, 12, 0.06f, P_SEC, "Envelope", nullptr, 0.3f},
		{"flt_type", "Filter", 0, 3, 0, P_CHOICE, "Filter", "Off|Low|Band|High", 1},
		{"flt_cut", "Cutoff", 20, 20000, 20000, P_HZ, "Filter", nullptr, 0.3f},
		{"flt_res", "Reso", 0, 1, 0, P_PCT, "Filter", nullptr, 1},
		{"vel", "Velocity", 0, 1, 0.8f, P_PCT, "Voice", nullptr, 1},
		{"voices", "Polyphony", 1, 24, 12, P_SEMI, "Voice", nullptr, 1},
		{"oneshot", "One Shot", 0, 1, 0, P_BOOL, "Voice", nullptr, 1},
		{"level", "Level", -60, 12, -3, P_DB, "Output", nullptr, 1},
		{"pan", "Pan", -1, 1, 0, P_FLOAT, "Output", nullptr, 1},
		{"str_mode", "Stretch", 0, 3, 3, P_CHOICE, "Time stretching",
			"Resample|Stretch|Pitch|Off", 1},
		{"str_mul", "Mul", 0.25f, 4, 1, P_FLOAT, "Time stretching", nullptr, 1},
		{"str_pitch", "Pitch", -24, 24, 0, P_SEMI, "Time stretching", nullptr, 1},
		{"normalize", "Normalise", 0, 1, 0, P_BOOL, "Precomputed", nullptr, 1},
		{"remove_dc", "Remove DC", 0, 1, 0, P_BOOL, "Precomputed", nullptr, 1},
		{"polarity", "Invert", 0, 1, 0, P_BOOL, "Precomputed", nullptr, 1},
		{"swap_stereo", "Swap Stereo", 0, 1, 0, P_BOOL, "Precomputed", nullptr, 1},
		{"fade_stereo", "Fade Stereo", 0, 1, 0, P_BOOL, "Precomputed", nullptr, 1},
		{"trim", "Trim", -100, -20, -100, P_DB, "Precomputed", nullptr, 1},
		{"smp_in", "In", 0, 2, 0, P_SEC, "Precomputed", nullptr, 0.4f},
		{"smp_out", "Out", 0, 2, 0, P_SEC, "Precomputed", nullptr, 0.4f},
	}, make_sampler});

	out.push_back({"cd.soundfont", "SoundFont", "Cadmium", "Sampler", true, UI_SOUNDFONT, {
		{"preset", "Preset", 0, 4095, 0, P_SEMI, "Bank", nullptr, 1},
		{"level", "Level", -60, 12, -3, P_DB, "Output", nullptr, 1},
		{"pan", "Pan", -1, 1, 0, P_FLOAT, "Output", nullptr, 1},
		{"tune", "Transpose", -24, 24, 0, P_SEMI, "Pitch", nullptr, 1},
		{"fine", "Fine", -100, 100, 0, P_SEMI, "Pitch", nullptr, 1},
		{"cut_ofs", "Brightness", -4, 4, 0, P_PCT, "Tone", nullptr, 1},
		{"res_ofs", "Resonance", 0, 2, 0, P_PCT, "Tone", nullptr, 1},
		{"attack_ofs", "Attack", -2, 2, 0, P_PCT, "Envelope", nullptr, 1},
		{"release_ofs", "Release", -2, 2, 0, P_PCT, "Envelope", nullptr, 1},
		{"vel_curve", "Vel Curve", 0, 1, 1, P_PCT, "Voice", nullptr, 1},
		{"voices", "Polyphony", 4, 64, 48, P_SEMI, "Voice", nullptr, 1},
		{"mono", "Mono", 0, 1, 0, P_BOOL, "Voice", nullptr, 1},
	}, make_soundfont});
}

} // namespace cd
