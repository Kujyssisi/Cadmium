// Cadmium — hosting a VST3 plugin's own editor inside one of our windows.
//
// The plugin draws into a child window we create inside a Godot window: an X11
// child on Linux, a child HWND on Windows. Linux additionally requires the host
// to run the plugin's event loop for it (there is no global one), so we
// implement IRunLoop and pump it from the frame loop.
#include "vst3_editor.h"

#include "crashlog.h"

#include <cctype>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#if defined(__linux__)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <poll.h>
#elif defined(_WIN32)
#include <windows.h>
#endif

#include "pluginterfaces/gui/iplugviewcontentscalesupport.h"

using namespace Steinberg;

// The SDK's interface identifiers live in a source file we do not compile, so
// the one we ask for by name is defined here. Every other identifier this host
// uses comes from a header that defines it inline.
DEF_CLASS_IID(Steinberg::IPlugViewContentScaleSupport)

namespace cd {

/// Where the canvas waits while the plugin builds it: directly below the area
/// of the window it belongs to, which is outside the parent's client area and
/// so clipped away entirely. Below rather than off to one side, because a
/// plugin that works out its scaling from the monitor its window is on should
/// go on finding the same monitor.
static int parked_y(int y, int h) { return y + std::max(1, h) + 8; }

#if defined(_WIN32)
/// Where a container of Cadmium's own waits instead: a window that is not
/// inside anything cannot be clipped away by a parent, so it goes somewhere
/// no monitor reaches. It stays visible as far as the plugin is concerned.
static const int kParkX = -20000;
static const int kParkY = -20000;

/// Godot draws its windows with Vulkan, which presents over the whole of the
/// client area every frame and takes no notice of child windows sitting in it:
/// a plugin canvas parented into one is painted over sixty times a second,
/// which is what a plugin interface that is "there but mostly not drawn" is.
/// A window of Cadmium's own, owned by the Godot window and kept over the same
/// rectangle a child would have filled, is composed by the system separately
/// and cannot be painted over. It looks the same and behaves the same.
///
/// The old way is still one environment variable away, for the day a machine
/// disagrees: CADMIUM_PLUGIN_WINDOW=child.
static bool own_window_wanted() {
	static bool asked = false;
	static bool want = true;
	if (asked) return want;
	asked = true;
	const char *how = getenv("CADMIUM_PLUGIN_WINDOW");
	if (how && *how) {
		std::string s;
		for (const char *c = how; *c; c++) s.push_back((char)tolower((unsigned char)*c));
		want = (s != "child");
	}
	return want;
}
#endif

static bool ed_iid_eq(const TUID a, const TUID b) { return std::memcmp(a, b, 16) == 0; }

#if defined(__linux__)
// Xlib's default error handler calls exit(). A plugin that draws into a window
// we destroyed, or a focus request that loses a race with an unmap, is a normal
// event during embedding and must not take the whole DAW down with it.
static int cd_x_error(Display *, XErrorEvent *) { return 0; }

/// Swallows X errors for the duration of a block and restores the handler that
/// was there before -- Godot installs its own and reports through it.
struct XErrGuard {
	XErrorHandler prev;
	XErrGuard() : prev(XSetErrorHandler(cd_x_error)) {}
	~XErrGuard() { XSetErrorHandler(prev); }
};
#endif

#if defined(_WIN32)
// A container of our own rather than a STATIC control. STATIC answers a hit
// test with "transparent", which sends the mouse to whatever is behind it --
// and what is behind it is Cadmium's window, not the plugin. It also paints
// its own background, which flickers under a plugin that draws every frame.
static const wchar_t *kHostClass = L"CadmiumVst3Host";

static LRESULT CALLBACK cd_host_proc(HWND h, UINT m, WPARAM w, LPARAM l) {
	switch (m) {
		case WM_ERASEBKGND:
			return 1;             // the plugin covers it; painting twice flickers
		case WM_NCHITTEST:
			return HTCLIENT;      // the mouse belongs to what is inside
		default:
			return DefWindowProcW(h, m, w, l);
	}
}

static void register_host_class() {
	static bool done = false;
	if (done) return;
	done = true;
	WNDCLASSEXW wc{};
	wc.cbSize = sizeof(wc);
	wc.style = CS_HREDRAW | CS_VREDRAW;
	wc.lpfnWndProc = cd_host_proc;
	wc.hInstance = GetModuleHandleW(nullptr);
	wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
	wc.hbrBackground = nullptr;
	wc.lpszClassName = kHostClass;
	RegisterClassExW(&wc);
}

/// The window the plugin made inside our container, if it has made one yet.
static HWND first_child(HWND parent) {
	return parent ? GetWindow(parent, GW_CHILD) : nullptr;
}
#endif

#define CD_ED_REFS \
	uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1000; } \
	uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1000; }

#if defined(__linux__)
// ---------------------------------------------------------------------------
// Linux run loop: the plugin hands us file descriptors and timers, we call it
// back when they are ready. JUCE and VSTGUI plugins will not draw without it.
// ---------------------------------------------------------------------------
class RunLoop : public Linux::IRunLoop {
public:
	struct Fd {
		Linux::IEventHandler *handler;
		int fd;
	};
	struct Timer {
		Linux::ITimerHandler *handler;
		uint64 interval;
		uint64 next;
	};
	std::vector<Fd> fds;
	std::vector<Timer> timers;

	tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE {
		if (ed_iid_eq(_iid, FUnknown_iid) || ed_iid_eq(_iid, Linux::IRunLoop_iid)) {
			*obj = this;
			return kResultOk;
		}
		*obj = nullptr;
		return kNoInterface;
	}
	CD_ED_REFS

	static uint64 now_ms() {
		return (uint64)std::chrono::duration_cast<std::chrono::milliseconds>(
				std::chrono::steady_clock::now().time_since_epoch()).count();
	}

	tresult PLUGIN_API registerEventHandler(Linux::IEventHandler *handler, Linux::FileDescriptor fd) SMTG_OVERRIDE {
		if (!handler) return kInvalidArgument;
		fds.push_back({handler, fd});
		return kResultOk;
	}
	tresult PLUGIN_API unregisterEventHandler(Linux::IEventHandler *handler) SMTG_OVERRIDE {
		for (auto it = fds.begin(); it != fds.end();) {
			if (it->handler == handler) it = fds.erase(it); else ++it;
		}
		return kResultOk;
	}
	tresult PLUGIN_API registerTimer(Linux::ITimerHandler *handler, Linux::TimerInterval ms) SMTG_OVERRIDE {
		if (!handler) return kInvalidArgument;
		const uint64 interval = ms < 1 ? 1 : (uint64)ms;
		timers.push_back({handler, interval, now_ms() + interval});
		return kResultOk;
	}
	tresult PLUGIN_API unregisterTimer(Linux::ITimerHandler *handler) SMTG_OVERRIDE {
		for (auto it = timers.begin(); it != timers.end();) {
			if (it->handler == handler) it = timers.erase(it); else ++it;
		}
		return kResultOk;
	}

	/// How many times one file descriptor may be serviced in a single pump.
	/// A toolkit that handles one event per call would otherwise fall behind by
	/// everything the mouse produced since the last frame, and dragging a knob
	/// would lag by however long a frame takes.
	static const int kMaxServicePerFd = 64;

	void pump() {
		for (size_t i = 0; i < fds.size(); i++) {
			const int fd = fds[i].fd;
			Linux::IEventHandler *handler = fds[i].handler;
			// Serviced at least once whether or not the socket has anything:
			// a toolkit that has already read its events into its own queue
			// shows nothing on the socket and still has work to do.
			handler->onFDIsSet(fd);
			for (int n = 0; n < kMaxServicePerFd; n++) {
				// The handler may have unregistered itself; re-check the slot.
				if (i >= fds.size() || fds[i].fd != fd || fds[i].handler != handler) break;
				pollfd pf{fd, POLLIN, 0};
				// Zero timeout: this runs inside the host's frame and must
				// never block it.
				if (poll(&pf, 1, 0) <= 0 || !(pf.revents & POLLIN)) break;
				handler->onFDIsSet(fd);
			}
		}
		const uint64 t = now_ms();
		for (size_t i = 0; i < timers.size(); i++) {
			if (t < timers[i].next) continue;
			// Never more than one catch-up call: a repaint timer that fell
			// behind wants to draw the current state once, not once per frame
			// it missed.
			timers[i].next = t + timers[i].interval;
			Linux::ITimerHandler *h = timers[i].handler;
			h->onTimer();
			if (i >= timers.size()) break;
		}
	}
};
#endif

// ---------------------------------------------------------------------------
// IPlugFrame: the plugin asks us to resize through this, and on Linux fetches
// the run loop from it.
// ---------------------------------------------------------------------------
class PlugFrame : public IPlugFrame {
public:
	Vst3Editor *owner = nullptr;
#if defined(__linux__)
	RunLoop run_loop;
#endif

	tresult PLUGIN_API queryInterface(const TUID _iid, void **obj) SMTG_OVERRIDE {
		if (ed_iid_eq(_iid, FUnknown_iid) || ed_iid_eq(_iid, IPlugFrame_iid)) {
			*obj = this;
			return kResultOk;
		}
#if defined(__linux__)
		if (ed_iid_eq(_iid, Linux::IRunLoop_iid)) {
			*obj = &run_loop;
			return kResultOk;
		}
#endif
		*obj = nullptr;
		return kNoInterface;
	}
	CD_ED_REFS

	tresult PLUGIN_API resizeView(IPlugView *, ViewRect *newSize) SMTG_OVERRIDE;
};

#if defined(__linux__)
/// Asks X to send Expose events for a window and everything inside it.
///
/// A toolkit that only paints when it is told to -- and several do -- draws
/// nothing at all if the host hands it a window whose size it had already
/// chosen, because then nothing generates the first expose. This is the host
/// saying "you are on screen now, draw".
static void expose_all(Display *dpy, Window w) {
	if (!dpy || !w) return;
	XClearArea(dpy, w, 0, 0, 0, 0, True);
	Window root = 0, parent = 0, *kids = nullptr;
	unsigned int n = 0;
	if (XQueryTree(dpy, w, &root, &parent, &kids, &n) && kids) {
		for (unsigned int i = 0; i < n; i++) expose_all(dpy, kids[i]);
		XFree(kids);
	}
}
#endif

// A run loop that outlives every editor, for the factory-wide host context.
// Handing a plugin factory a context that belongs to one plugin instance is a
// use-after-free waiting to happen: the factory keeps the pointer, and the
// instance that owned it goes away first.
#if defined(__linux__)
static RunLoop g_run_loop;

FUnknown *vst3_global_run_loop() { return (FUnknown *)&g_run_loop; }
void vst3_pump_global() { g_run_loop.pump(); }
#else
FUnknown *vst3_global_run_loop() { return nullptr; }
void vst3_pump_global() {}
#endif

// ---------------------------------------------------------------------------
struct Vst3Editor::Impl {
	IPlugView *view = nullptr;
	Vst::IEditController *controller = nullptr;   // kept so a view can be remade
	PlugFrame frame;
	bool attached = false;
	int req_w = 0, req_h = 0;
	bool resize_pending = false;
	int cur_w = 0, cur_h = 0;
	/// Consecutive idles where the plugin's own window did not match the
	/// container. Used to correct the ones that ignore onSize without
	/// fighting the ones that honour it.
	int fit_strikes = 0;
	/// Why the last open failed, for the test harness to report.
	std::string last_err;
	/// What the display is scaled by, as Godot sees it. Applied to the view
	/// when there is one, and again after every fresh one is made.
	float scale = 1.0f;
	/// The plugin's canvas is parked outside the window it belongs to until it
	/// has finished building itself. It is a window of the operating system's,
	/// drawn over anything Godot paints, so it cannot be covered up -- but a
	/// child window outside its parent is clipped away entirely, which comes
	/// to the same thing and still lets the plugin believe it is on screen.
	bool parked = false;
	int want_x = 0, want_y = 0;
#if defined(__linux__)
	Display *display = nullptr;
	Window child = 0;
#elif defined(_WIN32)
	HWND child = nullptr;
	/// The window the canvas belongs to. Kept because a container of our own
	/// is placed in screen coordinates, and the caller talks in that window's.
	HWND parent = nullptr;
	/// Whether the container is a window of Cadmium's own rather than a child
	/// window inside Godot's. See open().
	bool own_window = false;
	bool shown_now = true;
	RECT placed{0, 0, 0, 0};

	/// Puts the container where the canvas is meant to be. A child window is
	/// placed in the parent's client coordinates; a window of our own has to
	/// be put in the screen's -- which is also how it follows Cadmium about
	/// when the window it belongs to is dragged.
	/// Where a container of our own waits while the plugin builds what goes in
	/// it. Nowhere any monitor reaches: a window of our own is not inside
	/// anything, so it cannot be parked just outside a parent and clipped away
	/// the way the Linux one is. Putting it a pixel onto the screen instead --
	/// so that a plugin asking which monitor it is on gets an answer -- was
	/// tried and made every editor come up blank.
	POINT parked_screen() { return POINT{kParkX, kParkY}; }

	void place(int w, int h) {
		if (!child) return;
		w = (std::max)(1, w);
		h = (std::max)(1, h);
		int x = want_x, y = want_y;
		if (own_window) {
			if (parked) {
				const POINT p = parked_screen();
				x = p.x;
				y = p.y;
			} else {
				POINT pt{want_x, want_y};
				if (parent) ClientToScreen(parent, &pt);
				x = pt.x;
				y = pt.y;
			}
		} else if (parked) {
			y = parked_y(want_y, h);
		}
		const RECT want{x, y, x + w, y + h};
		if (std::memcmp(&want, &placed, sizeof(RECT)) == 0) return;
		placed = want;
		SetWindowPos(child, nullptr, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
	}
#endif
};

tresult PLUGIN_API PlugFrame::resizeView(IPlugView *view, ViewRect *newSize) {
	if (!owner || !newSize) return kInvalidArgument;
	owner->on_resize_request(newSize->getWidth(), newSize->getHeight());
	// Accept the size, then tell the view it now has it -- a plugin that asked
	// to grow will not redraw until onSize confirms.
	if (view) view->onSize(newSize);
	return kResultTrue;
}

Vst3Editor::Vst3Editor() : d(new Impl()) { d->frame.owner = this; }

Vst3Editor::~Vst3Editor() {
	destroy();
	delete d;
}

void Vst3Editor::destroy() {
	close();
	d->controller = nullptr;
#if defined(__linux__)
	if (d->display) {
		XCloseDisplay(d->display);
		d->display = nullptr;
	}
#endif
}

const char *Vst3Editor::platform_type() {
#if defined(_WIN32)
	return kPlatformTypeHWND;
#else
	return kPlatformTypeX11EmbedWindowID;
#endif
}

bool Vst3Editor::create(Vst::IEditController *controller) {
	if (controller) d->controller = controller;
	if (d->view) return true;
	if (!d->controller) return false;
	d->view = d->controller->createView(Vst::ViewType::kEditor);
	if (!d->view) return false;
	if (d->view->isPlatformTypeSupported(platform_type()) != kResultTrue) {
		d->view->release();
		d->view = nullptr;
		return false;
	}
	// Before it is attached, so a view that lays itself out on the scale gets
	// it in time to ask for the right size.
	set_scale(d->scale);
	return true;
}

void Vst3Editor::set_scale(float factor) {
	if (factor > 0.05f && factor < 16.0f) d->scale = factor;
	if (!d->view) return;
	IPlugViewContentScaleSupport *css = nullptr;
	if (d->view->queryInterface(IPlugViewContentScaleSupport::iid, (void **)&css) == kResultOk && css) {
		css->setContentScaleFactor((IPlugViewContentScaleSupport::ScaleFactor)d->scale);
		css->release();
	}
}


bool Vst3Editor::available() const { return d->view != nullptr; }
bool Vst3Editor::is_open() const { return d->attached; }

void Vst3Editor::size(int &w, int &h) const {
	w = 0;
	h = 0;
	if (!d->view) return;
	ViewRect r{};
	if (d->view->getSize(&r) == kResultOk) {
		w = r.getWidth();
		h = r.getHeight();
	}
}

void Vst3Editor::on_resize_request(int w, int h) {
	d->req_w = w;
	d->req_h = h;
	d->resize_pending = true;
	d->cur_w = w;
	d->cur_h = h;
#if defined(__linux__)
	if (d->display && d->child) {
		XResizeWindow(d->display, d->child, (unsigned)std::max(1, w), (unsigned)std::max(1, h));
		XFlush(d->display);
	}
#elif defined(_WIN32)
	if (d->child) {
		SetWindowPos(d->child, nullptr, 0, 0, std::max(1, w), std::max(1, h),
				SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
	}
#endif
}

bool Vst3Editor::take_resize(int &w, int &h) {
	if (!d->resize_pending) return false;
	d->resize_pending = false;
	w = d->req_w;
	h = d->req_h;
	return true;
}

bool Vst3Editor::open(uint64_t parent, int x, int y, int w, int h) {
	// The last close let go of the view; make a new one.
	if (!d->view) create(nullptr);
	if (!d->view || d->attached) return d->attached;
	if (w <= 0 || h <= 0) size(w, h);
	if (w <= 0 || h <= 0) {
		w = 800;
		h = 600;
	}
#if defined(__linux__)
	// A child window of our own, so the plugin's canvas can be positioned under
	// Cadmium's toolbar instead of over it. Godot owns the parent window on its
	// own X connection; window ids are server-side, so a second connection can
	// still parent to it.
	XErrGuard xguard;
	if (!d->display) d->display = XOpenDisplay(nullptr);
	if (!d->display) return false;
	const Window parent_win = (Window)parent;
	// Godot selects SubstructureRedirectMask on its windows, which turns a map
	// request for any child into a MapRequest event it then ignores -- the
	// container would exist and never appear. override_redirect bypasses the
	// redirection, which is what an embedded plugin canvas wants anyway.
	XSetWindowAttributes swa{};
	swa.background_pixel = 0x00202020;
	swa.border_pixel = 0;
	swa.override_redirect = True;
	swa.event_mask = StructureNotifyMask | SubstructureNotifyMask;
	d->parked = true;
	d->want_x = x;
	d->want_y = y;
	d->child = XCreateWindow(d->display, parent_win, x, parked_y(y, h), (unsigned)w, (unsigned)h, 0,
			CopyFromParent, InputOutput, CopyFromParent,
			CWBackPixel | CWBorderPixel | CWOverrideRedirect | CWEventMask, &swa);
	if (!d->child) return false;
	XMapWindow(d->display, d->child);
	XRaiseWindow(d->display, d->child);
	XSync(d->display, False);
	d->view->setFrame(&d->frame);
	if (d->view->attached((void *)(uintptr_t)d->child, platform_type()) != kResultOk) {
		XDestroyWindow(d->display, d->child);
		d->child = 0;
		XFlush(d->display);
		return false;
	}
	ViewRect r(0, 0, w, h);
	d->view->onSize(&r);
	expose_all(d->display, d->child);
	XFlush(d->display);
#elif defined(_WIN32)
	register_host_class();
	d->parked = true;
	d->want_x = x;
	d->want_y = y;
	d->parent = (HWND)(uintptr_t)parent;
	d->own_window = own_window_wanted();
	d->shown_now = true;
	d->placed = RECT{0, 0, 0, 0};
	if (d->own_window) {
		// Owned by Godot's window, so it stays above it, goes away with it and
		// never turns up in the taskbar or in Alt-Tab as a window of its own.
		const POINT pt = d->parked_screen();
		d->child = CreateWindowExW(WS_EX_TOOLWINDOW, kHostClass, L"",
				WS_POPUP | WS_VISIBLE | WS_CLIPCHILDREN,
				pt.x, pt.y, w, h, d->parent, nullptr,
				GetModuleHandleW(nullptr), nullptr);
		d->placed = RECT{pt.x, pt.y, pt.x + w, pt.y + h};
	} else {
		// A child window is only ever seen if the parent leaves its area
		// alone, which is what this style is for.
		if (d->parent) {
			const LONG_PTR st = GetWindowLongPtrW(d->parent, GWL_STYLE);
			if (st && !(st & WS_CLIPCHILDREN)) {
				SetWindowLongPtrW(d->parent, GWL_STYLE, st | WS_CLIPCHILDREN);
			}
		}
		d->child = CreateWindowExW(0, kHostClass, L"", WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN,
				x, parked_y(y, h), w, h, d->parent, nullptr,
				GetModuleHandleW(nullptr), nullptr);
		d->placed = RECT{x, parked_y(y, h), x + w, parked_y(y, h) + h};
	}
	if (!d->child) {
		char e[128];
		snprintf(e, sizeof(e), "CreateWindowEx failed (%lu) parent=%p",
				(unsigned long)GetLastError(), (void *)(uintptr_t)parent);
		d->last_err = e;
		return false;
	}
	d->view->setFrame(&d->frame);
	if (d->view->attached((void *)d->child, platform_type()) != kResultOk) {
		d->last_err = "the view refused the window";
		DestroyWindow(d->child);
		d->child = nullptr;
		return false;
	}
	d->last_err.clear();
	// The container paints nothing of its own afterwards -- painting under a
	// plugin that draws every frame is what makes an interface flicker -- so
	// whatever it is going to show around a canvas smaller than itself is put
	// there once, now, rather than being left as whatever was on the screen.
	if (HDC dc = GetDC(d->child)) {
		RECT rc{};
		GetClientRect(d->child, &rc);
		if (HBRUSH br = CreateSolidBrush(RGB(32, 32, 32))) {
			FillRect(dc, &rc, br);
			DeleteObject(br);
		}
		ReleaseDC(d->child, dc);
	}
	ViewRect r(0, 0, w, h);
	d->view->onSize(&r);
	// A canvas that was built while nothing was watching does not always paint
	// itself when it is finally looked at.
	RedrawWindow(d->child, nullptr, nullptr,
			RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
#else
	(void)parent; (void)x; (void)y;
	return false;
#endif
	d->attached = true;
	d->cur_w = w;
	d->cur_h = h;
	adopt_view_size();
	return true;
}

/// What the view says it is once it is attached, which is not always what it
/// said before.
///
/// A plugin told the display is scaled works its layout out when it has a
/// window to work it out against, and several of the big ones only report the
/// scaled size afterwards. Sized from the earlier answer, the canvas is a
/// third bigger than the container it is drawing into: the interface comes up
/// at the wrong scale with most of it off the edge, which is exactly what
/// "the plugin window is broken" looks like. So it is asked again, and the
/// second answer is the one that counts -- the container is resized to it and
/// the window Cadmium put it in follows, the same way it follows a plugin that
/// asks for a new size later.
void Vst3Editor::adopt_view_size() {
	if (!d->view || !d->attached) return;
	ViewRect after{};
	if (d->view->getSize(&after) != kResultOk) return;
	const int vw = after.getWidth();
	const int vh = after.getHeight();
	if (vw <= 32 || vh <= 32) return;
	if (std::abs(vw - d->cur_w) <= 2 && std::abs(vh - d->cur_h) <= 2) return;
	on_resize_request(vw, vh);
	ViewRect r(0, 0, vw, vh);
	d->view->onSize(&r);
}

void Vst3Editor::move(int x, int y, int w, int h) {
	if (!d->attached) return;
#if defined(__linux__)
	XErrGuard xguard;
#endif
	w = std::max(1, w);
	h = std::max(1, h);
	// A plugin that asked to be a given size gets told about a resize only when
	// the size really changed. Echoing its own request back at it makes
	// VSTGUI-based editors redraw in a loop and flicker.
	const bool same = (w == d->cur_w && h == d->cur_h);
	if (d->view && !same) {
		ViewRect want(0, 0, w, h);
		// Let the plugin snap the size to something it can actually draw.
		if (d->view->checkSizeConstraint(&want) == kResultTrue) {
			if (want.getWidth() > 0 && want.getHeight() > 0) {
				w = want.getWidth();
				h = want.getHeight();
			}
		}
	}
	d->cur_w = w;
	d->cur_h = h;
	d->want_x = x;
	d->want_y = y;
	const int py = d->parked ? parked_y(y, h) : y;
#if defined(__linux__)
	if (d->display && d->child) {
		XMoveResizeWindow(d->display, d->child, x, py, (unsigned)std::max(1, w), (unsigned)std::max(1, h));
		XFlush(d->display);
	}
#elif defined(_WIN32)
	(void)py;
	d->place(w, h);
#endif
	if (d->view && !same) {
		ViewRect r(0, 0, w, h);
		d->view->onSize(&r);
#if defined(__linux__)
		if (d->display && d->child) {
			expose_all(d->display, d->child);
			XFlush(d->display);
		}
		// Whether the plugin actually took the new size is checked from idle(),
		// not here: a plugin resizes its own window from its own event loop,
		// which has not run yet.
		d->fit_strikes = 0;
#endif
	}
}

bool Vst3Editor::can_resize() const {
	return d->view != nullptr && d->view->canResize() == kResultTrue;
}

void Vst3Editor::constrain(int &w, int &h) const {
	if (!d->view) return;
	ViewRect want(0, 0, std::max(1, w), std::max(1, h));
	if (d->view->checkSizeConstraint(&want) != kResultTrue) return;
	if (want.getWidth() > 0 && want.getHeight() > 0) {
		w = want.getWidth();
		h = want.getHeight();
	}
}

void Vst3Editor::focus() {
#if defined(__linux__)
	XErrGuard xguard;
	// The plugin creates its own window inside our container; X sends key
	// events to whatever holds the input focus, so hand it there directly.
	// (There is no window manager involved for a child window.)
	if (!d->display || !d->child || !d->attached) return;
	Window target = d->child;
	Window root = 0, parent = 0, *children = nullptr;
	unsigned int n = 0;
	if (XQueryTree(d->display, d->child, &root, &parent, &children, &n) && children) {
		if (n > 0) target = children[0];
		XFree(children);
	}
	XWindowAttributes at{};
	if (XGetWindowAttributes(d->display, target, &at) && at.map_state == IsViewable) {
		XSetInputFocus(d->display, target, RevertToParent, CurrentTime);
		XFlush(d->display);
	}
#elif defined(_WIN32)
	// As on X11: the plugin makes its own window inside ours, and keys go to
	// whatever holds the focus, so hand it to that one rather than to the
	// container, which would swallow them.
	if (!d->child || !d->attached) return;
	HWND target = first_child(d->child);
	SetFocus(target ? target : d->child);
#endif
}

/// Whether the plugin has actually put its own interface inside our container
/// and shown it. A view can accept the window and then take a while to build
/// what goes in it -- JUCE and VSTGUI both do -- and what is on screen until
/// then is a grey rectangle that reads as a broken plugin.
bool Vst3Editor::ready() const {
	if (!d->attached || !d->view) return false;
#if defined(__linux__)
	XErrGuard xguard;
	if (!d->display || !d->child) return false;
	Window root = 0, parent = 0, *children = nullptr;
	unsigned int n = 0;
	if (!XQueryTree(d->display, d->child, &root, &parent, &children, &n)) return false;
	bool up = false;
	if (children) {
		for (unsigned int i = 0; i < n && !up; i++) {
			XWindowAttributes at{};
			if (XGetWindowAttributes(d->display, children[i], &at) && at.map_state == IsViewable
					&& at.width > 8 && at.height > 8) {
				up = true;
			}
		}
		XFree(children);
	}
	return up;
#elif defined(_WIN32)
	if (!d->child) return false;
	const HWND kid = first_child(d->child);
	if (!kid || !IsWindowVisible(kid)) return false;
	RECT r{};
	if (!GetClientRect(kid, &r)) return false;
	return (r.right - r.left) > 8 && (r.bottom - r.top) > 8;
#else
	return false;
#endif
}

/// Whether the plugin has made any window of its own inside the container yet
/// -- which is how a plugin that is still building its interface is told from
/// one that has done nothing at all and needs another go.
bool Vst3Editor::started() const {
	if (!d->attached) return false;
#if defined(__linux__)
	XErrGuard xguard;
	if (!d->display || !d->child) return false;
	Window root = 0, parent = 0, *children = nullptr;
	unsigned int n = 0;
	if (!XQueryTree(d->display, d->child, &root, &parent, &children, &n)) return false;
	if (children) XFree(children);
	return n > 0;
#elif defined(_WIN32)
	return d->child != nullptr && first_child(d->child) != nullptr;
#else
	return false;
#endif
}

/// Brings the plugin's canvas in from where it was parked. Called once the
/// interface has been built, or once waiting for it has gone on long enough
/// that showing whatever there is beats showing nothing.
void Vst3Editor::show() {
	if (!d->attached || !d->parked) return;
	d->parked = false;
#if defined(__linux__)
	XErrGuard xguard;
	if (!d->display || !d->child) return;
	XMoveWindow(d->display, d->child, d->want_x, d->want_y);
	XRaiseWindow(d->display, d->child);
	expose_all(d->display, d->child);
	XFlush(d->display);
#elif defined(_WIN32)
	if (!d->child) return;
	d->place(d->cur_w, d->cur_h);
	RedrawWindow(d->child, nullptr, nullptr,
			RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
#endif
}

bool Vst3Editor::showing() const { return d->attached && !d->parked; }

/// Hands the keyboard back to the window Cadmium owns, if the plugin's own
/// window has taken it. A plugin that grabs the focus when it is clicked --
/// most of the ones with a search box do -- otherwise keeps every key from
/// then on, so the typing keyboard stops playing notes and Space stops
/// starting the transport for no reason the user can see. Only ever called
/// while "keyboard goes to the plugin" is off.
/// Whether the keyboard is currently going to the plugin's own window rather
/// than to Cadmium. A key held down when this becomes true can never be seen
/// coming back up, so whoever is holding it needs to know.
bool Vst3Editor::has_keyboard() const {
#if defined(__linux__)
	XErrGuard xguard;
	if (!d->display || !d->child || !d->attached) return false;
	Window focus = 0;
	int revert = 0;
	if (!XGetInputFocus(d->display, &focus, &revert) || focus == None || focus == PointerRoot) {
		return false;
	}
	Window w = focus;
	for (int i = 0; i < 32 && w; i++) {
		if (w == d->child) return true;
		Window root = 0, parent = 0, *children = nullptr;
		unsigned int n = 0;
		if (!XQueryTree(d->display, w, &root, &parent, &children, &n)) break;
		if (children) XFree(children);
		if (parent == root || parent == 0) break;
		w = parent;
	}
	return false;
#elif defined(_WIN32)
	if (!d->child || !d->attached) return false;
	const HWND focus = GetFocus();
	return focus != nullptr && (focus == d->child || IsChild(d->child, focus) != 0);
#else
	return false;
#endif
}

void Vst3Editor::unfocus() {
	if (!has_keyboard()) return;
#if defined(__linux__)
	XErrGuard xguard;
	if (!d->display || !d->child) return;
	Window focus = 0;
	int revert = 0;
	if (!XGetInputFocus(d->display, &focus, &revert) || focus == None || focus == PointerRoot) return;
	// The window at the top of the tree the focus is in: that is Cadmium's.
	Window top = 0;
	Window w = focus;
	for (int i = 0; i < 32 && w; i++) {
		Window root = 0, parent = 0, *children = nullptr;
		unsigned int n = 0;
		if (!XQueryTree(d->display, w, &root, &parent, &children, &n)) break;
		if (children) XFree(children);
		if (parent == root || parent == 0) {
			top = w;
			break;
		}
		w = parent;
	}
	if (!top || top == focus) return;
	XSetInputFocus(d->display, top, RevertToParent, CurrentTime);
	XFlush(d->display);
#elif defined(_WIN32)
	// Never out of a window somebody is using.
	//
	// The canvas is a window of Cadmium's own, so clicking a plugin makes that
	// window the one in front -- and taking the focus off it then is taking it
	// out of the user's hands mid-gesture. A JUCE plugin treats losing the
	// focus as the end of whatever was being dragged, so this cancelled a
	// wavetable drag in Vital the instant it started.
	const HWND front = GetForegroundWindow();
	for (HWND w = front; w; w = GetAncestor(w, GA_PARENT)) {
		if (w == d->child) return;
	}
	// Cadmium's own window, which is the parent of a child container and the
	// owner of one of ours -- never the container itself.
	const HWND top = d->parent ? d->parent : GetAncestor(d->child, GA_ROOT);
	if (top && top != GetFocus()) SetFocus(top);
#endif
}

void Vst3Editor::close() {
	d->parked = false;
	if (d->attached && d->view) {
		d->view->removed();
		d->view->setFrame(nullptr);
	}
	d->attached = false;
#if defined(__linux__)
	XErrGuard xguard;
	// The view is let go of and made again next time rather than reattached.
	// A detached view is allowed to be reattached by the specification, but
	// several plugins simply do not: on the second attach they return success
	// and then create no window at all, so the editor comes up blank. Every
	// plugin handles being asked for a fresh view.
	//
	// With the view gone, anything it left registered on the run loop is dead,
	// so those go too -- calling a handler belonging to a destroyed editor is
	// a use-after-free.
	d->frame.run_loop.fds.clear();
	d->frame.run_loop.timers.clear();
	if (d->display && d->child) {
		XDestroyWindow(d->display, d->child);
		d->child = 0;
		XFlush(d->display);
	}
	// The connection stays open for the life of the editor: reconnecting per
	// open buys nothing and costs a round trip.
#elif defined(_WIN32)
	if (d->child) {
		DestroyWindow(d->child);
		d->child = nullptr;
	}
	d->parent = nullptr;
	d->shown_now = true;
	d->placed = RECT{0, 0, 0, 0};
#endif
	if (d->view) {
		d->view->release();
		d->view = nullptr;
	}
	d->cur_w = 0;
	d->cur_h = 0;
}

bool Vst3Editor::grab(std::vector<unsigned char> &rgb, int &w, int &h) const {
	rgb.clear();
	w = 0;
	h = 0;
#if defined(__linux__)
	if (!d->display || !d->child || !d->attached) return false;
	XErrGuard xguard;
	XWindowAttributes at{};
	if (!XGetWindowAttributes(d->display, d->child, &at)) return false;
	if (at.map_state != IsViewable || at.width <= 0 || at.height <= 0) return false;
	// Reading a window reads the screen area it covers, so anything stacked on
	// top of it is read instead -- and plugins put their own dialogs up there
	// (LSP shows a "greetings" window over everything on first run). Lift our
	// whole window to the front first. Only the test harness reads pixels back,
	// so this costs nothing in normal use.
	{
		Window top = d->child, root = 0, parent = 0, *kids = nullptr;
		unsigned int n = 0;
		while (XQueryTree(d->display, top, &root, &parent, &kids, &n)) {
			if (kids) XFree(kids);
			if (!parent || parent == root) break;
			top = parent;
		}
		XRaiseWindow(d->display, top);
		XSync(d->display, False);
	}
	// Whatever the plugin painted into its own child windows is included.
	XImage *img = XGetImage(d->display, d->child, 0, 0, (unsigned)at.width, (unsigned)at.height,
			AllPlanes, ZPixmap);
	if (!img) return false;
	w = at.width;
	h = at.height;
	rgb.resize((size_t)w * (size_t)h * 3);
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			const unsigned long px = XGetPixel(img, x, y);
			unsigned char *o = &rgb[((size_t)y * (size_t)w + (size_t)x) * 3];
			o[0] = (unsigned char)((px & img->red_mask) >> 16);
			o[1] = (unsigned char)((px & img->green_mask) >> 8);
			o[2] = (unsigned char)(px & img->blue_mask);
		}
	}
	XDestroyImage(img);
	return true;
#elif defined(_WIN32)
	if (!d->child || !d->attached) return false;
	RECT cr{};
	if (!GetClientRect(d->child, &cr)) return false;
	w = cr.right - cr.left;
	h = cr.bottom - cr.top;
	if (w <= 0 || h <= 0) return false;
	POINT origin{0, 0};
	ClientToScreen(d->child, &origin);
	HDC screen = GetDC(nullptr);
	if (!screen) return false;
	HDC mem = CreateCompatibleDC(screen);
	HBITMAP bmp = CreateCompatibleBitmap(screen, w, h);
	bool ok = false;
	if (mem && bmp) {
		HGDIOBJ old_obj = SelectObject(mem, bmp);
		// Off the screen, which is the only way to see what a plugin drawing
		// with anything other than plain GDI actually put there. If that comes
		// back blank -- the window is covered, or there is no compositor --
		// the window is asked to paint itself instead.
		BitBlt(mem, 0, 0, w, h, screen, origin.x, origin.y, SRCCOPY);
		BITMAPINFO bi{};
		bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
		bi.bmiHeader.biWidth = w;
		bi.bmiHeader.biHeight = -h;          // top down, like everyone else
		bi.bmiHeader.biPlanes = 1;
		bi.bmiHeader.biBitCount = 32;
		bi.bmiHeader.biCompression = BI_RGB;
		std::vector<unsigned char> bgra((size_t)w * (size_t)h * 4);
		auto read_back = [&]() {
			return GetDIBits(mem, bmp, 0, (UINT)h, bgra.data(), &bi, DIB_RGB_COLORS) != 0;
		};
		auto flat = [&]() {
			for (size_t i = 4, n = (size_t)w * (size_t)h * 4; i < n; i += 4) {
				if (bgra[i] != bgra[0] || bgra[i + 1] != bgra[1] || bgra[i + 2] != bgra[2]) {
					return false;
				}
			}
			return true;
		};
		ok = read_back();
		if (ok && flat()) {
			SendMessageW(d->child, WM_PRINT, (WPARAM)mem,
					PRF_CHILDREN | PRF_CLIENT | PRF_ERASEBKGND);
			ok = read_back();
		}
		if (ok) {
			rgb.resize((size_t)w * (size_t)h * 3);
			for (size_t i = 0, n = (size_t)w * (size_t)h; i < n; i++) {
				rgb[i * 3 + 0] = bgra[i * 4 + 2];
				rgb[i * 3 + 1] = bgra[i * 4 + 1];
				rgb[i * 3 + 2] = bgra[i * 4 + 0];
			}
		}
		SelectObject(mem, old_obj);
	}
	if (bmp) DeleteObject(bmp);
	if (mem) DeleteDC(mem);
	ReleaseDC(nullptr, screen);
	return ok;
#else
	return false;
#endif
}

std::string Vst3Editor::debug() const {
	char buf[512];
	int w = 0, h = 0;
	if (d->view) {
		ViewRect r{};
		if (d->view->getSize(&r) == kResultOk) { w = r.getWidth(); h = r.getHeight(); }
	}
#if defined(__linux__)
	unsigned int nchildren = 0;
	int cw = 0, ch = 0, cx = 0, cy = 0;
	int gmap = -1, gw = 0, gh = 0;
	int cmap = -1, pmap = -1;
	if (d->display && d->child) {
		Window root = 0, parent = 0, *children = nullptr;
		if (XQueryTree(d->display, d->child, &root, &parent, &children, &nchildren) && children) {
			if (nchildren > 0) {
				XWindowAttributes ga{};
				if (XGetWindowAttributes(d->display, children[0], &ga)) {
					gmap = ga.map_state;
					gw = ga.width;
					gh = ga.height;
				}
			}
			XFree(children);
		}
		XWindowAttributes at{};
		if (XGetWindowAttributes(d->display, d->child, &at)) {
			cw = at.width; ch = at.height; cx = at.x; cy = at.y; cmap = at.map_state;
		}
		Window root2 = 0, par2 = 0, *ch2 = nullptr;
		unsigned int n2 = 0;
		if (XQueryTree(d->display, d->child, &root2, &par2, &ch2, &n2)) {
			if (ch2) XFree(ch2);
			XWindowAttributes pa{};
			if (par2 && XGetWindowAttributes(d->display, par2, &pa)) pmap = pa.map_state;
		}
	}
	snprintf(buf, sizeof(buf),
			"view=%p attached=%d size=%dx%d child=0x%lx at %d,%d %dx%d map=%d parentmap=%d "
			"children=%u grandchild(map=%d %dx%d) fds=%zu timers=%zu",
			(void *)d->view, (int)d->attached, w, h, (unsigned long)d->child, cx, cy, cw, ch, cmap, pmap,
			nchildren, gmap, gw, gh, d->frame.run_loop.fds.size(), d->frame.run_loop.timers.size());
#elif defined(_WIN32)
	RECT cr{};
	int cw = 0, ch = 0, kids = 0, kw = 0, kh = 0;
	if (d->child && GetClientRect(d->child, &cr)) {
		cw = cr.right - cr.left;
		ch = cr.bottom - cr.top;
	}
	for (HWND k = first_child(d->child); k; k = GetWindow(k, GW_HWNDNEXT)) {
		kids++;
		RECT kr{};
		if (kids == 1 && GetWindowRect(k, &kr)) {
			kw = kr.right - kr.left;
			kh = kr.bottom - kr.top;
		}
	}
	snprintf(buf, sizeof(buf),
			"view=%p attached=%d size=%dx%d child=%p client=%dx%d visible=%d "
			"children=%d first(%dx%d) err=%s",
			(void *)d->view, (int)d->attached, w, h, (void *)d->child, cw, ch,
			d->child ? (int)IsWindowVisible(d->child) : 0, kids, kw, kh,
			d->last_err.empty() ? "-" : d->last_err.c_str());
#else
	snprintf(buf, sizeof(buf), "view=%p attached=%d size=%dx%d", (void *)d->view, (int)d->attached, w, h);
#endif
	return buf;
}

void Vst3Editor::idle() {
#if defined(_WIN32)
	// No run loop to pump here -- a plugin's timers and paints arrive on the
	// thread's own message queue, which the frame loop is already draining --
	// but the canvas still has to be kept the size of its container.
	if (d->attached) {
		// A window of Cadmium's own does not move with the one it belongs to,
		// so it is put back over it -- which is also what takes it away when
		// Cadmium is minimised or hidden.
		if (d->own_window && d->child) {
			const bool up = d->parent && IsWindowVisible(d->parent) && !IsIconic(d->parent);
			if (up != d->shown_now) {
				d->shown_now = up;
				ShowWindow(d->child, up ? SW_SHOWNA : SW_HIDE);
			}
			if (up) d->place(d->cur_w, d->cur_h);
		}
		fit_child();
	}
	return;
#endif
#if defined(__linux__)
	// Pumped even with no editor open: plugins register timers on the run loop
	// they take from the host context, long before they are ever shown.
	d->frame.run_loop.pump();
	if (!d->attached) return;
	fit_child();
	// Watch what happens to the container: something was unmapping it.
	if (d->display) {
		XEvent e;
		while (XPending(d->display)) {
			XNextEvent(d->display, &e);
			// Events on the container are consumed so the queue cannot grow;
			// the plugin gets its own on its own connection.
			(void)e;
		}
	}
#endif
}

/// Most plugins resize their own window when told the view's new size. The ones
/// that do not leave their canvas the old shape inside a container of the new
/// one, which is what "resizing the window breaks the interface until you turn
/// it off and on again" looks like. Give them a few frames of their own event
/// loop to do it, then do it for them.
void Vst3Editor::fit_child() {
#if defined(_WIN32)
	if (!d->child || !d->attached) return;
	RECT cr{};
	if (!GetClientRect(d->child, &cr)) return;
	const int cw = cr.right - cr.left, ch = cr.bottom - cr.top;
	bool mismatch = false;
	for (HWND k = first_child(d->child); k; k = GetWindow(k, GW_HWNDNEXT)) {
		RECT kr{};
		if (!GetWindowRect(k, &kr)) continue;
		POINT tl{kr.left, kr.top};
		ScreenToClient(d->child, &tl);
		if (tl.x != 0 || tl.y != 0 || std::abs((kr.right - kr.left) - cw) > 2 ||
				std::abs((kr.bottom - kr.top) - ch) > 2) {
			mismatch = true;
		}
	}
	if (!mismatch) { d->fit_strikes = 0; return; }
	if (++d->fit_strikes < 12) return;
	d->fit_strikes = 0;
	for (HWND k = first_child(d->child); k; k = GetWindow(k, GW_HWNDNEXT)) {
		SetWindowPos(k, nullptr, 0, 0, cw, ch, SWP_NOZORDER | SWP_NOACTIVATE);
	}
	InvalidateRect(d->child, nullptr, TRUE);
	return;
#endif
#if defined(__linux__)
	if (!d->display || !d->child || !d->attached) return;
	XErrGuard xguard;
	XWindowAttributes ca{};
	if (!XGetWindowAttributes(d->display, d->child, &ca)) return;
	Window root = 0, parent = 0, *kids = nullptr;
	unsigned int n = 0;
	if (!XQueryTree(d->display, d->child, &root, &parent, &kids, &n) || !kids) return;
	bool mismatch = false;
	for (unsigned int i = 0; i < n; i++) {
		XWindowAttributes ka{};
		if (!XGetWindowAttributes(d->display, kids[i], &ka)) continue;
		if (std::abs(ka.width - ca.width) > 2 || std::abs(ka.height - ca.height) > 2 ||
				ka.x != 0 || ka.y != 0) {
			mismatch = true;
		}
	}
	if (!mismatch) {
		d->fit_strikes = 0;
		XFree(kids);
		return;
	}
	// About a fifth of a second at a normal frame rate.
	if (++d->fit_strikes < 12) {
		XFree(kids);
		return;
	}
	d->fit_strikes = 0;
	for (unsigned int i = 0; i < n; i++) {
		XMoveResizeWindow(d->display, kids[i], 0, 0, (unsigned)ca.width, (unsigned)ca.height);
	}
	XFree(kids);
	expose_all(d->display, d->child);
	XFlush(d->display);
#endif
}

FUnknown *Vst3Editor::run_loop_context() {
#if defined(__linux__)
	// Handed to the plugin as part of the host context: plugins are allowed to
	// ask for a run loop before they ever open an editor.
	return (FUnknown *)&d->frame;
#else
	return nullptr;
#endif
}

} // namespace cd
