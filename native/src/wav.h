// Cadmium — WAV read/write. Everything else (mp3, flac, ogg, video) is handed
// to ffmpeg by the GDScript side and arrives here as a canonical float WAV.
#pragma once

#include <string>
#include <vector>

namespace cd {

struct AudioFile {
	/// Buckets in the overview built at load time. Enough for a waveform on a
	/// wide screen without going back to the samples.
	static const int PEAKS = 4096;

	int channels = 0;
	int rate = 0;
	std::vector<float> data;   // interleaved
	std::vector<float> peaks;  // min, max per bucket across all channels
	int frames() const { return channels > 0 ? (int)(data.size() / (size_t)channels) : 0; }
	bool valid() const { return channels > 0 && !data.empty(); }
};

/// What a sample in the project is set to do with itself: the same settings
/// FL puts on an audio clip's channel. The ones that change the sound rather
/// than the playing of it are applied once, to a copy of the audio, the way FL
/// calls them "precomputed" -- reversing a file on every block would be work
/// done a thousand times for an answer that never changes.
struct SampleSettings {
	float gain = 1.0f;
	float pan = 0.0f;
	/// Semitones, and how much longer or shorter to make it. What each one
	/// does depends on the mode.
	float pitch = 0.0f;
	float stretch = 1.0f;
	/// 0 resample (speed and pitch together), 1 stretch (length only),
	/// 2 pitch (pitch only), 3 off (no stretching at all).
	int mode = 0;
	bool normalize = false;
	bool reverse = false;
	bool remove_dc = false;
	bool polarity = false;
	bool swap_stereo = false;
	bool fade_stereo = false;
	/// The part of the file that is used, and the shape of its edges. All in
	/// fractions of the whole, except the fades, which are seconds.
	float start = 0.0f;
	float length = 1.0f;
	float fade_in = 0.0f;
	float fade_out = 0.0f;
	/// Below this, in dB, the head and tail of the file count as silence and
	/// are trimmed away. -100 leaves it alone.
	float trim_db = -100.0f;
	/// Which mixer track this sample plays through, so effects can be put on
	/// it. Below zero means the one the clip's own playlist track feeds, which
	/// is what everything did before there was a choice.
	///
	/// Deliberately not part of the comparison below: it changes where the
	/// sound goes, not what the sound is, so changing it must not throw away
	/// the baked audio and build it again.
	int mixer = -1;

	bool operator==(const SampleSettings &o) const {
		return gain == o.gain && pan == o.pan && pitch == o.pitch && stretch == o.stretch
				&& mode == o.mode && normalize == o.normalize && reverse == o.reverse
				&& remove_dc == o.remove_dc && polarity == o.polarity
				&& swap_stereo == o.swap_stereo && fade_stereo == o.fade_stereo
				&& start == o.start && length == o.length && fade_in == o.fade_in
				&& fade_out == o.fade_out && trim_db == o.trim_db;
	}
};


/// The played copy of a sample: the part of it that is used, everything the
/// settings say to do to it, and whatever stretching was asked for.
void bake_sample(const AudioFile &src, const SampleSettings &set, AudioFile &out);

bool wav_load(const std::string &path, AudioFile &out);
/// Builds the overview an already-loaded file draws from. wav_load does this
/// as it reads; audio made rather than read -- a stretched or reversed copy of
/// a sample -- has to be given one.
void build_peaks(AudioFile &f);
bool wav_save(const std::string &path, const float *interleaved, int frames, int channels, int rate, int bits);

} // namespace cd
