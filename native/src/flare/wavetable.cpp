// FLARE — wavetable construction and lookup.
#include "wavetable.h"

#include "dsp.h"
#include "wav.h"

#include <cmath>
#include <cstring>

namespace flare {

namespace {

/// In-place radix-2 FFT. Only used while building tables, never per sample.
void fft(std::vector<float> &re, std::vector<float> &im, bool inverse) {
	const int n = (int)re.size();
	for (int i = 1, j = 0; i < n; i++) {
		int bit = n >> 1;
		for (; j & bit; bit >>= 1) j ^= bit;
		j ^= bit;
		if (i < j) { std::swap(re[(size_t)i], re[(size_t)j]); std::swap(im[(size_t)i], im[(size_t)j]); }
	}
	for (int len = 2; len <= n; len <<= 1) {
		const float ang = 2.0f * PI_F / (float)len * (inverse ? 1.0f : -1.0f);
		const float wr = std::cos(ang), wi = std::sin(ang);
		for (int i = 0; i < n; i += len) {
			float cr = 1.0f, ci = 0.0f;
			for (int k = 0; k < len / 2; k++) {
				const int a = i + k, b = i + k + len / 2;
				const float xr = re[(size_t)b] * cr - im[(size_t)b] * ci;
				const float xi = re[(size_t)b] * ci + im[(size_t)b] * cr;
				re[(size_t)b] = re[(size_t)a] - xr;
				im[(size_t)b] = im[(size_t)a] - xi;
				re[(size_t)a] += xr;
				im[(size_t)a] += xi;
				const float ncr = cr * wr - ci * wi;
				ci = cr * wi + ci * wr;
				cr = ncr;
			}
		}
	}
	if (inverse) {
		for (int i = 0; i < n; i++) { re[(size_t)i] /= (float)n; im[(size_t)i] /= (float)n; }
	}
}

void normalise(std::vector<float> &v) {
	float peak = 0.0f;
	for (float x : v) peak = std::max(peak, std::fabs(x));
	if (peak < 1e-9f) return;
	const float g = 1.0f / peak;
	for (float &x : v) x *= g;
}

} // namespace

void build_frame(WaveFrame &f, const std::vector<float> &harm, const std::vector<float> &phases) {
	for (int k = 0; k < WT_MIPS; k++) {
		const int n = wt_mip_size(k);
		const int limit = wt_mip_harmonics(k);
		std::vector<float> out((size_t)n, 0.0f);
		for (int h = 0; h < (int)harm.size() && h < limit; h++) {
			const float a = harm[(size_t)h];
			if (std::fabs(a) < 1e-6f) continue;
			const float ph = h < (int)phases.size() ? phases[(size_t)h] : 0.0f;
			const float w = TWO_PI_F * (float)(h + 1) / (float)n;
			for (int i = 0; i < n; i++) out[(size_t)i] += a * std::sin(w * (float)i + ph);
		}
		normalise(out);
		f.mip[k].swap(out);
	}
}

void build_frame_from_cycle(WaveFrame &f, const float *cycle, int n) {
	// Resample the cycle up to WT_SIZE, then take its spectrum once and cut it
	// back for each mipmap. Doing it in the frequency domain is what makes the
	// small mipmaps free of the harmonics they cannot hold.
	std::vector<float> re((size_t)WT_SIZE), im((size_t)WT_SIZE, 0.0f);
	for (int i = 0; i < WT_SIZE; i++) {
		const float t = (float)i * (float)n / (float)WT_SIZE;
		const int a = (int)t % n;
		const int b = (a + 1) % n;
		re[(size_t)i] = lerpf(cycle[a], cycle[b], t - std::floor(t));
	}
	fft(re, im, false);
	// Kill DC: a table with an offset makes every note thump when it starts.
	re[0] = im[0] = 0.0f;
	const std::vector<float> re0 = re, im0 = im;

	for (int k = 0; k < WT_MIPS; k++) {
		const int n2 = wt_mip_size(k);
		const int limit = wt_mip_harmonics(k);
		std::vector<float> r = re0, i2 = im0;
		for (int h = limit + 1; h < WT_SIZE - limit; h++) { r[(size_t)h] = 0.0f; i2[(size_t)h] = 0.0f; }
		fft(r, i2, true);
		std::vector<float> out((size_t)n2);
		const int stride = WT_SIZE / n2;
		for (int s = 0; s < n2; s++) out[(size_t)s] = r[(size_t)(s * stride)];
		normalise(out);
		f.mip[k].swap(out);
	}
}

float WaveTable::read_frame(int frame, float phase, int mip) const {
	if (frames.empty()) return 0.0f;
	const int fi = frame < 0 ? 0 : (frame >= (int)frames.size() ? (int)frames.size() - 1 : frame);
	const int k = mip < 0 ? 0 : (mip >= WT_MIPS ? WT_MIPS - 1 : mip);
	const std::vector<float> &m = frames[(size_t)fi].mip[k];
	const int n = (int)m.size();
	if (n < 4) return 0.0f;
	const int mask = n - 1;
	float p = phase - std::floor(phase);
	const float x = p * (float)n;
	const int i = (int)x;
	const float t = x - (float)i;
	// Catmull-Rom. Two taps is not enough: the error a linear read makes on a
	// table whose top harmonic is a decent fraction of its length is
	// distortion, and it lands right where the band limiting was supposed to
	// have cleaned up.
	const float y0 = m[(size_t)((i - 1) & mask)];
	const float y1 = m[(size_t)(i & mask)];
	const float y2 = m[(size_t)((i + 1) & mask)];
	const float y3 = m[(size_t)((i + 2) & mask)];
	const float a = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
	const float b = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
	const float c = 0.5f * (y2 - y0);
	return ((a * t + b) * t + c) * t + y1;
}

float WaveTable::read(float pos, float phase, int mip) const {
	if (frames.empty()) return 0.0f;
	if (frames.size() == 1) return read_frame(0, phase, mip);
	const float fp = clampf(pos, 0.0f, 1.0f) * (float)(frames.size() - 1);
	const int a = (int)fp;
	const int b = std::min(a + 1, (int)frames.size() - 1);
	const float t = fp - (float)a;
	if (t < 1e-5f) return read_frame(a, phase, mip);
	return lerpf(read_frame(a, phase, mip), read_frame(b, phase, mip), t);
}

int mip_for(float hz, double sr) {
	// Mipmap k holds harmonics up to (WT_SIZE >> k) / 2. Pick the first one
	// whose top harmonic still lands under Nyquist.
	const float nyq = (float)sr * 0.5f;
	const float f = std::max(1.0f, std::fabs(hz));
	const float allowed = nyq / f;      // how many harmonics fit
	for (int k = 0; k < WT_MIPS; k++) {
		if ((float)((WT_SIZE >> k) / 2) <= allowed) return k;
	}
	return WT_MIPS - 1;
}

// ---------------------------------------------------------------------------
// The built-in bank
// ---------------------------------------------------------------------------
namespace {

using H = std::vector<float>;

H harm_sine() { H h(1); h[0] = 1.0f; return h; }
H harm_saw(int n = 512) {
	H h((size_t)n);
	for (int i = 0; i < n; i++) h[(size_t)i] = 1.0f / (float)(i + 1);
	return h;
}
H harm_square(int n = 512) {
	H h((size_t)n, 0.0f);
	for (int i = 0; i < n; i += 2) h[(size_t)i] = 1.0f / (float)(i + 1);
	return h;
}
H harm_tri(int n = 512) {
	H h((size_t)n, 0.0f);
	for (int i = 0; i < n; i += 2) {
		h[(size_t)i] = 1.0f / (float)((i + 1) * (i + 1));
		if ((i / 2) & 1) h[(size_t)i] = -h[(size_t)i];
	}
	return h;
}
H harm_pulse(float duty, int n = 512) {
	H h((size_t)n);
	for (int i = 0; i < n; i++) {
		const float k = (float)(i + 1);
		h[(size_t)i] = std::sin(PI_F * k * duty) / k;
	}
	return h;
}
/// A saw with only every `step`th harmonic, which is what the hollow, reedy
/// and organ-like shapes all are underneath.
H harm_every(int step, int n = 512, float tilt = 1.0f) {
	H h((size_t)n, 0.0f);
	for (int i = 0; i < n; i += step) h[(size_t)i] = std::pow(1.0f / (float)(i + 1), tilt);
	return h;
}

WaveTable single(const char *name, const H &h, const std::vector<float> &ph = {}) {
	WaveTable t;
	t.name = name;
	t.frames.resize(1);
	build_frame(t.frames[0], h, ph);
	return t;
}

/// A morph between recipes: `n` frames interpolated between the given corners.
WaveTable morph(const char *name, const std::vector<H> &corners, int n) {
	WaveTable t;
	t.name = name;
	t.frames.resize((size_t)n);
	size_t hn = 0;
	for (const H &c : corners) hn = std::max(hn, c.size());
	for (int f = 0; f < n; f++) {
		const float u = n == 1 ? 0.0f : (float)f / (float)(n - 1) * (float)(corners.size() - 1);
		const int a = std::min((int)u, (int)corners.size() - 1);
		const int b = std::min(a + 1, (int)corners.size() - 1);
		const float m = u - (float)a;
		H h(hn, 0.0f);
		for (size_t i = 0; i < hn; i++) {
			const float ha = i < corners[(size_t)a].size() ? corners[(size_t)a][i] : 0.0f;
			const float hb = i < corners[(size_t)b].size() ? corners[(size_t)b][i] : 0.0f;
			h[i] = lerpf(ha, hb, m);
		}
		build_frame(t.frames[(size_t)f], h);
	}
	return t;
}

/// Harmonics shaped by a formant: a bump in the spectrum at `centre` (as a
/// harmonic number) of the given width. This is what makes the vocal and
/// vowel tables sound like anything at all.
H harm_formant(float centre, float width, int n = 512, float tilt = 1.0f) {
	H h((size_t)n);
	for (int i = 0; i < n; i++) {
		const float k = (float)(i + 1);
		const float d = (k - centre) / width;
		h[(size_t)i] = std::exp(-d * d) * std::pow(1.0f / k, tilt * 0.5f);
	}
	return h;
}

H harm_add(const H &a, const H &b, float ga = 1.0f, float gb = 1.0f) {
	H h(std::max(a.size(), b.size()), 0.0f);
	for (size_t i = 0; i < h.size(); i++) {
		if (i < a.size()) h[i] += a[i] * ga;
		if (i < b.size()) h[i] += b[i] * gb;
	}
	return h;
}

/// Inharmonic partials, for bells and metal.
H harm_partials(const std::vector<std::pair<float, float>> &p, int n = 512) {
	H h((size_t)n, 0.0f);
	for (const auto &pp : p) {
		const int i = (int)std::lround(pp.first) - 1;
		if (i >= 0 && i < n) h[(size_t)i] += pp.second;
	}
	return h;
}

} // namespace

WaveBank::WaveBank() {
	// --- Analogue shapes, in the order the "Wave" choice list names them.
	analog_.push_back(single("Sine", harm_sine()));
	analog_.push_back(single("Triangle", harm_tri()));
	analog_.push_back(single("Saw", harm_saw()));
	analog_.push_back(single("Square", harm_square()));
	analog_.push_back(single("Pulse 25", harm_pulse(0.25f)));
	analog_.push_back(single("Pulse 12", harm_pulse(0.125f)));
	{
		// Seven detuned saws folded into one cycle: the same interference the
		// classic supersaw gets from seven oscillators, for the cost of one.
		H h(512, 0.0f);
		for (int i = 0; i < 512; i++) {
			const float k = (float)(i + 1);
			float a = 1.0f / k;
			a *= 1.0f + 0.55f * std::cos(k * 0.37f) + 0.25f * std::cos(k * 1.13f);
			h[(size_t)i] = a;
		}
		analog_.push_back(single("Super Saw", h));
	}
	{
		H h = harm_square();
		for (int i = 0; i < (int)h.size(); i++)
			h[(size_t)i] *= 1.0f + 0.5f * std::cos((float)(i + 1) * 0.61f);
		analog_.push_back(single("Super Square", h));
	}
	analog_.push_back(single("Double Saw", harm_add(harm_saw(), harm_every(2, 512, 1.0f), 1.0f, 0.7f)));
	analog_.push_back(single("Half Saw", harm_every(1, 256, 1.4f)));
	analog_.push_back(single("Trapezoid", harm_pulse(0.42f, 96)));
	{
		H h(512);
		for (int i = 0; i < 512; i++) h[(size_t)i] = std::exp(-(float)i * 0.045f);
		analog_.push_back(single("Exponential", h));
	}
	{
		H h(512);
		for (int i = 0; i < 512; i++) h[(size_t)i] = 1.0f / std::pow((float)(i + 1), 1.35f);
		analog_.push_back(single("Log Saw", h));
	}
	analog_.push_back(single("Rounded Square", harm_square(24)));
	{
		H h(4, 0.0f); h[0] = 1.0f; h[1] = 0.55f;
		analog_.push_back(single("Sine x2", h));
	}
	{
		H h(6, 0.0f); h[0] = 1.0f; h[1] = 0.45f; h[2] = 0.3f;
		analog_.push_back(single("Sine x3", h));
	}
	{
		H h(16, 0.0f);
		for (int i = 0; i < 16; i++) h[(size_t)i] = std::pow(1.0f / (float)(i + 1), 0.7f);
		analog_.push_back(single("Bright Sine", h));
	}
	{
		// Drawbar footages: 16', 5 1/3', 8', 4', 2 2/3', 2', 1 3/5', 1 1/3', 1'.
		H h = harm_partials({{1, 1.0f}, {2, 0.85f}, {3, 0.6f}, {4, 0.7f},
				{6, 0.4f}, {8, 0.5f}, {10, 0.3f}, {12, 0.25f}, {16, 0.35f}});
		analog_.push_back(single("Organ", h));
	}
	analog_.push_back(single("Hollow", harm_every(3, 512, 0.9f)));
	analog_.push_back(single("Nasal", harm_add(harm_formant(6.0f, 3.0f), harm_saw(), 1.0f, 0.35f)));

	// --- Morphing tables.
	tables_.push_back(morph("Basic Shapes",
			{harm_sine(), harm_tri(), harm_saw(), harm_square(), harm_pulse(0.15f)}, 17));
	{
		std::vector<H> f;
		for (int i = 0; i < 9; i++) f.push_back(harm_formant(1.5f + (float)i * 4.0f, 2.5f, 512, 1.0f));
		tables_.push_back(morph("Formant Sweep", f, 17));
	}
	{
		// Three moving formants, which is roughly what a vowel is.
		std::vector<H> f;
		static const float F1[5] = {7.0f, 5.0f, 3.0f, 4.0f, 3.0f};
		static const float F2[5] = {14.0f, 22.0f, 27.0f, 9.0f, 8.0f};
		static const float F3[5] = {26.0f, 30.0f, 32.0f, 25.0f, 24.0f};
		for (int i = 0; i < 5; i++) {
			H h = harm_formant(F1[i], 2.0f, 512, 1.2f);
			h = harm_add(h, harm_formant(F2[i], 3.0f, 512, 1.2f), 1.0f, 0.55f);
			h = harm_add(h, harm_formant(F3[i], 4.0f, 512, 1.2f), 1.0f, 0.3f);
			f.push_back(h);
		}
		tables_.push_back(morph("Vocal", f, 17));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 8; i++) {
			H h(512, 0.0f);
			for (int k = 0; k < 512; k++) h[(size_t)k] = std::pow(1.0f / (float)(k + 1), 2.0f - (float)i * 0.22f);
			f.push_back(h);
		}
		tables_.push_back(morph("Harmonics", f, 17));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 9; i++) {
			H h = harm_saw();
			const float notch = 1.0f + (float)i * 0.9f;
			for (int k = 0; k < 512; k++)
				h[(size_t)k] *= 0.5f + 0.5f * std::cos((float)(k + 1) * notch * 0.25f);
			f.push_back(h);
		}
		tables_.push_back(morph("Additive Comb", f, 17));
	}
	{
		std::vector<H> f;
		f.push_back(harm_partials({{1, 1.0f}, {2, 0.6f}, {3, 0.35f}, {5, 0.2f}}));
		f.push_back(harm_partials({{1, 1.0f}, {3, 0.7f}, {5, 0.4f}, {9, 0.25f}, {14, 0.15f}}));
		f.push_back(harm_partials({{1, 1.0f}, {2, 0.4f}, {5, 0.8f}, {9, 0.5f}, {17, 0.3f}, {23, 0.2f}}));
		f.push_back(harm_partials({{1, 0.7f}, {4, 1.0f}, {7, 0.7f}, {13, 0.5f}, {19, 0.4f}, {29, 0.3f}}));
		tables_.push_back(morph("Bell Partials", f, 13));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 8; i++) {
			H h(512, 0.0f);
			const float fold = 1.0f + (float)i * 0.7f;
			for (int k = 0; k < 512; k++)
				h[(size_t)k] = std::sin(fold * (float)(k + 1) * 0.5f) / (float)(k + 1);
			f.push_back(h);
		}
		tables_.push_back(morph("Digital Fold", f, 17));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 7; i++) {
			H h(512, 0.0f);
			for (int k = 0; k < 512; k++) {
				const float kk = (float)(k + 1);
				h[(size_t)k] = (1.0f / kk) * std::fabs(std::sin(kk * (0.3f + (float)i * 0.35f)));
			}
			f.push_back(h);
		}
		tables_.push_back(morph("Metallic", f, 15));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 9; i++) {
			H h = harm_saw();
			const float peak = 1.0f + (float)i * 5.0f;
			for (int k = 0; k < 512; k++) {
				const float d = ((float)(k + 1) - peak) / 3.0f;
				h[(size_t)k] *= 1.0f + 6.0f * std::exp(-d * d);
			}
			f.push_back(h);
		}
		tables_.push_back(morph("Reso Sweep", f, 17));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 9; i++) f.push_back(harm_pulse(0.5f - (float)i * 0.052f));
		tables_.push_back(morph("PWM", f, 17));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 9; i++) {
			H h(512, 0.0f);
			const float r = 1.0f + (float)i * 0.6f;
			for (int k = 0; k < 512; k++) {
				const float kk = (float)(k + 1);
				h[(size_t)k] = std::sin(PI_F * kk / r) / kk;
			}
			f.push_back(h);
		}
		tables_.push_back(morph("Sync Sweep", f, 17));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 6; i++) {
			H h = harm_formant(3.0f + (float)i * 2.0f, 1.5f, 512, 0.8f);
			h = harm_add(h, harm_every(2, 512, 1.1f), 1.0f, 0.6f);
			f.push_back(h);
		}
		tables_.push_back(morph("Growl", f, 13));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 6; i++) {
			H h(512, 0.0f);
			for (int k = 0; k < 512; k++)
				h[(size_t)k] = std::pow(1.0f / (float)(k + 1), 1.6f - (float)i * 0.18f)
						* (0.6f + 0.4f * std::cos((float)k * 0.9f));
			f.push_back(h);
		}
		tables_.push_back(morph("Glass", f, 13));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 6; i++) {
			H h = harm_partials({{1, 1.0f}, {2, 0.2f}, {3, 0.5f}, {7, 0.4f}, {11, 0.3f}, {13, 0.25f}});
			for (int k = 0; k < (int)h.size(); k++) h[(size_t)k] *= std::exp(-(float)k * (0.2f - (float)i * 0.03f));
			f.push_back(h);
		}
		tables_.push_back(morph("Wire", f, 11));
	}
	{
		std::vector<H> f;
		f.push_back(harm_partials({{1, 1.0f}, {3, 0.5f}, {6, 0.4f}, {10, 0.3f}, {15, 0.2f}}));
		f.push_back(harm_partials({{1, 1.0f}, {2, 0.7f}, {4, 0.5f}, {8, 0.4f}, {16, 0.25f}, {24, 0.15f}}));
		f.push_back(harm_partials({{1, 0.8f}, {5, 1.0f}, {11, 0.6f}, {19, 0.4f}, {31, 0.3f}}));
		tables_.push_back(morph("Chime", f, 11));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 6; i++) {
			H h = harm_every(2, 512, 0.85f);
			for (int k = 0; k < 512; k++)
				h[(size_t)k] *= std::exp(-(float)k * (0.12f - (float)i * 0.018f));
			f.push_back(harm_add(h, harm_formant(4.0f + (float)i, 2.0f), 1.0f, 0.5f));
		}
		tables_.push_back(morph("Reed", f, 13));
	}
	{
		std::vector<H> f;
		static const float A[3] = {7.0f, 5.0f, 3.0f};
		static const float B[3] = {12.0f, 20.0f, 28.0f};
		for (int i = 0; i < 3; i++) {
			H h = harm_formant(A[i], 2.0f, 512, 1.1f);
			h = harm_add(h, harm_formant(B[i], 3.0f, 512, 1.1f), 1.0f, 0.6f);
			f.push_back(h);
		}
		tables_.push_back(morph("Vowel A-E-I", f, 9));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 5; i++) {
			H h = harm_saw();
			// A fifth above, folded into the same cycle.
			for (int k = 2; k < 512; k += 3) h[(size_t)k] += (float)i * 0.18f / (float)(k + 1);
			f.push_back(h);
		}
		tables_.push_back(morph("Fifths", f, 9));
	}
	{
		std::vector<H> f;
		for (int i = 0; i < 6; i++) {
			H h(512, 0.0f);
			for (int k = 0; k < 512; k++) {
				const float kk = (float)(k + 1);
				h[(size_t)k] = (1.0f / kk) * (1.0f + (float)i * 0.3f * std::cos(kk * 0.21f * (float)(i + 1)));
			}
			f.push_back(h);
		}
		tables_.push_back(morph("Detuned Stack", f, 13));
	}
	{
		std::vector<H> f;
		Rng r(12345);
		for (int i = 0; i < 8; i++) {
			H h(512, 0.0f);
			for (int k = 0; k < 512; k++) {
				const float band = std::exp(-std::pow(((float)k - (float)i * 60.0f) / 40.0f, 2.0f));
				h[(size_t)k] = band * (0.4f + 0.6f * r.uni()) / std::sqrt((float)(k + 1));
			}
			f.push_back(h);
		}
		tables_.push_back(morph("Noise Bands", f, 15));
	}

	// --- Struck and plucked instruments.
	//
	// The tables above are shapes; these are instruments. What separates a
	// piano from a sawtooth is not brightness, it is that its partials are
	// not quite whole multiples of the fundamental -- a real string is stiff,
	// so the nth partial sits a little sharp -- and that how many of them
	// there are depends on how hard it was hit. Both of those are built in
	// here: the position axis runs from softly struck to hard, which is what
	// a velocity-to-position route then plays.
	{
		std::vector<H> f;
		for (int v = 0; v < 7; v++) {
			// Inharmonicity of a piano string: partial n lands at
			// n*f0*sqrt(1 + B*n*n), and B is small. Rounded to the nearest
			// harmonic slot it shows up as the slight detune between partials
			// that makes the tone shimmer instead of sitting still.
			const float B = 0.00035f;
			H h(200, 0.0f);
			const float hardness = (float)v / 6.0f;
			// A harder strike keeps the upper partials; a soft one is nearly
			// a sine.
			const float rolloff = 1.9f - hardness * 1.05f;
			for (int n = 1; n <= 60; n++) {
				const float stretched = (float)n * std::sqrt(1.0f + B * (float)(n * n));
				const int slot = (int)std::lround(stretched) - 1;
				if (slot < 0 || slot >= 200) continue;
				float a = std::pow(1.0f / (float)n, rolloff);
				// The hammer strikes about an eighth of the way along, which
				// puts a notch on every eighth partial. It is the single
				// clearest reason a piano does not sound like an organ.
				a *= std::fabs(std::sin(PI_F * (float)n / 8.0f));
				h[(size_t)slot] += a;
			}
			f.push_back(h);
		}
		tables_.push_back(morph("Piano String", f, 13));
	}
	{
		// The tine of an electric piano: a fundamental with one strong high
		// partial well above it, and the bark on top when it is hit hard.
		std::vector<H> f;
		for (int v = 0; v < 6; v++) {
			const float hard = (float)v / 5.0f;
			H h = harm_partials({{1, 1.0f}, {2, 0.22f}, {3, 0.10f}, {4, 0.06f}});
			h[8] += 0.30f * hard;     // the ninth partial is the tine itself
			h[13] += 0.18f * hard;
			h[19] += 0.10f * hard;
			for (int k = 0; k < (int)h.size(); k++)
				h[(size_t)k] *= std::exp(-(float)k * (0.16f - hard * 0.06f));
			f.push_back(h);
		}
		tables_.push_back(morph("Tine", f, 11));
	}
	{
		// A struck bar or bell: partials at genuinely unrelated ratios, which
		// is what makes it ring rather than sound a note.
		std::vector<H> f;
		static const float RATIO[3][7] = {
			{1.0f, 2.76f, 5.40f, 8.93f, 13.34f, 18.64f, 24.80f},   // bar
			{1.0f, 2.00f, 3.01f, 4.15f, 5.43f, 6.79f, 8.21f},      // tube
			{0.56f, 1.00f, 1.49f, 2.00f, 2.56f, 3.00f, 4.07f},     // bell
		};
		for (int kind = 0; kind < 3; kind++) {
			H h(200, 0.0f);
			for (int i = 0; i < 7; i++) {
				const int slot = (int)std::lround(RATIO[kind][i] * 4.0f) - 1;
				if (slot >= 0 && slot < 200) h[(size_t)slot] += std::pow(0.62f, (float)i);
			}
			f.push_back(h);
		}
		tables_.push_back(morph("Struck Bar", f, 9));
	}
	{
		// A plucked nylon or gut string: all the partials, falling away fast,
		// with the notch where it was plucked.
		std::vector<H> f;
		for (int v = 0; v < 5; v++) {
			const float pos = 0.12f + (float)v * 0.05f;   // where it is plucked
			H h(160, 0.0f);
			for (int n = 1; n <= 60; n++)
				h[(size_t)(n - 1)] = std::fabs(std::sin(PI_F * (float)n * pos))
						/ std::pow((float)n, 1.35f);
			f.push_back(h);
		}
		tables_.push_back(morph("Plucked String", f, 9));
	}
	{
		// An organ pipe: strong fundamental, a breathy cluster of upper
		// partials, and very little in between.
		std::vector<H> f;
		for (int v = 0; v < 5; v++) {
			H h = harm_partials({{1, 1.0f}, {2, 0.35f}, {3, 0.20f}, {4, 0.28f}, {6, 0.12f},
					{8, 0.16f}});
			for (int k = 8; k < 24; k++) h[(size_t)k] += 0.05f * (float)v * std::exp(-(float)(k - 8) * 0.3f);
			f.push_back(h);
		}
		tables_.push_back(morph("Pipe", f, 9));
	}
}

WaveBank &WaveBank::get() {
	static WaveBank b;
	return b;
}

const WaveTable &WaveBank::analog(int i) const {
	if (i < 0 || i >= (int)analog_.size()) i = 0;
	return analog_[(size_t)i];
}

const WaveTable &WaveBank::table(int i) const {
	if (i < 0 || i >= (int)tables_.size()) i = 0;
	return tables_[(size_t)i];
}

const WaveTable *WaveBank::user(int i) const {
	if (i < 0 || i >= (int)user_.size()) return nullptr;
	return &user_[(size_t)i];
}

std::string WaveBank::user_name(int i) const {
	const WaveTable *t = user(i);
	return t ? t->name : std::string();
}

int WaveBank::add_cycle(const std::string &name, const float *data, int n) {
	if (!data || n < 4) return -1;
	WaveTable t;
	t.name = name;
	t.frames.resize(1);
	build_frame_from_cycle(t.frames[0], data, n);
	user_.push_back(std::move(t));
	return (int)user_.size() - 1;
}

int WaveBank::add_harmonic(const std::string &name, const std::vector<std::vector<float>> &fh) {
	if (fh.empty()) return -1;
	WaveTable t;
	t.name = name;
	t.frames.resize(fh.size());
	for (size_t i = 0; i < fh.size(); i++) build_frame(t.frames[i], fh[i]);
	user_.push_back(std::move(t));
	return (int)user_.size() - 1;
}

int WaveBank::load_wav(const std::string &path, int frame_size) {
	AudioFile f;
	if (!wav_load(path, f) || !f.valid()) return -1;
	const int frames_total = f.frames();
	if (frames_total < frame_size) {
		// Too short to be a table: treat the whole thing as one cycle.
		std::vector<float> cycle((size_t)frames_total);
		for (int i = 0; i < frames_total; i++) cycle[(size_t)i] = f.data[(size_t)i * (size_t)f.channels];
		return add_cycle(path, cycle.data(), frames_total);
	}
	WaveTable t;
	t.name = path;
	const int count = std::min(256, frames_total / frame_size);
	t.frames.resize((size_t)count);
	std::vector<float> cycle((size_t)frame_size);
	for (int fr = 0; fr < count; fr++) {
		for (int i = 0; i < frame_size; i++)
			cycle[(size_t)i] = f.data[((size_t)(fr * frame_size + i)) * (size_t)f.channels];
		build_frame_from_cycle(t.frames[(size_t)fr], cycle.data(), frame_size);
	}
	user_.push_back(std::move(t));
	return (int)user_.size() - 1;
}

} // namespace flare
