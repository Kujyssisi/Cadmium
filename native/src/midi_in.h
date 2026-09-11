// Cadmium — MIDI input over the ALSA sequencer.
//
// Godot 4.7's OS.open_midi_inputs() segfaults on this system, and going through
// ALSA directly is better anyway: we get the port list, can connect to a chosen
// device, and read events without a driver in between.
#pragma once

#include <string>
#include <vector>

namespace cd {

struct MidiPort {
	int client = 0;
	int port = 0;
	std::string name;
};

class MidiIn {
public:
	~MidiIn();
	bool open();
	void close();
	bool is_open() const { return seq_ != nullptr; }

	std::vector<MidiPort> ports() const;
	bool connect(int client, int port);
	void disconnect_all();
	int connect_all();

	// Drains whatever arrived since the last call: [status, data1, data2] per
	// event, so the caller can stay ignorant of ALSA's event structs.
	std::vector<int> poll_events();

private:
	void *seq_ = nullptr;   // snd_seq_t
	int my_port_ = -1;
	std::vector<std::pair<int, int>> connected_;
};

} // namespace cd
