// Cadmium — FLARE.
//
// The synthesiser itself is in flare/, host-agnostic and with its own
// parameter table. This is the whole of what Cadmium needs to play it: a
// descriptor built from that table, and a Plug that forwards.
//
// FLARE draws no window of its own here. Its panel is Godot, like every other
// stock processor's -- which is what makes it scale with the rest of the
// program, take the theme, and behave like part of Cadmium rather than a
// canvas embedded in it.
#include "flare/engine.h"
#include "flare/library.h"
#include "flare/params.h"
#include "flare/preset.h"
#include "plugin.h"

#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace cd {

namespace {

/// FLARE's units, in Cadmium's vocabulary. Where Cadmium has no equivalent the
/// nearest one is used and the readout comes from FLARE itself through
/// param_text, so nothing is displayed wrongly.
int kind_of(int k) {
	switch (k) {
		case flare::K_DB: return P_DB;
		case flare::K_HZ: return P_HZ;
		case flare::K_PCT: return P_PCT;
		case flare::K_CHOICE: return P_CHOICE;
		case flare::K_BOOL: return P_BOOL;
		case flare::K_SEMI:
		case flare::K_CENT: return P_SEMI;
		case flare::K_MS: return P_MS;
		case flare::K_SEC: return P_SEC;
		case flare::K_BEATS: return P_BEATS;
		case flare::K_Q: return P_Q;
		default: return P_FLOAT;
	}
}

class FlarePlug : public Plug {
public:
	void prepare() override {
		synth_.prepare(sr, block);
		// Everything Cadmium already had is pushed back in: prepare is called
		// again whenever the rate changes, and a synth that forgot its patch
		// every time the device changed would be a synth nobody could use.
		for (size_t i = 0; i < pv.size(); i++) synth_.set_param((int)i, pv[i]);
	}
	void reset() override { synth_.reset(); }

	void note_on(int key, float vel, int id) override {
		synth_.set_next_expression(next_pan, next_fine);
		next_pan = 0.0f;
		next_fine = 0.0f;
		synth_.note_on(key, vel, id);
	}
	void note_off(int key, int id) override { synth_.note_off(key, id); }
	void all_notes_off() override { synth_.all_notes_off(); }
	void pitch_bend(float semis) override { synth_.pitch_bend(semis); }
	void mod_wheel(float v) override { synth_.mod_wheel(v); }
	void aftertouch(float v) override { synth_.aftertouch(v); }

	void process(float *L, float *R, int n) override {
		synth_.set_transport(bpm, song_beat, playing);
		synth_.process(L, R, n);
	}

	void set_param(int i, float v) override {
		Plug::set_param(i, v);
		synth_.set_param(i, v);
	}

	bool set_string(const std::string &key, const std::string &value) override {
		if (key == "state") {
			if (!flare::preset_from_string(synth_, value)) return false;
		} else if (key == "preset") {
			if (!flare::preset_load(synth_, value)) return false;
		} else if (key == "save_preset") {
			if (!flare::preset_save(synth_, value)) return false;
			flare::library().scan();
			return true;
		} else if (key == "rescan") {
			flare::library().scan();
			return true;
		} else if (key == "name") {
			synth_.preset_name = value;
			return true;
		} else if (key == "init") {
			synth_.set_all_default();
			synth_.preset_name = "Init";
			synth_.preset_type.clear();
			synth_.preset_style.clear();
			synth_.preset_pack.clear();
			for (int i = 0; i < flare::MACRO_N; i++) synth_.set_macro_name(i, std::string());
		} else {
			for (int i = 0; i < flare::PART_N; i++) {
				const std::string pre = std::string("osc") + (char)('a' + i) + ".";
				if (key == pre + "sample") {
					if (value.empty()) { synth_.clear_sample(i); return true; }
					return synth_.load_sample(i, value);
				}
				if (key == pre + "wavetable") return synth_.load_wavetable(i, value);
			}
			for (int i = 0; i < flare::MACRO_N; i++) {
				if (key == "macro" + std::to_string(i + 1) + "_name") {
					synth_.set_macro_name(i, value);
					return true;
				}
			}
			return false;
		}
		// A preset moves every control at once, so Cadmium's own copy of the
		// values is brought back into line or the panel keeps drawing the
		// patch that was there before.
		for (size_t i = 0; i < pv.size(); i++) pv[i] = synth_.get_param((int)i);
		return true;
	}

	std::string get_string(const std::string &key) const override {
		if (key == "state") return flare::preset_to_string(synth_);
		if (key == "presets") {
			if (!flare::library().scanned()) flare::library().scan();
			return flare::library().presets_json();
		}
		if (key == "content") {
			if (!flare::library().scanned()) flare::library().scan();
			return flare::library().content_json();
		}
		if (key == "meta") {
			flare::Json j = flare::Json::object();
			j.set("name", flare::Json::string(synth_.preset_name));
			j.set("author", flare::Json::string(synth_.preset_author));
			j.set("type", flare::Json::string(synth_.preset_type));
			j.set("style", flare::Json::string(synth_.preset_style));
			j.set("pack", flare::Json::string(synth_.preset_pack));
			j.set("user_dir", flare::Json::string(flare::user_preset_dir()));
			flare::Json macros = flare::Json::array();
			for (int i = 0; i < flare::MACRO_N; i++)
				macros.push(flare::Json::string(synth_.macro_name(i)));
			j.set("macros", macros);
			for (int i = 0; i < flare::PART_N; i++) {
				const std::string pre = std::string("osc") + (char)('a' + i) + ".";
				j.set(pre + "sample", flare::Json::string(synth_.source(i).sample_path));
				j.set(pre + "wavetable", flare::Json::string(synth_.source(i).wavetable_path));
			}
			return j.dump();
		}
		if (key.compare(0, 10, "soundfont:") == 0)
			return flare::Library::soundfont_presets_json(key.substr(10));
		return std::string();
	}

	std::string param_text(int index, float value) const override {
		return flare::param_text(index, value);
	}

	/// What the panel draws. 0 is a cycle of each oscillator, 1 the filter's
	/// response, 2 the voice count and output level.
	int aux(int what, float *out, int max) override {
		if (!out || max <= 0) return 0;
		switch (what) {
			case 0: {
				const int per = 96;
				int written = 0;
				for (int part = 0; part < flare::PART_N && written + per <= max; part++) {
					const flare::PartSource &s = synth_.source(part);
					const int base = flare::layout().part + part * flare::PRT_COUNT;
					const float pos = synth_.get_param(base + flare::PRT_POS);
					for (int i = 0; i < per; i++) {
						out[written + i] = s.table
								? s.table->read(pos, (float)i / (float)per, 2) : 0.0f;
					}
					written += per;
				}
				return written;
			}
			case 2:
				out[0] = (float)synth_.active_voices();
				if (max > 1) out[1] = synth_.peak();
				return max > 1 ? 2 : 1;
			default:
				return 0;
		}
	}

	int active_voices() const override { return synth_.active_voices(); }
	float tail() const override { return 6.0f; }

private:
	flare::Synth synth_;
};

Plug *make_flare() { return new FlarePlug(); }

} // namespace

void register_flare(std::vector<PlugDesc> &out) {
	PlugDesc d;
	d.id = "cd.flare";
	d.name = "FLARE";
	d.vendor = "Cadmium";
	d.category = "Synth";
	d.instrument = true;
	d.ui = UI_FLARE;
	d.make = make_flare;
	// Built from FLARE's own table rather than written out again here. The
	// strings belong to that table, which is a static that outlives every
	// instance, so pointing at them is safe for the life of the program -- and
	// the two can never drift apart, because there is only one of them.
	const std::vector<flare::ParamInfo> &src = flare::params();
	d.params.reserve(src.size());
	for (const flare::ParamInfo &p : src) {
		ParamDesc q;
		q.id = p.id.c_str();
		q.name = p.name.c_str();
		q.min = p.min;
		q.max = p.max;
		q.def = p.def;
		q.kind = kind_of(p.kind);
		q.group = p.group.c_str();
		q.choices = p.choices.c_str();
		q.skew = p.skew > 0.0f ? p.skew : 1.0f;
		q.steps = p.steps;
		q.readonly = false;
		d.params.push_back(q);
	}
	out.push_back(d);
}

} // namespace cd
