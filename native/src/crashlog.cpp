#include "crashlog.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <csignal>
#include <cstdlib>

#if defined(_WIN32)
#include <windows.h>
#else
#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#endif

namespace cd {
namespace {

// Fixed buffers, written to from a signal handler: nothing here allocates,
// takes a lock, or calls anything that might.
char g_dir[1024] = {0};
char g_prefix[64] = "cadmium-crash";
char g_version[128] = {0};
char g_note[512] = {0};
/// A note that is a string literal: kept by pointer, so the hot paths can set
/// one without copying anything.
std::atomic<const char *> g_static_note{nullptr};
/// Whose code it was: the plugin's own file, kept by pointer for the same
/// reason as the note.
std::atomic<const char *> g_whose{nullptr};
std::atomic<unsigned long long> g_audio_thread{0};
std::atomic<bool> g_armed{false};

#if defined(_WIN32)
LPTOP_LEVEL_EXCEPTION_FILTER g_previous = nullptr;
#else
struct sigaction g_previous[8] = {};
const int g_signals[] = {SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL};
#endif

void put(int fd, const char *s) {
#if defined(_WIN32)
	(void)fd;
	(void)s;
#else
	if (s == nullptr) return;
	const size_t n = strlen(s);
	if (n > 0) {
		ssize_t written = write(fd, s, n);
		(void)written;
	}
#endif
}

/// The report's path, built without allocating: <dir>/cadmium-crash-<time>.log
void report_path(char *out, size_t size) {
	const time_t now = time(nullptr);
	struct tm parts;
#if defined(_WIN32)
	localtime_s(&parts, &now);
#else
	localtime_r(&now, &parts);
#endif
	snprintf(out, size, "%s/%s-%04d-%02d-%02d_%02d-%02d-%02d.log", g_dir, g_prefix,
			parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
			parts.tm_hour, parts.tm_min, parts.tm_sec);
}

void write_report(const char *reason) {
	if (g_dir[0] == 0) return;
	char path[1200];
	report_path(path, sizeof(path));

#if defined(_WIN32)
	// stdio rather than a raw handle: on Windows this runs from the unhandled
	// exception filter, not from a signal handler, so it is allowed to.
	FILE *f = fopen(path, "wb");
	if (!f) return;
	fprintf(f, "Cadmium stopped unexpectedly\n");
	fprintf(f, "version   %s\n", g_version);
	fprintf(f, "reason    %s\n", reason);
	const char *stat = g_static_note.load();
	fprintf(f, "doing     %s\n", g_note[0] ? g_note : (stat ? stat : "nothing in particular"));
	if (g_note[0] && stat) fprintf(f, "also      %s\n", stat);
	const char *whose = g_whose.load();
	if (whose) fprintf(f, "whose     %s\n", whose);
	fprintf(f, "thread    %s\n\n",
			(unsigned long long)GetCurrentThreadId() == g_audio_thread.load()
					? "the audio thread" : "the interface thread");
	void *frames[64];
	const USHORT n = CaptureStackBackTrace(0, 64, frames, nullptr);
	fprintf(f, "%u frames:\n", (unsigned)n);
	for (USHORT i = 0; i < n; i++) {
		HMODULE mod = nullptr;
		char name[MAX_PATH] = {0};
		if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
						| GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
				(LPCSTR)frames[i], &mod)) {
			GetModuleFileNameA(mod, name, MAX_PATH);
			fprintf(f, "  %p  %s+0x%llx\n", frames[i], name,
					(unsigned long long)((char *)frames[i] - (char *)mod));
		} else {
			fprintf(f, "  %p\n", frames[i]);
		}
	}
	fclose(f);
#else
	const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) return;
	put(fd, "Cadmium stopped unexpectedly\nversion   ");
	put(fd, g_version);
	put(fd, "\nreason    ");
	put(fd, reason);
	put(fd, "\ndoing     ");
	const char *stat = g_static_note.load();
	put(fd, g_note[0] ? g_note : (stat ? stat : "nothing in particular"));
	if (g_note[0] && stat) {
		put(fd, "\nalso      ");
		put(fd, stat);
	}
	const char *whose = g_whose.load();
	if (whose) {
		put(fd, "\nwhose     ");
		put(fd, whose);
	}
	put(fd, "\nthread    ");
	put(fd, (unsigned long long)pthread_self() == g_audio_thread.load()
			? "the audio thread" : "the interface thread");
	put(fd, "\n\n");
	void *frames[64];
	const int n = backtrace(frames, 64);
	backtrace_symbols_fd(frames, n, fd);
	close(fd);
#endif
}

#if defined(_WIN32)
LONG WINAPI on_exception(EXCEPTION_POINTERS *info) {
	char reason[64];
	snprintf(reason, sizeof(reason), "exception 0x%08lx",
			info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionCode : 0);
	write_report(reason);
	// Godot's own handler goes first, so its log still says its piece, and
	// then the process is ended here rather than handed to Windows.
	//
	// Left to Windows, a process that stopped like this sits about waiting for
	// Error Reporting to decide what to do with it: the copy of Cadmium that
	// opens plugins to check them takes a minute to actually die, they pile up
	// in Task Manager, and the scan that is waiting for one to finish waits for
	// all of it. Nothing useful happens in that minute -- the report is already
	// written -- so it does not happen at all.
	if (g_previous) g_previous(info);
	TerminateProcess(GetCurrentProcess(), 3);
	return EXCEPTION_EXECUTE_HANDLER;
}
#else
void on_signal(int sig, siginfo_t *info, void *ctx) {
	const char *reason = "signal";
	switch (sig) {
		case SIGSEGV: reason = "SIGSEGV -- wrote or read somewhere it should not"; break;
		case SIGABRT: reason = "SIGABRT -- gave up on itself"; break;
		case SIGBUS:  reason = "SIGBUS"; break;
		case SIGFPE:  reason = "SIGFPE"; break;
		case SIGILL:  reason = "SIGILL"; break;
		default: break;
	}
	write_report(reason);
	// And on to whoever was here first, so the engine's own report still
	// happens and the process still dies the way it would have.
	for (size_t i = 0; i < sizeof(g_signals) / sizeof(g_signals[0]); i++) {
		if (g_signals[i] != sig) continue;
		if (g_previous[i].sa_flags & SA_SIGINFO) {
			if (g_previous[i].sa_sigaction) g_previous[i].sa_sigaction(sig, info, ctx);
		} else if (g_previous[i].sa_handler && g_previous[i].sa_handler != SIG_DFL
				&& g_previous[i].sa_handler != SIG_IGN) {
			g_previous[i].sa_handler(sig);
		} else {
			signal(sig, SIG_DFL);
			raise(sig);
		}
		return;
	}
}
#endif

}  // namespace

void crash_init(const std::string &dir, const std::string &version,
		const std::string &prefix) {
	snprintf(g_dir, sizeof(g_dir), "%s", dir.c_str());
	snprintf(g_version, sizeof(g_version), "%s", version.c_str());
	if (!prefix.empty()) snprintf(g_prefix, sizeof(g_prefix), "%s", prefix.c_str());
	if (g_armed.exchange(true)) return;
#if defined(_WIN32)
	g_previous = SetUnhandledExceptionFilter(on_exception);
#else
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = on_signal;
	sa.sa_flags = SA_SIGINFO | SA_RESTART;
	sigemptyset(&sa.sa_mask);
	for (size_t i = 0; i < sizeof(g_signals) / sizeof(g_signals[0]); i++) {
		sigaction(g_signals[i], &sa, &g_previous[i]);
	}
#endif
}

void crash_note(const char *what) {
	if (what == nullptr) {
		g_note[0] = 0;
		return;
	}
	snprintf(g_note, sizeof(g_note), "%s", what);
}

void crash_note(const std::string &what) { crash_note(what.c_str()); }

void crash_note_static(const char *what) { g_static_note.store(what); }

CrashStep::CrashStep(const char *what, const char *whose)
		: previous(g_static_note.load()), previous_whose(g_whose.load()) {
	g_static_note.store(what);
	if (whose != nullptr) g_whose.store(whose);
}

CrashStep::~CrashStep() {
	g_static_note.store(previous);
	g_whose.store(previous_whose);
}

void crash_mark_audio_thread() {
#if defined(_WIN32)
	g_audio_thread.store((unsigned long long)GetCurrentThreadId());
#else
	g_audio_thread.store((unsigned long long)pthread_self());
#endif
}

void crash_now() {
	volatile int *nowhere = (volatile int *)0;
	*nowhere = 1;
}

}  // namespace cd
