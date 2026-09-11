// FLARE — wavetables.
//
// Every oscillator shape in the plugin is a wavetable, including the ones that
// look analogue. A table is a list of frames; a frame is a chain of mipmaps,
// each holding only the harmonics that fit below Nyquist at the octave it is
// meant for. Reading the right mipmap is what stops a saw at C7 turning into a
// bag of gravel.
#pragma once

#include <memory>
#include <string>
#include <vector>

namespace flare {

static const int WT_SIZE = 2048;   // samples in the top mipmap
static const int WT_MIPS = 11;
/// No mipmap is stored shorter than this, however few harmonics it holds. The
/// harmonic limit is what stops a table aliasing; the *length* is what keeps
/// the interpolator honest, and a 32-sample table read with four taps is
/// distortion whether or not it is band-limited.
static const int WT_MIN_SIZE = 256;

inline int wt_mip_size(int k) {
	const int n = WT_SIZE >> (k < 0 ? 0 : (k >= WT_MIPS ? WT_MIPS - 1 : k));
	return n < WT_MIN_SIZE ? WT_MIN_SIZE : n;
}
/// Harmonics mipmap k is allowed to hold, which is tied to the octave it
/// serves rather than to how long the table happens to be.
inline int wt_mip_harmonics(int k) {
	const int n = WT_SIZE >> (k < 0 ? 0 : (k >= WT_MIPS ? WT_MIPS - 1 : k));
	return n / 2 - 1 < 1 ? 1 : n / 2 - 1;
}

struct WaveFrame {
	/// Every mipmap is a power of two long, so the interpolator wraps with a
	/// mask instead of a branch and needs no guard samples.
	std::vector<float> mip[WT_MIPS];
	int size(int k) const { return wt_mip_size(k); }
};

struct WaveTable {
	std::string name;
	std::vector<WaveFrame> frames;
	bool ready() const { return !frames.empty(); }

	/// One sample. `pos` picks between frames (0..1), `phase` is 0..1, and
	/// `mip` is chosen from the oscillator's frequency by mip_for().
	float read(float pos, float phase, int mip) const;
	/// Same, without crossfading between frames -- for tables where the frames
	/// are unrelated sounds rather than a morph.
	float read_frame(int frame, float phase, int mip) const;
};

/// Which mipmap an oscillator running at `hz` should read so that its topmost
/// harmonic stays below Nyquist.
int mip_for(float hz, double sr);

/// The built-in bank: the analogue shapes first, then the morphing tables.
/// Built on first use and shared by every voice in every instance.
class WaveBank {
public:
	static WaveBank &get();

	int analog_count() const { return (int)analog_.size(); }
	int table_count() const { return (int)tables_.size(); }
	const WaveTable &analog(int i) const;
	const WaveTable &table(int i) const;
	/// A table loaded from a file, by the index handed back at load time.
	const WaveTable *user(int i) const;

	/// Reads a wavetable from a WAV file. Frames are taken as consecutive
	/// blocks of `frame_size` samples -- 2048 by convention, which is what
	/// every wavetable anyone will drop in here is written as. Returns the
	/// index to pass to user(), or -1.
	int load_wav(const std::string &path, int frame_size = WT_SIZE);
	/// A table built straight from a single cycle already in memory.
	int add_cycle(const std::string &name, const float *data, int n);
	/// One frame per named recipe, so a preset can carry its own table.
	int add_harmonic(const std::string &name, const std::vector<std::vector<float>> &frames_harmonics);

	std::string user_name(int i) const;
	int user_count() const { return (int)user_.size(); }

private:
	WaveBank();
	std::vector<WaveTable> analog_;
	std::vector<WaveTable> tables_;
	std::vector<WaveTable> user_;
};

/// Fills a frame's mipmap chain from a harmonic series (index 0 is the
/// fundamental). Public because presets and the importers build tables too.
void build_frame(WaveFrame &f, const std::vector<float> &harmonics,
		const std::vector<float> &phases = {});
/// Fills a frame from one cycle of audio, band-limiting each mipmap by FFT.
void build_frame_from_cycle(WaveFrame &f, const float *cycle, int n);

} // namespace flare
