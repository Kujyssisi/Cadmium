// FLARE — WAV reading, and the audio buffer everything sampled lives in.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace flare {

struct AudioFile {
	int channels = 0;
	int rate = 0;
	std::vector<float> data;   // interleaved
	/// Loop points read from the file's `smpl` chunk, which is how a sample
	/// library says where a sustaining note repeats. -1 when there are none.
	int loop_start = -1, loop_end = -1;
	int root_key = -1;         // also from `smpl`
	int fine_cents = 0;

	int frames() const { return channels > 0 ? (int)(data.size() / (size_t)channels) : 0; }
	bool valid() const { return channels > 0 && !data.empty(); }
	float at(int frame, int ch) const {
		const size_t i = (size_t)frame * (size_t)channels + (size_t)(ch % channels);
		return i < data.size() ? data[i] : 0.0f;
	}
};

bool wav_load(const std::string &path, AudioFile &out);
/// Reads a WAV already in memory, which is how samples come out of a pack.
bool wav_parse(const uint8_t *bytes, size_t n, AudioFile &out);
bool wav_save(const std::string &path, const float *interleaved, int frames,
		int channels, int rate);

} // namespace flare
