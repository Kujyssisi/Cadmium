#include "keyboard.h"

#if defined(__linux__)
#include <X11/Xlib.h>
#elif defined(_WIN32)
#include <windows.h>
#endif

namespace cd {

#if defined(__linux__)
/// A connection of our own, opened once and kept.
///
/// XQueryKeymap is a round trip to the X server, so it is only ever asked while
/// a key is actually being held -- see the caller. Godot's own connection is
/// not used because this is asked from a different place in the frame and
/// sharing a connection across that is not worth the trouble.
static Display *keyboard_display() {
	static Display *display = nullptr;
	static bool tried = false;
	if (!tried) {
		tried = true;
		display = XOpenDisplay(nullptr);
	}
	return display;
}
#endif

bool any_key_held() {
#if defined(__linux__)
	Display *display = keyboard_display();
	if (!display) return true;
	// A bit per key on the whole keyboard, whoever the keys are going to.
	char keys[32] = {0};
	if (!XQueryKeymap(display, keys)) return true;
	for (int i = 0; i < 32; i++) {
		if (keys[i] != 0) return true;
	}
	return false;
#elif defined(_WIN32)
	// From 0x07: below that are the mouse buttons, and a held mouse button is
	// not somebody holding a note.
	for (int vk = 0x07; vk <= 0xFE; vk++) {
		if (GetAsyncKeyState(vk) & 0x8000) return true;
	}
	return false;
#else
	return true;
#endif
}

}  // namespace cd
