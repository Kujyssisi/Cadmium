// FLARE — sampled content.
//
// One shape for every sampled source the plugin can play, whoever produced it:
// a lone WAV, a folder of them named by note, a SoundFont preset, or a preset
// out of a pack. The voice only ever sees zones.
#pragma once

#include <map>
#include <memory>
#include <string>
#include <vector>

namespace flare {

struct SampleData {
	std::string name;
	int channels = 1;
	int rate = 44100;
	std::vector<float> pcm;   // interleaved
	int frames() const { return channels > 0 ? (int)(pcm.size() / (size_t)channels) : 0; }
};

/// One region of a multisample: which keys and velocities reach it, and how it
/// should be played back when they do.
struct Zone {
	std::shared_ptr<SampleData> data;
	int lo_key = 0, hi_key = 127, root_key = 60;
	int lo_vel = 0, hi_vel = 127;
	int start = 0, end = 0;             // end 0 means "to the last frame"
	int loop_start = -1, loop_end = -1;
	int loop_mode = 0;                  // 0 none, 1 forward, 2 ping-pong, 3 until release
	float tune = 0.0f;                  // semitones, fractional
	float gain = 1.0f;
	float pan = 0.0f;
	float key_track = 1.0f;             // 0 plays every key at the root pitch
	/// Envelope and filter carried by the content itself. A SoundFont zone
	/// that says how it decays is not guessing, and overriding it with the
	/// synth's own envelope is what makes an imported piano sound wrong.
	bool has_env = false;
	float delay = 0, attack = 0, hold = 0, decay = 0, sustain = 1.0f, release = 0.1f;
	bool has_filter = false;
	float filter_hz = 20000.0f, filter_q = 0.7f;
	int exclusive = 0;                  // SoundFont exclusive class: hi-hats
};

/// A playable sampled instrument.
class MultiSample {
public:
	std::string name;
	std::vector<Zone> zones;
	/// Keeps the audio alive for as long as any zone points at it. Several
	/// zones normally share one buffer -- a SoundFont is one big block.
	std::vector<std::shared_ptr<SampleData>> pool;
	/// Whatever produced this, held so it outlives the zones.
	///
	/// A soundfont reader keeps its own cache so that four instances of the
	/// plugin playing the same font share one copy of it. That only works if
	/// something holds the reader open: without this the reader was freed the
	/// moment it had been read, the cache entry expired, and the next instance
	/// loaded the whole hundred and fifty megabytes again.
	std::shared_ptr<void> source;

	bool empty() const { return zones.empty(); }
	int frames_total() const;
	/// Every zone this note reaches, in the order they should be layered.
	void select(int key, int vel, std::vector<const Zone *> &out) const;
	/// The lowest and highest key any zone covers, for the browser.
	void key_range(int &lo, int &hi) const;
	void clear() { zones.clear(); pool.clear(); name.clear(); }
};

/// Reads one file into a multisample that spans the keyboard. Root note comes
/// from the file's `smpl` chunk when it has one, else from the filename, else
/// middle C.
bool multisample_from_wav(const std::string &path, MultiSample &out);

/// Reads a folder of WAVs, working out each one's key and velocity layer from
/// its name. Recognises "Piano_C#3.wav", "kick 36.wav", "Str-A4-v80.wav" and
/// the round-robin suffixes libraries use.
bool multisample_from_folder(const std::string &dir, MultiSample &out);

/// The note a name implies, or -1. Understands "C4", "F#-1", "Bb2" and a bare
/// MIDI number.
int key_from_name(const std::string &name);

/// Plays one zone. The reader is separate from the zone so that a voice can
/// hold several at once -- layered velocity splits, stereo pairs from a
/// SoundFont -- without copying anything.
struct SampleReader {
	const Zone *z = nullptr;
	double pos = 0.0;
	bool reverse = false;      // ping-pong state
	bool done = false;

	void start(const Zone *zone, double sr, float start_offset01);
	/// Advances by `step` frames of source audio and returns the frame, which
	/// is why the caller works out the ratio rather than a pitch.
	void next(double step, float &l, float &r);
	void release();
	bool finished() const { return done; }

private:
	double rate_ratio = 1.0;
	bool in_loop = false;
	bool released = false;
};

/// Frequency ratio for playing `zone` at `key`, in semitones above its root.
float zone_pitch_offset(const Zone &z, float key);

} // namespace flare
