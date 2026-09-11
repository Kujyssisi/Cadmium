// FLARE — WAV reader.
//
// Handles the formats sample libraries are actually shipped in: 8/16/24/32-bit
// PCM and 32/64-bit float, in RIFF or RF64. Anything else is somebody else's
// job -- the host decodes it and hands over floats.
#include "wav.h"

#include <cmath>
#include <cstdio>
#include <cstring>

namespace flare {

namespace {

inline uint32_t rd32(const uint8_t *p) {
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
inline uint16_t rd16(const uint8_t *p) { return (uint16_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8)); }

float sample_at(const uint8_t *p, int bits, bool is_float) {
	if (is_float) {
		if (bits == 64) {
			double d;
			std::memcpy(&d, p, 8);
			return (float)d;
		}
		float f;
		std::memcpy(&f, p, 4);
		return f;
	}
	switch (bits) {
		case 8: return ((float)p[0] - 128.0f) * (1.0f / 128.0f);
		case 16: return (float)(int16_t)rd16(p) * (1.0f / 32768.0f);
		case 24: {
			int32_t v = (int32_t)(((uint32_t)p[0] << 8) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 24));
			return (float)(v >> 8) * (1.0f / 8388608.0f);
		}
		case 32: return (float)(int32_t)rd32(p) * (1.0f / 2147483648.0f);
		default: return 0.0f;
	}
}

} // namespace

bool wav_parse(const uint8_t *b, size_t n, AudioFile &out) {
	if (!b || n < 44) return false;
	if (std::memcmp(b, "RIFF", 4) != 0 && std::memcmp(b, "RF64", 4) != 0) return false;
	if (std::memcmp(b + 8, "WAVE", 4) != 0) return false;

	int bits = 16, channels = 0, rate = 0;
	bool is_float = false;
	const uint8_t *data = nullptr;
	uint64_t data_bytes = 0;
	uint64_t ds64_data = 0;

	size_t p = 12;
	while (p + 8 <= n) {
		const char *id = (const char *)(b + p);
		uint64_t sz = rd32(b + p + 4);
		const size_t body = p + 8;
		if (std::memcmp(id, "ds64", 4) == 0 && body + 24 <= n) {
			ds64_data = (uint64_t)rd32(b + body + 8) | ((uint64_t)rd32(b + body + 12) << 32);
		} else if (std::memcmp(id, "fmt ", 4) == 0 && body + 16 <= n) {
			uint16_t fmt = rd16(b + body);
			channels = rd16(b + body + 2);
			rate = (int)rd32(b + body + 4);
			bits = rd16(b + body + 14);
			if (fmt == 0xFFFE && sz >= 40 && body + 26 <= n) {
				// Extensible: the real format is the first two bytes of the GUID.
				fmt = rd16(b + body + 24);
			}
			is_float = (fmt == 3);
			if (fmt != 1 && fmt != 3 && fmt != 0xFFFE) return false;
		} else if (std::memcmp(id, "data", 4) == 0) {
			data = b + body;
			data_bytes = (sz == 0xFFFFFFFFu && ds64_data) ? ds64_data : sz;
			if (body + data_bytes > n) data_bytes = n - body;
		} else if (std::memcmp(id, "smpl", 4) == 0 && body + 36 <= n) {
			out.root_key = (int)rd32(b + body + 12);
			const int32_t frac = (int32_t)rd32(b + body + 16);
			out.fine_cents = (int)std::lround((double)(uint32_t)frac / 4294967296.0 * 100.0);
			const uint32_t loops = rd32(b + body + 28);
			if (loops > 0 && body + 36 + 24 <= n) {
				out.loop_start = (int)rd32(b + body + 36 + 8);
				out.loop_end = (int)rd32(b + body + 36 + 12);
			}
		}
		p = body + (size_t)sz + ((sz & 1u) ? 1u : 0u);
		if (sz == 0) break;
	}
	if (!data || channels <= 0 || rate <= 0 || data_bytes == 0) return false;

	const int bytes = bits / 8;
	if (bytes <= 0) return false;
	const size_t total = (size_t)(data_bytes / (uint64_t)bytes);
	out.channels = channels;
	out.rate = rate;
	out.data.resize(total);
	for (size_t i = 0; i < total; i++) out.data[i] = sample_at(data + i * (size_t)bytes, bits, is_float);
	return true;
}

bool wav_load(const std::string &path, AudioFile &out) {
	FILE *f = std::fopen(path.c_str(), "rb");
	if (!f) return false;
	std::fseek(f, 0, SEEK_END);
	const long len = std::ftell(f);
	std::fseek(f, 0, SEEK_SET);
	if (len <= 0) { std::fclose(f); return false; }
	std::vector<uint8_t> buf((size_t)len);
	const size_t got = std::fread(buf.data(), 1, (size_t)len, f);
	std::fclose(f);
	if (got != (size_t)len) return false;
	return wav_parse(buf.data(), buf.size(), out);
}

bool wav_save(const std::string &path, const float *in, int frames, int channels, int rate) {
	if (!in || frames <= 0 || channels <= 0) return false;
	FILE *f = std::fopen(path.c_str(), "wb");
	if (!f) return false;
	const uint32_t data_bytes = (uint32_t)frames * (uint32_t)channels * 2u;
	uint8_t h[44];
	std::memcpy(h, "RIFF", 4);
	const uint32_t riff = 36u + data_bytes;
	std::memcpy(h + 4, &riff, 4);
	std::memcpy(h + 8, "WAVEfmt ", 8);
	const uint32_t sixteen = 16;
	std::memcpy(h + 16, &sixteen, 4);
	const uint16_t one = 1, ch = (uint16_t)channels, bits = 16;
	std::memcpy(h + 20, &one, 2);
	std::memcpy(h + 22, &ch, 2);
	const uint32_t sr = (uint32_t)rate;
	std::memcpy(h + 24, &sr, 4);
	const uint32_t byte_rate = sr * (uint32_t)channels * 2u;
	std::memcpy(h + 28, &byte_rate, 4);
	const uint16_t align = (uint16_t)(channels * 2);
	std::memcpy(h + 32, &align, 2);
	std::memcpy(h + 34, &bits, 2);
	std::memcpy(h + 36, "data", 4);
	std::memcpy(h + 40, &data_bytes, 4);
	std::fwrite(h, 1, 44, f);
	std::vector<int16_t> pcm((size_t)frames * (size_t)channels);
	for (size_t i = 0; i < pcm.size(); i++) {
		float v = in[i];
		v = v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v);
		pcm[i] = (int16_t)std::lround(v * 32767.0f);
	}
	std::fwrite(pcm.data(), sizeof(int16_t), pcm.size(), f);
	std::fclose(f);
	return true;
}

} // namespace flare
