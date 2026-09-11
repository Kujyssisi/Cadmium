#include "analyze.h"

#include "dsp.h"
#include "wav.h"

#include <algorithm>
#include <vector>

namespace cd {

// Onset strength: spectral flux, the sum of every bin that got louder since the
// last frame. Percussive music produces a clean pulse train from this.
static void onset_envelope(const std::vector<float> &mono, double sr,
		std::vector<float> &env, double &env_rate) {
	const int N = 1024;
	const int hop = 256;
	env.clear();
	if ((int)mono.size() < N * 2) {
		env_rate = 1.0;
		return;
	}
	std::vector<float> re(N), im(N), prev(N / 2, 0.0f), win(N);
	for (int i = 0; i < N; i++) win[i] = 0.5f - 0.5f * std::cos((float)TAU * i / (float)(N - 1));

	for (size_t start = 0; start + (size_t)N < mono.size(); start += (size_t)hop) {
		for (int i = 0; i < N; i++) {
			re[i] = mono[start + (size_t)i] * win[i];
			im[i] = 0.0f;
		}
		fft(re.data(), im.data(), N, false);
		float flux = 0.0f;
		for (int i = 1; i < N / 2; i++) {
			const float mag = std::sqrt(re[i] * re[i] + im[i] * im[i]);
			// Log compression keeps a loud bass drum from swamping everything.
			const float m = std::log1p(mag * 8.0f);
			const float d = m - prev[i];
			if (d > 0.0f) flux += d;
			prev[i] = m;
		}
		env.push_back(flux);
	}
	env_rate = sr / (double)hop;

	// Subtract a moving average: this is what separates onsets from loudness.
	const int w = std::max(4, (int)(env_rate * 0.25));
	std::vector<float> smoothed(env.size(), 0.0f);
	for (size_t i = 0; i < env.size(); i++) {
		int a = (int)i - w / 2, b = (int)i + w / 2;
		a = std::max(0, a);
		b = std::min((int)env.size() - 1, b);
		float sum = 0.0f;
		for (int k = a; k <= b; k++) sum += env[(size_t)k];
		smoothed[i] = sum / (float)std::max(1, b - a + 1);
	}
	for (size_t i = 0; i < env.size(); i++) env[i] = std::max(0.0f, env[i] - smoothed[i]);
}

// Autocorrelation of the onset envelope, scored over musically plausible
// tempos, with the harmonics of each candidate folded in so that 87 and 174 BPM
// vote for each other instead of competing.
static float estimate_bpm(const std::vector<float> &env, double env_rate, float &confidence) {
	confidence = 0.0f;
	if (env.size() < 32) return 0.0f;
	const int min_lag = std::max(2, (int)(env_rate * 60.0 / 200.0));
	const int max_lag = std::min((int)env.size() - 2, (int)(env_rate * 60.0 / 55.0));
	if (max_lag <= min_lag) return 0.0f;

	std::vector<float> ac((size_t)(max_lag + 1), 0.0f);
	for (int lag = min_lag; lag <= max_lag; lag++) {
		float sum = 0.0f;
		for (size_t i = 0; i + (size_t)lag < env.size(); i++) sum += env[i] * env[i + (size_t)lag];
		ac[(size_t)lag] = sum / (float)(env.size() - (size_t)lag);
	}
	float best_score = 0.0f;
	float best_bpm = 0.0f;
	float total = 1e-9f;
	for (int lag = min_lag; lag <= max_lag; lag++) {
		const float bpm = (float)(60.0 * env_rate / (double)lag);
		float score = ac[(size_t)lag];
		// Fold in the multiples: a real beat period repeats at 2x, 3x, 4x.
		for (int k = 2; k <= 4; k++) {
			const int l = lag * k;
			if (l <= max_lag) score += ac[(size_t)l] * (1.0f / (float)k);
		}
		// Dance-music prior: prefer 90-150, taper away from it.
		const float centre = 120.0f;
		score *= std::exp(-0.5f * std::pow(std::log2(bpm / centre) / 0.9f, 2.0f));
		total += score;
		if (score > best_score) {
			best_score = score;
			best_bpm = bpm;
		}
	}
	confidence = clampf(best_score / (total / (float)(max_lag - min_lag + 1)) / 6.0f, 0.0f, 1.0f);
	// Nudge to two decimals; nobody wants 127.99331.
	return std::round(best_bpm * 100.0f) / 100.0f;
}

// Krumhansl-Schmuckler: correlate the chroma profile against the 24 keys.
static void estimate_key(const std::vector<float> &mono, double sr, int &key, bool &minor, float &conf) {
	key = -1;
	minor = false;
	conf = 0.0f;
	const int N = 4096;
	const int hop = 2048;
	if ((int)mono.size() < N * 2) return;
	std::vector<float> re(N), im(N), win(N), chroma(12, 0.0f);
	for (int i = 0; i < N; i++) win[i] = 0.5f - 0.5f * std::cos((float)TAU * i / (float)(N - 1));
	int frames = 0;
	for (size_t start = 0; start + (size_t)N < mono.size(); start += (size_t)hop) {
		for (int i = 0; i < N; i++) {
			re[i] = mono[start + (size_t)i] * win[i];
			im[i] = 0.0f;
		}
		fft(re.data(), im.data(), N, false);
		for (int i = 2; i < N / 2; i++) {
			const float hz = (float)i * (float)sr / (float)N;
			if (hz < 55.0f || hz > 2200.0f) continue;
			const float mag = std::sqrt(re[i] * re[i] + im[i] * im[i]);
			const int pc = ((int)std::lround(hz_to_note(hz))) % 12;
			chroma[(size_t)((pc + 12) % 12)] += mag;
		}
		frames++;
		if (frames > 400) break;   // a minute of audio is plenty
	}
	float sum = 0.0f;
	for (float c : chroma) sum += c;
	if (sum < 1e-6f) return;
	for (float &c : chroma) c /= sum;

	static const float major[12] = {6.35f, 2.23f, 3.48f, 2.33f, 4.38f, 4.09f, 2.52f, 5.19f, 2.39f, 3.66f, 2.29f, 2.88f};
	static const float minorp[12] = {6.33f, 2.68f, 3.52f, 5.38f, 2.60f, 3.53f, 2.54f, 4.75f, 3.98f, 2.69f, 3.34f, 3.17f};
	float best = -1e9f, second = -1e9f;
	for (int root = 0; root < 12; root++) {
		for (int m = 0; m < 2; m++) {
			const float *prof = m ? minorp : major;
			float dot = 0.0f, pn = 0.0f, cn = 0.0f;
			for (int i = 0; i < 12; i++) {
				const float p = prof[(i - root + 24) % 12];
				dot += chroma[(size_t)i] * p;
				pn += p * p;
				cn += chroma[(size_t)i] * chroma[(size_t)i];
			}
			const float score = dot / std::sqrt(std::max(1e-9f, pn * cn));
			if (score > best) {
				second = best;
				best = score;
				key = root;
				minor = m != 0;
			} else if (score > second) {
				second = score;
			}
		}
	}
	conf = clampf((best - second) * 6.0f, 0.0f, 1.0f);
}

Analysis analyze_file(const std::string &path) {
	Analysis out;
	AudioFile f;
	if (!wav_load(path, f) || !f.valid()) return out;
	const int frames = f.frames();
	out.duration = (float)frames / (float)std::max(1, f.rate);

	// Mono, and decimated to about 11 kHz: tempo lives well below that and the
	// analysis gets four times faster.
	const int decim = std::max(1, f.rate / 11025);
	std::vector<float> mono;
	mono.reserve((size_t)(frames / decim) + 4);
	for (int i = 0; i + decim <= frames; i += decim) {
		float acc = 0.0f;
		for (int d = 0; d < decim; d++) {
			for (int c = 0; c < f.channels; c++) acc += f.data[(size_t)(i + d) * f.channels + c];
		}
		mono.push_back(acc / (float)(decim * f.channels));
	}
	const double sr = (double)f.rate / (double)decim;

	std::vector<float> env;
	double env_rate = 1.0;
	onset_envelope(mono, sr, env, env_rate);
	out.bpm = estimate_bpm(env, env_rate, out.bpm_confidence);
	estimate_key(mono, sr, out.key, out.minor, out.key_confidence);
	out.ok = out.bpm > 20.0f;
	return out;
}

} // namespace cd
