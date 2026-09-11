// Cadmium — VST3 host.
//
// Loads a plugin bundle, wires component and controller together, and presents
// the result as an ordinary cd::Plug so the mixer does not care whether a slot
// holds stock DSP or somebody else's.
#pragma once

#include "plugin.h"

#include <memory>
#include <string>
#include <vector>

namespace cd {

struct Vst3Info {
	std::string path;      // bundle path
	std::string cid;       // 32-char hex of the class TUID
	std::string name;
	std::string vendor;
	std::string category;  // subCategories string as reported
	std::string version;
	bool instrument = false;
	// Set when the bundle could not be read at all: no module, no factory, or
	// no audio class in it. A plugin that fails silently is indistinguishable
	// from one that is not installed, which is exactly the report we kept
	// getting -- so the failure travels with the results instead.
	std::string error;
};

// Scans the standard VST3 locations plus anything extra passed in.
std::vector<Vst3Info> vst3_scan(const std::vector<std::string> &dirs);
std::vector<std::string> vst3_default_dirs();

/// Every bundle under `dirs`, without opening any of them. The caller probes
/// them one at a time so it can show progress, keep a per-bundle cache, and
/// know which one was being opened if opening it takes the process down.
std::vector<std::string> vst3_bundles(const std::vector<std::string> &dirs);

/// Probes one bundle. Always returns at least one entry: on failure, a single
/// one with `error` filled in.
std::vector<Vst3Info> vst3_scan_bundle(const std::string &bundle);

/// Closes modules that were only ever opened to be scanned. A plugin with a
/// live instance is left alone -- unloading one of those is what used to take
/// Cadmium down on quit.
void vst3_release_unused_modules();

class Vst3Impl;

class Vst3Plug : public Plug {
public:
	Vst3Plug();
	~Vst3Plug() override;

	bool load(const std::string &bundle, const std::string &cid, double rate, int blk);
	bool ok() const;
	const std::string &error() const;

	void prepare() override;
	void reset() override;
	void note_on(int key, float vel, int id) override;
	void note_off(int key, int id) override;
	void all_notes_off() override;
	void pitch_bend(float semis) override;
	void mod_wheel(float v) override;
	void process(float *L, float *R, int n) override;
	void set_param(int i, float v) override;
	bool set_string(const std::string &key, const std::string &value) override;
	std::string get_string(const std::string &key) const override;
	int active_voices() const override { return 0; }

	// The dynamically built descriptor this instance points `desc` at.
	PlugDesc dyn;
	std::vector<std::string> group_pool;   // keeps group name storage alive
	std::vector<std::string> name_pool;
	std::vector<std::string> id_pool;

	std::string state_base64() const;
	bool restore_base64(const std::string &s);
	std::string param_display(int i, float normalized) const;
	// Parameter edits the plugin's own editor made, as "index:value" lines.
	std::string drain_edits();

	/// The plugin's own editor. `parent` is a native window handle (X11 Window
	/// id or HWND); the view is placed in a child window at x,y so Cadmium's
	/// own strip can stay visible above it.
	bool has_editor();
	bool open_editor(uint64_t parent, int x, int y, int w, int h);
	void close_editor();
	void editor_idle();
	bool editor_open() const;
	void editor_size(int &w, int &h);
	void editor_move(int x, int y, int w, int h);
	bool editor_take_resize(int &w, int &h);
	/// False when the plugin's view is a fixed size.
	bool editor_can_resize() const;
	void editor_constrain(int &w, int &h) const;
	/// Puts keyboard focus into the plugin's own window.
	void editor_focus();
	void editor_unfocus();
	bool editor_has_keys() const;
	bool editor_ready() const;
	bool editor_started() const;
	/// True when the plugin puts processing and interface in one object.
	bool single_component() const;
	/// True once, when the plugin has said its parameters have all moved --
	/// which is what happens when a preset is chosen inside its own window.
	bool take_restart();
	/// Pretends the plugin's own interface moved a control, so the path from
	/// its editor to its audio side can be tested without a pair of hands.
	void simulate_gui_edit(int i, float v);
	/// True when the object driving the interface is the one making the sound.
	/// These two agreeing is what keeps a plugin's own knobs connected to what
	/// you hear.
	bool controller_is_component() const;
	void editor_show();
	bool editor_showing() const;
	/// What the plugin itself says a parameter is, rather than what we last
	/// told it. The two disagreeing is a plugin refusing the value.
	float param_live(int i) const;
	/// The scale the display is running at, for views that lay out on it.
	void editor_set_scale(float factor);
	bool editor_grab(std::vector<unsigned char> &rgb, int &w, int &h) const;
	std::string editor_debug();

private:
	std::unique_ptr<Vst3Impl> d;
};

} // namespace cd
