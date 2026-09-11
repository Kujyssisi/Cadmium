// Cadmium — the essentials. If a machine had no plugins on it at all, these are
// the ones that would be missed first: something to stop a mix clipping,
// something to take the hiss off a vocal, something to pump a bass under a
// kick, something to look at the spectrum with, and something to tune to.
#include "plugin.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace cd {

// ---------------------------------------------------------------------------
// Clipper — the last thing on a master. Drive into a ceiling, choose how sharp
// the corner is, and oversample so the corner does not fold back down the band.
// ---------------------------------------------------------------------------
class Clipper : public Plug {
	enum { P_DRIVE, P_CEIL, P_MODE, P_OS, P_KNEE, P_MIX, P_AUTO, P_OUT };

	// Two cascaded Butterworth sections either side of the oversampled stage:
	// enough to keep what the clipper makes above the old Nyquist out of the
	// band we care about.
	Biquad up[2][2], down[2][2];
	float last_os_sr = 0.0f;
	float vis_gr = 0.0f;      // how far the loudest sample was pushed back, dB
	float vis_hit = 0.0f;     // share of samples that met the ceiling

	static float shape(float x, int mode, float knee) {
		switch (mode) {
			case 0:   // hard
				return clampf(x, -1.0f, 1.0f);
			case 1: { // soft: a knee that rounds into the ceiling
				const float k = std::max(0.05f, knee);
				const float a = std::fabs(x);
				if (a <= 1.0f - k) return x;
				if (a >= 1.0f + k) return x < 0.0f ? -1.0f : 1.0f;
				const float t = (a - (1.0f - k)) / (2.0f * k);
				const float y = (1.0f - k) + 2.0f * k * (t - t * t * 0.5f) * 0.5f * 2.0f - k * t * t;
				return (x < 0.0f ? -1.0f : 1.0f) * std::min(1.0f, y);
			}
			case 2:   // tanh: no corner at all, just a squeeze
				return tanh_fast(x);
			default: {// sine fold, for the sound rather than the transparency
				const float c = clampf(x, -1.5707963f, 1.5707963f);
				return std::sin(c);
			}
		}
	}

	void set_rates(float os_sr) {
		if (os_sr == last_os_sr) return;
		last_os_sr = os_sr;
		const float corner = (float)sr * 0.47f;
		for (int c = 0; c < 2; c++) {
			for (int s = 0; s < 2; s++) {
				up[c][s].low_pass(os_sr, corner, 0.7071f);
				down[c][s].low_pass(os_sr, corner, 0.7071f);
			}
		}
	}

public:
	void prepare() override {
		for (int c = 0; c < 2; c++)
			for (int s = 0; s < 2; s++) { up[c][s].reset(); down[c][s].reset(); }
		last_os_sr = 0.0f;
		vis_gr = vis_hit = 0.0f;
	}
	void reset() override { prepare(); }

	// what 0: 65 points of the transfer curve, input -1..1 mapped to output.
	// what 1: [gain reduction dB, share of samples at the ceiling].
	int aux(int what, float *o, int max) override {
		if (what == 0) {
			const int N = 65;
			if (max < N) return 0;
			const int mode = pi(P_MODE);
			const float knee = p(P_KNEE);
			const float drive = db_to_gain(p(P_DRIVE));
			for (int i = 0; i < N; i++) {
				const float x = -1.0f + 2.0f * (float)i / (float)(N - 1);
				o[i] = shape(x * drive, mode, knee);
			}
			return N;
		}
		if (what == 1) {
			if (max < 2) return 0;
			o[0] = vis_gr;
			o[1] = vis_hit;
			return 2;
		}
		return 0;
	}

	void process(float *L, float *R, int n) override {
		const int mode = pi(P_MODE);
		const int os = 1 << pi(P_OS);          // 1, 2 or 4
		const float knee = p(P_KNEE);
		const float ceil_g = db_to_gain(p(P_CEIL));
		const float drive = db_to_gain(p(P_DRIVE));
		// With auto on, whatever the drive pushed in comes back out, so the
		// only thing that changes as you turn it is how hard it is clipping.
		const float make = pb(P_AUTO) ? 1.0f / std::max(0.0001f, drive) : 1.0f;
		const float mix = p(P_MIX);
		const float out_g = db_to_gain(p(P_OUT));
		set_rates((float)sr * (float)os);

		float worst = 0.0f;
		int hits = 0;
		for (int i = 0; i < n; i++) {
			float dry[2] = {L[i], R[i]};
			float wet[2];
			for (int c = 0; c < 2; c++) {
				const float in = dry[c] * drive / std::max(1e-4f, ceil_g);
				float acc = 0.0f;
				for (int k = 0; k < os; k++) {
					// Zero stuffing then filtering is the cheap way up; the
					// gain the zeros cost is put back by the os factor.
					float x = (k == 0) ? in * (float)os : 0.0f;
					if (os > 1) { x = up[c][0](x); x = up[c][1](x); }
					float y = shape(x, mode, knee);
					if (std::fabs(x) > 1.0f) {
						hits++;
						worst = std::max(worst, std::fabs(x));
					}
					if (os > 1) { y = down[c][0](y); y = down[c][1](y); }
					// Only the sample that lands on the original grid is kept.
					if (k == 0) acc = y;
				}
				wet[c] = acc * ceil_g * make;
			}
			L[i] = lerp(dry[0], wet[0], mix) * out_g;
			R[i] = lerp(dry[1], wet[1], mix) * out_g;
		}
		const float gr = worst > 1.0f ? gain_to_db(1.0f / worst) : 0.0f;
		vis_gr = std::min(gr, vis_gr * 0.8f);
		vis_hit = std::max((float)hits / (float)std::max(1, n * 2 * os), vis_hit * 0.85f);
	}
};

// ---------------------------------------------------------------------------
// De-Esser — a compressor that only hears the top, and in split mode only
// turns the top down, so the body of the voice is left where it was.
// ---------------------------------------------------------------------------
class DeEsser : public Plug {
	enum { P_FREQ, P_THRESH, P_RANGE, P_ATK, P_REL, P_MODE, P_LISTEN, P_OUT };

	Biquad sc[2];                 // what the detector hears
	Biquad hp[2][2], lp[2][2];    // the split, when splitting
	float env = 0.0f;
	float gr_db = 0.0f;
	float vis_gr = 0.0f, vis_level = -90.0f;
	float last_f = -1.0f;

	void set_freq(float f) {
		if (f == last_f) return;
		last_f = f;
		for (int c = 0; c < 2; c++) {
			// The detector listens through a shelf-like high pass an octave
			// down, so an "s" is well inside it and a vowel is not.
			sc[c].high_pass(sr, std::max(1000.0f, f * 0.85f), 0.7071f);
			for (int s = 0; s < 2; s++) {
				hp[c][s].high_pass(sr, f, 0.7071f);
				lp[c][s].low_pass(sr, f, 0.7071f);
			}
		}
	}

public:
	void prepare() override {
		for (int c = 0; c < 2; c++) {
			sc[c].reset();
			for (int s = 0; s < 2; s++) { hp[c][s].reset(); lp[c][s].reset(); }
		}
		env = 0.0f; gr_db = 0.0f; vis_gr = 0.0f; vis_level = -90.0f;
		last_f = -1.0f;
	}
	void reset() override { prepare(); }

	// what 0: [gain reduction dB, band level dB, crossover Hz, threshold dB]
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 4) return 0;
		o[0] = vis_gr;
		o[1] = vis_level;
		o[2] = p(P_FREQ);
		o[3] = p(P_THRESH);
		return 4;
	}

	void process(float *L, float *R, int n) override {
		const float f = p(P_FREQ);
		set_freq(f);
		const float th = p(P_THRESH);
		const float range = p(P_RANGE);
		const bool split = pi(P_MODE) == 0;
		const bool listen = pb(P_LISTEN);
		const float out_g = db_to_gain(p(P_OUT));
		const float atk = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.0001f, p(P_ATK) * 0.001f)));
		const float rel = 1.0f - std::exp(-1.0f / (float)(sr * std::max(0.002f, p(P_REL) * 0.001f)));
		float worst = 0.0f, loudest = 0.0f;

		for (int i = 0; i < n; i++) {
			const float dl = L[i], dr = R[i];
			// Detector: the loudest of the two sides above the corner.
			const float d = std::max(std::fabs(sc[0](dl)), std::fabs(sc[1](dr)));
			env += (d > env ? atk : rel) * (d - env);
			loudest = std::max(loudest, env);
			const float lvl = gain_to_db(std::max(env, 1e-6f));
			// Straight above the threshold, no ratio to set: how far it may go
			// is the range knob, which is what a de-esser is actually asked.
			float want = 0.0f;
			if (lvl > th) want = -std::min(range, lvl - th);
			gr_db += 0.35f * (want - gr_db);
			const float g = db_to_gain(gr_db);
			worst = std::min(worst, gr_db);

			if (split) {
				float highL = dl, highR = dr, lowL = dl, lowR = dr;
				for (int s = 0; s < 2; s++) {
					highL = hp[0][s](highL); highR = hp[1][s](highR);
					lowL = lp[0][s](lowL);  lowR = lp[1][s](lowR);
				}
				if (listen) {
					L[i] = highL * out_g;
					R[i] = highR * out_g;
				} else {
					L[i] = (lowL + highL * g) * out_g;
					R[i] = (lowR + highR * g) * out_g;
				}
			} else {
				L[i] = (listen ? sc[0](dl) : dl * g) * out_g;
				R[i] = (listen ? sc[1](dr) : dr * g) * out_g;
			}
		}
		vis_gr = worst;
		vis_level = gain_to_db(std::max(loudest, 1e-6f));
	}
};

// ---------------------------------------------------------------------------
// Ducker — the pumping you get from sidechaining a bass to a kick, without
// having to route a kick into it. Either the transport draws the shape or a
// send does.
// ---------------------------------------------------------------------------
class Ducker : public Plug {
	enum { P_MODE, P_DIV, P_DEPTH, P_CURVE, P_HOLD, P_RELEASE, P_SENSE, P_MIX, P_OUT };

	float sc_env = 0.0f;
	float gain = 1.0f;
	float phase = 0.0f;         // 0..1 through the current division
	float vis_pos = 0.0f;

	/// The shape itself: 0 at the start of the division, back up to 1 by the
	/// end of the release. Curve bends how it comes back.
	static float shape_at(float t, float hold, float rel, float curve) {
		if (t < hold) return 0.0f;
		const float u = clampf((t - hold) / std::max(0.001f, rel), 0.0f, 1.0f);
		return std::pow(u, std::max(0.05f, curve));
	}

public:
	bool wants_sidechain() const override { return pi(P_MODE) == 1; }
	void sidechain(const float *L, const float *R, int n) override {
		float peak = 0.0f;
		for (int i = 0; i < n; i++)
			peak = std::max(peak, std::max(std::fabs(L[i]), std::fabs(R[i])));
		sc_env = std::max(peak, sc_env * 0.9f);
	}

	void prepare() override { sc_env = 0.0f; gain = 1.0f; phase = 0.0f; }
	void reset() override { prepare(); }

	// what 0: 64 points of the shape, then where in it we are.
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 65) return 0;
		const float hold = p(P_HOLD);
		const float rel = p(P_RELEASE);
		const float curve = p(P_CURVE);
		const float depth = p(P_DEPTH);
		for (int i = 0; i < 64; i++) {
			const float t = (float)i / 63.0f;
			o[i] = lerp(1.0f, shape_at(t, hold, rel, curve), depth);
		}
		o[64] = vis_pos;
		return 65;
	}

	void process(float *L, float *R, int n) override {
		const bool synced = pi(P_MODE) == 0;
        const float beats = sync_beats(pi(P_DIV));
		const float depth = p(P_DEPTH);
		const float curve = p(P_CURVE);
		const float hold = p(P_HOLD);
		const float rel = p(P_RELEASE);
		const float sense = p(P_SENSE);
		const float mix = p(P_MIX);
		const float out_g = db_to_gain(p(P_OUT));
		const float per_sample = (float)(bpm / 60.0 / sr) / std::max(0.03125f, beats);

		for (int i = 0; i < n; i++) {
			float g;
			if (synced) {
				if (playing) {
					// Locked to the song, so the pump lands on the beat even
					// after a seek.
					const double pos = std::fmod(song_beat / (double)beats, 1.0);
					phase = (float)(pos < 0.0 ? pos + 1.0 : pos);
					song_beat += bpm / 60.0 / sr * 0.0;   // the engine advances it
				}
				phase += per_sample;
				if (phase >= 1.0f) phase -= 1.0f;
				g = lerp(1.0f, shape_at(phase, hold, rel, curve), depth);
				vis_pos = phase;
			} else {
				// Following a send: the envelope of what is coming in decides.
				const float target = clampf(1.0f - sc_env * sense * 4.0f, 0.0f, 1.0f);
				const float duck = lerp(1.0f, target, depth);
				gain += (duck < gain ? 0.4f : 0.002f + rel * 0.0005f) * (duck - gain);
				g = gain;
				vis_pos = 1.0f - g;
			}
			L[i] = lerp(L[i], L[i] * g, mix) * out_g;
			R[i] = lerp(R[i], R[i] * g, mix) * out_g;
			if (pi(P_MODE) == 1) sc_env *= 0.99995f;
		}
	}
};

// ---------------------------------------------------------------------------
// Analyser — what is actually in the signal, on a log axis with a tilt, which
// is the picture everyone is used to reading a mix from. Passes audio through
// untouched.
// ---------------------------------------------------------------------------
class Analyser : public Plug {
	enum { P_SLOPE, P_SPEED, P_FLOOR, P_HOLD, P_CHAN };

	static const int FFT_N = 2048;
	static const int OUT_N = 160;

	float ring[2][FFT_N] = {{0}};
	int ring_w = 0;
	float smooth[OUT_N] = {0};
	float hold[OUT_N] = {0};
	bool warm = false;

public:
	void prepare() override {
		std::memset(ring, 0, sizeof(ring));
		for (int i = 0; i < OUT_N; i++) { smooth[i] = -120.0f; hold[i] = -120.0f; }
		ring_w = 0;
		warm = false;
	}
	void reset() override { prepare(); }

	// what 0: OUT_N bins in dB, log spaced from 20 Hz to 20 kHz.
	// what 1: the same bins, peak held.
	int aux(int what, float *o, int max) override {
		if (what == 1) {
			if (max < OUT_N || p(P_HOLD) < 0.5f) return 0;
			for (int i = 0; i < OUT_N; i++) o[i] = hold[i];
			return OUT_N;
		}
		if (what != 0 || max < OUT_N) return 0;
		static float re[2][FFT_N], im[2][FFT_N];
		const int chans = pi(P_CHAN) == 0 ? 1 : 2;
		const int w = ring_w;
		for (int c = 0; c < chans; c++) {
			for (int i = 0; i < FFT_N; i++) {
				const float win = 0.5f - 0.5f * std::cos(6.2831853f * (float)i / (float)(FFT_N - 1));
				re[c][i] = ring[c][(w + i) & (FFT_N - 1)] * win;
				im[c][i] = 0.0f;
			}
			fft(re[c], im[c], FFT_N, false);
		}
		const float slope = p(P_SLOPE);
		const float floor_db = p(P_FLOOR);
		const float speed = clampf(p(P_SPEED), 0.02f, 1.0f);
		for (int i = 0; i < OUT_N; i++) {
			const float t = (float)i / (float)(OUT_N - 1);
			const float hz = 20.0f * std::pow(1000.0f, t);
			// Each output point takes the loudest bin it covers, so a narrow
			// tone is not lost between two wide points at the top end.
			const float lo_hz = 20.0f * std::pow(1000.0f, std::max(0.0f, t - 0.5f / (OUT_N - 1)));
			const float hi_hz = 20.0f * std::pow(1000.0f, std::min(1.0f, t + 0.5f / (OUT_N - 1)));
			int lo = std::max(1, (int)(lo_hz * FFT_N / (float)sr));
			int hi = std::min(FFT_N / 2 - 1, std::max(lo, (int)(hi_hz * FFT_N / (float)sr)));
			float mag = 0.0f;
			for (int k = lo; k <= hi; k++) {
				for (int c = 0; c < chans; c++) {
					const float m = std::sqrt(re[c][k] * re[c][k] + im[c][k] * im[c][k]);
					mag = std::max(mag, m);
				}
			}
			float db = gain_to_db(mag * (2.0f / FFT_N)) + slope * std::log2(std::max(hz, 20.0f) / 1000.0f);
			db = std::max(db, floor_db);
			if (!warm) smooth[i] = db;
			smooth[i] = smooth[i] + (db > smooth[i] ? 0.9f : speed) * (db - smooth[i]);
			hold[i] = std::max(smooth[i], hold[i] - 0.25f);
			o[i] = smooth[i];
		}
		warm = true;
		return OUT_N;
	}

	void process(float *L, float *R, int n) override {
		const bool mid_side = pi(P_CHAN) == 2;
		for (int i = 0; i < n; i++) {
			if (mid_side) {
				ring[0][ring_w] = (L[i] + R[i]) * 0.5f;
				ring[1][ring_w] = (L[i] - R[i]) * 0.5f;
			} else {
				ring[0][ring_w] = pi(P_CHAN) == 0 ? (L[i] + R[i]) * 0.5f : L[i];
				ring[1][ring_w] = R[i];
			}
			ring_w = (ring_w + 1) & (FFT_N - 1);
		}
	}
	float tail() const override { return 0.0f; }
};

// ---------------------------------------------------------------------------
// Tuner — what note is coming in and how far off it is. Autocorrelation on a
// decimated copy, which is accurate enough for an instrument and cheap enough
// to leave switched on.
// ---------------------------------------------------------------------------
class Tuner : public Plug {
	enum { P_REF, P_TRANS, P_THRU, P_STRICT };

	static const int BUF = 4096;
	float buf[BUF] = {0};
	int w = 0;
	Biquad pre[2];
	float found_hz = 0.0f, found_conf = 0.0f;
	int since = 0;

	void analyse() {
		// Copy oldest-first so the correlation reads a straight window.
		static float x[BUF];
		double mean = 0.0;
		for (int i = 0; i < BUF; i++) {
			x[i] = buf[(w + i) & (BUF - 1)];
			mean += x[i];
		}
		mean /= BUF;
		double energy = 0.0;
		for (int i = 0; i < BUF; i++) {
			x[i] -= (float)mean;
			energy += (double)x[i] * x[i];
		}
		if (energy < 1e-4) { found_conf = std::max(0.0f, found_conf - 0.2f); return; }

		// Difference function over the range a note can be in: 40 Hz to 1.6 kHz.
		const int min_lag = std::max(2, (int)(sr / 1600.0));
		const int max_lag = std::min(BUF / 2, (int)(sr / 40.0));
		float best = 0.0f;
		int best_lag = -1;
		double running = 0.0;
		for (int lag = min_lag; lag < max_lag; lag++) {
			double corr = 0.0, norm = 0.0;
			for (int i = 0; i < BUF - lag; i++) {
				corr += (double)x[i] * x[i + lag];
				norm += (double)x[i + lag] * x[i + lag];
			}
			const float nc = (float)(corr / (std::sqrt(norm * energy) + 1e-12));
			running += nc;
			// The first peak that clears the bar, not the tallest: the tallest
			// is usually an octave down.
			if (nc > 0.86f && nc > best) { best = nc; best_lag = lag; }
			if (best_lag > 0 && lag > best_lag * 2) break;
		}
		if (best_lag < 1) { found_conf = std::max(0.0f, found_conf - 0.2f); return; }
		// Parabolic fit around the peak for a fraction of a sample.
		double c0 = 0.0, c1 = 0.0, c2 = 0.0;
		for (int i = 0; i < BUF - best_lag - 1; i++) {
			c0 += (double)x[i] * x[i + best_lag - 1];
			c1 += (double)x[i] * x[i + best_lag];
			c2 += (double)x[i] * x[i + best_lag + 1];
		}
		const double denom = 2.0 * (2.0 * c1 - c0 - c2);
		const double shift = denom != 0.0 ? (c2 - c0) / denom : 0.0;
		const float lag = (float)best_lag + (float)clampf((float)shift, -1.0f, 1.0f);
		found_hz = (float)sr / std::max(1.0f, lag);
		found_conf = best;
	}

public:
	void prepare() override {
		std::memset(buf, 0, sizeof(buf));
		w = 0; found_hz = 0.0f; found_conf = 0.0f; since = 0;
		for (int c = 0; c < 2; c++) pre[c].low_pass(sr, 2000.0f, 0.7071f);
	}
	void reset() override { prepare(); }

	// what 0: [hz, midi note, cents off, confidence]
	int aux(int what, float *o, int max) override {
		if (what != 0 || max < 4) return 0;
		const float ref = p(P_REF);
		o[0] = found_hz;
		if (found_hz > 20.0f) {
			const float note = 69.0f + 12.0f * std::log2(found_hz / std::max(400.0f, ref))
					- p(P_TRANS);
			const float nearest = std::round(note);
			o[1] = nearest;
			o[2] = (note - nearest) * 100.0f;
		} else {
			o[1] = -1.0f;
			o[2] = 0.0f;
		}
		o[3] = found_conf;
		return 4;
	}

	void process(float *L, float *R, int n) override {
		for (int i = 0; i < n; i++) {
			// Low passed before it is looked at, so a bright string's harmonics
			// do not out-shout the note itself.
			buf[w] = (pre[0](L[i]) + pre[1](R[i])) * 0.5f;
			w = (w + 1) & (BUF - 1);
		}
		since += n;
		// Four times a second is faster than anyone can turn a peg.
		if (since >= (int)(sr / 6.0)) { since = 0; analyse(); }
		if (!pb(P_THRU)) { std::memset(L, 0, sizeof(float) * (size_t)n);
			std::memset(R, 0, sizeof(float) * (size_t)n); }
	}
	float tail() const override { return 0.0f; }
};

// ---------------------------------------------------------------------------
static Plug *make_clipper() { return new Clipper(); }
static Plug *make_deesser() { return new DeEsser(); }
static Plug *make_ducker() { return new Ducker(); }
static Plug *make_analyser() { return new Analyser(); }
static Plug *make_tuner() { return new Tuner(); }

void register_effects4(std::vector<PlugDesc> &out) {
	out.push_back({"cd.clip", "Clipper", "Cadmium", "Dynamics", false, UI_CLIP, {
		{"drive", "Drive", 0, 24, 0, P_DB, "Clip", nullptr, 1},
		{"ceil", "Ceiling", -24, 0, -0.3f, P_DB, "Clip", nullptr, 1},
		{"mode", "Mode", 0, 3, 1, P_CHOICE, "Clip", "Hard|Soft|Tanh|Fold", 1},
		{"os", "Oversample", 0, 2, 1, P_CHOICE, "Clip", "Off|2x|4x", 1},
		{"knee", "Knee", 0.02f, 0.6f, 0.2f, P_PCT, "Clip", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
		{"auto", "Auto Gain", 0, 1, 1, P_BOOL, "Output", nullptr, 1},
		{"out", "Output", -24, 12, 0, P_DB, "Output", nullptr, 1},
	}, make_clipper});

	out.push_back({"cd.deess", "De-Esser", "Cadmium", "Dynamics", false, UI_DEESS, {
		{"freq", "Frequency", 2000, 16000, 6500, P_HZ, "Band", nullptr, 0.35f},
		{"thresh", "Threshold", -60, 0, -28, P_DB, "Band", nullptr, 1},
		{"range", "Range", 0, 24, 8, P_DB, "Band", nullptr, 1},
		{"attack", "Attack", 0.1f, 20, 1.0f, P_MS, "Response", nullptr, 0.35f},
		{"release", "Release", 5, 400, 60, P_MS, "Response", nullptr, 0.35f},
		{"mode", "Mode", 0, 1, 0, P_CHOICE, "Response", "Split|Wide", 1},
		{"listen", "Listen", 0, 1, 0, P_BOOL, "Response", nullptr, 1},
		{"out", "Output", -24, 24, 0, P_DB, "Output", nullptr, 1},
	}, make_deesser});

	out.push_back({"cd.duck", "Ducker", "Cadmium", "Dynamics", false, UI_DUCK, {
		{"mode", "Source", 0, 1, 0, P_CHOICE, "Source", "Tempo|Sidechain", 1},
		{"div", "Every", 0, 12, 7, P_CHOICE, "Source", SYNC_NAMES, 1},
		{"depth", "Depth", 0, 1, 0.85f, P_PCT, "Shape", nullptr, 1},
		{"curve", "Curve", 0.2f, 4, 1.4f, P_FLOAT, "Shape", nullptr, 1},
		{"hold", "Hold", 0, 0.5f, 0.02f, P_PCT, "Shape", nullptr, 1},
		{"release", "Release", 0.05f, 1, 0.55f, P_PCT, "Shape", nullptr, 1},
		{"sense", "Sensitivity", 0.1f, 4, 1, P_FLOAT, "Source", nullptr, 1},
		{"mix", "Mix", 0, 1, 1, P_PCT, "Output", nullptr, 1},
		{"out", "Output", -24, 12, 0, P_DB, "Output", nullptr, 1},
	}, make_ducker});

	out.push_back({"cd.span", "Analyser", "Cadmium", "Utility", false, UI_SPAN, {
		{"slope", "Slope", 0, 6, 4.5f, P_FLOAT, "View", nullptr, 1},
		{"speed", "Speed", 0.02f, 1, 0.25f, P_PCT, "View", nullptr, 1},
		{"floor", "Floor", -120, -40, -96, P_DB, "View", nullptr, 1},
		{"hold", "Peak Hold", 0, 1, 1, P_BOOL, "View", nullptr, 1},
		{"chan", "Channels", 0, 2, 0, P_CHOICE, "View", "Sum|Left+Right|Mid/Side", 1},
	}, make_analyser});

	out.push_back({"cd.tuner", "Tuner", "Cadmium", "Utility", false, UI_TUNER, {
		{"ref", "Reference", 415, 465, 440, P_HZ, "Tuning", nullptr, 1},
		{"trans", "Transpose", -12, 12, 0, P_SEMI, "Tuning", nullptr, 1},
		{"thru", "Pass Audio", 0, 1, 1, P_BOOL, "Tuning", nullptr, 1},
		{"strict", "Fine", 0, 1, 0, P_BOOL, "Tuning", nullptr, 1},
	}, make_tuner});
}

} // namespace cd
