// Cadmium — offline analysis of an audio file: tempo and musical key.
#pragma once

#include <string>

namespace cd {

struct Analysis {
	bool ok = false;
	float bpm = 0.0f;
	float bpm_confidence = 0.0f;
	int key = -1;         // 0 = C ... 11 = B
	bool minor = false;
	float key_confidence = 0.0f;
	float duration = 0.0f;
};

Analysis analyze_file(const std::string &wav_path);

} // namespace cd
