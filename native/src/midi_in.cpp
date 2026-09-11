#include "midi_in.h"

#if defined(_WIN32)
// ---------------------------------------------------------------------------
// Windows: the multimedia MIDI API. Every input device is a "port"; the driver
// calls back on its own thread, so the queue is guarded.
// ---------------------------------------------------------------------------
#include <windows.h>
#include <mmsystem.h>

#include <mutex>

namespace cd {

struct WinMidi {
	std::vector<HMIDIIN> handles;
	std::vector<int> queue;
	std::mutex lock;
};

static WinMidi *win_midi(void *&slot) {
	if (!slot) slot = new WinMidi();
	return (WinMidi *)slot;
}

static void CALLBACK midi_proc(HMIDIIN, UINT msg, DWORD_PTR user, DWORD_PTR p1, DWORD_PTR) {
	if (msg != MIM_DATA) return;
	WinMidi *m = (WinMidi *)user;
	if (!m) return;
	const int status = (int)(p1 & 0xFF);
	const int d1 = (int)((p1 >> 8) & 0x7F);
	const int d2 = (int)((p1 >> 16) & 0x7F);
	const int kind = status & 0xF0;
	if (kind != 0x90 && kind != 0x80 && kind != 0xB0 && kind != 0xE0) return;
	std::lock_guard<std::mutex> g(m->lock);
	if (m->queue.size() > 3000) return;
	m->queue.push_back(status);
	m->queue.push_back(d1);
	m->queue.push_back(d2);
}

MidiIn::~MidiIn() { close(); }

bool MidiIn::open() {
	if (seq_) return true;
	seq_ = new WinMidi();
	return true;
}

void MidiIn::close() {
	if (!seq_) return;
	disconnect_all();
	delete (WinMidi *)seq_;
	seq_ = nullptr;
}

std::vector<MidiPort> MidiIn::ports() const {
	std::vector<MidiPort> out;
	const UINT n = midiInGetNumDevs();
	for (UINT i = 0; i < n; i++) {
		MIDIINCAPSA caps{};
		if (midiInGetDevCapsA(i, &caps, sizeof(caps)) != MMSYSERR_NOERROR) continue;
		MidiPort p;
		p.client = (int)i;
		p.port = 0;
		p.name = caps.szPname;
		out.push_back(p);
	}
	return out;
}

bool MidiIn::connect(int client, int) {
	if (!seq_) return false;
	WinMidi *m = (WinMidi *)seq_;
	HMIDIIN h = nullptr;
	if (midiInOpen(&h, (UINT)client, (DWORD_PTR)midi_proc, (DWORD_PTR)m, CALLBACK_FUNCTION) != MMSYSERR_NOERROR) {
		return false;
	}
	midiInStart(h);
	m->handles.push_back(h);
	connected_.push_back({client, 0});
	return true;
}

void MidiIn::disconnect_all() {
	if (!seq_) return;
	WinMidi *m = (WinMidi *)seq_;
	for (HMIDIIN h : m->handles) {
		midiInStop(h);
		midiInClose(h);
	}
	m->handles.clear();
	connected_.clear();
}

int MidiIn::connect_all() {
	int n = 0;
	for (const MidiPort &p : ports()) {
		if (connect(p.client, p.port)) n++;
	}
	return n;
}

std::vector<int> MidiIn::poll_events() {
	std::vector<int> out;
	if (!seq_) return out;
	WinMidi *m = (WinMidi *)seq_;
	std::lock_guard<std::mutex> g(m->lock);
	out.swap(m->queue);
	return out;
}

} // namespace cd

#else
// ---------------------------------------------------------------------------
// Linux: the ALSA sequencer.
// ---------------------------------------------------------------------------
#include <alsa/asoundlib.h>

namespace cd {

MidiIn::~MidiIn() { close(); }

bool MidiIn::open() {
	if (seq_) return true;
	snd_seq_t *seq = nullptr;
	if (snd_seq_open(&seq, "default", SND_SEQ_OPEN_INPUT, SND_SEQ_NONBLOCK) < 0) return false;
	snd_seq_set_client_name(seq, "Cadmium");
	const int p = snd_seq_create_simple_port(seq, "Cadmium In",
			SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_SUBS_WRITE,
			SND_SEQ_PORT_TYPE_APPLICATION | SND_SEQ_PORT_TYPE_MIDI_GENERIC);
	if (p < 0) {
		snd_seq_close(seq);
		return false;
	}
	seq_ = seq;
	my_port_ = p;
	return true;
}

void MidiIn::close() {
	if (!seq_) return;
	disconnect_all();
	snd_seq_close((snd_seq_t *)seq_);
	seq_ = nullptr;
	my_port_ = -1;
}

std::vector<MidiPort> MidiIn::ports() const {
	std::vector<MidiPort> out;
	if (!seq_) return out;
	snd_seq_t *seq = (snd_seq_t *)seq_;
	snd_seq_client_info_t *cinfo;
	snd_seq_port_info_t *pinfo;
	snd_seq_client_info_alloca(&cinfo);
	snd_seq_port_info_alloca(&pinfo);
	snd_seq_client_info_set_client(cinfo, -1);
	while (snd_seq_query_next_client(seq, cinfo) >= 0) {
		const int client = snd_seq_client_info_get_client(cinfo);
		if (client == snd_seq_client_id(seq)) continue;
		snd_seq_port_info_set_client(pinfo, client);
		snd_seq_port_info_set_port(pinfo, -1);
		// Client 0 is the kernel's own sequencer: a timer that ticks forever
		// and an announce port that fires on every subscription change. Both
		// advertise themselves as readable MIDI sources, and subscribing to
		// them buries the poll in events that are not notes -- which froze
		// Cadmium solid at startup, before its window ever appeared.
		if (client == SND_SEQ_CLIENT_SYSTEM) continue;
		while (snd_seq_query_next_port(seq, pinfo) >= 0) {
			const unsigned int caps = snd_seq_port_info_get_capability(pinfo);
			// A source we can subscribe to: anything that reads out MIDI.
			if (!(caps & SND_SEQ_PORT_CAP_READ) || !(caps & SND_SEQ_PORT_CAP_SUBS_READ)) continue;
			// And it has to actually carry MIDI. Everything else on the bus --
			// PipeWire's own control ports, timers, announcements -- is not a
			// keyboard and has no business being connected to one.
			const unsigned int type = snd_seq_port_info_get_type(pinfo);
			const unsigned int midi_types = SND_SEQ_PORT_TYPE_MIDI_GENERIC |
					SND_SEQ_PORT_TYPE_MIDI_GM | SND_SEQ_PORT_TYPE_MIDI_GS |
					SND_SEQ_PORT_TYPE_MIDI_XG | SND_SEQ_PORT_TYPE_MIDI_MT32 |
					SND_SEQ_PORT_TYPE_HARDWARE | SND_SEQ_PORT_TYPE_SYNTHESIZER |
					SND_SEQ_PORT_TYPE_APPLICATION;
			if (!(type & midi_types)) continue;
			MidiPort mp;
			mp.client = client;
			mp.port = snd_seq_port_info_get_port(pinfo);
			mp.name = std::string(snd_seq_client_info_get_name(cinfo)) + ": " + snd_seq_port_info_get_name(pinfo);
			out.push_back(mp);
		}
	}
	return out;
}

bool MidiIn::connect(int client, int port) {
	if (!seq_) return false;
	if (snd_seq_connect_from((snd_seq_t *)seq_, my_port_, client, port) < 0) return false;
	connected_.push_back({client, port});
	return true;
}

void MidiIn::disconnect_all() {
	if (!seq_) return;
	for (auto &c : connected_) snd_seq_disconnect_from((snd_seq_t *)seq_, my_port_, c.first, c.second);
	connected_.clear();
}

int MidiIn::connect_all() {
	int n = 0;
	for (const MidiPort &p : ports()) {
		// "Midi Through" would echo Cadmium's own output straight back in.
		if (p.name.find("Midi Through") != std::string::npos) continue;
		if (connect(p.client, p.port)) n++;
	}
	return n;
}

std::vector<int> MidiIn::poll_events() {
	std::vector<int> out;
	if (!seq_) return out;
	snd_seq_t *seq = (snd_seq_t *)seq_;
	snd_seq_event_t *ev = nullptr;
	// Bounded by events read, not by notes produced. A port that sends
	// something other than notes -- and there are plenty on the bus -- used to
	// keep this loop running for as long as it kept talking, with the whole
	// application stopped behind it.
	int budget = 4096;
	while (budget-- > 0 && snd_seq_event_input(seq, &ev) >= 0 && ev) {
		switch (ev->type) {
			case SND_SEQ_EVENT_NOTEON:
				out.push_back(0x90 | (ev->data.note.channel & 0x0F));
				out.push_back(ev->data.note.note);
				out.push_back(ev->data.note.velocity);
				break;
			case SND_SEQ_EVENT_NOTEOFF:
				out.push_back(0x80 | (ev->data.note.channel & 0x0F));
				out.push_back(ev->data.note.note);
				out.push_back(ev->data.note.velocity);
				break;
			case SND_SEQ_EVENT_CONTROLLER:
				out.push_back(0xB0 | (ev->data.control.channel & 0x0F));
				out.push_back(ev->data.control.param & 0x7F);
				out.push_back(ev->data.control.value & 0x7F);
				break;
			case SND_SEQ_EVENT_PITCHBEND:
				out.push_back(0xE0 | (ev->data.control.channel & 0x0F));
				// ALSA centres the bend on zero; MIDI centres it on 8192.
				out.push_back((ev->data.control.value + 8192) & 0x7F);
				out.push_back(((ev->data.control.value + 8192) >> 7) & 0x7F);
				break;
			default:
				break;
		}
		if (out.size() > 3000) break;
	}
	return out;
}

} // namespace cd

#endif // _WIN32
