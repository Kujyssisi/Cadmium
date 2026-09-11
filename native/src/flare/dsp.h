// FLARE — DSP primitives.
//
// Everything here is header-only and host-agnostic: the core links against no
// audio framework, so the same objects serve the Cadmium adapter and the VST3
// wrapper without either one owning them.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace flare {

static const float PI_F = 3.14159265358979f;
static const float TWO_PI_F = 6.28318530717959f;

inline float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }
inline float lerpf(float a, float b, float t) { return a + (b - a) * t; }
inline float db_to_gain(float db) { return db <= -90.0f ? 0.0f : std::pow(10.0f, db * 0.05f); }
inline float gain_to_db(float g) { return g <= 1e-6f ? -120.0f : 20.0f * std::log10(g); }
inline float note_to_hz(float n) { return 440.0f * std::pow(2.0f, (n - 69.0f) / 12.0f); }

/// Denormals cost more than the sample is worth. Anything this quiet is zero.
inline float flush(float x) { return std::fabs(x) < 1e-20f ? 0.0f : x; }

inline float soft_clip(float x) {
	if (x <= -1.5f) return -1.0f;
	if (x >= 1.5f) return 1.0f;
	return x - (4.0f / 27.0f) * x * x * x;
}

/// Padé approximant. Within 1e-4 of std::tanh over the range that matters and
/// about eight times quicker, which is what a per-sample saturator needs.
inline float tanh_fast(float x) {
	if (x < -3.0f) return -1.0f;
	if (x > 3.0f) return 1.0f;
	const float x2 = x * x;
	return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

/// A skewed 0..1 map. `skew` < 1 packs resolution at the bottom, which is what
/// a frequency or a time control wants; 1 is linear.
inline float skewed(float t, float skew) {
	return skew == 1.0f ? t : std::pow(clampf(t, 0.0f, 1.0f), 1.0f / skew);
}

// ---------------------------------------------------------------------------
// Noise
// ---------------------------------------------------------------------------
struct Rng {
	uint32_t s = 0x9E3779B9u;
	explicit Rng(uint32_t seed = 0x9E3779B9u) : s(seed ? seed : 1u) {}
	uint32_t next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
	/// -1..1
	float bi() { return (float)(int32_t)next() * (1.0f / 2147483648.0f); }
	/// 0..1
	float uni() { return (float)next() * (1.0f / 4294967296.0f); }
};

/// Voss-McCartney pink noise, seven octaves deep. Cheaper and flatter than a
/// filtered white source, and it does not drift.
struct Pink {
	float rows[7] = {0};
	float running = 0.0f;
	uint32_t counter = 0;
	float next(Rng &r) {
		counter++;
		uint32_t n = counter;
		for (int i = 0; i < 7; i++) {
			if (n & 1u) {
				running -= rows[i];
				rows[i] = r.bi() * 0.25f;
				running += rows[i];
				break;
			}
			n >>= 1;
			if (n == 0) break;
		}
		return running + r.bi() * 0.06f;
	}
};

// ---------------------------------------------------------------------------
// Smoothing
// ---------------------------------------------------------------------------
/// A one-pole ramp towards a target. Every parameter a voice reads per sample
/// goes through one of these, because a knob moved during a note is otherwise
/// a step in the signal and a step is a click.
struct Smoothed {
	float v = 0.0f, target = 0.0f, a = 0.002f;
	void set_time(float ms, double sr) {
		const float n = std::max(1.0f, (float)(ms * 0.001 * sr));
		a = 1.0f - std::exp(-1.0f / n);
	}
	void snap(float x) { v = target = x; }
	void to(float x) { target = x; }
	float next() { v += (target - v) * a; return v; }
	float peek() const { return v; }
};

struct OnePole {
	float z = 0.0f, a = 0.5f;
	void set_hz(float hz, double sr) {
		a = 1.0f - std::exp(-TWO_PI_F * std::max(0.1f, hz) / (float)sr);
	}
	float lp(float x) { z += (x - z) * a; return flush(z); }
	float hp(float x) { return x - lp(x); }
};

struct DCBlock {
	float x1 = 0.0f, y1 = 0.0f;
	float next(float x) {
		const float y = x - x1 + 0.9975f * y1;
		x1 = x; y1 = flush(y);
		return y1;
	}
};

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------
/// Topology-preserving state variable filter (Zavalishin). Stable when the
/// cutoff is modulated at audio rate, which is the whole point: a filter env
/// or an LFO on cutoff blows up a naive biquad.
struct SVF {
	float ic1 = 0.0f, ic2 = 0.0f;
	float g = 0.1f, k = 1.0f, a1 = 0.0f, a2 = 0.0f, a3 = 0.0f;

	void set(float cutoff_hz, float res01, double sr) {
		const float fc = clampf(cutoff_hz, 8.0f, (float)sr * 0.49f);
		g = std::tan(PI_F * fc / (float)sr);
		k = 2.0f - 1.98f * clampf(res01, 0.0f, 1.0f);
		a1 = 1.0f / (1.0f + g * (g + k));
		a2 = g * a1;
		a3 = g * a2;
	}
	void reset() { ic1 = ic2 = 0.0f; }

	/// One pass; every response is a mix of the three taps.
	void tick(float x, float &lp, float &bp, float &hp) {
		const float v3 = x - ic2;
		const float v1 = a1 * ic1 + a2 * v3;
		const float v2 = ic2 + a2 * ic1 + a3 * v3;
		ic1 = flush(2.0f * v1 - ic1);
		ic2 = flush(2.0f * v2 - ic2);
		lp = v2; bp = v1; hp = x - k * v1 - v2;
	}
};

/// Transposed direct form II biquad, for the fixed responses in the FX rack.
struct Biquad {
	float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f, a1 = 0.0f, a2 = 0.0f;
	float z1 = 0.0f, z2 = 0.0f;

	void reset() { z1 = z2 = 0.0f; }
	float next(float x) {
		const float y = b0 * x + z1;
		z1 = flush(b1 * x - a1 * y + z2);
		z2 = flush(b2 * x - a2 * y);
		return y;
	}
	void norm(float B0, float B1, float B2, float A0, float A1, float A2) {
		const float ia = 1.0f / A0;
		b0 = B0 * ia; b1 = B1 * ia; b2 = B2 * ia; a1 = A1 * ia; a2 = A2 * ia;
	}
	void low_shelf(float hz, float db, double sr) {
		const float A = std::pow(10.0f, db / 40.0f);
		const float w = TWO_PI_F * clampf(hz, 10.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn * 0.5f * std::sqrt(2.0f);
		const float t = 2.0f * std::sqrt(A) * al;
		norm(A * ((A + 1) - (A - 1) * cs + t), 2 * A * ((A - 1) - (A + 1) * cs),
				A * ((A + 1) - (A - 1) * cs - t), (A + 1) + (A - 1) * cs + t,
				-2 * ((A - 1) + (A + 1) * cs), (A + 1) + (A - 1) * cs - t);
	}
	void high_shelf(float hz, float db, double sr) {
		const float A = std::pow(10.0f, db / 40.0f);
		const float w = TWO_PI_F * clampf(hz, 10.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn * 0.5f * std::sqrt(2.0f);
		const float t = 2.0f * std::sqrt(A) * al;
		norm(A * ((A + 1) + (A - 1) * cs + t), -2 * A * ((A - 1) + (A + 1) * cs),
				A * ((A + 1) + (A - 1) * cs - t), (A + 1) - (A - 1) * cs + t,
				2 * ((A - 1) - (A + 1) * cs), (A + 1) - (A - 1) * cs - t);
	}
	void peaking(float hz, float db, float q, double sr) {
		const float A = std::pow(10.0f, db / 40.0f);
		const float w = TWO_PI_F * clampf(hz, 10.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn / (2.0f * std::max(0.05f, q));
		norm(1 + al * A, -2 * cs, 1 - al * A, 1 + al / A, -2 * cs, 1 - al / A);
	}
	void high_pass(float hz, float q, double sr) {
		const float w = TWO_PI_F * clampf(hz, 5.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn / (2.0f * std::max(0.05f, q));
		norm((1 + cs) * 0.5f, -(1 + cs), (1 + cs) * 0.5f, 1 + al, -2 * cs, 1 - al);
	}
	void low_pass(float hz, float q, double sr) {
		const float w = TWO_PI_F * clampf(hz, 5.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn / (2.0f * std::max(0.05f, q));
		norm((1 - cs) * 0.5f, 1 - cs, (1 - cs) * 0.5f, 1 + al, -2 * cs, 1 - al);
	}
};

/// Four-pole ladder with the nonlinearity in the feedback path, so pushing the
/// input squashes the resonance the way the original does instead of just
/// getting louder.
struct Ladder {
	float s[4] = {0}, zi = 0.0f;
	float g = 0.1f, k = 0.0f;

	void set(float cutoff_hz, float res01, double sr) {
		const float fc = clampf(cutoff_hz, 8.0f, (float)sr * 0.49f);
		const float wd = TWO_PI_F * fc;
		const float T = 1.0f / (float)sr;
		g = std::tan(wd * T * 0.5f);
		g = g / (1.0f + g);
		k = 4.0f * clampf(res01, 0.0f, 1.0f) * 0.98f;
	}
	void reset() { s[0] = s[1] = s[2] = s[3] = zi = 0.0f; }

	float next(float x, float drive) {
		const float G = g * g * g * g;
		const float S = g * g * g * s[0] + g * g * s[1] + g * s[2] + s[3];
		float u = (x * drive - k * S) / (1.0f + k * G);
		u = tanh_fast(u);
		float y = u;
		for (int i = 0; i < 4; i++) {
			const float v = (y - s[i]) * g;
			y = v + s[i];
			s[i] = flush(y + v);
		}
		return y;
	}
};

// ---------------------------------------------------------------------------
// Envelope
// ---------------------------------------------------------------------------
/// DAHDSR with adjustable segment curves. `curve` runs -1 (logarithmic, fast
/// start) through 0 (linear) to 1 (exponential, slow start); the analogue
/// envelopes people reach for live at either end, not in the middle.
struct Env {
	enum Stage { IDLE, DELAY, ATTACK, HOLD, DECAY, SUSTAIN, RELEASE };
	int stage = IDLE;
	float level = 0.0f, from = 0.0f, pos = 0.0f;
	float delay_s = 0, attack_s = 0.005f, hold_s = 0, decay_s = 0.2f;
	float sustain = 0.7f, release_s = 0.2f;
	float atk_curve = 0.0f, dec_curve = -0.4f, rel_curve = -0.4f;
	bool loop = false;
	double sr = 48000.0;

	void gate_on() { stage = DELAY; pos = 0.0f; from = level; }
	void gate_off() {
		if (stage == IDLE) return;
		stage = RELEASE; pos = 0.0f; from = level;
	}
	void kill() { stage = IDLE; level = 0.0f; }
	bool active() const { return stage != IDLE; }

	static float shape(float t, float c) {
		if (c > 0.001f) return std::pow(t, 1.0f + c * 3.0f);
		if (c < -0.001f) return 1.0f - std::pow(1.0f - t, 1.0f - c * 3.0f);
		return t;
	}

	float next() {
		const float dt = 1.0f / (float)sr;
		switch (stage) {
			case IDLE: level = 0.0f; break;
			case DELAY:
				pos += dt;
				if (pos >= delay_s) { stage = ATTACK; pos = 0.0f; from = level; }
				break;
			case ATTACK: {
				pos += dt;
				const float t = attack_s <= 0.0f ? 1.0f : clampf(pos / attack_s, 0.0f, 1.0f);
				level = from + (1.0f - from) * shape(t, atk_curve);
				if (t >= 1.0f) { stage = HOLD; pos = 0.0f; level = 1.0f; }
				break;
			}
			case HOLD:
				level = 1.0f;
				pos += dt;
				if (pos >= hold_s) { stage = DECAY; pos = 0.0f; from = 1.0f; }
				break;
			case DECAY: {
				pos += dt;
				const float t = decay_s <= 0.0f ? 1.0f : clampf(pos / decay_s, 0.0f, 1.0f);
				level = from + (sustain - from) * shape(t, dec_curve);
				if (t >= 1.0f) {
					level = sustain;
					if (loop) { stage = DELAY; pos = 0.0f; from = level; }
					else stage = SUSTAIN;
				}
				break;
			}
			case SUSTAIN: level = sustain; break;
			case RELEASE: {
				pos += dt;
				const float t = release_s <= 0.0f ? 1.0f : clampf(pos / release_s, 0.0f, 1.0f);
				level = from * (1.0f - shape(t, rel_curve));
				if (t >= 1.0f) { level = 0.0f; stage = IDLE; }
				break;
			}
			default: break;
		}
		return level;
	}
};

// ---------------------------------------------------------------------------
// Delay line
// ---------------------------------------------------------------------------
struct DelayLine {
	float *buf = nullptr;
	int size = 0, w = 0;

	DelayLine() {}
	/// Owns a buffer, so it must not be copied: two of these pointing at one
	/// allocation is a double free the first time a voice array is resized.
	DelayLine(const DelayLine &) = delete;
	DelayLine &operator=(const DelayLine &) = delete;

	void alloc(int n) {
		delete[] buf;
		size = std::max(2, n);
		buf = new float[(size_t)size];
		std::memset(buf, 0, sizeof(float) * (size_t)size);
		w = 0;
	}
	~DelayLine() { delete[] buf; }
	void clear() { if (buf) std::memset(buf, 0, sizeof(float) * (size_t)size); }
	void write(float x) { buf[w] = flush(x); w = (w + 1) % size; }
	float read(float d) const {
		float dd = clampf(d, 1.0f, (float)(size - 2));
		int i = (int)dd;
		const float f = dd - (float)i;
		int a = w - i; while (a < 0) a += size;
		int b = a - 1; while (b < 0) b += size;
		return lerpf(buf[a], buf[b], f);
	}
};

// ---------------------------------------------------------------------------
// Band-limited analogue shapes
// ---------------------------------------------------------------------------
/// The correction a naive saw or square needs at the point it wraps. Without
/// it every analogue oscillator in the plugin aliases audibly above about C5.
inline float poly_blep(float t, float dt) {
	if (t < dt) { t /= dt; return t + t - t * t - 1.0f; }
	if (t > 1.0f - dt) { t = (t - 1.0f) / dt; return t * t + t + t + 1.0f; }
	return 0.0f;
}

} // namespace flare
