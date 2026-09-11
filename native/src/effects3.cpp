// Cadmium — a third bank of stock effects, the ones a mix reaches for.
#include "plugin.h"

#include <algorithm>
#include <cmath>

namespace cd {

// ---------------------------------------------------------------------------
// Multiband — three bands, each with its own compressor, split by Linkwitz-
// Riley crossovers so the bands sum back flat when nothing is compressing.
// ---------------------------------------------------------------------------
class Multiband : public Plug {
	enum { P_XLOW, P_XHIGH,
		P_TH1, P_RA1, P_MK1, P_MU1,
		P_TH2, P_RA2, P_MK2, P_MU2,
		P_TH3, P_RA3, P_MK3, P_MU3,
		P_ATK, P_REL, P_KNEE, P_MIX, P_OUT };

	// Two cascaded Butterworth sections per crossover leg is a Linkwitz-Riley
	// of fourth order: flat sum, and the phase matches between bands.
	Biquad lp1[2][2], hp1[2][2], lp2[2][2], hp2[2][2];
	float env[3] = {0, 0, 0};
	float gr[3] = {1, 1, 1};
	float vis_gr[3] = {0, 0, 0};
	float last_low = -1.0f, last_high = -1.0f;

	void set_crossovers(float lo, float hi) {
		if (lo == last_low && hi == last_high) return;
		last_low = lo;
		last_high = hi;
		for (int c = 0; c < 2; c++) {
			for (int s = 0; s < 2; s++) {
				lp1[c][s].low_pass(sr, lo, 0.7071f);
				hp1[c][s].high_pass(sr, lo, 0.7071f);
				lp2[c][s].low_pass(sr, hi, 0.7071f);
				hp2[c][s].high_pass(sr, hi, 0.7071f);
			}
		}
	}

public:
	void prepare() override {
		for (int c = 0; c < 2; c++) {
			for (int s = 0; s < 2; s++) {
				lp1[c][s].reset(); hp1[c][s].reset();
				lp2[c][s].reset(); hp2[c][s].reset();
			}
		}
		last_low = last_high = -1.0f;
		for (int b = 0; b < 3; b++) { env[b] = 0.0f; gr[b] = 1.0f; }
	}
	void reset() override { prepare(); }

	int aux(int what, float *out, int max) override {
		if (what != 0 || max < 3) return 0;
		for (int b = 0; b < 3; b++) out[b] = vis_gr[b];
		return 3;
	}

	void process(float *L, float *R, int n) override {
		const float lo = p(P_XLOW);
		const float hi = std::max(p(P_XHIGH), lo * 1.2f);
		set_crossovers(lo, hi);
		const float th[3] = {p(P_TH1), p(P_TH2), p(P_TH3)};
		const float ra[3] = {p(P_RA1), p(P_RA2), p(P_RA3)};
		const float mk[3] = {db_to_gain(p(P_MK1)), db_to_gain(p(P_MK2)), db_to_gain(p(P_MK3))};
		const bool mute[3] = {pb(P_MU1), pb(P_MU2), pb(P_MU3)};
		const float atk = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.0002f, p(P_ATK) * 0.001f)));
		const float rel = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.005f, p(P_REL) * 0.001f)));
		const float knee = std::max(0.1f, p(P_KNEE));
		const float mix = p(P_MIX);
		const float out_g = db_to_gain(p(P_OUT));
		float peak_gr[3] = {0, 0, 0};

		for (int i = 0; i < n; i++) {
			const float dryL = L[i], dryR = R[i];
			float bl[3], br[3];
			for (int c = 0; c < 2; c++) {
				const float x = c == 0 ? dryL : dryR;
				// Low band, then the rest split again at the high crossover.
				float low = lp1[c][1](lp1[c][0](x));
				float rest = hp1[c][1](hp1[c][0](x));
				float mid = lp2[c][1](lp2[c][0](rest));
				float high = hp2[c][1](hp2[c][0](rest));
				if (c == 0) { bl[0] = low; bl[1] = mid; bl[2] = high; }
				else { br[0] = low; br[1] = mid; br[2] = high; }
			}
			float sumL = 0.0f, sumR = 0.0f;
			for (int b = 0; b < 3; b++) {
				if (mute[b]) continue;
				const float det = std::max(std::fabs(bl[b]), std::fabs(br[b]));
				env[b] += (det - env[b]) * (det > env[b] ? atk : rel);
				const float db = gain_to_db(std::max(env[b], 1e-6f));
				float over = db - th[b];
				float reduce = 0.0f;
				if (over > -knee) {
					// Soft knee: the ratio comes in gradually around threshold.
					if (over < knee) {
						const float t = (over + knee) / (2.0f * knee);
						reduce = (1.0f - 1.0f / ra[b]) * over * t * 0.5f * (over + knee) / std::max(0.01f, over + knee);
						reduce = (1.0f - 1.0f / ra[b]) * (over + knee) * (over + knee) / (4.0f * knee);
					} else {
						reduce = (1.0f - 1.0f / ra[b]) * over;
					}
				}
				const float want = db_to_gain(-std::max(0.0f, reduce));
				gr[b] += (want - gr[b]) * 0.35f;
				peak_gr[b] = std::max(peak_gr[b], 1.0f - gr[b]);
				sumL += bl[b] * gr[b] * mk[b];
				sumR += br[b] * gr[b] * mk[b];
			}
			L[i] = lerp(dryL, sumL * out_g, mix);
			R[i] = lerp(dryR, sumR * out_g, mix);
		}
		for (int b = 0; b < 3; b++) vis_gr[b] = std::max(peak_gr[b], vis_gr[b] * 0.88f);
	}
};

// ---------------------------------------------------------------------------
// Tape — wow, flutter, saturation, head bump and hiss. The movement is what
// makes it sound like tape; the distortion on its own just sounds broken.
// ---------------------------------------------------------------------------
class Tape : public Plug {
	enum { P_DRIVE, P_BIAS, P_WOW, P_FLUTTER, P_WOW_RATE, P_HISS,
		P_BUMP, P_HF, P_WIDTH_LOSS, P_MIX, P_OUT };
	Delay dl, dr;
	float wow_ph = 0.0f, flut_ph = 0.0f, flut2_ph = 0.0f;
	Biquad bump[2], hf[2];
	OnePole hiss_lp[2];
	DCBlock dc[2];
	Rng rng;
	float last_bump = -1.0f, last_hf = -1.0f;
	float vis_offset = 0.0f;

public:
	void prepare() override {
		// Room for the deepest wow the controls allow, plus the nominal delay.
		dl.prepare((int)(sr * 0.05) + 16);
		dr.prepare((int)(sr * 0.05) + 16);
		for (int c = 0; c < 2; c++) { bump[c].reset(); hf[c].reset(); hiss_lp[c].set(sr, 9000.0f); }
		last_bump = last_hf = -1.0f;
	}
	void reset() override { prepare(); }

	int aux(int what, float *out, int max) override {
		if (what != 0 || max < 1) return 0;
		out[0] = vis_offset;
		return 1;
	}

	void process(float *L, float *R, int n) override {
		const float drive = 1.0f + p(P_DRIVE) * 8.0f;
		const float bias = p(P_BIAS);
		const float wow = p(P_WOW);
		const float flut = p(P_FLUTTER);
		const float wow_rate = p(P_WOW_RATE);
		const float hiss = p(P_HISS) * 0.004f;
		const float bump_db = p(P_BUMP);
		const float hf_hz = p(P_HF);
		const float loss = p(P_WIDTH_LOSS);
		const float mix = p(P_MIX);
		const float out_g = db_to_gain(p(P_OUT));

		if (bump_db != last_bump) {
			last_bump = bump_db;
			for (int c = 0; c < 2; c++) bump[c].low_shelf(sr, 90.0f, 0.8f, bump_db);
		}
		if (hf_hz != last_hf) {
			last_hf = hf_hz;
			for (int c = 0; c < 2; c++) hf[c].low_pass(sr, hf_hz, 0.7071f);
		}

		const float base = (float)(sr * 0.012);
		const float wow_inc = wow_rate / (float)sr;
		const float flut_inc = 7.3f / (float)sr;
		const float flut2_inc = 11.7f / (float)sr;

		for (int i = 0; i < n; i++) {
			wow_ph += wow_inc;
			if (wow_ph >= 1.0f) wow_ph -= 1.0f;
			flut_ph += flut_inc;
			if (flut_ph >= 1.0f) flut_ph -= 1.0f;
			flut2_ph += flut2_inc;
			if (flut2_ph >= 1.0f) flut2_ph -= 1.0f;
			// Two flutter rates beating against each other, so it never sounds
			// like a single tremolo.
			const float w = std::sin((float)TAU * wow_ph) * wow * (float)(sr * 0.006);
			const float f = (std::sin((float)TAU * flut_ph) * 0.6f
					+ std::sin((float)TAU * flut2_ph) * 0.4f) * flut * (float)(sr * 0.0006);
			vis_offset = (w + f) / (float)(sr * 0.006 + 1.0);

			const float dryL = L[i], dryR = R[i];
			dl.write(dryL);
			dr.write(dryR);
			float a = dl.read_h(base + w + f);
			float b = dr.read_h(base + w * 0.94f + f * 1.07f);

			// Bias sets how much of the curve's soft shoulder is used.
			a = tanh_fast(a * drive + bias * 0.15f) - tanh_fast(bias * 0.15f);
			b = tanh_fast(b * drive + bias * 0.15f) - tanh_fast(bias * 0.15f);
			a = bump[0](a);
			b = bump[1](b);
			a = hf[0](a);
			b = hf[1](b);
			if (hiss > 0.0f) {
				a += hiss_lp[0].lp(rng.bi()) * hiss;
				b += hiss_lp[1].lp(rng.bi()) * hiss;
			}
			// Tape loses the sides before it loses the middle.
			if (loss > 0.001f) {
				const float m = (a + b) * 0.5f;
				const float s = (a - b) * 0.5f * (1.0f - loss);
				a = m + s;
				b = m - s;
			}
			a = dc[0](a) / drive * (1.0f + p(P_DRIVE) * 2.0f);
			b = dc[1](b) / drive * (1.0f + p(P_DRIVE) * 2.0f);
			L[i] = lerp(dryL, a * out_g, mix);
			R[i] = lerp(dryR, b * out_g, mix);
		}
	}
};

// ---------------------------------------------------------------------------
// Imager — width per band, with the bottom end kept in the middle where it
// belongs, and a goniometer to see what you did.
// ---------------------------------------------------------------------------
class Imager : public Plug {
	enum { P_XOVER, P_LOW_W, P_HIGH_W, P_MONO_HZ, P_ROTATE, P_OUT };
	Biquad lp[2][2], hp[2][2], mono_hp[2], mono_lp[2];
	float last_x = -1.0f, last_mono = -1.0f;
	static const int SCOPE = 256;
	float scope[SCOPE * 2] = {0};
	int scope_w = 0;
	float corr = 0.0f;

public:
	void prepare() override {
		for (int c = 0; c < 2; c++) {
			for (int s = 0; s < 2; s++) { lp[c][s].reset(); hp[c][s].reset(); }
			mono_hp[c].reset();
			mono_lp[c].reset();
		}
		last_x = last_mono = -1.0f;
		scope_w = 0;
	}
	void reset() override { prepare(); }

	int aux(int what, float *out, int max) override {
		if (what == 0) {
			// Newest last, so the panel can draw it as a trail.
			const int n = std::min(max, SCOPE * 2);
			for (int i = 0; i < n; i += 2) {
				const int s = ((scope_w + i / 2) % SCOPE) * 2;
				out[i] = scope[s];
				out[i + 1] = scope[s + 1];
			}
			return n;
		}
		if (what == 1 && max >= 1) { out[0] = corr; return 1; }
		return 0;
	}

	void process(float *L, float *R, int n) override {
		const float x = p(P_XOVER);
		const float mono_hz = p(P_MONO_HZ);
		if (x != last_x) {
			last_x = x;
			for (int c = 0; c < 2; c++) {
				for (int s = 0; s < 2; s++) { lp[c][s].low_pass(sr, x, 0.7071f); hp[c][s].high_pass(sr, x, 0.7071f); }
			}
		}
		if (mono_hz != last_mono) {
			last_mono = mono_hz;
			for (int c = 0; c < 2; c++) { mono_lp[c].low_pass(sr, mono_hz, 0.7071f); mono_hp[c].high_pass(sr, mono_hz, 0.7071f); }
		}
		const float lw = p(P_LOW_W);
		const float hw = p(P_HIGH_W);
		const float rot = p(P_ROTATE) * (float)PI / 180.0f;
		const float cr = std::cos(rot), sn = std::sin(rot);
		const float out_g = db_to_gain(p(P_OUT));
		float sum_lr = 0.0f, sum_ll = 0.0f, sum_rr = 0.0f;

		for (int i = 0; i < n; i++) {
			const float low_l = lp[0][1](lp[0][0](L[i]));
			const float low_r = lp[1][1](lp[1][0](R[i]));
			const float hi_l = hp[0][1](hp[0][0](L[i]));
			const float hi_r = hp[1][1](hp[1][0](R[i]));

			auto widen = [](float l, float r, float w, float &ol, float &orr) {
				const float m = (l + r) * 0.5f;
				const float s = (l - r) * 0.5f * w;
				ol = m + s;
				orr = m - s;
			};
			float ll, lr, hl, hr;
			widen(low_l, low_r, lw, ll, lr);
			widen(hi_l, hi_r, hw, hl, hr);
			float a = ll + hl;
			float b = lr + hr;

			// Below the mono point the sides are folded back to the middle.
			if (mono_hz > 25.0f) {
				const float bl = mono_lp[0](a), br = mono_lp[1](b);
				const float tl = mono_hp[0](a), tr = mono_hp[1](b);
				const float bm = (bl + br) * 0.5f;
				a = bm + tl;
				b = bm + tr;
			}
			// Rotation tilts the whole image without narrowing it.
			const float ra = a * cr - b * sn;
			const float rb = a * sn + b * cr;
			a = ra * out_g;
			b = rb * out_g;

			sum_lr += a * b;
			sum_ll += a * a;
			sum_rr += b * b;
			scope[(size_t)scope_w * 2] = a;
			scope[(size_t)scope_w * 2 + 1] = b;
			scope_w = (scope_w + 1) % SCOPE;
			L[i] = a;
			R[i] = b;
		}
		const float d = std::sqrt(std::max(1e-12f, sum_ll * sum_rr));
		corr = lerp(corr, clampf(sum_lr / d, -1.0f, 1.0f), 0.25f);
	}
};

// ---------------------------------------------------------------------------
// Trance Gate — sixteen steps of level, locked to the tempo. Every step is a
// parameter of its own, so the pattern automates and saves like anything else.
// ---------------------------------------------------------------------------
class Gate16 : public Plug {
	enum { P_S1 = 0, P_STEPS = 16, P_DIV = 16, P_LENGTH, P_SMOOTH, P_SWING,
		P_DEPTH, P_MIX };
	float level = 1.0f;
	double phase = 0.0;      // position within the pattern, 0..steps
	int cur = 0;
	float vis_step = 0.0f;

public:
	void prepare() override { level = 1.0f; phase = 0.0; }
	void reset() override { prepare(); }

	int aux(int what, float *out, int max) override {
		if (what != 0 || max < 1) return 0;
		out[0] = (float)cur;
		if (max >= 2) out[1] = vis_step;
		return max >= 2 ? 2 : 1;
	}

	void process(float *L, float *R, int n) override {
		const int steps = std::max(2, pi(P_LENGTH));
		const float beats = sync_beats(pi(P_DIV));
		const float depth = p(P_DEPTH);
		const float mix = p(P_MIX);
		// Smoothing is a time constant, so short steps still open and close
		// rather than clicking.
		const float sm = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.0004f, p(P_SMOOTH) * 0.001f)));
		const float swing = p(P_SWING);
		const double step_beats = std::max(0.001f, beats);
		const double per_sample = (bpm / 60.0) / sr / step_beats;

		for (int i = 0; i < n; i++) {
			// Locked to the song when it is running, free otherwise.
			if (playing) {
				const double pos = (song_beat + (double)i * (bpm / 60.0) / sr) / step_beats;
				phase = pos;
			} else {
				phase += per_sample;
			}
			double idx = std::fmod(phase, (double)steps);
			if (idx < 0.0) idx += steps;
			// Swing pushes every second step later.
			const int s = (int)idx;
			const double frac = idx - (double)s;
			int use = s;
			if (swing > 0.001f && (s & 1) == 1 && frac < swing * 0.5) use = s - 1;
			cur = std::max(0, std::min(steps - 1, use));
			const float target = p(P_S1 + cur);
			level += (target - level) * sm;
			vis_step = level;
			const float g = 1.0f - depth * (1.0f - level);
			L[i] = lerp(L[i], L[i] * g, mix);
			R[i] = lerp(R[i], R[i] * g, mix);
		}
	}
};

static Plug *make_multiband() { return new Multiband(); }
static Plug *make_tape() { return new Tape(); }
static Plug *make_imager() { return new Imager(); }
static Plug *make_gate16() { return new Gate16(); }

void register_effects3(std::vector<PlugDesc> &out) {
	out.push_back({"cd.multiband", "Multiband", "Cadmium", "Dynamics", false, UI_MULTIBAND, {
		{"x_low", "Low / Mid", 40, 800, 180, P_HZ, "Crossover", nullptr, 0.3f},
		{"x_high", "Mid / High", 800, 12000, 2800, P_HZ, "Crossover", nullptr, 0.3f},
		{"th1", "Threshold", -60, 0, -18, P_DB, "Low", nullptr, 1},
		{"ra1", "Ratio", 1, 20, 3, P_FLOAT, "Low", nullptr, 0.5f},
		{"mk1", "Makeup", -12, 24, 0, P_DB, "Low", nullptr, 1},
		{"mu1", "Mute", 0, 1, 0, P_BOOL, "Low", nullptr, 1},
		{"th2", "Threshold", -60, 0, -16, P_DB, "Mid", nullptr, 1},
		{"ra2", "Ratio", 1, 20, 2.5f, P_FLOAT, "Mid", nullptr, 0.5f},
		{"mk2", "Makeup", -12, 24, 0, P_DB, "Mid", nullptr, 1},
		{"mu2", "Mute", 0, 1, 0, P_BOOL, "Mid", nullptr, 1},
		{"th3", "Threshold", -60, 0, -14, P_DB, "High", nullptr, 1},
		{"ra3", "Ratio", 1, 20, 2, P_FLOAT, "High", nullptr, 0.5f},
		{"mk3", "Makeup", -12, 24, 0, P_DB, "High", nullptr, 1},
		{"mu3", "Mute", 0, 1, 0, P_BOOL, "High", nullptr, 1},
		{"attack", "Attack", 0.1f, 200, 12, P_MS, "Response", nullptr, 0.3f},
		{"release", "Release", 5, 2000, 180, P_MS, "Response", nullptr, 0.3f},
		{"knee", "Knee", 0.1f, 24, 6, P_DB, "Response", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
		{"out", "Output", -24, 24, 0, P_DB, "Output", nullptr, 1},
	}, make_multiband});

	out.push_back({"cd.tape", "Tape", "Cadmium", "Distortion", false, UI_TAPE, {
		{"drive", "Drive", 0, 1, 0.35f, P_PCT, "Tape", nullptr, 1},
		{"bias", "Bias", -1, 1, 0.2f, P_PCT, "Tape", nullptr, 1},
		{"wow", "Wow", 0, 1, 0.3f, P_PCT, "Motion", nullptr, 1},
		{"flutter", "Flutter", 0, 1, 0.25f, P_PCT, "Motion", nullptr, 1},
		{"wow_rate", "Wow Rate", 0.05f, 3, 0.6f, P_HZ, "Motion", nullptr, 0.5f},
		{"hiss", "Hiss", 0, 1, 0.1f, P_PCT, "Tape", nullptr, 1},
		{"bump", "Head Bump", 0, 9, 2.5f, P_DB, "Tone", nullptr, 1},
		{"hf", "HF Roll", 2000, 20000, 12000, P_HZ, "Tone", nullptr, 0.3f},
		{"loss", "Side Loss", 0, 1, 0.12f, P_PCT, "Tone", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
		{"out", "Output", -24, 24, 0, P_DB, "Output", nullptr, 1},
	}, make_tape});

	out.push_back({"cd.imager", "Imager", "Cadmium", "Utility", false, UI_IMAGER, {
		{"xover", "Crossover", 60, 2000, 300, P_HZ, "Bands", nullptr, 0.3f},
		{"low_w", "Low Width", 0, 2, 0.8f, P_PCT, "Bands", nullptr, 1},
		{"high_w", "High Width", 0, 2, 1.3f, P_PCT, "Bands", nullptr, 1},
		{"mono_hz", "Mono Below", 20, 400, 110, P_HZ, "Bands", nullptr, 0.3f},
		{"rotate", "Rotate", -45, 45, 0, P_SEMI, "Image", nullptr, 1},
		{"out", "Output", -24, 24, 0, P_DB, "Output", nullptr, 1},
	}, make_imager});

	std::vector<ParamDesc> gp;
	static const char *STEP_NAMES[16] = {
		"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16"};
	static const char *STEP_IDS[16] = {
		"s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8",
		"s9", "s10", "s11", "s12", "s13", "s14", "s15", "s16"};
	for (int i = 0; i < 16; i++) {
		// A pattern that is something to begin with, rather than all on.
		const float def = (i % 2 == 0) ? 1.0f : ((i % 4 == 1) ? 0.0f : 0.35f);
		gp.push_back({STEP_IDS[i], STEP_NAMES[i], 0, 1, def, P_PCT, "Steps", nullptr, 1});
	}
	gp.push_back({"div", "Step", 0, 12, 3, P_CHOICE, "Timing", SYNC_NAMES, 1});
	gp.push_back({"length", "Length", 2, 16, 16, P_SEMI, "Timing", nullptr, 1});
	gp.push_back({"smooth", "Smooth", 0.4f, 200, 12, P_MS, "Timing", nullptr, 0.3f});
	gp.push_back({"swing", "Swing", 0, 1, 0, P_PCT, "Timing", nullptr, 1});
	gp.push_back({"depth", "Depth", 0, 1, 1, P_PCT, "Output", nullptr, 1});
	gp.push_back({"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1});
	out.push_back({"cd.gate16", "Trance Gate", "Cadmium", "Modulation", false, UI_GATE, gp, make_gate16});
}

} // namespace cd
