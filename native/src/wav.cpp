#include "wav.h"

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <algorithm>

namespace cd {

static inline float lerp(float a, float b, float t) { return a + (b - a) * t; }
static inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
static const double PI = 3.14159265358979323846;


static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint16_t rd16(const uint8_t *p) { return (uint16_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8)); }

static float sample_at(const uint8_t *s, int fmt, int bits) {
	if (fmt == 3 && bits == 32) { float t; memcpy(&t, s, 4); return t; }
	if (fmt == 3 && bits == 64) { double t; memcpy(&t, s, 8); return (float)t; }
	if (bits == 8) return ((float)s[0] - 128.0f) / 128.0f;
	if (bits == 16) return (float)(int16_t)rd16(s) / 32768.0f;
	if (bits == 24) {
		int32_t t = (int32_t)((uint32_t)s[0] << 8 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 24);
		return (float)(t >> 8) / 8388608.0f;
	}
	if (bits == 32) return (float)(int32_t)rd32(s) / 2147483648.0f;
	return 0.0f;
}

/// Reads a WAV a chunk at a time rather than swallowing the file whole.
///
/// A ten-minute stereo float WAV is a quarter of a gigabyte; slurping it into a
/// byte buffer and then converting doubles that for as long as the conversion
/// takes. Streaming keeps the peak at what the samples themselves need, which
/// is what makes long files usable at all.
/// Time stretching by overlapping and adding: the file is walked in grains,
/// each one laid down further apart or closer together than it was taken from,
/// and each placed where it lines up best with what is already there. It is
/// the standard way of making something longer without making it lower, and it
/// costs one pass over the audio rather than a spectrum per block.
static void stretch_wsola(const AudioFile &in, AudioFile &out, double ratio) {
	const int ch = std::max(1, in.channels);
	const int n = in.frames();
	out.channels = ch;
	out.rate = in.rate;
	if (n < 8 || ratio <= 0.01 || std::fabs(ratio - 1.0) < 0.001) {
		out.data = in.data;
		return;
	}
	// A grain of about fifty milliseconds, half of it overlapping its
	// neighbour: long enough to keep a pitch, short enough to follow a beat.
	const int grain = std::max(256, (int)(in.rate * 0.05));
	const int hop_out = grain / 2;
	const int hop_in = std::max(1, (int)std::llround((double)hop_out / ratio));
	const int search = std::min(hop_in / 2, (int)(in.rate * 0.005));
	const int frames_out = std::max(1, (int)((double)n * ratio) + grain);
	out.data.assign((size_t)frames_out * (size_t)ch, 0.0f);
	std::vector<float> window((size_t)grain);
	for (int i = 0; i < grain; i++) {
		window[(size_t)i] = 0.5f - 0.5f * std::cos(2.0f * (float)PI * (float)i / (float)(grain - 1));
	}
	int64_t read = 0;
	int64_t write = 0;
	while (write + grain < frames_out && read + grain < n) {
		int64_t best = read;
		if (search > 0 && write > 0) {
			// Line the grain up with what is already written, so the join does
			// not cancel itself out.
			float top = -1e30f;
			for (int off = -search; off <= search; off++) {
				const int64_t at = read + off;
				if (at < 0 || at + grain >= n) continue;
				float sum = 0.0f;
				for (int i = 0; i < grain; i += 8) {
					const float a = out.data[(size_t)(write + i) * (size_t)ch];
					const float b = in.data[(size_t)(at + i) * (size_t)ch];
					sum += a * b;
				}
				if (sum > top) { top = sum; best = at; }
			}
		}
		for (int i = 0; i < grain; i++) {
			const float w = window[(size_t)i];
			for (int c = 0; c < ch; c++) {
				out.data[(size_t)(write + i) * (size_t)ch + (size_t)c] +=
						in.data[(size_t)(best + i) * (size_t)ch + (size_t)c] * w;
			}
		}
		read = best + hop_in;
		write += hop_out;
	}
	out.data.resize((size_t)std::max<int64_t>(1, write + grain) * (size_t)ch);
}


/// Reads a file back at another speed, which moves its pitch with it.
static void resample_file(const AudioFile &in, AudioFile &out, double step) {
	const int ch = std::max(1, in.channels);
	const int n = in.frames();
	out.channels = ch;
	out.rate = in.rate;
	if (n < 2 || std::fabs(step - 1.0) < 0.0001) {
		out.data = in.data;
		return;
	}
	const int frames_out = std::max(1, (int)((double)n / step));
	out.data.assign((size_t)frames_out * (size_t)ch, 0.0f);
	for (int i = 0; i < frames_out; i++) {
		const double at = (double)i * step;
		const int i0 = (int)at;
		const float f = (float)(at - (double)i0);
		for (int c = 0; c < ch; c++) {
			const float a = in.data[(size_t)std::min(i0, n - 1) * (size_t)ch + (size_t)c];
			const float b = in.data[(size_t)std::min(i0 + 1, n - 1) * (size_t)ch + (size_t)c];
			out.data[(size_t)i * (size_t)ch + (size_t)c] = lerp(a, b, f);
		}
	}
}


void bake_sample(const AudioFile &src, const SampleSettings &set, AudioFile &out_file) {
	const int ch = std::max(1, src.channels);
	const int n = src.frames();
	AudioFile *out = &out_file;
	out->channels = ch;
	out->rate = src.rate;
	out->data.clear();
	if (n <= 0) return;

	// The stretch or two of silence at either end, if it was asked for.
	int64_t first = 0;
	int64_t last = n;
	if (set.trim_db > -99.0f) {
		const float floor_amp = std::pow(10.0f, set.trim_db / 20.0f);
		while (first < n) {
			float peak = 0.0f;
			for (int c = 0; c < ch; c++) {
				peak = std::max(peak, std::fabs(src.data[(size_t)first * (size_t)ch + (size_t)c]));
			}
			if (peak > floor_amp) break;
			first++;
		}
		while (last > first + 1) {
			float peak = 0.0f;
			for (int c = 0; c < ch; c++) {
				peak = std::max(peak, std::fabs(src.data[(size_t)(last - 1) * (size_t)ch + (size_t)c]));
			}
			if (peak > floor_amp) break;
			last--;
		}
	}
	// And the part of that the settings ask for.
	const int64_t span = std::max<int64_t>(1, last - first);
	const int64_t s0 = first + (int64_t)(clampf(set.start, 0.0f, 0.999f) * (float)span);
	const int64_t s1 = std::min<int64_t>(last, s0 + (int64_t)std::max(1.0f,
			clampf(set.length, 0.001f, 1.0f) * (float)span));
	AudioFile work;
	work.channels = ch;
	work.rate = src.rate;
	work.data.assign(src.data.begin() + (long)(s0 * ch), src.data.begin() + (long)(s1 * ch));
	const int m = work.frames();

	if (set.remove_dc) {
		for (int c = 0; c < ch; c++) {
			double sum = 0.0;
			for (int i = 0; i < m; i++) sum += work.data[(size_t)i * (size_t)ch + (size_t)c];
			const float mean = (float)(sum / std::max(1, m));
			for (int i = 0; i < m; i++) work.data[(size_t)i * (size_t)ch + (size_t)c] -= mean;
		}
	}
	if (set.normalize) {
		float peak = 0.0f;
		for (float v : work.data) peak = std::max(peak, std::fabs(v));
		if (peak > 0.0001f) {
			const float g = 0.99f / peak;
			for (float &v : work.data) v *= g;
		}
	}
	if (set.polarity) {
		for (float &v : work.data) v = -v;
	}
	if (set.swap_stereo && ch > 1) {
		for (int i = 0; i < m; i++) {
			std::swap(work.data[(size_t)i * (size_t)ch], work.data[(size_t)i * (size_t)ch + 1]);
		}
	}
	if (set.fade_stereo && ch > 1) {
		// Both sides towards the middle: the stereo width taken out of it.
		for (int i = 0; i < m; i++) {
			float &l = work.data[(size_t)i * (size_t)ch];
			float &r = work.data[(size_t)i * (size_t)ch + 1];
			const float mid = (l + r) * 0.5f;
			l = mid;
			r = mid;
		}
	}
	if (set.reverse) {
		for (int i = 0; i < m / 2; i++) {
			for (int c = 0; c < ch; c++) {
				std::swap(work.data[(size_t)i * (size_t)ch + (size_t)c],
						work.data[(size_t)(m - 1 - i) * (size_t)ch + (size_t)c]);
			}
		}
	}
	const int fade_in = std::min(m / 2, (int)(set.fade_in * (float)src.rate));
	for (int i = 0; i < fade_in; i++) {
		const float g = (float)i / (float)std::max(1, fade_in);
		for (int c = 0; c < ch; c++) work.data[(size_t)i * (size_t)ch + (size_t)c] *= g;
	}
	const int fade_out = std::min(m / 2, (int)(set.fade_out * (float)src.rate));
	for (int i = 0; i < fade_out; i++) {
		const float g = (float)i / (float)std::max(1, fade_out);
		const int at = m - 1 - i;
		for (int c = 0; c < ch; c++) work.data[(size_t)at * (size_t)ch + (size_t)c] *= g;
	}

	// And the stretching, which is where the modes differ: resampling moves
	// the pitch with the speed, stretching leaves the pitch where it was, and
	// pitching leaves the length where it was.
	const double semis = std::pow(2.0, (double)set.pitch / 12.0);
	const double want = std::max(0.05, (double)set.stretch);
	switch (set.mode) {
		case 1: {          // stretch: length only
			AudioFile tmp;
			stretch_wsola(work, tmp, want);
			*out = tmp;
			break;
		}
		case 2: {          // pitch: the same length, another pitch
			AudioFile tmp;
			stretch_wsola(work, tmp, semis);
			resample_file(tmp, *out, semis);
			break;
		}
		case 3:            // off
			*out = work;
			break;
		default: {         // resample: speed and pitch together
			resample_file(work, *out, semis / want);
			break;
		}
	}
	build_peaks(*out);
}



void build_peaks(AudioFile &f) {
	const int ch = std::max(1, f.channels);
	const size_t frames = f.data.size() / (size_t)ch;
	f.peaks.assign((size_t)AudioFile::PEAKS * 2, 0.0f);
	if (frames == 0) return;
	const size_t per_bucket = std::max<size_t>(1, frames / (size_t)AudioFile::PEAKS);
	for (size_t frame = 0; frame < frames; frame++) {
		const size_t bucket = std::min<size_t>(AudioFile::PEAKS - 1, frame / per_bucket);
		for (int c = 0; c < ch; c++) {
			const float v = f.data[frame * (size_t)ch + (size_t)c];
			float &lo = f.peaks[bucket * 2];
			float &hi = f.peaks[bucket * 2 + 1];
			if (v < lo) lo = v;
			if (v > hi) hi = v;
		}
	}
}


bool wav_load(const std::string &path, AudioFile &out) {
	FILE *f = fopen(path.c_str(), "rb");
	if (!f) return false;
	uint8_t head[12];
	if (fread(head, 1, 12, f) != 12 || memcmp(head, "RIFF", 4) != 0 || memcmp(head + 8, "WAVE", 4) != 0) {
		fclose(f);
		return false;
	}
	int fmt = 1, channels = 0, bits = 0, rate = 0;
	long data_pos = -1;
	uint32_t data_len = 0;

	// Walk the chunk headers, reading only what each chunk needs.
	uint8_t hdr[8];
	while (fread(hdr, 1, 8, f) == 8) {
		const uint32_t sz = rd32(hdr + 4);
		if (memcmp(hdr, "fmt ", 4) == 0 && sz >= 16) {
			std::vector<uint8_t> body(std::min<uint32_t>(sz, 64));
			if (fread(body.data(), 1, body.size(), f) != body.size()) break;
			fmt = rd16(body.data());
			channels = rd16(body.data() + 2);
			rate = (int)rd32(body.data() + 4);
			bits = rd16(body.data() + 14);
			if (fmt == 0xFFFE && body.size() >= 26) fmt = rd16(body.data() + 24);
			if (sz > body.size()) fseek(f, (long)(sz - body.size()), SEEK_CUR);
		} else if (memcmp(hdr, "data", 4) == 0) {
			data_pos = ftell(f);
			data_len = sz;
			// A streamed file can claim a size it does not have; trust the file.
			fseek(f, 0, SEEK_END);
			const long end = ftell(f);
			if (data_pos + (long)data_len > end) data_len = (uint32_t)(end - data_pos);
			break;
		} else {
			fseek(f, (long)(sz + (sz & 1)), SEEK_CUR);
		}
	}
	if (data_pos < 0 || channels <= 0 || bits <= 0) { fclose(f); return false; }

	const int bytes = bits / 8;
	const size_t frame_bytes = (size_t)bytes * (size_t)channels;
	const size_t frames = frame_bytes ? (size_t)data_len / frame_bytes : 0;
	if (!frames) { fclose(f); return false; }
	out.channels = channels;
	out.rate = rate;
	out.data.resize(frames * (size_t)channels);

	// The overview is built while the samples go past, so drawing a waveform
	// later never has to walk millions of samples again.
	out.peaks.assign((size_t)AudioFile::PEAKS * 2, 0.0f);
	const size_t per_bucket = std::max<size_t>(1, frames / (size_t)AudioFile::PEAKS);

	fseek(f, data_pos, SEEK_SET);
	std::vector<uint8_t> chunk(frame_bytes * 8192);
	size_t done = 0;
	while (done < frames) {
		const size_t want = std::min(frames - done, chunk.size() / frame_bytes);
		const size_t got = fread(chunk.data(), frame_bytes, want, f);
		if (got == 0) break;
		for (size_t i = 0; i < got; i++) {
			const size_t frame = done + i;
			const size_t bucket = std::min<size_t>(AudioFile::PEAKS - 1, frame / per_bucket);
			for (int c = 0; c < channels; c++) {
				const float v = sample_at(chunk.data() + (i * (size_t)channels + (size_t)c) * (size_t)bytes,
						fmt, bits);
				out.data[frame * (size_t)channels + (size_t)c] = v;
				float &lo = out.peaks[bucket * 2];
				float &hi = out.peaks[bucket * 2 + 1];
				if (v < lo) lo = v;
				if (v > hi) hi = v;
			}
		}
		done += got;
	}
	fclose(f);
	if (done < frames) {
		out.data.resize(done * (size_t)channels);
	}
	return !out.data.empty();
}

static void w32(FILE *f, uint32_t v) { uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)}; fwrite(b, 1, 4, f); }
static void w16(FILE *f, uint16_t v) { uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)}; fwrite(b, 1, 2, f); }

bool wav_save(const std::string &path, const float *x, int frames, int channels, int rate, int bits) {
	FILE *f = fopen(path.c_str(), "wb");
	if (!f) return false;
	const int fmt = bits == 32 ? 3 : 1;
	const int bytes = bits / 8;
	const uint32_t data_bytes = (uint32_t)frames * (uint32_t)channels * (uint32_t)bytes;
	fwrite("RIFF", 1, 4, f);
	w32(f, 36 + data_bytes);
	fwrite("WAVE", 1, 4, f);
	fwrite("fmt ", 1, 4, f);
	w32(f, 16);
	w16(f, (uint16_t)fmt);
	w16(f, (uint16_t)channels);
	w32(f, (uint32_t)rate);
	w32(f, (uint32_t)(rate * channels * bytes));
	w16(f, (uint16_t)(channels * bytes));
	w16(f, (uint16_t)bits);
	fwrite("data", 1, 4, f);
	w32(f, data_bytes);
	for (size_t i = 0; i < (size_t)frames * (size_t)channels; i++) {
		const float v = x[i];
		if (bits == 32) {
			fwrite(&v, 4, 1, f);
		} else if (bits == 24) {
			const float c = std::max(-1.0f, std::min(1.0f, v));
			int32_t t = (int32_t)std::lround(c * 8388607.0f);
			uint8_t b[3] = {(uint8_t)(t & 0xFF), (uint8_t)((t >> 8) & 0xFF), (uint8_t)((t >> 16) & 0xFF)};
			fwrite(b, 1, 3, f);
		} else {
			const float c = std::max(-1.0f, std::min(1.0f, v));
			w16(f, (uint16_t)(int16_t)std::lround(c * 32767.0f));
		}
	}
	fclose(f);
	return true;
}

} // namespace cd
