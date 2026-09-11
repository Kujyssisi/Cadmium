// Cadmium — stock effects, part 1: EQ, dynamics, saturation, utility.
#include "plugin.h"

namespace cd {

// ===========================================================================
// EQ Eight
// ===========================================================================
enum { EQ_BANDS = 8 };
enum {
	EQ_B0_ON, EQ_B0_TYPE, EQ_B0_FREQ, EQ_B0_GAIN, EQ_B0_Q,
	EQ_STRIDE = 5,
	EQ_OUT = EQ_B0_ON + EQ_BANDS * EQ_STRIDE,
	EQ_MIX, EQ_ANALYZER,
	EQ_COUNT
};

class EqEight : public Plug {
public:
	Biquad bl[EQ_BANDS], br[EQ_BANDS];
	// Analyser: a rolling window fed from the audio thread, transformed on
	// demand by the UI thread through aux().
	static const int FFT_N = 1024;
	float ring[FFT_N];
	int ring_w = 0;
	float spec[FFT_N / 2];

	void prepare() override {
		std::memset(ring, 0, sizeof(ring));
		std::memset(spec, 0, sizeof(spec));
		for (int b = 0; b < EQ_BANDS; b++) { bl[b].reset(); br[b].reset(); }
	}
	void update_band(int b) {
		const int base = EQ_B0_ON + b * EQ_STRIDE;
		const int type = (int)std::lround(pv[(size_t)(base + 1)]);
		const float f = pv[(size_t)(base + 2)];
		const float g = pv[(size_t)(base + 3)];
		const float q = pv[(size_t)(base + 4)];
		switch (type) {
			case 0: bl[b].low_shelf(sr, f, q, g); break;
			case 1: bl[b].peaking(sr, f, q, g); break;
			case 2: bl[b].high_shelf(sr, f, q, g); break;
			case 3: bl[b].high_pass(sr, f, q); break;
			case 4: bl[b].low_pass(sr, f, q); break;
			case 5: bl[b].notch(sr, f, q); break;
			default: bl[b].band_pass(sr, f, q); break;
		}
		br[b].b0 = bl[b].b0; br[b].b1 = bl[b].b1; br[b].b2 = bl[b].b2;
		br[b].a1 = bl[b].a1; br[b].a2 = bl[b].a2;
	}
	void process(float *L, float *R, int n) override {
		for (int b = 0; b < EQ_BANDS; b++) update_band(b);
		const float out = db_to_gain(p(EQ_OUT));
		const float mix = p(EQ_MIX);
		for (int s = 0; s < n; s++) {
			const float dl = L[s], dr = R[s];
			float l = dl, r = dr;
			for (int b = 0; b < EQ_BANDS; b++) {
				if (pv[(size_t)(EQ_B0_ON + b * EQ_STRIDE)] < 0.5f) continue;
				l = bl[b](l);
				r = br[b](r);
			}
			l = lerp(dl, l * out, mix);
			r = lerp(dr, r * out, mix);
			L[s] = l; R[s] = r;
			ring[ring_w] = (l + r) * 0.5f;
			ring_w = (ring_w + 1) & (FFT_N - 1);
		}
	}
	// what 0: 129-point magnitude response curve in dB (for the drawn curve)
	// what 1: FFT_N/2 spectrum bins in dB (analyser)
	int aux(int what, float *o, int max) override {
		if (what == 0) {
			const int N = 129;
			if (max < N) return 0;
			for (int i = 0; i < N; i++) {
				const float hz = 20.0f * std::pow(1000.0f, (float)i / (float)(N - 1));
				float mag = 1.0f;
				for (int b = 0; b < EQ_BANDS; b++) {
					if (pv[(size_t)(EQ_B0_ON + b * EQ_STRIDE)] < 0.5f) continue;
					mag *= bl[b].magnitude(sr, hz);
				}
				o[i] = gain_to_db(mag) + p(EQ_OUT);
			}
			return N;
		}
		if (what == 1) {
			if (p(EQ_ANALYZER) < 0.5f) return 0;
			static float re[FFT_N], im[FFT_N];
			const int w = ring_w;
			for (int i = 0; i < FFT_N; i++) {
				const float win = 0.5f - 0.5f * std::cos((float)TAU * i / (float)(FFT_N - 1));
				re[i] = ring[(w + i) & (FFT_N - 1)] * win;
				im[i] = 0.0f;
			}
			fft(re, im, FFT_N, false);
			const int bins = std::min(max, FFT_N / 2);
			for (int i = 0; i < bins; i++) {
				const float m = std::sqrt(re[i] * re[i] + im[i] * im[i]) * (2.0f / FFT_N);
				// Slow decay so the display does not flicker between frames.
				spec[i] = std::max(m, spec[i] * 0.72f);
				o[i] = gain_to_db(spec[i] + 1e-7f);
			}
			return bins;
		}
		return 0;
	}
};
static Plug *make_eq() { return new EqEight(); }

// ===========================================================================
// Compressor (with external sidechain)
// ===========================================================================
enum {
	CO_THRESH, CO_RATIO, CO_ATTACK, CO_RELEASE, CO_KNEE, CO_MAKEUP, CO_MIX,
	CO_SC_EXT, CO_SC_HP, CO_LOOKAHEAD, CO_AUTO, CO_RMS, CO_COUNT
};

class Compressor : public Plug {
public:
	float env = 0.0f, gr_db = 0.0f;
	Biquad schp_l, schp_r;
	std::vector<float> la_l, la_r;
	int la_w = 0, la_n = 0;
	std::vector<float> sc_l, sc_r;
	bool has_sc = false;
	float rms_z = 0.0f;

	void prepare() override {
		la_l.assign((size_t)(sr * 0.02) + 8, 0.0f);
		la_r.assign(la_l.size(), 0.0f);
		sc_l.assign((size_t)block + 64, 0.0f);
		sc_r.assign(sc_l.size(), 0.0f);
		la_w = 0;
	}
	bool wants_sidechain() const override { return pv.size() > CO_SC_EXT && pv[CO_SC_EXT] > 0.5f; }
	void sidechain(const float *l, const float *r, int n) override {
		if ((int)sc_l.size() < n) { sc_l.resize((size_t)n); sc_r.resize((size_t)n); }
		std::memcpy(sc_l.data(), l, sizeof(float) * (size_t)n);
		std::memcpy(sc_r.data(), r, sizeof(float) * (size_t)n);
		has_sc = true;
	}
	void process(float *L, float *R, int n) override {
		const float thr = p(CO_THRESH);
		const float ratio = std::max(1.0f, p(CO_RATIO));
		const float knee = p(CO_KNEE);
		const float atk = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.0001f, p(CO_ATTACK) * 0.001f)));
		const float rel = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.001f, p(CO_RELEASE) * 0.001f)));
		const float mix = p(CO_MIX);
		const float auto_mk = pb(CO_AUTO) ? -thr * (1.0f - 1.0f / ratio) * 0.6f : 0.0f;
		const float makeup = db_to_gain(p(CO_MAKEUP) + auto_mk);
		const int la = std::min((int)la_l.size() - 1, (int)(sr * p(CO_LOOKAHEAD) * 0.001f));
		const float rms_c = 1.0f - std::exp(-1.0f / (float)(sr * 0.008));
		schp_l.high_pass(sr, std::max(20.0f, p(CO_SC_HP)), 0.707f);
		schp_r.b0 = schp_l.b0; schp_r.b1 = schp_l.b1; schp_r.b2 = schp_l.b2;
		schp_r.a1 = schp_l.a1; schp_r.a2 = schp_l.a2;
		const bool ext = pb(CO_SC_EXT) && has_sc;

		float worst = 0.0f;
		for (int s = 0; s < n; s++) {
			float dl = L[s], dr = R[s];
			float kl = ext ? sc_l[(size_t)s] : dl;
			float kr = ext ? sc_r[(size_t)s] : dr;
			if (p(CO_SC_HP) > 21.0f) { kl = schp_l(kl); kr = schp_r(kr); }
			float key;
			if (pb(CO_RMS)) {
				rms_z += ((kl * kl + kr * kr) * 0.5f - rms_z) * rms_c;
				key = std::sqrt(std::max(0.0f, rms_z));
			} else {
				key = std::max(std::fabs(kl), std::fabs(kr));
			}
			const float key_db = gain_to_db(key + 1e-9f);
			// Soft knee around the threshold.
			float over = key_db - thr;
			float target = 0.0f;
			if (knee > 0.01f && over > -knee * 0.5f && over < knee * 0.5f) {
				const float x = over + knee * 0.5f;
				target = (1.0f / ratio - 1.0f) * x * x / (2.0f * knee);
			} else if (over > 0.0f) {
				target = over * (1.0f / ratio - 1.0f);
			}
			const float c = target < env ? atk : rel;
			env += (target - env) * c;
			gr_db = env;
			worst = std::min(worst, env);
			const float g = db_to_gain(env) * makeup;

			// Lookahead: delay the audio, not the detector.
			la_l[(size_t)la_w] = dl;
			la_r[(size_t)la_w] = dr;
			const int rd = (la_w - la + (int)la_l.size()) % (int)la_l.size();
			const float ol = la > 0 ? la_l[(size_t)rd] : dl;
			const float or_ = la > 0 ? la_r[(size_t)rd] : dr;
			la_w = (la_w + 1) % (int)la_l.size();

			L[s] = lerp(dl, ol * g, mix);
			R[s] = lerp(dr, or_ * g, mix);
		}
		has_sc = false;
		gr_db = worst;
	}
	int aux(int what, float *o, int max) override {
		if (what == 0 && max >= 1) { o[0] = gr_db; return 1; }
		return 0;
	}
};
static Plug *make_comp() { return new Compressor(); }

// ===========================================================================
// Limiter — lookahead brickwall
// ===========================================================================
enum { LI_CEILING, LI_GAIN, LI_RELEASE, LI_LOOKAHEAD, LI_COUNT };

class Limiter : public Plug {
public:
	std::vector<float> dl, dr, envbuf;
	int w = 0;
	float env = 1.0f, gr_db = 0.0f;

	void prepare() override {
		const int n = (int)(sr * 0.02) + 8;
		dl.assign((size_t)n, 0.0f); dr.assign((size_t)n, 0.0f);
		envbuf.assign((size_t)n, 1.0f);
		w = 0;
	}
	void process(float *L, float *R, int n) override {
		const float ceil_g = db_to_gain(p(LI_CEILING));
		const float in_g = db_to_gain(p(LI_GAIN));
		const float rel = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.005f, p(LI_RELEASE) * 0.001f)));
		const int la = std::max(1, std::min((int)dl.size() - 1, (int)(sr * p(LI_LOOKAHEAD) * 0.001f)));
		float worst = 0.0f;
		for (int s = 0; s < n; s++) {
			const float xl = L[s] * in_g, xr = R[s] * in_g;
			dl[(size_t)w] = xl; dr[(size_t)w] = xr;
			const float peak = std::max(std::fabs(xl), std::fabs(xr));
			const float need = peak > ceil_g ? ceil_g / peak : 1.0f;
			// Attack is instant over the lookahead window; release is smoothed.
			if (need < env) env = need; else env += (need - env) * rel;
			const int rd = (w - la + (int)dl.size()) % (int)dl.size();
			float g = env;
			// Scan the window so a peak arriving soon is already ducked.
			envbuf[(size_t)w] = need;
			for (int k = 1; k <= la; k += std::max(1, la / 16)) {
				const int idx = (w - la + k + (int)dl.size()) % (int)dl.size();
				g = std::min(g, envbuf[(size_t)idx]);
			}
			worst = std::min(worst, gain_to_db(g));
			L[s] = clampf(dl[(size_t)rd] * g, -1.0f, 1.0f);
			R[s] = clampf(dr[(size_t)rd] * g, -1.0f, 1.0f);
			w = (w + 1) % (int)dl.size();
		}
		gr_db = worst;
	}
	int aux(int what, float *o, int max) override {
		if (what == 0 && max >= 1) { o[0] = gr_db; return 1; }
		return 0;
	}
};
static Plug *make_limiter() { return new Limiter(); }

// ===========================================================================
// Gate
// ===========================================================================
enum { GA_THRESH, GA_RANGE, GA_ATTACK, GA_HOLD, GA_RELEASE, GA_HP, GA_COUNT };

class Gate : public Plug {
public:
	float env = 0.0f;
	int hold_left = 0;
	Biquad hp;
	float vis_level = -90.0f;
	// what 0: [open 0..1, key level dB, threshold dB, range dB]
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 4) return 0;
		o[0] = env;
		o[1] = vis_level;
		o[2] = p(GA_THRESH);
		o[3] = p(GA_RANGE);
		return 4;
	}
	void process(float *L, float *R, int n) override {
		const float thr = db_to_gain(p(GA_THRESH));
		const float floor_g = db_to_gain(p(GA_RANGE));
		const float atk = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.0001f, p(GA_ATTACK) * 0.001f)));
		const float rel = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.001f, p(GA_RELEASE) * 0.001f)));
		const int hold = (int)(sr * p(GA_HOLD) * 0.001f);
		hp.high_pass(sr, std::max(20.0f, p(GA_HP)), 0.707f);
		for (int s = 0; s < n; s++) {
			float key = std::max(std::fabs(L[s]), std::fabs(R[s]));
			if (p(GA_HP) > 21.0f) key = std::fabs(hp(key));
			vis_level = std::max(gain_to_db(std::max(key, 1e-6f)), vis_level - 0.02f);
			if (key > thr) { env += (1.0f - env) * atk; hold_left = hold; }
			else if (hold_left > 0) { hold_left--; }
			else { env += (floor_g - env) * rel; }
			L[s] *= env; R[s] *= env;
		}
	}
};
static Plug *make_gate() { return new Gate(); }

// ===========================================================================
// Saturator
// ===========================================================================
enum { SA_DRIVE, SA_MODE, SA_TONE, SA_BIAS, SA_OUT, SA_MIX, SA_COUNT };

class Saturator : public Plug {
public:
	Biquad tl, tr;
	DCBlock dc1, dc2;
	OnePole ol, orr;
	void prepare() override { dc1.set(sr); dc2.set(sr); }
	static inline float shape(int mode, float x, float bias) {
		x += bias;
		switch (mode) {
			case 0: return tanh_fast(x);                                        // Tube
			case 1: return soft_clip(x);                                        // Soft
			case 2: return clampf(x, -1.0f, 1.0f);                              // Hard
			case 3: {                                                           // Fold
				float y = x;
				for (int i = 0; i < 4 && (y > 1.0f || y < -1.0f); i++) {
					y = y > 1.0f ? 2.0f - y : (y < -1.0f ? -2.0f - y : y);
				}
				return y;
			}
			case 4: return std::sin(clampf(x, -2.0f, 2.0f) * (float)PI * 0.5f);  // Sine
			default: {                                                           // Tape
				const float y = tanh_fast(x * 0.8f);
				return y - 0.12f * y * y * y;
			}
		}
	}
	// what 0: 65 points of the curve, input -1..1 through drive and shape.
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 65) return 0;
		const float drv = db_to_gain(p(SA_DRIVE));
		const float out = db_to_gain(p(SA_OUT));
		const int mode = pi(SA_MODE);
		const float bias = p(SA_BIAS);
		for (int i = 0; i < 65; i++) {
			const float x = -1.0f + 2.0f * (float)i / 64.0f;
			o[i] = clampf(lerp(x, shape(mode, x * drv, bias) * out, p(SA_MIX)), -1.5f, 1.5f);
		}
		return 65;
	}
	void process(float *L, float *R, int n) override {
		const float drv = db_to_gain(p(SA_DRIVE));
		const int mode = pi(SA_MODE);
		const float bias = p(SA_BIAS);
		const float out = db_to_gain(p(SA_OUT));
		const float mix = p(SA_MIX);
		const float tone = p(SA_TONE);
		tl.high_shelf(sr, 2500.0f, 0.707f, tone);
		tr.b0 = tl.b0; tr.b1 = tl.b1; tr.b2 = tl.b2; tr.a1 = tl.a1; tr.a2 = tl.a2;
		for (int s = 0; s < n; s++) {
			const float dl = L[s], dr = R[s];
			float l = dc1(shape(mode, tl(dl) * drv, bias));
			float r = dc2(shape(mode, tr(dr) * drv, bias));
			L[s] = lerp(dl, l * out, mix);
			R[s] = lerp(dr, r * out, mix);
		}
	}
};
static Plug *make_sat() { return new Saturator(); }

// ===========================================================================
// Crusher — bit depth and sample rate reduction
// ===========================================================================
enum { CR_BITS, CR_RATE, CR_JITTER, CR_MIX, CR_OUT, CR_COUNT };

class Crusher : public Plug {
public:
	float hl = 0.0f, hr = 0.0f, phase = 0.0f;
	Rng rng;
	// what 0: 129 points of the staircase, so the steps can be counted.
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 129) return 0;
		const float steps = std::pow(2.0f, p(CR_BITS)) - 1.0f;
		const float out = db_to_gain(p(CR_OUT));
		for (int i = 0; i < 129; i++) {
			const float x = -1.0f + 2.0f * (float)i / 128.0f;
			o[i] = lerp(x, std::round(clampf(x, -1.0f, 1.0f) * steps) / steps * out, p(CR_MIX));
		}
		return 129;
	}
	void process(float *L, float *R, int n) override {
		const float bits = p(CR_BITS);
		const float steps = std::pow(2.0f, bits) - 1.0f;
		const float rate = clampf(p(CR_RATE), 200.0f, (float)sr);
		const float inc = rate / (float)sr;
		const float mix = p(CR_MIX), out = db_to_gain(p(CR_OUT));
		for (int s = 0; s < n; s++) {
			phase += inc * (1.0f + rng.bi() * p(CR_JITTER));
			if (phase >= 1.0f) {
				phase -= std::floor(phase);
				hl = std::round(clampf(L[s], -1.0f, 1.0f) * steps) / steps;
				hr = std::round(clampf(R[s], -1.0f, 1.0f) * steps) / steps;
			}
			L[s] = lerp(L[s], hl * out, mix);
			R[s] = lerp(R[s], hr * out, mix);
		}
	}
};
static Plug *make_crush() { return new Crusher(); }

// ===========================================================================
// Utility — gain, pan, width, mono-below, polarity
// ===========================================================================
enum { UT_GAIN, UT_PAN, UT_WIDTH, UT_MONO_BELOW, UT_INVERT_L, UT_INVERT_R, UT_SWAP, UT_COUNT };

class Utility : public Plug {
public:
	Biquad lp_l, lp_r, hp_l, hp_r;
	float vis_l = 0.0f, vis_r = 0.0f, vis_corr = 1.0f;
	// what 0: [peak L, peak R, correlation -1..1]
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 3) return 0;
		o[0] = vis_l; o[1] = vis_r; o[2] = vis_corr;
		return 3;
	}
	void process(float *L, float *R, int n) override {
		const float g = db_to_gain(p(UT_GAIN));
		const float pan = p(UT_PAN);
		const float w = p(UT_WIDTH);
		const float pl = std::cos((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
		const float pr = std::sin((pan * 0.5f + 0.5f) * (float)PI * 0.5f) * 1.41f;
		const bool mb = p(UT_MONO_BELOW) > 21.0f;
		if (mb) {
			lp_l.low_pass(sr, p(UT_MONO_BELOW), 0.707f);
			hp_l.high_pass(sr, p(UT_MONO_BELOW), 0.707f);
			lp_r.b0 = lp_l.b0; lp_r.b1 = lp_l.b1; lp_r.b2 = lp_l.b2; lp_r.a1 = lp_l.a1; lp_r.a2 = lp_l.a2;
			hp_r.b0 = hp_l.b0; hp_r.b1 = hp_l.b1; hp_r.b2 = hp_l.b2; hp_r.a1 = hp_l.a1; hp_r.a2 = hp_l.a2;
		}
		for (int s = 0; s < n; s++) {
			float l = L[s] * (pb(UT_INVERT_L) ? -1.0f : 1.0f);
			float r = R[s] * (pb(UT_INVERT_R) ? -1.0f : 1.0f);
			if (pb(UT_SWAP)) std::swap(l, r);
			if (mb) {
				const float bl = lp_l(l), brr = lp_r(r);
				const float bass = (bl + brr) * 0.5f;
				l = hp_l(l) + bass;
				r = hp_r(r) + bass;
			}
			const float mid = (l + r) * 0.5f, side = (l - r) * 0.5f * w;
			L[s] = (mid + side) * g * pl;
			R[s] = (mid - side) * g * pr;
		}
		float pk_l = 0.0f, pk_r = 0.0f;
		double lr = 0.0, ll = 0.0, rr = 0.0;
		for (int s = 0; s < n; s++) {
			pk_l = std::max(pk_l, std::fabs(L[s]));
			pk_r = std::max(pk_r, std::fabs(R[s]));
			lr += (double)L[s] * R[s];
			ll += (double)L[s] * L[s];
			rr += (double)R[s] * R[s];
		}
		vis_l = std::max(pk_l, vis_l * 0.85f);
		vis_r = std::max(pk_r, vis_r * 0.85f);
		const double denom = std::sqrt(ll * rr);
		// Silence correlates with nothing, so leave the needle where it was.
		if (denom > 1e-9) vis_corr = lerp(vis_corr, (float)(lr / denom), 0.2f);
	}
};
static Plug *make_util() { return new Utility(); }

// ===========================================================================
// Exciter — band-split harmonic generator
// ===========================================================================
enum { EX_FREQ, EX_AMOUNT, EX_HARMONICS, EX_MIX, EX_COUNT };

class Exciter : public Plug {
public:
	Biquad hp_l, hp_r;
	DCBlock d1, d2;
	float vis_added = 0.0f;
	// what 0: [crossover Hz, how much is being added 0..1, odd/even blend]
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 3) return 0;
		o[0] = p(EX_FREQ);
		o[1] = vis_added;
		o[2] = p(EX_HARMONICS);
		return 3;
	}
	void prepare() override { d1.set(sr); d2.set(sr); }
	void process(float *L, float *R, int n) override {
		hp_l.high_pass(sr, p(EX_FREQ), 0.707f);
		hp_r.b0 = hp_l.b0; hp_r.b1 = hp_l.b1; hp_r.b2 = hp_l.b2; hp_r.a1 = hp_l.a1; hp_r.a2 = hp_l.a2;
		const float amt = p(EX_AMOUNT), h = p(EX_HARMONICS), mix = p(EX_MIX);
		for (int s = 0; s < n; s++) {
			const float bl = hp_l(L[s]), br = hp_r(R[s]);
			// Blend even (x^2, asymmetric) and odd (tanh) harmonics.
			const float el = d1(bl * std::fabs(bl) * 2.0f), er = d2(br * std::fabs(br) * 2.0f);
			const float ol = tanh_fast(bl * 4.0f), orr = tanh_fast(br * 4.0f);
			const float add = std::fabs(lerp(el, ol, h)) * amt * mix;
			vis_added = std::max(add, vis_added * 0.9f);
			L[s] = lerp(L[s], L[s] + (lerp(el, ol, h)) * amt, mix);
			R[s] = lerp(R[s], R[s] + (lerp(er, orr, h)) * amt, mix);
		}
	}
};
static Plug *make_exciter() { return new Exciter(); }

// ===========================================================================
// Transient shaper
// ===========================================================================
enum { TR_ATTACK, TR_SUSTAIN, TR_OUT, TR_COUNT };

class Transient : public Plug {
public:
	float fast = 0.0f, slow = 0.0f;
	float vis_gain = 1.0f, vis_diff = 0.0f;
	// what 0: [gain now, fast envelope, slow envelope, onset amount]
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 4) return 0;
		o[0] = vis_gain; o[1] = fast; o[2] = slow; o[3] = vis_diff;
		return 4;
	}
	void process(float *L, float *R, int n) override {
		const float fc = 1.0f - std::exp(-1.0f / (float)(sr * 0.003));
		const float sc = 1.0f - std::exp(-1.0f / (float)(sr * 0.12));
		const float atk = p(TR_ATTACK), sus = p(TR_SUSTAIN);
		const float out = db_to_gain(p(TR_OUT));
		for (int s = 0; s < n; s++) {
			const float x = std::max(std::fabs(L[s]), std::fabs(R[s]));
			fast += (x - fast) * fc;
			slow += (x - slow) * sc;
			const float diff = fast - slow;
			// Positive difference is an onset, negative is the decaying tail.
			float g = 1.0f;
			if (diff > 0.0f) g += diff * atk * 8.0f;
			else g += diff * sus * -8.0f * -1.0f;
			g = clampf(g, 0.05f, 8.0f);
			vis_gain = lerp(vis_gain, g, 0.05f);
			vis_diff = std::max(diff, vis_diff * 0.9f);
			L[s] *= g * out; R[s] *= g * out;
		}
	}
};
static Plug *make_transient() { return new Transient(); }

// ---------------------------------------------------------------------------
void register_effects(std::vector<PlugDesc> &out) {
	std::vector<ParamDesc> eq;
	static const char *bon[EQ_BANDS] = {"b0_on", "b1_on", "b2_on", "b3_on", "b4_on", "b5_on", "b6_on", "b7_on"};
	static const char *bty[EQ_BANDS] = {"b0_type", "b1_type", "b2_type", "b3_type", "b4_type", "b5_type", "b6_type", "b7_type"};
	static const char *bfr[EQ_BANDS] = {"b0_freq", "b1_freq", "b2_freq", "b3_freq", "b4_freq", "b5_freq", "b6_freq", "b7_freq"};
	static const char *bga[EQ_BANDS] = {"b0_gain", "b1_gain", "b2_gain", "b3_gain", "b4_gain", "b5_gain", "b6_gain", "b7_gain"};
	static const char *bq[EQ_BANDS] = {"b0_q", "b1_q", "b2_q", "b3_q", "b4_q", "b5_q", "b6_q", "b7_q"};
	static const char *bgrp[EQ_BANDS] = {"Band 1", "Band 2", "Band 3", "Band 4", "Band 5", "Band 6", "Band 7", "Band 8"};
	static const float bfreq[EQ_BANDS] = {60, 120, 300, 800, 2000, 4500, 9000, 14000};
	static const float btype[EQ_BANDS] = {3, 0, 1, 1, 1, 1, 2, 4};
	static const float bdef_on[EQ_BANDS] = {0, 1, 1, 1, 1, 1, 1, 0};
	for (int b = 0; b < EQ_BANDS; b++) {
		eq.push_back({bon[b], "On", 0, 1, bdef_on[b], P_BOOL, bgrp[b], nullptr, 1});
		eq.push_back({bty[b], "Type", 0, 6, btype[b], P_CHOICE, bgrp[b], "Low Shelf|Bell|High Shelf|High Pass|Low Pass|Notch|Band Pass", 1});
		eq.push_back({bfr[b], "Freq", 20, 20000, bfreq[b], P_HZ, bgrp[b], nullptr, 0.3f});
		eq.push_back({bga[b], "Gain", -24, 24, 0, P_DB, bgrp[b], nullptr, 1});
		eq.push_back({bq[b], "Q", 0.1f, 18, 0.9f, P_Q, bgrp[b], nullptr, 0.4f});
	}
	eq.push_back({"out", "Output", -24, 24, 0, P_DB, "Output", nullptr, 1});
	eq.push_back({"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1});
	eq.push_back({"analyzer", "Analyser", 0, 1, 1, P_BOOL, "Output", nullptr, 1});
	out.push_back({"cd.eq8", "EQ Eight", "Cadmium", "EQ", false, UI_EQ, eq, make_eq});

	out.push_back({"cd.comp", "Compressor", "Cadmium", "Dynamics", false, UI_COMP, {
		{"thresh", "Threshold", -60, 0, -18, P_DB, "Compress", nullptr, 1},
		{"ratio", "Ratio", 1, 20, 4, P_FLOAT, "Compress", nullptr, 0.5f},
		{"attack", "Attack", 0.05f, 200, 8, P_MS, "Compress", nullptr, 0.3f},
		{"release", "Release", 1, 2000, 120, P_MS, "Compress", nullptr, 0.3f},
		{"knee", "Knee", 0, 24, 6, P_DB, "Compress", nullptr, 1},
		{"makeup", "Makeup", -12, 24, 0, P_DB, "Output", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
		{"sc_ext", "Sidechain", 0, 1, 0, P_BOOL, "Detector", nullptr, 1},
		{"sc_hp", "SC High Pass", 20, 2000, 20, P_HZ, "Detector", nullptr, 0.3f},
		{"lookahead", "Lookahead", 0, 15, 0, P_MS, "Detector", nullptr, 1},
		{"auto", "Auto Gain", 0, 1, 0, P_BOOL, "Output", nullptr, 1},
		{"rms", "RMS", 0, 1, 0, P_BOOL, "Detector", nullptr, 1},
	}, make_comp});

	out.push_back({"cd.limiter", "Limiter", "Cadmium", "Dynamics", false, UI_COMP, {
		{"ceiling", "Ceiling", -24, 0, -0.3f, P_DB, "Limit", nullptr, 1},
		{"gain", "Input", -12, 24, 0, P_DB, "Limit", nullptr, 1},
		{"release", "Release", 1, 1000, 80, P_MS, "Limit", nullptr, 0.3f},
		{"lookahead", "Lookahead", 0.5f, 15, 3, P_MS, "Limit", nullptr, 1},
	}, make_limiter});

	out.push_back({"cd.gate", "Gate", "Cadmium", "Dynamics", false, UI_GATEDYN, {
		{"thresh", "Threshold", -80, 0, -40, P_DB, "Gate", nullptr, 1},
		{"range", "Range", -80, 0, -60, P_DB, "Gate", nullptr, 1},
		{"attack", "Attack", 0.05f, 100, 1, P_MS, "Gate", nullptr, 0.3f},
		{"hold", "Hold", 0, 500, 20, P_MS, "Gate", nullptr, 0.3f},
		{"release", "Release", 1, 2000, 100, P_MS, "Gate", nullptr, 0.3f},
		{"hp", "SC High Pass", 20, 2000, 20, P_HZ, "Gate", nullptr, 0.3f},
	}, make_gate});

	out.push_back({"cd.sat", "Saturator", "Cadmium", "Distortion", false, UI_SHAPE, {
		{"drive", "Drive", -12, 36, 6, P_DB, "Drive", nullptr, 1},
		{"mode", "Mode", 0, 5, 0, P_CHOICE, "Drive", "Tube|Soft|Hard|Fold|Sine|Tape", 1},
		{"tone", "Tone", -18, 18, 0, P_DB, "Drive", nullptr, 1},
		{"bias", "Bias", -0.5f, 0.5f, 0, P_FLOAT, "Drive", nullptr, 1},
		{"out", "Output", -24, 12, -3, P_DB, "Output", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
	}, make_sat});

	out.push_back({"cd.crush", "Crusher", "Cadmium", "Distortion", false, UI_SHAPE, {
		{"bits", "Bits", 1, 16, 8, P_FLOAT, "Crush", nullptr, 1},
		{"rate", "Rate", 200, 48000, 12000, P_HZ, "Crush", nullptr, 0.3f},
		{"jitter", "Jitter", 0, 0.5f, 0, P_PCT, "Crush", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
		{"out", "Output", -24, 12, 0, P_DB, "Output", nullptr, 1},
	}, make_crush});

	out.push_back({"cd.utility", "Utility", "Cadmium", "Utility", false, UI_LEVEL, {
		{"gain", "Gain", -60, 24, 0, P_DB, "Level", nullptr, 1},
		{"pan", "Pan", -1, 1, 0, P_FLOAT, "Level", nullptr, 1},
		{"width", "Width", 0, 2, 1, P_PCT, "Stereo", nullptr, 1},
		{"mono_below", "Mono Below", 20, 500, 20, P_HZ, "Stereo", nullptr, 0.3f},
		{"invert_l", "Invert L", 0, 1, 0, P_BOOL, "Stereo", nullptr, 1},
		{"invert_r", "Invert R", 0, 1, 0, P_BOOL, "Stereo", nullptr, 1},
		{"swap", "Swap L/R", 0, 1, 0, P_BOOL, "Stereo", nullptr, 1},
	}, make_util});

	out.push_back({"cd.exciter", "Exciter", "Cadmium", "Distortion", false, UI_EXCITE, {
		{"freq", "Frequency", 500, 12000, 3000, P_HZ, "Excite", nullptr, 0.3f},
		{"amount", "Amount", 0, 2, 0.5f, P_PCT, "Excite", nullptr, 1},
		{"harmonics", "Odd / Even", 0, 1, 0.5f, P_PCT, "Excite", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
	}, make_exciter});

	out.push_back({"cd.transient", "Transient", "Cadmium", "Dynamics", false, UI_TRANSIENT, {
		{"attack", "Attack", -1, 1, 0.3f, P_PCT, "Shape", nullptr, 1},
		{"sustain", "Sustain", -1, 1, 0, P_PCT, "Shape", nullptr, 1},
		{"out", "Output", -24, 12, 0, P_DB, "Output", nullptr, 1},
	}, make_transient});
}

} // namespace cd
