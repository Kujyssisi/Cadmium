#pragma once
#include <string>

/// What Cadmium was doing when it stopped, written where it can be read
/// afterwards.
///
/// A host that loads other people's code cannot be crash-proof: a plugin that
/// writes over memory takes the process with it, and no amount of care here
/// prevents that. What it can do is leave a note saying which plugin it was
/// and what was being done to it, so the next start can say so plainly instead
/// of the program simply vanishing.
namespace cd {

/// Where the reports go and what to stamp them with. Called once at startup.
///
/// `prefix` names the files. The copy of Cadmium that opens plugins to find
/// out whether they can be opened uses a different one, so that a crash it
/// contained on purpose is not read afterwards as the program falling over.
void crash_init(const std::string &dir, const std::string &version,
		const std::string &prefix = "cadmium-crash");

/// The one-line breadcrumb: "loading Omnisphere.vst3", "opening its editor".
/// Cheap enough to set on every step -- it copies into a fixed buffer and
/// touches nothing else, because it has to be readable from a signal handler.
void crash_note(const char *what);
void crash_note(const std::string &what);

/// The same, for a note that never changes: keeps the pointer rather than
/// copying, so it costs nothing on a path that runs every audio block.
void crash_note_static(const char *what);

/// A note for as long as this is in scope, and whatever was there before
/// afterwards. Every call into somebody else's code should be wrapped in one:
/// what a report most needs to say is whose code was running.
struct CrashStep {
	explicit CrashStep(const char *what, const char *whose = nullptr);
	~CrashStep();
	const char *previous;
	const char *previous_whose;
};

/// Which thread this is, for the report.
void crash_mark_audio_thread();

/// Deliberately falls over, for testing that any of this works.
void crash_now();

}  // namespace cd
