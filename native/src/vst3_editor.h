// Cadmium — the plugin-drawn editor, embedded in one of our windows.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"

namespace cd {

/// A run loop that belongs to the process rather than to any one editor, for
/// the host context the plugin factory is given. Pumped from vst3_pump_global()
/// once a frame.
Steinberg::FUnknown *vst3_global_run_loop();
void vst3_pump_global();

class Vst3Editor {
public:
	Vst3Editor();
	~Vst3Editor();

	/// Asks the controller for a view and checks it speaks this platform.
	bool create(Steinberg::Vst::IEditController *controller);
	bool available() const;
	bool is_open() const;
	void size(int &w, int &h) const;

	/// `parent` is a native window handle: an X11 Window id, or an HWND.
	bool open(uint64_t parent, int x, int y, int w, int h);
	/// Tells a view that cares what the display's scale is, so its interface
	/// comes out the same size as everything around it.
	void set_scale(float factor);
	void move(int x, int y, int w, int h);
	void close();
	/// Takes the size the view reports once it is attached, if it changed its
	/// mind on the way. See the definition.
	void adopt_view_size();
	/// Closes and lets go of the view. Must happen before the controller that
	/// made the view is terminated.
	void destroy();
	/// Runs the plugin's event loop for one frame (Linux); harmless elsewhere.
	void idle();
	/// Makes the plugin's own window match the container, for plugins that do
	/// not do it themselves. Called from idle().
	void fit_child();

	/// False when the plugin refuses to be resized: the host window should be
	/// locked to the size the plugin asks for.
	bool can_resize() const;
	/// The nearest size the plugin says it can actually draw at. The host has
	/// to move its window to this, or the window and the canvas disagree.
	void constrain(int &w, int &h) const;
	/// Nudges keyboard focus into the plugin's own window so its text fields
	/// and typing shortcuts work. No-op where the platform handles it.
	void focus();

	/// Reads back what the plugin actually drew, as tightly packed RGB8.
	/// Empty when there is nothing on screen to read. This is how the test
	/// harness tells "the editor opened" from "the editor painted".
	bool grab(std::vector<unsigned char> &rgb, int &w, int &h) const;

	/// A resize the plugin asked for, if one is pending.
	bool take_resize(int &w, int &h);
	void on_resize_request(int w, int h);

	void unfocus();
	bool has_keyboard() const;
	bool ready() const;
	bool started() const;
	void show();
	bool showing() const;
	Steinberg::FUnknown *run_loop_context();
	/// What actually happened after attaching -- child windows, run-loop
	/// registrations, sizes. Diagnostics for "the plugin drew nothing".
	std::string debug() const;
	static const char *platform_type();

private:
	struct Impl;
	Impl *d;
};

} // namespace cd
