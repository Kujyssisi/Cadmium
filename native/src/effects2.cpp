// Cadmium — stock effects, part 2: modulation, delay, reverb, spectral.
#include "plugin.h"
#include "wav.h"

namespace cd {

// ===========================================================================
// Chorus
// ===========================================================================
enum { CH_VOICES, CH_RATE, CH_DEPTH, CH_DELAY, CH_SPREAD, CH_FEEDBACK, CH_MIX, CH_COUNT };

class Chorus : public Plug {
public:
	Delay dl, dr;
	LFO lfo[4];
	float fbl = 0.0f, fbr = 0.0f;
	void prepare() override {
		dl.prepare((int)(sr * 0.08) + 8);
		dr.prepare((int)(sr * 0.08) + 8);
		for (int i = 0; i < 4; i++) lfo[i].reset((float)i * 0.25f);
	}
	void process(float *L, float *R, int n) override {
		const int voices = std::max(1, std::min(4, pi(CH_VOICES)));
		const float base = p(CH_DELAY) * 0.001f * (float)sr;
		const float depth = p(CH_DEPTH) * 0.001f * (float)sr;
		const float mix = p(CH_MIX), fb = p(CH_FEEDBACK) * 0.7f;
		const float spread = p(CH_SPREAD);
		for (int i = 0; i < 4; i++) lfo[i].set(sr, p(CH_RATE) * (1.0f + (float)i * 0.07f));
		for (int s = 0; s < n; s++) {
			const float xl = L[s], xr = R[s];
			dl.write(xl + fbl * fb);
			dr.write(xr + fbr * fb);
			float wl = 0.0f, wr = 0.0f;
			for (int i = 0; i < voices; i++) {
				const float m = lfo[i].next();
				const float d = base + depth * (m * 0.5f + 0.5f);
				const float a = dl.read(d);
				const float b = dr.read(d * (1.0f + spread * 0.15f));
				const float w = (float)i / (float)voices;
				wl += a * (1.0f - w * spread) + b * (w * spread);
				wr += b * (1.0f - w * spread) + a * (w * spread);
			}
			wl /= (float)voices; wr /= (float)voices;
			fbl = wl; fbr = wr;
			L[s] = lerp(xl, wl, mix);
			R[s] = lerp(xr, wr, mix);
		}
	}
};
static Plug *make_chorus() { return new Chorus(); }

// ===========================================================================
// Flanger
// ===========================================================================
enum { FL_RATE, FL_DEPTH, FL_MANUAL, FL_FEEDBACK, FL_INVERT, FL_MIX, FL_COUNT };

class Flanger : public Plug {
public:
	Delay dl, dr;
	LFO lfo;
	float fbl = 0.0f, fbr = 0.0f;
	void prepare() override {
		dl.prepare((int)(sr * 0.03) + 8);
		dr.prepare((int)(sr * 0.03) + 8);
	}
	void process(float *L, float *R, int n) override {
		lfo.set(sr, p(FL_RATE));
		const float manual = p(FL_MANUAL) * 0.001f * (float)sr;
		const float depth = p(FL_DEPTH) * 0.001f * (float)sr;
		const float fb = clampf(p(FL_FEEDBACK), -0.98f, 0.98f);
		const float mix = p(FL_MIX);
		const float sign = pb(FL_INVERT) ? -1.0f : 1.0f;
		for (int s = 0; s < n; s++) {
			const float m = lfo.next();
			const float d1 = std::max(1.0f, manual + depth * (m * 0.5f + 0.5f));
			const float d2 = std::max(1.0f, manual + depth * (-m * 0.5f + 0.5f));
			const float xl = L[s], xr = R[s];
			dl.write(xl + fbl * fb);
			dr.write(xr + fbr * fb);
			const float wl = dl.read(d1), wr = dr.read(d2);
			fbl = wl; fbr = wr;
			L[s] = lerp(xl, xl + wl * sign, mix);
			R[s] = lerp(xr, xr + wr * sign, mix);
		}
	}
};
static Plug *make_flanger() { return new Flanger(); }

// ===========================================================================
// Phaser
// ===========================================================================
enum { PH_STAGES, PH_RATE, PH_DEPTH, PH_CENTER, PH_FEEDBACK, PH_SPREAD, PH_MIX, PH_COUNT };

struct AllpassOne {
	float a = 0.0f, z = 0.0f;
	inline void set(double sr, float hz) {
		const float t = std::tan((float)PI * clampf(hz, 20.0f, (float)sr * 0.45f) / (float)sr);
		a = (t - 1.0f) / (t + 1.0f);
	}
	inline float operator()(float x) {
		const float y = a * x + z;
		z = flush(x - a * y);
		return y;
	}
};

class Phaser : public Plug {
public:
	AllpassOne apl[12], apr[12];
	LFO lfo;
	float fbl = 0.0f, fbr = 0.0f;
	void process(float *L, float *R, int n) override {
		const int stages = std::max(2, std::min(12, pi(PH_STAGES) * 2));
		lfo.set(sr, p(PH_RATE));
		const float fb = clampf(p(PH_FEEDBACK), -0.95f, 0.95f);
		const float mix = p(PH_MIX);
		const float spread = p(PH_SPREAD);
		for (int s = 0; s < n; s++) {
			const float m = lfo.next();
			const float f = p(PH_CENTER) * std::pow(2.0f, m * p(PH_DEPTH) * 3.0f);
			const float fr = p(PH_CENTER) * std::pow(2.0f, (m * (1.0f - spread) - spread) * p(PH_DEPTH) * 3.0f);
			float l = L[s] + fbl * fb, r = R[s] + fbr * fb;
			for (int i = 0; i < stages; i++) {
				apl[i].set(sr, f * (1.0f + (float)i * 0.12f));
				apr[i].set(sr, fr * (1.0f + (float)i * 0.12f));
				l = apl[i](l);
				r = apr[i](r);
			}
			fbl = l; fbr = r;
			L[s] = lerp(L[s], (L[s] + l) * 0.5f, mix);
			R[s] = lerp(R[s], (R[s] + r) * 0.5f, mix);
		}
	}
};
static Plug *make_phaser() { return new Phaser(); }

// ===========================================================================
// Delay
// ===========================================================================
enum {
	DE_SYNC, DE_TIME, DE_DIV, DE_OFFSET, DE_FEEDBACK, DE_PINGPONG,
	DE_LO_CUT, DE_HI_CUT, DE_MOD_RATE, DE_MOD_DEPTH, DE_DUCK, DE_MIX, DE_COUNT
};

class DelayFx : public Plug {
public:
	Delay dl, dr;
	Biquad hpl, hpr, lpl, lpr;
	LFO lfo;
	float duck_env = 0.0f;
	Smoothed tl, tr;
	void prepare() override {
		dl.prepare((int)(sr * 8.0) + 8);
		dr.prepare((int)(sr * 8.0) + 8);
		tl.prepare(sr, 60.0f); tr.prepare(sr, 60.0f);
		tl.snap(0.25f * (float)sr); tr.snap(0.25f * (float)sr);
	}
	void process(float *L, float *R, int n) override {
		float t = pb(DE_SYNC) ? (float)(sync_beats(pi(DE_DIV)) * 60.0 / std::max(20.0, bpm)) : p(DE_TIME);
		t = clampf(t, 0.001f, 7.9f);
		const float base = t * (float)sr;
		tl.set(base);
		tr.set(base * (1.0f + p(DE_OFFSET)));
		const float fb = clampf(p(DE_FEEDBACK), 0.0f, 1.2f);
		const float mix = p(DE_MIX);
		const bool ping = pb(DE_PINGPONG);
		hpl.high_pass(sr, p(DE_LO_CUT), 0.707f);
		lpl.low_pass(sr, p(DE_HI_CUT), 0.707f);
		hpr.b0 = hpl.b0; hpr.b1 = hpl.b1; hpr.b2 = hpl.b2; hpr.a1 = hpl.a1; hpr.a2 = hpl.a2;
		lpr.b0 = lpl.b0; lpr.b1 = lpl.b1; lpr.b2 = lpl.b2; lpr.a1 = lpl.a1; lpr.a2 = lpl.a2;
		lfo.set(sr, p(DE_MOD_RATE));
		const float depth = p(DE_MOD_DEPTH) * 0.001f * (float)sr;
		const float duck_c = 1.0f - std::exp(-1.0f / (float)(sr * 0.05));

		for (int s = 0; s < n; s++) {
			const float xl = L[s], xr = R[s];
			const float m = lfo.next() * depth;
			const float dtl = tl.next() + m, dtr = tr.next() - m;
			float yl = dl.read(dtl), yr = dr.read(dtr);
			yl = lpl(hpl(yl));
			yr = lpr(hpr(yr));
			if (ping) {
				dl.write(xl * 0.5f + yr * fb);
				dr.write(xr * 0.5f + yl * fb);
			} else {
				dl.write(xl + yl * fb);
				dr.write(xr + yr * fb);
			}
			const float in_lvl = std::max(std::fabs(xl), std::fabs(xr));
			duck_env += (in_lvl - duck_env) * duck_c;
			const float duck = 1.0f - clampf(duck_env * p(DE_DUCK) * 3.0f, 0.0f, 0.95f);
			L[s] = xl + yl * mix * duck;
			R[s] = xr + yr * mix * duck;
		}
	}
	float tail() const override { return 6.0f; }
};
static Plug *make_delay() { return new DelayFx(); }

// ===========================================================================
// Reverb — 8-line feedback delay network with a Householder matrix
// ===========================================================================
enum {
	RV_SIZE, RV_DECAY, RV_DAMP, RV_LOW_DAMP, RV_PREDELAY, RV_DIFFUSION,
	RV_MOD, RV_WIDTH, RV_EARLY, RV_MIX, RV_COUNT
};

class Reverb : public Plug {
public:
	static const int LINES = 8;
	Delay line[LINES], pre;
	Allpass diff[4];
	OnePole damp[LINES], ldamp[LINES];
	LFO mod[LINES];
	float base_len[LINES];
	Delay er;

	void prepare() override {
		// Mutually prime-ish lengths avoid the metallic ring of a common divisor.
		static const float ms[LINES] = {29.7f, 37.1f, 41.3f, 47.9f, 53.7f, 61.1f, 67.3f, 73.9f};
		for (int i = 0; i < LINES; i++) {
			base_len[i] = (float)(sr * ms[i] * 0.001);
			line[i].prepare((int)(base_len[i] * 3.0f) + 64);
			mod[i].reset((float)i / LINES);
			mod[i].set(sr, 0.3f + 0.11f * (float)i);
		}
		pre.prepare((int)(sr * 0.5) + 8);
		er.prepare((int)(sr * 0.12) + 8);
		static const int ap[4] = {113, 271, 421, 719};
		for (int i = 0; i < 4; i++) { diff[i].prepare((int)(ap[i] * sr / 44100.0)); diff[i].g = 0.62f; }
	}
	void reset() override {
		for (int i = 0; i < LINES; i++) line[i].clear();
		pre.clear(); er.clear();
		for (int i = 0; i < 4; i++) diff[i].clear();
	}
	void process(float *L, float *R, int n) override {
		const float size = clampf(p(RV_SIZE), 0.15f, 2.5f);
		const float decay = clampf(p(RV_DECAY), 0.0f, 1.0f);
		const float mix = p(RV_MIX);
		const float pd = clampf(p(RV_PREDELAY) * 0.001f * (float)sr, 0.0f, (float)sr * 0.49f);
		const float width = p(RV_WIDTH);
		const float early = p(RV_EARLY);
		const float moddepth = p(RV_MOD) * 0.004f * (float)sr;
		for (int i = 0; i < LINES; i++) {
			damp[i].set(sr, clampf(20000.0f * (1.0f - p(RV_DAMP) * 0.96f), 400.0f, (float)sr * 0.45f));
			ldamp[i].set(sr, clampf(30.0f + p(RV_LOW_DAMP) * 600.0f, 20.0f, 900.0f));
		}
		for (int i = 0; i < 4; i++) diff[i].g = 0.45f + p(RV_DIFFUSION) * 0.4f;
		// Feedback gain from RT60 over the mean line length.
		const float mean = base_len[3] * size / (float)sr;
		const float rt = 0.15f + decay * 11.0f;
		const float g = std::pow(10.0f, -3.0f * mean / rt);

		float s_l[LINES];
		for (int s = 0; s < n; s++) {
			const float xl = L[s], xr = R[s];
			pre.write((xl + xr) * 0.5f);
			float in = pre.read(pd);
			for (int i = 0; i < 4; i++) in = diff[i](in);

			// Early reflections: a short tapped delay ahead of the tank.
			er.write((xl + xr) * 0.5f);
			static const float taps[6] = {0.0043f, 0.0071f, 0.0113f, 0.0171f, 0.0237f, 0.0301f};
			float e = 0.0f;
			for (int i = 0; i < 6; i++) e += er.read(taps[i] * (float)sr * size) * (0.7f - 0.09f * (float)i);
			e *= 0.4f;

			float sum = 0.0f;
			for (int i = 0; i < LINES; i++) {
				const float d = base_len[i] * size + mod[i].next() * moddepth;
				float y = line[i].read(d);
				y = damp[i].lp(y);
				y = y - ldamp[i].lp(y) * 0.5f;
				s_l[i] = y;
				sum += y;
			}
			// Householder: y_i = x_i - 2/N * sum
			const float c = 2.0f / (float)LINES * sum;
			for (int i = 0; i < LINES; i++) {
				const float v = (s_l[i] - c) * g + in * 0.35f;
				line[i].write(v);
			}
			float wl = 0.0f, wr = 0.0f;
			for (int i = 0; i < LINES; i++) {
				if (i & 1) wr += s_l[i]; else wl += s_l[i];
			}
			wl = wl * 0.5f + e * early;
			wr = wr * 0.5f + e * early * 0.86f;
			const float mid = (wl + wr) * 0.5f, side = (wl - wr) * 0.5f * width;
			L[s] = xl + (mid + side) * mix;
			R[s] = xr + (mid - side) * mix;
		}
	}
	float tail() const override { return 12.0f; }
};
static Plug *make_reverb() { return new Reverb(); }

// ===========================================================================
// Space — partitioned convolution reverb
// ===========================================================================
enum { SP_MIX, SP_PREDELAY, SP_GAIN, SP_LOW_CUT, SP_HIGH_CUT, SP_WIDTH, SP_STRETCH, SP_COUNT };

class Space : public Plug {
public:
	static const int N = 512;              // partition size
	static const int FN = N * 2;
	std::vector<float> ir_re[2], ir_im[2]; // partitions, interleaved per block
	int parts = 0;
	std::vector<float> fifo_l, fifo_r, out_l, out_r;
	std::vector<float> hist_re, hist_im;   // input spectrum history (FDL)
	int fifo_n = 0, hist_pos = 0;
	std::string ir_path;
	Delay pre_l, pre_r;
	Biquad hpl, hpr, lpl, lpr;
	bool loaded = false;

	void prepare() override {
		fifo_l.assign(N, 0.0f); fifo_r.assign(N, 0.0f);
		out_l.assign(N, 0.0f); out_r.assign(N, 0.0f);
		pre_l.prepare((int)(sr * 0.3) + 8);
		pre_r.prepare((int)(sr * 0.3) + 8);
		fifo_n = 0;
		if (!loaded) build_default_ir();
	}

	// A synthetic plate so the plugin makes a sound before anyone loads a file.
	void build_default_ir() {
		AudioFile f;
		f.channels = 2;
		f.rate = (int)sr;
		const int len = (int)(sr * 2.2);
		f.data.assign((size_t)len * 2, 0.0f);
		Rng rng;
		for (int i = 0; i < len; i++) {
			const float t = (float)i / (float)sr;
			const float env = std::exp(-t * 3.4f) * (t < 0.004f ? t / 0.004f : 1.0f);
			f.data[(size_t)i * 2] = rng.bi() * env;
			f.data[(size_t)i * 2 + 1] = rng.bi() * env;
		}
		// A few discrete early reflections give it a room rather than a hiss.
		static const float taps[5] = {0.007f, 0.013f, 0.019f, 0.029f, 0.041f};
		for (int k = 0; k < 5; k++) {
			const int idx = (int)(taps[k] * sr);
			if (idx * 2 + 1 < (int)f.data.size()) {
				f.data[(size_t)idx * 2] += 0.5f - 0.08f * k;
				f.data[(size_t)idx * 2 + 1] += 0.42f - 0.07f * k;
			}
		}
		set_ir(f);
		loaded = false;   // still counts as "no file chosen"
	}

	void set_ir(const AudioFile &in) {
		if (!in.valid()) return;
		// Normalise to unit energy: a raw impulse response can be 30 dB hotter
		// or colder than the dry signal, and the Mix knob should mean the same
		// thing whichever file is loaded.
		AudioFile f = in;
		double energy = 0.0;
		for (float x : f.data) energy += (double)x * (double)x;
		energy = std::sqrt(energy / std::max(1.0, (double)f.channels));
		if (energy > 1e-9) {
			const float g = (float)(1.0 / energy);
			for (float &x : f.data) x *= g;
		}
		const float ratio = (float)f.rate / (float)sr;
		const int frames = (int)(f.frames() / std::max(0.01f, ratio));
		const int cap = std::min(frames, (int)(sr * 8.0));
		parts = (cap + N - 1) / N;
		for (int c = 0; c < 2; c++) {
			ir_re[c].assign((size_t)parts * FN, 0.0f);
			ir_im[c].assign((size_t)parts * FN, 0.0f);
		}
		std::vector<float> re(FN), im(FN);
		for (int c = 0; c < 2; c++) {
			for (int pI = 0; pI < parts; pI++) {
				std::fill(re.begin(), re.end(), 0.0f);
				std::fill(im.begin(), im.end(), 0.0f);
				for (int i = 0; i < N; i++) {
					const float src = (float)(pI * N + i) * ratio;
					const int i0 = (int)src;
					if (i0 + 1 >= f.frames()) break;
					const int ch = std::min(c, f.channels - 1);
					const float a = f.data[(size_t)i0 * f.channels + ch];
					const float b = f.data[(size_t)(i0 + 1) * f.channels + ch];
					re[i] = lerp(a, b, src - (float)i0);
				}
				fft(re.data(), im.data(), FN, false);
				std::memcpy(&ir_re[c][(size_t)pI * FN], re.data(), sizeof(float) * FN);
				std::memcpy(&ir_im[c][(size_t)pI * FN], im.data(), sizeof(float) * FN);
			}
		}
		hist_re.assign((size_t)parts * FN, 0.0f);
		hist_im.assign((size_t)parts * FN, 0.0f);
		hist_pos = 0;
		std::fill(out_l.begin(), out_l.end(), 0.0f);
		std::fill(out_r.begin(), out_r.end(), 0.0f);
		loaded = true;
	}

	bool set_string(const std::string &key, const std::string &value) override {
		if (key != "ir") return false;
		if (value.empty()) { build_default_ir(); ir_path.clear(); return true; }
		AudioFile f;
		if (!wav_load(value, f)) return false;
		ir_path = value;
		set_ir(f);
		return true;
	}
	std::string get_string(const std::string &key) const override {
		return key == "ir" ? ir_path : std::string();
	}

	std::vector<float> in_re, in_im, acc_re[2], acc_im[2], tail_l, tail_r;

	void run_block() {
		if (parts <= 0) return;
		if ((int)in_re.size() != FN) {
			in_re.assign(FN, 0.0f); in_im.assign(FN, 0.0f);
			for (int c = 0; c < 2; c++) { acc_re[c].assign(FN, 0.0f); acc_im[c].assign(FN, 0.0f); }
			tail_l.assign(N, 0.0f); tail_r.assign(N, 0.0f);
		}
		// One shared input spectrum: the IR is stereo but the send is summed,
		// which halves the transform cost and is inaudible for a reverb.
		std::fill(in_re.begin(), in_re.end(), 0.0f);
		std::fill(in_im.begin(), in_im.end(), 0.0f);
		for (int i = 0; i < N; i++) in_re[i] = (fifo_l[(size_t)i] + fifo_r[(size_t)i]) * 0.5f;
		fft(in_re.data(), in_im.data(), FN, false);
		std::memcpy(&hist_re[(size_t)hist_pos * FN], in_re.data(), sizeof(float) * FN);
		std::memcpy(&hist_im[(size_t)hist_pos * FN], in_im.data(), sizeof(float) * FN);

		for (int c = 0; c < 2; c++) {
			std::fill(acc_re[c].begin(), acc_re[c].end(), 0.0f);
			std::fill(acc_im[c].begin(), acc_im[c].end(), 0.0f);
			for (int pI = 0; pI < parts; pI++) {
				const int h = (hist_pos - pI + parts * 2) % parts;
				const float *hr = &hist_re[(size_t)h * FN], *hi = &hist_im[(size_t)h * FN];
				const float *ar = &ir_re[c][(size_t)pI * FN], *ai = &ir_im[c][(size_t)pI * FN];
				float *orr = acc_re[c].data(), *oi = acc_im[c].data();
				for (int k = 0; k < FN; k++) {
					orr[k] += hr[k] * ar[k] - hi[k] * ai[k];
					oi[k] += hr[k] * ai[k] + hi[k] * ar[k];
				}
			}
			fft(acc_re[c].data(), acc_im[c].data(), FN, true);
		}
		hist_pos = (hist_pos + 1) % parts;
		for (int i = 0; i < N; i++) {
			out_l[(size_t)i] = acc_re[0][(size_t)i] + tail_l[(size_t)i];
			out_r[(size_t)i] = acc_re[1][(size_t)i] + tail_r[(size_t)i];
			tail_l[(size_t)i] = acc_re[0][(size_t)(i + N)];
			tail_r[(size_t)i] = acc_re[1][(size_t)(i + N)];
		}
	}

	void process(float *L, float *R, int n) override {
		const float mix = p(SP_MIX);
		const float g = db_to_gain(p(SP_GAIN));
		const float pd = clampf(p(SP_PREDELAY) * 0.001f * (float)sr, 0.0f, (float)sr * 0.29f);
		const float width = p(SP_WIDTH);
		hpl.high_pass(sr, p(SP_LOW_CUT), 0.707f);
		lpl.low_pass(sr, p(SP_HIGH_CUT), 0.707f);
		hpr.b0 = hpl.b0; hpr.b1 = hpl.b1; hpr.b2 = hpl.b2; hpr.a1 = hpl.a1; hpr.a2 = hpl.a2;
		lpr.b0 = lpl.b0; lpr.b1 = lpl.b1; lpr.b2 = lpl.b2; lpr.a1 = lpl.a1; lpr.a2 = lpl.a2;

		for (int s = 0; s < n; s++) {
			pre_l.write(L[s]); pre_r.write(R[s]);
			fifo_l[(size_t)fifo_n] = pre_l.read(pd);
			fifo_r[(size_t)fifo_n] = pre_r.read(pd);
			const float wl = out_l[(size_t)fifo_n], wr = out_r[(size_t)fifo_n];
			fifo_n++;
			if (fifo_n >= N) { run_block(); fifo_n = 0; }
			const float fl = lpl(hpl(wl)) * g, fr = lpr(hpr(wr)) * g;
			const float mid = (fl + fr) * 0.5f, side = (fl - fr) * 0.5f * width;
			L[s] += (mid + side) * mix;
			R[s] += (mid - side) * mix;
		}
	}
	float tail() const override { return 10.0f; }
};
static Plug *make_space() { return new Space(); }

// ===========================================================================
// Filter — modulated multimode with an envelope follower
// ===========================================================================
enum { FI_TYPE, FI_CUT, FI_RES, FI_DRIVE, FI_LFO_SHAPE, FI_LFO_RATE, FI_LFO_SYNC, FI_LFO_DIV,
	FI_LFO_AMT, FI_ENV_AMT, FI_ENV_ATK, FI_ENV_REL, FI_MIX, FI_COUNT };

class FilterFx : public Plug {
public:
	Ladder ll, lr;
	SVF sl, sr_;
	LFO lfo;
	float env = 0.0f;
	void process(float *L, float *R, int n) override {
		const int type = pi(FI_TYPE);
		lfo.shape = pi(FI_LFO_SHAPE);
		lfo.set(sr, pb(FI_LFO_SYNC) ? (float)(bpm / 60.0) / std::max(0.01f, sync_beats(pi(FI_LFO_DIV))) : p(FI_LFO_RATE));
		const float atk = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.0005f, p(FI_ENV_ATK) * 0.001f)));
		const float rel = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.001f, p(FI_ENV_REL) * 0.001f)));
		const float mix = p(FI_MIX);
		const float drive = 1.0f + p(FI_DRIVE) * 8.0f;
		for (int s = 0; s < n; s++) {
			const float dl = L[s], dr = R[s];
			const float x = std::max(std::fabs(dl), std::fabs(dr));
			env += (x - env) * (x > env ? atk : rel);
			const float m = lfo.next();
			const float cut = clampf(p(FI_CUT)
					* std::pow(2.0f, m * p(FI_LFO_AMT) / 12.0f)
					* std::pow(2.0f, env * p(FI_ENV_AMT) / 12.0f), 20.0f, (float)sr * 0.47f);
			float wl, wr;
			if (type < 4) {
				ll.mode = type; lr.mode = type;
				ll.set(sr, cut, p(FI_RES)); lr.set(sr, cut, p(FI_RES));
				wl = ll(dl * drive) / drive;
				wr = lr(dr * drive) / drive;
			} else {
				sl.set(sr, cut, 0.7f + p(FI_RES) * 16.0f);
				sr_.set(sr, cut, 0.7f + p(FI_RES) * 16.0f);
				sl.process(dl * drive); sr_.process(dr * drive);
				wl = (type == 4 ? sl.notch : sl.peak) / drive;
				wr = (type == 4 ? sr_.notch : sr_.peak) / drive;
			}
			L[s] = lerp(dl, wl, mix);
			R[s] = lerp(dr, wr, mix);
		}
	}
};
static Plug *make_filter() { return new FilterFx(); }

// ===========================================================================
// Auto Pan / Tremolo
// ===========================================================================
enum { AP_MODE, AP_SHAPE, AP_RATE, AP_SYNC, AP_DIV, AP_DEPTH, AP_PHASE, AP_COUNT };

class AutoPan : public Plug {
public:
	LFO lfo;
	void process(float *L, float *R, int n) override {
		lfo.shape = pi(AP_SHAPE);
		lfo.set(sr, pb(AP_SYNC) ? (float)(bpm / 60.0) / std::max(0.01f, sync_beats(pi(AP_DIV))) : p(AP_RATE));
		const float depth = p(AP_DEPTH);
		const bool trem = pi(AP_MODE) == 1;
		const float ph = p(AP_PHASE);
		for (int s = 0; s < n; s++) {
			const float m = lfo.next();
			// The right channel reads the LFO a phase-offset later.
			const float m2 = std::sin((float)TAU * (lfo.phase + ph));
			if (trem) {
				L[s] *= 1.0f - depth * (0.5f - m * 0.5f);
				R[s] *= 1.0f - depth * (0.5f - m2 * 0.5f);
			} else {
				const float pan = m * depth;
				L[s] *= std::cos((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
				R[s] *= std::sin((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
			}
		}
	}
};
static Plug *make_autopan() { return new AutoPan(); }

// ===========================================================================
// Ring Mod / frequency shifter
// ===========================================================================
enum { RM_FREQ, RM_MODE, RM_FEEDBACK, RM_MIX, RM_COUNT };

class RingMod : public Plug {
public:
	float phase = 0.0f;
	AllpassOne hl[8], hr[8], hl2[8], hr2[8];
	float fbl = 0.0f, fbr = 0.0f;
	void process(float *L, float *R, int n) override {
		const float f = p(RM_FREQ);
		const float mix = p(RM_MIX);
		const float fb = p(RM_FEEDBACK) * 0.9f;
		const bool shift = pi(RM_MODE) == 1;
		// Hilbert pair: two all-pass chains 90 degrees apart.
		static const float c1[4] = {0.6923878f, 0.9360654f, 0.9882295f, 0.9987488f};
		static const float c2[4] = {0.4021921f, 0.8561711f, 0.9722910f, 0.9952885f};
		for (int s = 0; s < n; s++) {
			const float dl = L[s], dr = R[s];
			phase += f / (float)sr;
			if (phase >= 1.0f) phase -= std::floor(phase);
			const float cs = std::cos((float)TAU * phase), sn = std::sin((float)TAU * phase);
			float wl, wr;
			if (shift) {
				float a = dl + fbl * fb, b = dr + fbr * fb;
				float a1 = a, a2 = a, b1 = b, b2 = b;
				for (int i = 0; i < 4; i++) {
					hl[i].a = c1[i] * c1[i]; a1 = hl[i](a1);
					hl2[i].a = c2[i] * c2[i]; a2 = hl2[i](a2);
					hr[i].a = c1[i] * c1[i]; b1 = hr[i](b1);
					hr2[i].a = c2[i] * c2[i]; b2 = hr2[i](b2);
				}
				wl = a1 * cs - a2 * sn;
				wr = b1 * cs - b2 * sn;
				fbl = wl; fbr = wr;
			} else {
				wl = dl * cs;
				wr = dr * cs;
			}
			L[s] = lerp(dl, wl, mix);
			R[s] = lerp(dr, wr, mix);
		}
	}
};
static Plug *make_ringmod() { return new RingMod(); }

// ===========================================================================
// Pitch Shifter — two crossfaded delay taps
// ===========================================================================
enum { PS_SEMI, PS_CENT, PS_FORMANT, PS_QUALITY, PS_DRY, PS_MIX, PS_COUNT };

/// A phase vocoder, which is what a pitch shifter has to be to sound like one.
///
/// The old one was a pair of taps on a delay line crossfading into each other.
/// That is cheap and it is what a stomp box does, but on anything with a pitch
/// in it the crossfade beats against the signal, and the result is the warbling
/// metallic screech this plugin was justly complained about.
///
/// Here the signal is taken apart into 2048 bins several times per window, each
/// bin's true frequency is read off from how far its phase moved since the last
/// frame, the bins are moved to where the new pitch puts them, and the phase is
/// re-accumulated on the way back out. Latency is one window, and the dry path
/// is delayed to match so that a blend of the two still lines up.
class PitchShift : public Plug {
	static const int N = 2048;
	static const int BINS = N / 2;

	struct Chan {
		float in[N] = {0};                 // ring of input history
		float out[N] = {0};                // ring the frames overlap-add into
		float last_phase[BINS + 1] = {0};
		float sum_phase[BINS + 1] = {0};
		int w = 0;                         // next slot to write / next to emit
		int fill = 0;                      // samples since the last frame
	};
	Chan c[2];
	float window[N];

	// Frame scratch. Members rather than locals: forty kilobytes of arrays on
	// the audio thread's stack is not a bet worth taking.
	float re[N], im[N];
	float mag[BINS + 1], frq[BINS + 1];
	float smag[BINS + 1], sfrq[BINS + 1];
	float env[BINS + 1], senv[BINS + 1];

	// What the panel draws: the spectrum going in and the one coming out.
	static const int VIS = 64;
	float vis_in[VIS] = {0};
	float vis_out[VIS] = {0};

public:
	PitchShift() {
		for (int i = 0; i < N; i++) {
			window[i] = 0.5f - 0.5f * std::cos((float)TAU * (float)i / (float)N);
		}
	}

	void prepare() override { reset(); }

	void reset() override {
		for (int ch = 0; ch < 2; ch++) c[ch] = Chan();
		for (int i = 0; i < VIS; i++) { vis_in[i] = 0.0f; vis_out[i] = 0.0f; }
	}

	int aux(int what, float *dst, int max) override {
		if (what != 0 || max < VIS * 2) return 0;
		for (int i = 0; i < VIS; i++) { dst[i] = vis_in[i]; dst[VIS + i] = vis_out[i]; }
		return VIS * 2;
	}

	void process(float *L, float *R, int n) override {
		const float ratio = clampf(std::pow(2.0f, (p(PS_SEMI) + p(PS_CENT) * 0.01f) / 12.0f), 0.25f, 4.0f);
		// Moving the spectral envelope back down after the bins have gone up is
		// what keeps a shifted voice from turning into a chipmunk.
		const float formant = clampf(std::pow(2.0f, -p(PS_FORMANT) / 12.0f), 0.25f, 4.0f);
		// Four frames per window is the quality setting; two costs half the
		// arithmetic and is honest enough for a shift of a few semitones.
		const int over = p(PS_QUALITY) > 0.5f ? 4 : 2;
		const int hop = N / over;
		const float mix = clampf(p(PS_MIX), 0.0f, 1.0f);
		const float dry_gain = clampf(p(PS_DRY), 0.0f, 1.0f);

		float *buf[2] = {L, R};
		for (int s = 0; s < n; s++) {
			for (int ch = 0; ch < 2; ch++) {
				Chan &q = c[ch];
				// The slot about to be overwritten holds the sample from a
				// whole window ago, which is exactly the dry to pair with the
				// wet coming out now.
				const float dry = q.in[q.w];
				q.in[q.w] = buf[ch][s];
				const float wet = q.out[q.w];
				q.out[q.w] = 0.0f;
				q.w = (q.w + 1) % N;
				if (++q.fill >= hop) {
					q.fill = 0;
					step(q, ratio, formant, over, ch == 0);
				}
				buf[ch][s] = dry * dry_gain + wet * mix;
			}
		}
	}

private:
	void step(Chan &q, float ratio, float formant, int over, bool watch) {
		const int hop = N / over;
		const float expected = (float)TAU * (float)hop / (float)N;
		const float freq_per_bin = (float)sr / (float)N;
		// Hann at both ends overlap-adds to over/2, so this puts it back to one.
		const float norm = 2.0f / (float)over;

		// Oldest first: q.w is the next slot to write, so it is also the start
		// of the window.
		for (int i = 0; i < N; i++) {
			re[i] = q.in[(q.w + i) % N] * window[i];
			im[i] = 0.0f;
		}
		fft(re, im, N, false);

		for (int k = 0; k <= BINS; k++) {
			mag[k] = 2.0f * std::sqrt(re[k] * re[k] + im[k] * im[k]);
			const float phase = std::atan2(im[k], re[k]);
			float d = phase - q.last_phase[k];
			q.last_phase[k] = phase;
			// Wrap into +/- pi, then read off how far this bin's real frequency
			// sits from its nominal one.
			d -= (float)k * expected;
			int wraps = (int)(d / (float)PI);
			wraps += (wraps >= 0) ? (wraps & 1) : -(wraps & 1);
			d -= (float)PI * (float)wraps;
			frq[k] = ((float)k + (float)over * d / (float)TAU) * freq_per_bin;
		}

		const bool shift_formants = formant < 0.999f || formant > 1.001f;
		if (shift_formants) envelope(mag, env);

		for (int k = 0; k <= BINS; k++) { smag[k] = 0.0f; sfrq[k] = 0.0f; }
		for (int k = 0; k <= BINS; k++) {
			const int t = (int)((float)k * ratio + 0.5f);
			if (t < 0 || t > BINS) continue;
			smag[t] += mag[k];
			sfrq[t] = frq[k] * ratio;
		}
		if (shift_formants) {
			// Divide the moved envelope out and put the original back, read
			// from wherever the formant control points.
			envelope(smag, senv);
			for (int k = 0; k <= BINS; k++) {
				const int src = std::min(BINS, std::max(0, (int)((float)k * formant + 0.5f)));
				smag[k] *= clampf(env[src] / std::max(1e-9f, senv[k]), 0.0f, 8.0f);
			}
		}

		for (int k = 0; k <= BINS; k++) {
			float d = sfrq[k] / freq_per_bin - (float)k;
			d = (float)TAU * d / (float)over + (float)k * expected;
			q.sum_phase[k] += d;
			re[k] = smag[k] * std::cos(q.sum_phase[k]);
			im[k] = smag[k] * std::sin(q.sum_phase[k]);
		}
		for (int k = BINS + 1; k < N; k++) { re[k] = re[N - k]; im[k] = -im[N - k]; }
		fft(re, im, N, true);
		for (int i = 0; i < N; i++) q.out[(q.w + i) % N] += re[i] * window[i] * norm;

		if (watch) {
			for (int b = 0; b < VIS; b++) {
				// Logarithmic bands, so it reads as a spectrum rather than a
				// spike at the left with nothing after it.
				const int k0 = (int)std::pow((float)BINS, (float)b / (float)VIS);
				const int k1 = std::max(k0 + 1, (int)std::pow((float)BINS, (float)(b + 1) / (float)VIS));
				float a = 0.0f, w = 0.0f;
				for (int k = k0; k < k1 && k <= BINS; k++) { a = std::max(a, mag[k]); w = std::max(w, smag[k]); }
				vis_in[b] = vis_in[b] * 0.7f + db_norm(a) * 0.3f;
				vis_out[b] = vis_out[b] * 0.7f + db_norm(w) * 0.3f;
			}
		}
	}

	static float db_norm(float m) {
		const float db = 20.0f * std::log10(std::max(1e-6f, m));
		return clampf((db + 90.0f) / 90.0f, 0.0f, 1.0f);
	}

	/// A coarse spectral envelope -- the magnitudes smeared across their
	/// neighbours, which moves formants convincingly without a cepstrum.
	/// Kept as a running sum, so it costs one pass rather than one per bin.
	void envelope(const float *m, float *out) const {
		const int span = 12;
		float run = 0.0f;
		for (int k = 0; k <= std::min(BINS, span); k++) run += m[k];
		for (int k = 0; k <= BINS; k++) {
			const int lo = k - span, hi = k + span;
			if (k > 0) {
				if (lo - 1 >= 0) run -= m[lo - 1];
				if (hi <= BINS) run += m[hi];
			}
			const int count = std::min(BINS, hi) - std::max(0, lo) + 1;
			out[k] = run / (float)count + 1e-9f;
		}
	}
};


static Plug *make_pitch() { return new PitchShift(); }

// ===========================================================================
// Vocoder — the sidechain speaks, the track carries
// ===========================================================================
enum { VO_BANDS, VO_ATTACK, VO_RELEASE, VO_FORMANT, VO_HISS, VO_MIX, VO_COUNT };

class Vocoder : public Plug {
public:
	static const int MAXB = 24;
	Biquad mod_f[MAXB][2], car_f[MAXB][2];
	float env[MAXB] = {0};
	std::vector<float> sc_l, sc_r;
	bool has_sc = false;
	Rng rng;

	// what 0: how many bands, then that many band levels 0..1.
	int aux(int what, float *o, int max) override {
		if (what != 0) return 0;
		const int bands = std::max(4, std::min(MAXB, pi(VO_BANDS)));
		if (max < bands + 1) return 0;
		o[0] = (float)bands;
		for (int b = 0; b < bands; b++) o[b + 1] = std::min(1.0f, env[b] * 4.0f);
		return bands + 1;
	}

	bool wants_sidechain() const override { return true; }
	void sidechain(const float *l, const float *r, int n) override {
		if ((int)sc_l.size() < n) { sc_l.resize((size_t)n); sc_r.resize((size_t)n); }
		std::memcpy(sc_l.data(), l, sizeof(float) * (size_t)n);
		std::memcpy(sc_r.data(), r, sizeof(float) * (size_t)n);
		has_sc = true;
	}
	void process(float *L, float *R, int n) override {
		const int bands = std::max(4, std::min(MAXB, pi(VO_BANDS)));
		const float atk = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.0005f, p(VO_ATTACK) * 0.001f)));
		const float rel = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.001f, p(VO_RELEASE) * 0.001f)));
		const float shift = std::pow(2.0f, p(VO_FORMANT) / 12.0f);
		const float mix = p(VO_MIX), hiss = p(VO_HISS);
		for (int b = 0; b < bands; b++) {
			const float t = (float)b / (float)(bands - 1);
			const float f = 110.0f * std::pow(7500.0f / 110.0f, t);
			const float q = 4.0f;
			mod_f[b][0].band_pass(sr, f, q);
			mod_f[b][1] = mod_f[b][0];
			car_f[b][0].band_pass(sr, clampf(f * shift, 40.0f, (float)sr * 0.45f), q);
			car_f[b][1] = car_f[b][0];
		}
		if (!has_sc) { return; }
		for (int s = 0; s < n; s++) {
			const float m = ((sc_l.empty() ? 0.0f : sc_l[(size_t)s]) + (sc_r.empty() ? 0.0f : sc_r[(size_t)s])) * 0.5f;
			const float c = (L[s] + R[s]) * 0.5f + rng.bi() * hiss * 0.1f;
			float outv = 0.0f;
			for (int b = 0; b < bands; b++) {
				const float mb = mod_f[b][0](m);
				const float a = std::fabs(mb);
				env[b] += (a - env[b]) * (a > env[b] ? atk : rel);
				outv += car_f[b][0](c) * env[b] * 3.0f;
			}
			L[s] = lerp(L[s], outv, mix);
			R[s] = lerp(R[s], outv, mix);
		}
		has_sc = false;
	}
};
static Plug *make_vocoder() { return new Vocoder(); }

// ---------------------------------------------------------------------------
void register_effects2(std::vector<PlugDesc> &out) {
	out.push_back({"cd.chorus", "Chorus", "Cadmium", "Modulation", false, UI_MOD, {
		{"voices", "Voices", 1, 4, 2, P_SEMI, "Chorus", nullptr, 1},
		{"rate", "Rate", 0.01f, 10, 0.6f, P_HZ, "Chorus", nullptr, 0.4f},
		{"depth", "Depth", 0, 20, 4, P_MS, "Chorus", nullptr, 1},
		{"delay", "Delay", 1, 40, 12, P_MS, "Chorus", nullptr, 1},
		{"spread", "Spread", 0, 1, 0.6f, P_PCT, "Chorus", nullptr, 1},
		{"feedback", "Feedback", 0, 0.95f, 0, P_PCT, "Chorus", nullptr, 1},
		{"mix", "Mix", 0, 1, 0.45f, P_PCT, "Output", nullptr, 1},
	}, make_chorus});

	out.push_back({"cd.flanger", "Flanger", "Cadmium", "Modulation", false, UI_MOD, {
		{"rate", "Rate", 0.01f, 8, 0.25f, P_HZ, "Flange", nullptr, 0.4f},
		{"depth", "Depth", 0, 10, 3, P_MS, "Flange", nullptr, 1},
		{"manual", "Manual", 0.1f, 10, 0.6f, P_MS, "Flange", nullptr, 1},
		{"feedback", "Feedback", -0.95f, 0.95f, 0.55f, P_PCT, "Flange", nullptr, 1},
		{"invert", "Invert", 0, 1, 0, P_BOOL, "Flange", nullptr, 1},
		{"mix", "Mix", 0, 1, 0.6f, P_PCT, "Output", nullptr, 1},
	}, make_flanger});

	out.push_back({"cd.phaser", "Phaser", "Cadmium", "Modulation", false, UI_MOD, {
		{"stages", "Stages", 1, 6, 3, P_SEMI, "Phase", nullptr, 1},
		{"rate", "Rate", 0.01f, 8, 0.4f, P_HZ, "Phase", nullptr, 0.4f},
		{"depth", "Depth", 0, 1, 0.7f, P_PCT, "Phase", nullptr, 1},
		{"center", "Centre", 60, 8000, 700, P_HZ, "Phase", nullptr, 0.3f},
		{"feedback", "Feedback", -0.95f, 0.95f, 0.4f, P_PCT, "Phase", nullptr, 1},
		{"spread", "Spread", 0, 1, 0.35f, P_PCT, "Phase", nullptr, 1},
		{"mix", "Mix", 0, 1, 0.7f, P_PCT, "Output", nullptr, 1},
	}, make_phaser});

	out.push_back({"cd.delay", "Delay", "Cadmium", "Delay", false, UI_DELAY, {
		{"sync", "Sync", 0, 1, 1, P_BOOL, "Time", nullptr, 1},
		{"time", "Time", 0.001f, 4, 0.375f, P_SEC, "Time", nullptr, 0.4f},
		{"div", "Division", 0, 12, 4, P_CHOICE, "Time", SYNC_NAMES, 1},
		{"offset", "L/R Offset", -0.5f, 0.5f, 0, P_PCT, "Time", nullptr, 1},
		{"feedback", "Feedback", 0, 1.1f, 0.42f, P_PCT, "Time", nullptr, 1},
		{"pingpong", "Ping Pong", 0, 1, 0, P_BOOL, "Time", nullptr, 1},
		{"lo_cut", "Low Cut", 20, 2000, 180, P_HZ, "Tone", nullptr, 0.3f},
		{"hi_cut", "High Cut", 500, 20000, 7000, P_HZ, "Tone", nullptr, 0.3f},
		{"mod_rate", "Mod Rate", 0.01f, 8, 0.3f, P_HZ, "Tone", nullptr, 0.4f},
		{"mod_depth", "Mod Depth", 0, 8, 0.6f, P_MS, "Tone", nullptr, 1},
		{"duck", "Ducking", 0, 1, 0, P_PCT, "Tone", nullptr, 1},
		{"mix", "Mix", 0, 1, 0.3f, P_PCT, "Output", nullptr, 1},
	}, make_delay});

	out.push_back({"cd.reverb", "Reverb", "Cadmium", "Reverb", false, UI_VERB, {
		{"size", "Size", 0.15f, 2.5f, 1.0f, P_PCT, "Room", nullptr, 1},
		{"decay", "Decay", 0, 1, 0.45f, P_PCT, "Room", nullptr, 1},
		{"damp", "Damping", 0, 1, 0.45f, P_PCT, "Tone", nullptr, 1},
		{"low_damp", "Low Cut", 0, 1, 0.2f, P_PCT, "Tone", nullptr, 1},
		{"predelay", "Pre Delay", 0, 250, 18, P_MS, "Room", nullptr, 1},
		{"diffusion", "Diffusion", 0, 1, 0.7f, P_PCT, "Room", nullptr, 1},
		{"mod", "Modulation", 0, 1, 0.25f, P_PCT, "Tone", nullptr, 1},
		{"width", "Width", 0, 2, 1.1f, P_PCT, "Output", nullptr, 1},
		{"early", "Early", 0, 1, 0.35f, P_PCT, "Room", nullptr, 1},
		{"mix", "Mix", 0, 1, 0.28f, P_PCT, "Output", nullptr, 1},
	}, make_reverb});

	out.push_back({"cd.space", "Space", "Cadmium", "Reverb", false, UI_CONV, {
		{"mix", "Mix", 0, 1, 0.3f, P_PCT, "Output", nullptr, 1},
		{"predelay", "Pre Delay", 0, 250, 0, P_MS, "Impulse", nullptr, 1},
		{"gain", "Gain", -24, 24, 0, P_DB, "Impulse", nullptr, 1},
		{"low_cut", "Low Cut", 20, 2000, 60, P_HZ, "Tone", nullptr, 0.3f},
		{"high_cut", "High Cut", 500, 20000, 12000, P_HZ, "Tone", nullptr, 0.3f},
		{"width", "Width", 0, 2, 1, P_PCT, "Output", nullptr, 1},
		{"stretch", "Stretch", 0.25f, 4, 1, P_PCT, "Impulse", nullptr, 1},
	}, make_space});

	out.push_back({"cd.filter", "Filter", "Cadmium", "Filter", false, UI_FILTER, {
		{"type", "Type", 0, 5, 0, P_CHOICE, "Filter", "Low 24|Low 12|Band|High|Notch|Peak", 1},
		{"cut", "Cutoff", 20, 20000, 1200, P_HZ, "Filter", nullptr, 0.3f},
		{"res", "Reso", 0, 1, 0.3f, P_PCT, "Filter", nullptr, 1},
		{"drive", "Drive", 0, 1, 0.1f, P_PCT, "Filter", nullptr, 1},
		{"lfo_shape", "LFO Shape", 0, 6, 0, P_CHOICE, "Modulation", "Sine|Triangle|Saw Down|Saw Up|Square|S&H|Noise", 1},
		{"lfo_rate", "LFO Rate", 0.01f, 20, 1, P_HZ, "Modulation", nullptr, 0.4f},
		{"lfo_sync", "LFO Sync", 0, 1, 0, P_BOOL, "Modulation", nullptr, 1},
		{"lfo_div", "Division", 0, 12, 5, P_CHOICE, "Modulation", SYNC_NAMES, 1},
		{"lfo_amt", "LFO Amount", -48, 48, 0, P_SEMI, "Modulation", nullptr, 1},
		{"env_amt", "Env Amount", -48, 48, 0, P_SEMI, "Modulation", nullptr, 1},
		{"env_atk", "Env Attack", 0.1f, 200, 5, P_MS, "Modulation", nullptr, 0.3f},
		{"env_rel", "Env Release", 1, 1000, 120, P_MS, "Modulation", nullptr, 0.3f},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
	}, make_filter});

	out.push_back({"cd.autopan", "Auto Pan", "Cadmium", "Modulation", false, UI_MOD, {
		{"mode", "Mode", 0, 1, 0, P_CHOICE, "Motion", "Pan|Tremolo", 1},
		{"shape", "Shape", 0, 6, 0, P_CHOICE, "Motion", "Sine|Triangle|Saw Down|Saw Up|Square|S&H|Noise", 1},
		{"rate", "Rate", 0.01f, 20, 2, P_HZ, "Motion", nullptr, 0.4f},
		{"sync", "Sync", 0, 1, 1, P_BOOL, "Motion", nullptr, 1},
		{"div", "Division", 0, 12, 3, P_CHOICE, "Motion", SYNC_NAMES, 1},
		{"depth", "Depth", 0, 1, 0.7f, P_PCT, "Motion", nullptr, 1},
		{"phase", "Phase", 0, 1, 0.5f, P_PCT, "Motion", nullptr, 1},
	}, make_autopan});

	out.push_back({"cd.ringmod", "Ring Mod", "Cadmium", "Distortion", false, UI_MOD, {
		{"freq", "Frequency", 0.1f, 4000, 220, P_HZ, "Modulator", nullptr, 0.3f},
		{"mode", "Mode", 0, 1, 0, P_CHOICE, "Modulator", "Ring|Freq Shift", 1},
		{"feedback", "Feedback", 0, 0.95f, 0, P_PCT, "Modulator", nullptr, 1},
		{"mix", "Mix", 0, 1, 0.5f, P_PCT, "Output", nullptr, 1},
	}, make_ringmod});

	out.push_back({"cd.pitch", "Pitch Shift", "Cadmium", "Pitch", false, UI_PITCH, {
		{"semi", "Semitones", -24, 24, 0, P_SEMI, "Pitch", nullptr, 1},
		{"cent", "Cents", -100, 100, 0, P_SEMI, "Pitch", nullptr, 1},
		{"formant", "Formant", -12, 12, 0, P_SEMI, "Pitch", nullptr, 1},
		{"quality", "Quality", 0, 1, 1, P_CHOICE, "Pitch", "Fast|Fine", 1},
		{"dry", "Dry", 0, 1, 0, P_PCT, "Output", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
	}, make_pitch});

	out.push_back({"cd.vocoder", "Vocoder", "Cadmium", "Filter", false, UI_VOCODER, {
		{"bands", "Bands", 4, 24, 16, P_SEMI, "Vocode", nullptr, 1},
		{"attack", "Attack", 0.5f, 100, 4, P_MS, "Vocode", nullptr, 0.3f},
		{"release", "Release", 1, 500, 40, P_MS, "Vocode", nullptr, 0.3f},
		{"formant", "Formant", -12, 12, 0, P_SEMI, "Vocode", nullptr, 1},
		{"hiss", "Hiss", 0, 1, 0.15f, P_PCT, "Vocode", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
	}, make_vocoder});
}

} // namespace cd
