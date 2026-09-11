// Cadmium — shared DSP primitives.
//
// Everything here is header-only, allocation-free once constructed and safe to
// call from the audio thread. Anything that needs to allocate does so in
// prepare(), which the engine only calls while the audio thread is stopped or
// holding the structural lock.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace cd {

static constexpr double PI = 3.14159265358979323846;
static constexpr double TAU = 6.28318530717958647692;

inline float flush(float x) {
	// Denormals cost more than the branch does; also kills NaN/Inf leaking out
	// of a misbehaving filter into the mix.
	if (!(x > -1e30f && x < 1e30f)) return 0.0f;
	return (std::fabs(x) < 1e-25f) ? 0.0f : x;
}

inline float db_to_gain(float db) { return db <= -90.0f ? 0.0f : std::pow(10.0f, db * 0.05f); }
inline float gain_to_db(float g) { return g <= 1e-6f ? -120.0f : 20.0f * std::log10(g); }
inline float note_to_hz(float note) { return 440.0f * std::pow(2.0f, (note - 69.0f) / 12.0f); }
inline float hz_to_note(float hz) { return 69.0f + 12.0f * std::log2(std::max(hz, 1e-6f) / 440.0f); }
inline float lerp(float a, float b, float t) { return a + (b - a) * t; }
inline float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }

// Cheap odd-symmetric saturator: unity slope at 0, asymptotic to +/-1.
inline float soft_clip(float x) {
	if (x < -3.0f) return -1.0f;
	if (x > 3.0f) return 1.0f;
	return x * (27.0f + x * x) / (27.0f + 9.0f * x * x);
}

inline float tanh_fast(float x) {
	const float x2 = x * x;
	const float a = x * (135135.0f + x2 * (17325.0f + x2 * (378.0f + x2)));
	const float b = 135135.0f + x2 * (62370.0f + x2 * (3150.0f + x2 * 28.0f));
	return clampf(a / b, -1.0f, 1.0f);
}

// ---------------------------------------------------------------------------
// Random
// ---------------------------------------------------------------------------
struct Rng {
	uint32_t s = 0x9e3779b9u;
	inline uint32_t next() {
		s ^= s << 13; s ^= s >> 17; s ^= s << 5;
		return s;
	}
	inline float uni() { return (next() >> 8) * (1.0f / 16777216.0f); }        // 0..1
	inline float bi() { return uni() * 2.0f - 1.0f; }                          // -1..1
};

// ---------------------------------------------------------------------------
// Parameter smoothing
// ---------------------------------------------------------------------------
struct Smoothed {
	float cur = 0.0f, target = 0.0f, coef = 0.0f;
	void prepare(double sr, float ms = 8.0f) {
		coef = 1.0f - std::exp(-1.0f / (float)(sr * (double)ms * 0.001));
	}
	inline void set(float v) { target = v; }
	inline void snap(float v) { cur = target = v; }
	inline float next() { cur += (target - cur) * coef; return cur; }
	inline bool settled() const { return std::fabs(target - cur) < 1e-6f; }
};

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------
struct OnePole {
	float a = 0.0f, z = 0.0f;
	void set(double sr, float hz) { a = 1.0f - std::exp(-(float)TAU * hz / (float)sr); }
	inline float lp(float x) { z += a * (x - z); return z; }
	inline float hp(float x) { return x - lp(x); }
	void reset() { z = 0.0f; }
};

struct DCBlock {
	float x1 = 0.0f, y1 = 0.0f, r = 0.9975f;
	void set(double sr) { r = 1.0f - (float)(TAU * 12.0 / sr); }
	inline float operator()(float x) {
		float y = x - x1 + r * y1;
		x1 = x; y1 = flush(y);
		return y1;
	}
};

// Topology-preserving state variable filter (Zavalishin / Simper). Stable while
// modulated, which is what a synth needs.
struct SVF {
	float g = 0.1f, k = 1.0f, a1 = 0, a2 = 0, a3 = 0;
	float ic1 = 0.0f, ic2 = 0.0f;
	float lp = 0, bp = 0, hp = 0, notch = 0, peak = 0;

	void set(double sr, float hz, float q) {
		hz = clampf(hz, 8.0f, (float)sr * 0.49f);
		g = std::tan((float)PI * hz / (float)sr);
		k = 1.0f / std::max(q, 0.02f);
		a1 = 1.0f / (1.0f + g * (g + k));
		a2 = g * a1;
		a3 = g * a2;
	}
	inline void process(float x) {
		const float v3 = x - ic2;
		const float v1 = a1 * ic1 + a2 * v3;
		const float v2 = ic2 + a2 * ic1 + a3 * v3;
		ic1 = flush(2.0f * v1 - ic1);
		ic2 = flush(2.0f * v2 - ic2);
		lp = v2; bp = v1; hp = x - k * v1 - v2;
		notch = x - k * v1;
		peak = lp - hp;
	}
	void reset() { ic1 = ic2 = 0.0f; lp = bp = hp = 0.0f; }
};

// Biquad in transposed direct form II, with the RBJ cookbook coefficients the
// EQ needs (peak / shelf / pass).
struct Biquad {
	float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
	float z1 = 0, z2 = 0;

	inline float operator()(float x) {
		const float y = b0 * x + z1;
		z1 = flush(b1 * x - a1 * y + z2);
		z2 = flush(b2 * x - a2 * y);
		return y;
	}
	void reset() { z1 = z2 = 0.0f; }
	void set_raw(float B0, float B1, float B2, float A0, float A1, float A2) {
		const float n = 1.0f / A0;
		b0 = B0 * n; b1 = B1 * n; b2 = B2 * n; a1 = A1 * n; a2 = A2 * n;
	}
	void peaking(double sr, float hz, float q, float gain_db) {
		const float A = std::pow(10.0f, gain_db / 40.0f);
		const float w = (float)TAU * clampf(hz, 10.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn / (2.0f * std::max(q, 0.05f));
		set_raw(1 + al * A, -2 * cs, 1 - al * A, 1 + al / A, -2 * cs, 1 - al / A);
	}
	void low_shelf(double sr, float hz, float q, float gain_db) {
		const float A = std::pow(10.0f, gain_db / 40.0f);
		const float w = (float)TAU * clampf(hz, 10.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn / 2.0f * std::sqrt((A + 1 / A) * (1 / std::max(q, 0.05f) - 1) + 2);
		const float sq = 2.0f * std::sqrt(A) * al;
		set_raw(A * ((A + 1) - (A - 1) * cs + sq), 2 * A * ((A - 1) - (A + 1) * cs),
				A * ((A + 1) - (A - 1) * cs - sq), (A + 1) + (A - 1) * cs + sq,
				-2 * ((A - 1) + (A + 1) * cs), (A + 1) + (A - 1) * cs - sq);
	}
	void high_shelf(double sr, float hz, float q, float gain_db) {
		const float A = std::pow(10.0f, gain_db / 40.0f);
		const float w = (float)TAU * clampf(hz, 10.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn / 2.0f * std::sqrt((A + 1 / A) * (1 / std::max(q, 0.05f) - 1) + 2);
		const float sq = 2.0f * std::sqrt(A) * al;
		set_raw(A * ((A + 1) + (A - 1) * cs + sq), -2 * A * ((A - 1) + (A + 1) * cs),
				A * ((A + 1) + (A - 1) * cs - sq), (A + 1) - (A - 1) * cs + sq,
				2 * ((A - 1) - (A + 1) * cs), (A + 1) - (A - 1) * cs - sq);
	}
	void low_pass(double sr, float hz, float q) {
		const float w = (float)TAU * clampf(hz, 10.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn / (2.0f * std::max(q, 0.05f));
		set_raw((1 - cs) / 2, 1 - cs, (1 - cs) / 2, 1 + al, -2 * cs, 1 - al);
	}
	void high_pass(double sr, float hz, float q) {
		const float w = (float)TAU * clampf(hz, 10.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn / (2.0f * std::max(q, 0.05f));
		set_raw((1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + al, -2 * cs, 1 - al);
	}
	void band_pass(double sr, float hz, float q) {
		const float w = (float)TAU * clampf(hz, 10.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn / (2.0f * std::max(q, 0.05f));
		set_raw(al, 0, -al, 1 + al, -2 * cs, 1 - al);
	}
	void notch(double sr, float hz, float q) {
		const float w = (float)TAU * clampf(hz, 10.0f, (float)sr * 0.49f) / (float)sr;
		const float cs = std::cos(w), sn = std::sin(w);
		const float al = sn / (2.0f * std::max(q, 0.05f));
		set_raw(1, -2 * cs, 1, 1 + al, -2 * cs, 1 - al);
	}
	// |H(w)| for the analyser curve, evaluated on the unit circle.
	float magnitude(double sr, float hz) const {
		const double w = TAU * hz / sr;
		const double cw = std::cos(w), sw = std::sin(w), c2 = std::cos(2 * w), s2 = std::sin(2 * w);
		const double nr = b0 + b1 * cw + b2 * c2, ni = -(b1 * sw + b2 * s2);
		const double dr = 1.0 + a1 * cw + a2 * c2, di = -(a1 * sw + a2 * s2);
		const double n = std::sqrt(nr * nr + ni * ni), d = std::sqrt(dr * dr + di * di);
		return (float)(n / std::max(d, 1e-12));
	}
};

// Four-pole Moog-style ladder with the usual nonlinearity in the feedback path.
struct Ladder {
	float stage[4] = {0, 0, 0, 0};
	float delay[4] = {0, 0, 0, 0};
	float p = 0, k = 0, t1 = 0, t2 = 0, res = 0;
	int mode = 0;   // 0 = LP24, 1 = LP12, 2 = BP, 3 = HP24

	void set(double sr, float hz, float reso) {
		const float f = clampf(hz * 2.0f / (float)sr, 0.0f, 0.98f);
		p = f * (1.8f - 0.8f * f);
		k = 2.0f * std::sin(f * (float)PI * 0.5f) - 1.0f;
		t1 = (1.0f - p) * 1.386f;
		t2 = 12.0f + t1 * t1;
		res = clampf(reso, 0.0f, 1.0f) * 4.0f;
	}
	inline float operator()(float x) {
		const float fb = res * stage[3];
		x = tanh_fast(x - fb * 0.9f);
		stage[0] = x * p + delay[0] * p - k * stage[0];
		stage[1] = stage[0] * p + delay[1] * p - k * stage[1];
		stage[2] = stage[1] * p + delay[2] * p - k * stage[2];
		stage[3] = stage[2] * p + delay[3] * p - k * stage[3];
		stage[3] -= (stage[3] * stage[3] * stage[3]) / 6.0f;
		delay[0] = x; delay[1] = stage[0]; delay[2] = stage[1]; delay[3] = stage[2];
		for (int i = 0; i < 4; i++) { stage[i] = flush(stage[i]); delay[i] = flush(delay[i]); }
		switch (mode) {
			case 1: return stage[1];
			case 2: return stage[3] - stage[1];
			case 3: return x - stage[3];
			default: return stage[3];
		}
	}
	void reset() { for (int i = 0; i < 4; i++) stage[i] = delay[i] = 0.0f; }
};

// ---------------------------------------------------------------------------
// Envelopes and LFOs
// ---------------------------------------------------------------------------
struct ADSR {
	enum Stage { IDLE, ATTACK, DECAY, SUSTAIN, RELEASE };
	Stage stage = IDLE;
	float value = 0.0f, sustain = 0.7f;
	float ac = 0, dc = 0, rc = 0;
	double sr = 48000.0;
	bool exp_curve = true;

	static float rate(double sr, float sec) {
		return 1.0f - std::exp(-1.0f / std::max(1.0f, (float)(sr * std::max(0.0005f, sec))));
	}
	void prepare(double s) { sr = s; }
	void set(float a, float d, float s, float r) {
		ac = rate(sr, a); dc = rate(sr, d); rc = rate(sr, r);
		sustain = clampf(s, 0.0f, 1.0f);
	}
	void gate_on() { stage = ATTACK; }
	void gate_off() { if (stage != IDLE) stage = RELEASE; }
	void kill() { stage = IDLE; value = 0.0f; }
	inline float next() {
		switch (stage) {
			case ATTACK:
				// Aim past 1 so the exponential reaches it in finite time.
				value += (1.24f - value) * ac;
				if (value >= 1.0f) { value = 1.0f; stage = DECAY; }
				break;
			case DECAY:
				value += (sustain - 0.02f - value) * dc;
				if (value <= sustain) { value = sustain; stage = SUSTAIN; }
				break;
			case SUSTAIN: value = sustain; break;
			case RELEASE:
				value += (-0.02f - value) * rc;
				if (value <= 0.0002f) { value = 0.0f; stage = IDLE; }
				break;
			default: value = 0.0f; break;
		}
		return value;
	}
	bool active() const { return stage != IDLE; }
};

struct LFO {
	float phase = 0.0f, inc = 0.0f;
	int shape = 0;   // sine tri saw ramp square s&h noise
	Rng rng;
	float held = 0.0f;

	void set(double sr, float hz) { inc = (float)(hz / sr); }
	void reset(float ph = 0.0f) { phase = ph; }
	inline float next() {
		const float p = phase;
		phase += inc;
		if (phase >= 1.0f) {
			phase -= std::floor(phase);
			held = rng.bi();
		}
		switch (shape) {
			case 1: return 4.0f * std::fabs(p - 0.5f) - 1.0f;
			case 2: return 1.0f - 2.0f * p;
			case 3: return 2.0f * p - 1.0f;
			case 4: return p < 0.5f ? 1.0f : -1.0f;
			case 5: return held;
			case 6: return rng.bi();
			default: return std::sin((float)TAU * p);
		}
	}
};

// ---------------------------------------------------------------------------
// Oscillators
// ---------------------------------------------------------------------------
// PolyBLEP band-limiting: cheap, good to about -60 dB of alias for a saw.
inline float poly_blep(float t, float dt) {
	if (t < dt) { t /= dt; return t + t - t * t - 1.0f; }
	if (t > 1.0f - dt) { t = (t - 1.0f) / dt; return t * t + t + t + 1.0f; }
	return 0.0f;
}

struct Osc {
	float phase = 0.0f;
	float last_tri = 0.0f;
	Rng rng;

	// shape: 0 sine 1 tri 2 saw 3 square 4 pulse(pw) 5 noise
	inline float next(int shape, float inc, float pw = 0.5f) {
		phase += inc;
		if (phase >= 1.0f) phase -= std::floor(phase);
		switch (shape) {
			case 0: return std::sin((float)TAU * phase);
			case 1: {
				float sq = phase < 0.5f ? 1.0f : -1.0f;
				sq += poly_blep(phase, inc);
				float ph2 = phase + 0.5f; if (ph2 >= 1.0f) ph2 -= 1.0f;
				sq -= poly_blep(ph2, inc);
				last_tri = flush(inc * 4.0f * sq + (1.0f - inc * 4.0f) * last_tri);
				return last_tri;
			}
			case 2: return 2.0f * phase - 1.0f - poly_blep(phase, inc);
			case 3: {
				float v = phase < 0.5f ? 1.0f : -1.0f;
				v += poly_blep(phase, inc);
				float ph2 = phase + 0.5f; if (ph2 >= 1.0f) ph2 -= 1.0f;
				v -= poly_blep(ph2, inc);
				return v;
			}
			case 4: {
				pw = clampf(pw, 0.02f, 0.98f);
				float v = phase < pw ? 1.0f : -1.0f;
				v += poly_blep(phase, inc);
				float ph2 = phase + (1.0f - pw); if (ph2 >= 1.0f) ph2 -= 1.0f;
				v -= poly_blep(ph2, inc);
				return v;
			}
			default: return rng.bi();
		}
	}
};

// ---------------------------------------------------------------------------
// Delay lines
// ---------------------------------------------------------------------------
struct Delay {
	std::vector<float> buf;
	int w = 0, mask = 0;

	void prepare(int max_samples) {
		int n = 1;
		while (n < std::max(8, max_samples)) n <<= 1;
		buf.assign((size_t)n, 0.0f);
		mask = n - 1;
		w = 0;
	}
	void clear() { std::fill(buf.begin(), buf.end(), 0.0f); }
	inline void write(float x) { buf[(size_t)w] = flush(x); w = (w + 1) & mask; }
	inline float read_int(int d) const { return buf[(size_t)((w - d) & mask)]; }
	inline float read(float d) const {
		d = clampf(d, 0.0f, (float)mask - 2.0f);
		const int i = (int)d;
		const float f = d - (float)i;
		const float a = buf[(size_t)((w - i) & mask)];
		const float b = buf[(size_t)((w - i - 1) & mask)];
		return a + (b - a) * f;
	}
	// Third-order Hermite, for pitch-shifting reads where linear whistles.
	inline float read_h(float d) const {
		d = clampf(d, 1.0f, (float)mask - 3.0f);
		const int i = (int)d;
		const float f = d - (float)i;
		const float m1 = buf[(size_t)((w - i + 1) & mask)];
		const float p0 = buf[(size_t)((w - i) & mask)];
		const float p1 = buf[(size_t)((w - i - 1) & mask)];
		const float p2 = buf[(size_t)((w - i - 2) & mask)];
		const float c = (p1 - m1) * 0.5f;
		const float v = p0 - p1;
		const float ww = c + v;
		const float a = ww + v + (p2 - p0) * 0.5f;
		const float b = ww + a;
		return ((a * f - b) * f + c) * f + p0;
	}
};

struct Allpass {
	Delay d;
	float g = 0.5f;
	void prepare(int n) { d.prepare(n + 4); len = n; }
	inline float operator()(float x) {
		const float y = d.read_int(len);
		const float v = x + g * y;
		d.write(v);
		return y - g * v;
	}
	int len = 1;
	void clear() { d.clear(); }
};

// ---------------------------------------------------------------------------
// Metering
// ---------------------------------------------------------------------------
struct Meter {
	float peak = 0.0f, rms = 0.0f, decay = 0.9995f, rms_c = 0.0005f;
	void prepare(double sr) {
		decay = std::exp(-1.0f / (float)(sr * 0.35));
		rms_c = 1.0f - std::exp(-1.0f / (float)(sr * 0.06));
	}
	inline void push(float x) {
		const float a = std::fabs(x);
		peak = a > peak ? a : peak * decay;
		rms += (a * a - rms) * rms_c;
	}
	float rms_value() const { return std::sqrt(std::max(0.0f, rms)); }
};

// ---------------------------------------------------------------------------
// FFT (radix-2, in place) — analyser and convolution helper.
// ---------------------------------------------------------------------------
inline void fft(float *re, float *im, int n, bool inverse) {
	for (int i = 1, j = 0; i < n; i++) {
		int bit = n >> 1;
		for (; j & bit; bit >>= 1) j ^= bit;
		j ^= bit;
		if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
	}
	for (int len = 2; len <= n; len <<= 1) {
		const double ang = (inverse ? TAU : -TAU) / len;
		const float wr = (float)std::cos(ang), wi = (float)std::sin(ang);
		for (int i = 0; i < n; i += len) {
			float cr = 1.0f, ci = 0.0f;
			for (int k = 0; k < len / 2; k++) {
				const int a = i + k, b = i + k + len / 2;
				const float xr = re[b] * cr - im[b] * ci;
				const float xi = re[b] * ci + im[b] * cr;
				re[b] = re[a] - xr; im[b] = im[a] - xi;
				re[a] += xr; im[a] += xi;
				const float nr = cr * wr - ci * wi;
				ci = cr * wi + ci * wr; cr = nr;
			}
		}
	}
	if (inverse) {
		const float s = 1.0f / (float)n;
		for (int i = 0; i < n; i++) { re[i] *= s; im[i] *= s; }
	}
}

} // namespace cd
