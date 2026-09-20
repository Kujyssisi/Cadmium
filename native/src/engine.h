// Cadmium — the audio engine.
//
// Plain C++ and Godot-free: the Godot node in cd_node.cpp only marshals. The
// UI thread edits the song through the methods here (each takes the structural
// lock); the audio thread walks the same structures in process().
#pragma once

#include "plugin.h"
#include "wav.h"

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace cd {

class Vst3Plug;

// ---------------------------------------------------------------------------
// Song model
// ---------------------------------------------------------------------------
struct Note {
	float beat = 0.0f;
	float length = 1.0f;
	int key = 60;
	float vel = 0.78f;
	/// Per-note expression, edited in the piano roll's control lane: where the
	/// note sits across the stereo field, and how far it is detuned from the
	/// key it is written on, in semitones.
	float pan = 0.0f;
	float fine = 0.0f;
	int channel = 0;
};

struct Pattern {
	std::vector<Note> notes;   // sorted by beat
	float length = 16.0f;
};

enum ClipType { CLIP_PATTERN = 0, CLIP_AUDIO = 1, CLIP_AUTOMATION = 2 };

struct Clip {
	int type = CLIP_PATTERN;
	int index = 0;      // pattern id / audio id / automation id
	int track = 0;      // playlist track
	double start = 0.0; // beats
	double length = 4.0;
	double offset = 0.0;
	float gain = 1.0f;
	bool mute = false;
	float pitch = 0.0f; // audio clips, semitones
};

enum AutoTarget {
	AT_PLUGIN = 0,     // a = plugin handle, b = param index
	AT_MIXER_VOL = 1,  // a = mixer track
	AT_MIXER_PAN = 2,
	AT_CHANNEL_VOL = 3,
	AT_CHANNEL_PAN = 4,
	AT_TEMPO = 5,
	AT_SEND = 6,       // a = track, b = send index
	AT_SAMPLE_VOL = 7, // a = sample index
	AT_SAMPLE_PAN = 8, // a = sample index
	AT_SAMPLE_PITCH = 9,  // a = sample index, semitones, played like a record
	AT_SAMPLE_SPEED = 10, // a = sample index, multiplier
};

struct AutoPoint {
	double beat = 0.0;
	float value = 0.0f;
	float curve = 0.0f;   // -1 .. 1 bend
};

/// What a lane does with the value it produces.
enum AutoMode {
	AM_FORCED = 0,    ///< the control is held at the curve
	AM_ADDITIVE = 1,  ///< the curve is added to whatever the control is set to
};

/// One control a lane drives. A lane can drive several at once -- the same
/// shape on a filter and on a delay's mix, say -- which is one lane to draw
/// and one clip to move rather than three of each.
struct AutoLink {
	int target = AT_PLUGIN;
	int a = 0, b = 0;
	/// What this control was set to by hand, for an additive lane.
	float base = 0.0f;
};

struct Automation {
	int mode = AM_FORCED;
	bool on = true;
	std::vector<AutoLink> links;
	std::vector<AutoPoint> points;
	float value_at(double beat) const;
};

struct AudioAsset {
	std::string path;
	/// What was read off disk, kept so a setting can be changed and the whole
	/// thing worked out again from the original rather than from the last
	/// answer.
	std::shared_ptr<AudioFile> file;
	/// What is actually played: the file with everything above applied.
	std::shared_ptr<AudioFile> baked;
	SampleSettings set;
	/// Played faster or slower and higher or lower while it plays, the way a
	/// record does. This is what automation moves: the settings above are
	/// worked into the audio itself and cannot be changed a hundred times a
	/// second, but the speed something is read at can.
	float live_pitch = 0.0f;   ///< semitones
	float live_speed = 1.0f;   ///< multiplier
};

// ---------------------------------------------------------------------------
// Mixing
// ---------------------------------------------------------------------------
struct Slot {
	Plug *plug = nullptr;
	int handle = -1;
	bool bypass = false;
	float wet = 1.0f;
};

struct Send {
	int dest = -1;
	float amount = 0.0f;
	bool pre = false;
	bool sidechain = false;
};

struct MixerTrack {
	std::string name;
	std::vector<Slot> inserts;
	/// As many as the track needs. Four is what a strip shows by default, but
	/// routing one track into another is a send too, and a track is allowed to
	/// feed as many others as you like.
	std::vector<Send> sends;
	float vol = 1.0f, pan = 0.0f;
	bool mute = false, solo = false;
	int route = 0;          // destination track, 0 = master
	// Audio-thread scratch.
	std::vector<float> L, R, scL, scR;
	bool has_sc = false;
	float peak_l = 0, peak_r = 0, rms_l = 0, rms_r = 0;
	Smoothed g_vol, g_pan;
};

struct Channel {
	/// One extra channel this one also plays, so a single pattern can drive a
	/// stack of instruments (the classic "layer" channel).
	struct Layer {
		int channel = -1;
		int transpose = 0;
		float gain = 1.0f;
	};
	std::string name;
	Plug *inst = nullptr;
	int handle = -1;
	int mixer = 1;
	float vol = 0.8f, pan = 0.0f;
	bool mute = false, solo = false;
	int transpose = 0;
	std::vector<Layer> layers;
	/// A pure layer channel: its own instrument is never played, only the
	/// layers it points at.
	bool layer_only = false;
	// Notes the sequencer started here, so they can be stopped on the beat.
	struct Held { int key; int id; double off_beat; };
	std::vector<Held> held;
	std::vector<float> L, R;
	Smoothed g_vol;
	/// Which keys are sounding, for the interface's keyboards. Counted rather
	/// than flagged: two patterns can hold the same key at once.
	unsigned char keys[128] = {0};
	float level = 0.0f;
};

// A playing audio clip voice.
struct AudioVoice {
	int clip = -1;
	double pos = 0.0;
	double inc = 1.0;
	/// The rate this voice would run at with nothing riding on it: the clip's
	/// own pitch and the file's rate. What is automated multiplies this.
	double base_inc = 1.0;
	int track = 0;
	float gain = 1.0f;
	float pan = 0.0f;
	bool active = false;
	int asset = -1;
	/// Output frames this voice still has to sound for. A clip is a stretch
	/// of the arrangement, so what decides when it stops is how long the clip
	/// is -- not where in the file it has got to. Counting source frames
	/// instead is why a sample played faster used to go quiet half way along
	/// a clip that still drew its whole waveform.
	double left = 0.0;
	/// Above zero while the voice is ramping out. A stopped sample is faded
	/// rather than cut, and a fading one is never restarted or re-pointed.
	double fade = 0.0;

	bool fading() const { return fade > 0.0; }
	void release() { if (fade <= 0.0) fade = 1.0; }
};

enum TransportMode { MODE_PATTERN = 0, MODE_SONG = 1 };

class Engine {
public:
	Engine();
	~Engine();

	// --- lifecycle
	void prepare(double sample_rate, int block);
	void panic();

	// --- transport
	void play(bool from_start);
	void stop();
	bool playing() const { return playing_; }
	void set_position(double beat);
	double position() const { return beat_; }
	void set_bpm(double b) { bpm_ = b; }
	double bpm() const { return bpm_; }
	void set_mode(int m);
	int mode() const { return mode_; }
	void set_loop(double a, double b, bool on) { loop_a_ = a; loop_b_ = b; loop_on_ = on; }
	double loop_start() const { return loop_a_; }
	double loop_end() const { return loop_b_; }
	void set_pattern_loop(int p);
	int current_pattern() const { return cur_pattern_; }
	void set_metronome(bool on) { metro_ = on; }
	/// The two clicks: `which` 0 is the accented one on the first beat of a
	/// bar, 1 is every other beat. Interleaved float frames plus the rate they
	/// were recorded at -- the engine reads them at whatever rate it is running
	/// at rather than needing them converted first. An empty sound puts that
	/// beat back to the synthesised click, which is what the engine falls back
	/// to when nothing has given it any.
	void set_metronome_sound(int which, const std::vector<float> &frames, double rate, int channels);
	void set_time_sig(int num, int den) { sig_num_ = num; sig_den_ = den; }

	// --- plugins
	int create_plugin(const std::string &id);                 // stock id
	int create_vst3(const std::string &path, const std::string &cid);
	void destroy_plugin(int handle);
	Plug *plug(int handle) const;
	/// Every live plugin handle, so the host can tick things that are not audio
	/// (a plugin's own editor event loop, for instance).
	std::vector<int> plugin_handles() const;
	const PlugDesc *plug_desc(int handle) const;

	// --- channels
	int add_channel(const std::string &name);
	void remove_channel(int index);
	int channel_count() const { return (int)channels_.size(); }
	void set_channel_instrument(int ch, int handle);
	void set_channel(int ch, float vol, float pan, bool mute, bool solo, int mixer, int transpose);
	void set_channel_name(int ch, const std::string &n);
	void set_channel_layers(int ch, const std::vector<Channel::Layer> &layers, bool layer_only);
	Channel *channel(int i) { return (i >= 0 && i < (int)channels_.size()) ? &channels_[(size_t)i] : nullptr; }
	void move_channel(int from, int to);

	// --- mixer
	void set_mixer_count(int n);
	int mixer_count() const { return (int)mixer_.size(); }
	void set_mixer(int t, float vol, float pan, bool mute, bool solo, int route);
	void set_mixer_name(int t, const std::string &n);
	void set_send(int t, int i, int dest, float amount, bool pre, bool sidechain);
	void set_insert(int t, int slot, int handle);
	void set_insert_flags(int t, int slot, bool bypass, float wet);
	void move_insert(int t, int from, int to);
	int insert_handle(int t, int slot) const;

	// --- song data
	void set_pattern(int id, const std::vector<Note> &notes, float length);
	void clear_pattern(int id);
	int pattern_count() const { return (int)patterns_.size(); }
	float pattern_length(int id) const;
	void set_playlist(const std::vector<Clip> &clips);
	void set_automation(int id, int target, int a, int b, const std::vector<AutoPoint> &points,
			int mode = AM_FORCED, bool on = true, float base = 0.0f);
	/// The same, for a lane driving more than one control.
	void set_automation_links(int id, const std::vector<AutoLink> &links,
			const std::vector<AutoPoint> &points, int mode, bool on);
	void clear_automation();
	int register_audio(const std::string &path);
	/// The project's sample list is an ordered thing and a clip points into it by
	/// number, so the host says which slot a file goes in rather than asking for
	/// one. register_audio() appends, and reuses a slot when it already holds
	/// the same path -- both of which quietly renumber everything after a sample
	/// that is missing or repeated, and a clip then plays the wrong audio, which
	/// is worse than silence and far harder to notice.
	///
	/// An empty or unreadable path leaves the slot there and silent. Setting a
	/// slot to what it already holds does nothing, so this stays cheap to call
	/// on every sync.
	void set_audio(int index, const std::string &path);
	/// The decoded file behind an asset index, for drawing it.
	/// What a sample is set to, and setting it. Changing anything makes the
	/// played copy again, which for a long file is a moment's work and then
	/// costs nothing while it plays.
	void set_sample_settings(int index, const SampleSettings &s);
	SampleSettings sample_settings(int index) const {
		return (index >= 0 && index < (int)assets_.size()) ? assets_[(size_t)index].set
				: SampleSettings();
	}
	/// The audio as it will be heard, which is what a waveform should draw.
	const AudioFile *asset_played(int index) const {
		if (index < 0 || index >= (int)assets_.size()) return nullptr;
		const AudioAsset &a = assets_[(size_t)index];
		return a.baked ? a.baked.get() : a.file.get();
	}
	void bake_asset(int index);

	const AudioFile *asset_file(int index) const {
		if (index < 0 || index >= (int)assets_.size()) return nullptr;
		return assets_[(size_t)index].file.get();
	}
	void forget_audio();
	double song_length() const;

	// --- live input
	void note_on(int channel, int key, float vel);
	void note_off(int channel, int key);
	void all_notes_off();
	/// Cuts whatever one channel is sounding, for muting something mid-note.
	void stop_channel(int channel);
	/// Starts any note the playhead has landed in the middle of, so pressing
	/// play part-way through a held note plays it rather than waiting for the
	/// next one.
	void retrigger_at(double beat);

	// --- live audio input
	/// Frames off the machine's own input, handed over by the interface thread
	/// a video frame at a time and read by the audio thread a block at a time.
	/// Dropped rather than blocked if the two ever get badly out of step: a
	/// microphone is worth a gap, never a stall in the audio callback.
	void push_input(const float *l, const float *r, int n);
	/// Which mixer track the input is heard on and how loud, or -1 for
	/// nowhere. The track is fed before anything else is summed into it, so
	/// its effects, its fader and its sends treat a voice like any other
	/// signal -- which is what lets a sidechain send carry it to a vocoder.
	void set_input(int track, float gain);
	int input_track() const { return in_track_.load(std::memory_order_relaxed); }
	float input_peak() const { return in_peak_; }
	/// Arms the take: everything coming in from the next block on is kept
	/// until this is turned off. take_start_beat() is where it began, taken on
	/// the audio thread so it lines up with what was playing at the time.
	void arm_record(bool on);
	bool record_armed() const { return rec_on_.load(std::memory_order_relaxed); }
	/// Moves what the audio thread has recorded into the take. Called from the
	/// interface thread often enough that the ring between them never fills;
	/// returns how many frames arrived.
	int pump_take();
	double take_seconds() const;
	double take_start_beat() const { return rec_beat_.load(std::memory_order_relaxed); }
	bool write_take(const std::string &path, int bits);
	void clear_take();

	// --- metering and visualisation
	void meters(std::vector<float> &out) const;
	/// The most recent master output, interleaved, newest last.
	void scope(int frames, std::vector<float> &out) const;
	/// Master spectrum in dB, `bins` bins from DC to Nyquist/2.
	void spectrum(int bins, std::vector<float> &out) const;
	void active_notes(int channel, std::vector<int> &out) const;
	float channel_level(int channel) const;
	float cpu() const { return cpu_; }
	int voices() const;
	/// Played like a record: semitones and a speed multiplier, applied to
	/// whatever is playing this sample right now and to anything that starts
	/// afterwards.
	void set_sample_live(int index, float pitch_semis, float speed);
	void set_sample_live_locked(int index, float pitch_semis, float speed);
	/// How many samples are sounding, as opposed to instrument voices.
	int sample_voices() const {
		int n = 0;
		for (const auto &v : audio_voices_) if (v.active) n++;
		return n;
	}

	// --- audio thread entry
	void process(float *out_l, float *out_r, int frames);

	// --- offline
	/// `tail` in seconds, or negative to let the decay decide when it has
	/// finished. With `loop_fold` the tail is added back onto the beginning
	/// and the file is cut to the length of the range, so what is left loops
	/// with its own reverb already running.
	bool render(const std::string &path, double start_beat, double end_beat, double tail, int bits,
			bool normalize, float *progress, bool loop_fold = false);
	bool render_stems(const std::string &dir, double start_beat, double end_beat, double tail, int bits);

	/// A ceiling on the master, so a runaway feedback loop or a synth with its
	/// gain wound up cannot reach the speakers at full scale. On by default:
	/// the cost of it being there is nothing until something asks for more
	/// than the ceiling, and the cost of it not being there is a pair of ears.
	void set_limiter(bool on, float ceiling_db);
	bool limiter_on() const { return limit_on_; }
	/// How much the limiter is holding back right now, in dB (0 when idle).
	float limiter_reduction() const;

	std::mutex mutex;
	double sr = 48000.0;
	int block = 512;

private:
	bool limit_on_ = true;
	float limit_ceiling_ = 0.891251f;    // -1 dBFS
	float limit_gain_ = 1.0f;
	void limit(float *L, float *R, int frames);

	struct Event {
		int frame;
		int type;     // 0 note on, 1 note off
		int channel;
		int key;
		float vel;
		int id;
		// Carried from the note so the voice can be placed and detuned as it
		// starts; see Plug::take_expr.
		float pan = 0.0f;
		float fine = 0.0f;
	};

	void render_block(float *L, float *R, int frames, bool advance);
	/// The mixer track a voice of this sample belongs on: the one the sample
	/// asks for, or the one its clip's playlist track feeds.
	int voice_track(int wanted, int clip_index) const;
	void collect_events(double b0, double b1, int frames, std::vector<Event> &out);
	void mix_tracks(int frames, float *L, float *R);
	void apply_automation(double beat);
	void apply_link(const AutoLink &link, float v);
	void start_audio_clips(double b0, double b1);
	void ensure_buffers(int frames);
	void order_tracks();
	/// retrigger_at() with the lock already held.
	void retrigger_locked(double beat);
	/// Makes what is sounding agree with what the song says should be sounding
	/// at the playhead, for an edit made while the transport is running: a clip
	/// dropped over the playhead, a note drawn into the pattern that is playing,
	/// an instrument put on a channel. Only ever starts things -- a note the
	/// sequencer is already holding keeps the voice it has, and a key played by
	/// hand is not the sequencer's to stop. Without it nothing added is heard
	/// until the playhead next crosses its start, which round a loop means
	/// waiting for the wrap and past the loop end means never: "it only plays
	/// after I stop and start again".
	void resync_locked();
	void start_audio_clip(size_t ci, double into);
	/// Audio clips the playhead is inside, started from where it has got to.
	void start_audio_at(double beat);
	/// A block's worth of the machine's input into its track, and into the
	/// take if one is being recorded.
	void pull_input(int frames);

	std::vector<Channel> channels_;
	std::vector<MixerTrack> mixer_;
	std::vector<Pattern> patterns_;
	std::vector<Clip> clips_;
	std::vector<Automation> autos_;
	std::vector<AudioAsset> assets_;
	std::vector<AudioVoice> audio_voices_;
	std::map<int, Plug *> plugins_;
	std::vector<int> order_;

	double beat_ = 0.0;
	double bpm_ = 140.0;
	bool playing_ = false;
	int mode_ = MODE_PATTERN;
	double loop_a_ = 0.0, loop_b_ = 16.0;
	bool loop_on_ = true;
	int cur_pattern_ = 0;
	bool metro_ = false;
	/// A click the metronome plays, as handed over: not resampled on the way
	/// in, because the engine's own rate can change under it.
	struct MetroSound {
		std::vector<float> data;
		int channels = 1;
		double rate = 48000.0;
		int frames() const { return channels > 0 ? (int)(data.size() / (size_t)channels) : 0; }
	};
	MetroSound metro_snd_[2];
	/// Which click is sounding, or -1 for none, and how far into it we are in
	/// its own frames.
	int metro_voice_ = -1;
	double metro_pos_ = 0.0;
	int sig_num_ = 4, sig_den_ = 4;
	double metro_phase_ = 0.0;
	double metro_last_beat_ = -1.0;
	float metro_env_ = 0.0f;
	float metro_freq_ = 1000.0f;
	// Live audio input. Two single-producer, single-consumer rings: the
	// interface thread fills the first and the audio thread empties it, and
	// the audio thread fills the second with the take while the interface
	// thread empties that into a buffer it owns. Neither one ever makes the
	// audio thread wait for the other.
	static const uint64_t kInRing = 1u << 16;     ///< frames, a power of two
	/// Held back before reading starts: enough that a slow video frame in the
	/// interface costs latency rather than a hole, and little enough that
	/// monitoring a voice is still monitoring rather than an echo.
	static const uint64_t kInPrime = 2048;
	/// And the most that is allowed to pile up. Past this the oldest frames go
	/// rather than the latency growing for the rest of the session.
	static const uint64_t kInMax = 16384;
	static const uint64_t kRecRing = 1u << 19;    ///< interleaved floats
	/// A take longer than this is a mistake rather than a performance.
	static const size_t kTakeMax = (size_t)48000 * 2 * 60 * 30;
	std::vector<float> in_l_, in_r_;
	std::atomic<uint64_t> in_w_{0};
	std::atomic<uint64_t> in_rd_{0};
	bool in_primed_ = false;
	std::atomic<int> in_track_{-1};
	std::atomic<float> in_gain_{1.0f};
	float in_peak_ = 0.0f;
	std::vector<float> rec_ring_;
	std::atomic<uint64_t> rec_w_{0};
	/// The interface thread owns this, but the audio thread reads it to know
	/// how much of the ring it is still allowed to write into.
	std::atomic<uint64_t> rec_rd_{0};
	std::atomic<bool> rec_on_{false};
	/// Set when the take is armed and cleared by the first block that records,
	/// which is the block that also writes down the beat it started on.
	std::atomic<bool> rec_mark_{false};
	std::atomic<double> rec_beat_{0.0};
	/// The take itself, which only the interface thread touches.
	std::vector<float> take_;
	/// True while an offline render is running, which has no live input and
	/// must not eat the one the audio thread is waiting for.
	bool offline_ = false;

	int next_handle_ = 1;
	int next_note_id_ = 1;
	float cpu_ = 0.0f;
	std::vector<float> mixL_, mixR_, tmpL_, tmpR_;
	// Master output history for the scope and the analyser.
	static const int SCOPE_N = 16384;
	std::vector<float> scope_l_, scope_r_;
	int scope_w_ = 0;
	std::vector<Event> events_;
	double last_beat_ = -1.0;
};

} // namespace cd
