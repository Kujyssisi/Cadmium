// Cadmium — the meters and the amp. Every DAW ships an oscilloscope and a
// loudness meter because you cannot mix without looking at something, and an
// amp because a guitar plugged straight in sounds like a guitar plugged
// straight in.
#include "plugin.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace cd {

// ---------------------------------------------------------------------------
// Oscilloscope — the waveform, held still by a trigger so a note stops sliding
// across the screen. Passes audio through.
// ---------------------------------------------------------------------------
class Oscilloscope : public Plug {
	enum { P_TIME, P_LEVEL, P_TRIG, P_SLOPE, P_MODE, P_FREEZE };

	static const int RING = 16384;
	float ring[2][RING] = {{0}};
	int w = 0;

public:
	void prepare() override { std::memset(ring, 0, sizeof(ring)); w = 0; }
	void reset() override { prepare(); }

	// what 0: 2 * points of L then R, aligned so the trigger sits at the start.
	// what 1: [points, samples per point], so the panel can label the axis.
	int aux(int what, float *o, int max) override {
		const float ms = p(P_TIME);
		const int span = std::max(64, std::min(RING - 8, (int)(sr * ms * 0.001f)));
		const int points = std::min(512, span);
		if (what == 1) {
			if (max < 2) return 0;
			o[0] = (float)points;
			o[1] = (float)span / (float)points;
			return 2;
		}
		if (what != 0 || max < points * 2) return 0;
		// Walk back from the newest sample to the last crossing of the trigger
		// level in the chosen direction, so the picture stands still.
		const float level = p(P_TRIG);
		const bool rising = pi(P_SLOPE) == 0;
		const int mode = pi(P_MODE);
		int start = (w - span + RING) % RING;
		if (p(P_FREEZE) < 0.5f) {
			for (int back = 0; back < RING - span - 2; back++) {
				const int i = (w - span - back + RING * 2) % RING;
				const int prev = (i - 1 + RING) % RING;
				const float a = ring[0][prev], b = ring[0][i];
				if (rising ? (a <= level && b > level) : (a >= level && b < level)) {
					start = i;
					break;
				}
			}
		}
		const float gain = db_to_gain(p(P_LEVEL));
		const float step = (float)span / (float)points;
		for (int i = 0; i < points; i++) {
			const int s = (start + (int)(i * step)) % RING;
			const float l = ring[0][s] * gain;
			const float r = ring[1][s] * gain;
			if (mode == 1) {          // mid / side
				o[i * 2] = (l + r) * 0.5f;
				o[i * 2 + 1] = (l - r) * 0.5f;
			} else {
				o[i * 2] = l;
				o[i * 2 + 1] = r;
			}
		}
		return points * 2;
	}

	void process(float *L, float *R, int n) override {
		for (int i = 0; i < n; i++) {
			ring[0][w] = L[i];
			ring[1][w] = R[i];
			w = (w + 1) % RING;
		}
	}
	float tail() const override { return 0.0f; }
};

// ---------------------------------------------------------------------------
// Loudness — momentary, short term and integrated, to BS.1770: K weighting,
// mean square over a window, gated for the integrated figure. Plus the true
// peak, which is what actually gets a master rejected.
// ---------------------------------------------------------------------------
class Loudness : public Plug {
	enum { P_TARGET, P_RESET };

	Biquad shelf[2], hp[2];
	// Four hundred milliseconds of block sums at 100 ms a piece: the momentary
	// window is four of them, the short term thirty.
	static const int BLOCKS = 300;
	double block_sum[2] = {0, 0};
	int block_n = 0;
	float blocks[BLOCKS] = {0};
	int bw = 0, filled = 0;
	double gate_sum = 0.0;
	int gate_n = 0;
	float peak = 0.0f;
	float last_reset = 0.0f;

	static float loud(double mean_square) {
		return mean_square <= 1e-12 ? -100.0f
				: -0.691f + 10.0f * (float)std::log10(mean_square);
	}
	float window(int n) const {
		double sum = 0.0;
		int have = std::min(filled, n);
		if (have < 1) return -100.0f;
		for (int i = 0; i < have; i++) sum += blocks[(bw - 1 - i + BLOCKS * 2) % BLOCKS];
		return loud(sum / (double)have);
	}

public:
	void prepare() override {
		for (int c = 0; c < 2; c++) {
			// The K weighting: a head shelf and a high pass, as the standard says.
			shelf[c].high_shelf(sr, 1500.0f, 0.707f, 4.0f);
			hp[c].high_pass(sr, 38.0f, 0.5f);
		}
		block_sum[0] = block_sum[1] = 0.0;
		block_n = 0; bw = 0; filled = 0;
		gate_sum = 0.0; gate_n = 0; peak = 0.0f;
		std::memset(blocks, 0, sizeof(blocks));
	}
	void reset() override { prepare(); }

	// what 0: [momentary, short term, integrated, true peak dB, target]
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 5) return 0;
		o[0] = window(4);
		o[1] = window(30);
		o[2] = gate_n > 0 ? loud(gate_sum / (double)gate_n) : -100.0f;
		o[3] = gain_to_db(std::max(peak, 1e-6f));
		o[4] = p(P_TARGET);
		return 5;
	}

	void process(float *L, float *R, int n) override {
		if (p(P_RESET) > 0.5f && last_reset < 0.5f) prepare();
		last_reset = p(P_RESET);
		const int per = std::max(1, (int)(sr * 0.1));
		for (int i = 0; i < n; i++) {
			peak = std::max(peak, std::max(std::fabs(L[i]), std::fabs(R[i])));
			const float kl = hp[0](shelf[0](L[i]));
			const float kr = hp[1](shelf[1](R[i]));
			block_sum[0] += (double)kl * kl;
			block_sum[1] += (double)kr * kr;
			if (++block_n >= per) {
				const float ms = (float)((block_sum[0] + block_sum[1]) / (double)per);
				blocks[bw] = ms;
				bw = (bw + 1) % BLOCKS;
				if (filled < BLOCKS) filled++;
				// The absolute gate: quiet blocks do not count towards the
				// integrated figure, or a fade-in would drag it down forever.
				if (loud(ms) > -70.0f) { gate_sum += ms; gate_n++; }
				block_sum[0] = block_sum[1] = 0.0;
				block_n = 0;
			}
		}
		peak *= 0.9999f;
	}
	float tail() const override { return 0.0f; }
};

// ---------------------------------------------------------------------------
// Amp — a guitar amplifier: the three-knob tone stack everyone knows, a
// preamp that clips like a valve, and a cabinet at the end, because an amp
// without one sounds like a fuzz pedal in a bucket.
// ---------------------------------------------------------------------------
class Amp : public Plug {
	enum { P_GAIN, P_BASS, P_MID, P_TREBLE, P_PRESENCE, P_MODEL,
		P_CAB, P_MASTER, P_MIX };

	Biquad bass[2], mid[2], treble[2], presence[2];
	Biquad cab_lp[2][2], cab_hp[2], cab_peak[2];
	DCBlock dc[2];
	float last[6] = {-1, -1, -1, -1, -1, -1};

	static float stage(int model, float x) {
		switch (model) {
			case 0:   // clean: barely anything until it is pushed hard
				return tanh_fast(x * 0.8f);
			case 1: { // crunch: asymmetric, so it makes even harmonics
				const float y = tanh_fast(x);
				return y + 0.15f * y * y;
			}
			default: {// lead: two stages, which is where the sustain comes from
				const float a = tanh_fast(x * 1.6f);
				return tanh_fast(a * 1.4f);
			}
		}
	}
	void set_tone(float b, float m, float t, float pres, int cab) {
		const float now[6] = {b, m, t, pres, (float)cab, 0.0f};
		bool same = true;
		for (int i = 0; i < 5; i++) if (now[i] != last[i]) same = false;
		if (same) return;
		for (int i = 0; i < 5; i++) last[i] = now[i];
		for (int c = 0; c < 2; c++) {
			bass[c].low_shelf(sr, 120.0f, 0.707f, b);
			mid[c].peaking(sr, 650.0f, 0.9f, m);
			treble[c].high_shelf(sr, 3000.0f, 0.707f, t);
			presence[c].peaking(sr, 4500.0f, 1.2f, pres);
			// Three cabinets, as three different corners and a resonance.
			const float corner = cab == 0 ? 5000.0f : (cab == 1 ? 4000.0f : 6500.0f);
			const float bump = cab == 0 ? 100.0f : (cab == 1 ? 85.0f : 140.0f);
			for (int s = 0; s < 2; s++) cab_lp[c][s].low_pass(sr, corner, 0.707f);
			cab_hp[c].high_pass(sr, bump, 0.8f);
			cab_peak[c].peaking(sr, cab == 2 ? 2200.0f : 1400.0f, 1.4f, 3.0f);
		}
	}

public:
	void prepare() override {
		for (int c = 0; c < 2; c++) {
			bass[c].reset(); mid[c].reset(); treble[c].reset(); presence[c].reset();
			cab_hp[c].reset(); cab_peak[c].reset();
			for (int s = 0; s < 2; s++) cab_lp[c][s].reset();
			dc[c].set(sr);
		}
		for (int i = 0; i < 6; i++) last[i] = -1.0f;
	}
	void reset() override { prepare(); }

	// what 0: 65 points of the tone stack's response in dB, 20 Hz to 20 kHz.
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 65) return 0;
		const bool cab_on = pi(P_CAB) < 3;
		for (int i = 0; i < 65; i++) {
			const float hz = 20.0f * std::pow(1000.0f, (float)i / 64.0f);
			float mag = bass[0].magnitude(sr, hz) * mid[0].magnitude(sr, hz)
					* treble[0].magnitude(sr, hz) * presence[0].magnitude(sr, hz);
			if (cab_on) {
				mag *= cab_lp[0][0].magnitude(sr, hz) * cab_lp[0][1].magnitude(sr, hz)
						* cab_hp[0].magnitude(sr, hz) * cab_peak[0].magnitude(sr, hz);
			}
			o[i] = gain_to_db(mag);
		}
		return 65;
	}

	void process(float *L, float *R, int n) override {
		const float drive = db_to_gain(p(P_GAIN));
		const int model = pi(P_MODEL);
		const int cab = pi(P_CAB);
		const float master = db_to_gain(p(P_MASTER));
		const float mix = p(P_MIX);
		set_tone(p(P_BASS), p(P_MID), p(P_TREBLE), p(P_PRESENCE), cab);
		for (int i = 0; i < n; i++) {
			float in[2] = {L[i], R[i]};
			for (int c = 0; c < 2; c++) {
				float x = stage(model, in[c] * drive);
				x = presence[c](treble[c](mid[c](bass[c](x))));
				if (cab < 3) {
					x = cab_peak[c](cab_hp[c](cab_lp[c][1](cab_lp[c][0](x))));
				}
				x = dc[c](x) * master;
				(c == 0 ? L : R)[i] = lerp(in[c], x, mix);
			}
		}
	}
};

// ---------------------------------------------------------------------------
static Plug *make_scope() { return new Oscilloscope(); }
static Plug *make_loud() { return new Loudness(); }
static Plug *make_amp() { return new Amp(); }

void register_effects5(std::vector<PlugDesc> &out) {
	out.push_back({"cd.osc", "Oscilloscope", "Cadmium", "Utility", false, UI_OSC, {
		{"time", "Time", 1, 200, 20, P_MS, "View", nullptr, 0.35f},
		{"level", "Gain", -24, 36, 0, P_DB, "View", nullptr, 1},
		{"trig", "Trigger", -1, 1, 0, P_FLOAT, "Trigger", nullptr, 1},
		{"slope", "Slope", 0, 1, 0, P_CHOICE, "Trigger", "Rising|Falling", 1},
		{"mode", "Channels", 0, 1, 0, P_CHOICE, "View", "Left/Right|Mid/Side", 1},
		{"freeze", "Free Run", 0, 1, 0, P_BOOL, "Trigger", nullptr, 1},
	}, make_scope});

	out.push_back({"cd.loud", "Loudness", "Cadmium", "Utility", false, UI_LOUD, {
		{"target", "Target", -30, -6, -14, P_DB, "Meter", nullptr, 1},
		{"reset", "Reset", 0, 1, 0, P_BOOL, "Meter", nullptr, 1},
	}, make_loud});

	out.push_back({"cd.amp", "Amp", "Cadmium", "Distortion", false, UI_AMP, {
		{"gain", "Gain", 0, 40, 14, P_DB, "Amp", nullptr, 1},
		{"model", "Model", 0, 2, 1, P_CHOICE, "Amp", "Clean|Crunch|Lead", 1},
		{"bass", "Bass", -12, 12, 2, P_DB, "Tone", nullptr, 1},
		{"mid", "Mid", -12, 12, -2, P_DB, "Tone", nullptr, 1},
		{"treble", "Treble", -12, 12, 3, P_DB, "Tone", nullptr, 1},
		{"presence", "Presence", -6, 12, 2, P_DB, "Tone", nullptr, 1},
		{"cab", "Cabinet", 0, 3, 0, P_CHOICE, "Cabinet", "4x12|1x12|2x12|Off", 1},
		{"master", "Master", -36, 6, -12, P_DB, "Output", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
	}, make_amp});
}

} // namespace cd
