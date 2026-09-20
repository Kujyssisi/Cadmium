class_name CdUpdate
extends RefCounted
## Looking for a newer Cadmium, and installing one.
##
## The published releases are the source of truth: one GitHub API call says
## what the newest tag is and what files it carries. Nothing is sent anywhere
## -- it is a plain GET of a public endpoint, made only when somebody asks for
## it from Help ▸ Check for Updates.
##
## Installing one is the part that has to be careful, because the thing being
## replaced is the thing doing the replacing. Cadmium never overwrites its own
## files while it is running: it downloads, unpacks, writes a short script that
## waits for this process to exit and then does the swap, starts that detached,
## and quits. On Windows it hands the downloaded installer the same job, since
## the installer already knows how to replace an installation.

const REPO := "Kujyssisi/Cadmium"
const LATEST_URL := "https://api.github.com/repos/%s/releases/latest" % REPO
const RELEASES_URL := "https://github.com/%s/releases" % REPO
## Anything smaller than this is not a Cadmium release; it is an error page.
const MIN_ASSET_BYTES := 1024 * 1024

## How Cadmium got onto this machine, which decides what updating it means.
enum Kind {
	SOURCE,     ## run from the project folder; there is nothing to replace
	INSTALLED,  ## install.sh put it somewhere and left a manifest
	PORTABLE,   ## unzipped into a folder and run from there
	SETUP,      ## the Windows installer put it in place
	MANAGED,    ## a distro package owns it; its package manager updates it
}


## What this copy reports itself as. The build stamps it in, so a release says
## the version it was released as and a source build says whatever the repo
## last recorded.
static func current() -> String:
	return String(ProjectSettings.get_setting("application/config/version", "0.0.0"))


## Compares two versions as runs of numbers: 2026.9.20 against 2026.10.1, and
## 1.2.0 against 1.10.0, both the way a person would read them. Anything that
## is not a number sorts before anything that is, so "2026.09.20-rc1" is older
## than "2026.09.20".
static func compare(a: String, b: String) -> int:
	var x := _parts(a)
	var y := _parts(b)
	for i in maxi(x.size(), y.size()):
		var xi: int = x[i] if i < x.size() else 0
		var yi: int = y[i] if i < y.size() else 0
		if xi != yi:
			return -1 if xi < yi else 1
	return 0


static func _parts(v: String) -> Array:
	var clean := v.strip_edges().trim_prefix("v")
	var out := []
	for piece in clean.replace("-", ".").split("."):
		out.append(int(String(piece)) if String(piece).is_valid_int() else -1)
	return out


## Where this copy lives, and what kind of installation it is.
static func installation() -> Dictionary:
	if OS.has_feature("editor"):
		return {"kind": Kind.SOURCE, "dir": "", "exe": ""}
	var exe := OS.get_executable_path()
	var dir := exe.get_base_dir()
	if OS.get_name() == "Windows":
		var reg := _windows_install_dir()
		if not reg.is_empty() and reg.simplify_path() == dir.simplify_path():
			return {"kind": Kind.SETUP, "dir": dir, "exe": exe}
		return {"kind": Kind.PORTABLE, "dir": dir, "exe": exe}
	if FileAccess.file_exists(dir.path_join(".install-manifest")):
		return {"kind": Kind.INSTALLED, "dir": dir, "exe": exe}
	# Under /usr with no manifest of ours is somebody else's package.
	if dir.begins_with("/usr/") and not dir.begins_with("/usr/local/"):
		return {"kind": Kind.MANAGED, "dir": dir, "exe": exe}
	return {"kind": Kind.PORTABLE, "dir": dir, "exe": exe}


## The registry says where the Windows installer put things. Read through reg
## rather than guessed at, so a copy installed somewhere of the user's choosing
## is still recognised as an installed one.
static func _windows_install_dir() -> String:
	var out := []
	var args := ["query", "HKCU\\Software\\Cadmium", "/v", "InstallDir"]
	if OS.execute("reg", args, out, true) != 0 or out.is_empty():
		return ""
	for line in String(out[0]).split("\n"):
		var at := line.find("REG_SZ")
		if at >= 0:
			return line.substr(at + 6).strip_edges()
	return ""


## Which release file this platform wants. The Windows installer for a copy the
## installer put down, and the plain zip for everything else.
static func asset_pattern(kind: int) -> String:
	if OS.get_name() == "Windows":
		return "-windows-x86_64-setup.exe" if kind == Kind.SETUP else "-windows-x86_64.zip"
	if OS.has_feature("arm64"):
		return "-linux-arm64.zip"
	return "-linux-x86_64.zip"


# ---------------------------------------------------------------------------
# Asking
# ---------------------------------------------------------------------------
## What the newest release is. Returns {ok, error, version, newer, notes, url,
## asset_url, asset_name, asset_size}. Never throws and never blocks: the
## caller awaits it.
static func check(tree: SceneTree) -> Dictionary:
	var out := {"ok": false, "error": "", "version": "", "newer": false,
			"notes": "", "url": RELEASES_URL, "asset_url": "", "asset_name": "",
			"asset_size": 0, "current": current()}
	var req := HTTPRequest.new()
	req.timeout = 20.0
	tree.root.add_child(req)
	# GitHub wants a user agent and will answer with JSON either way.
	var headers := PackedStringArray([
		"User-Agent: Cadmium/%s" % current(),
		"Accept: application/vnd.github+json",
	])
	var err := req.request(LATEST_URL, headers)
	if err != OK:
		req.queue_free()
		out.error = "Could not reach github.com (error %d)" % err
		return out
	var res: Array = await req.request_completed
	req.queue_free()
	var result := int(res[0])
	var code := int(res[1])
	var body: PackedByteArray = res[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		out.error = "Could not reach github.com"
		return out
	if code == 404:
		out.error = "No releases published yet"
		return out
	if code != 200:
		out.error = "github.com answered %d" % code
		return out
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		out.error = "github.com sent something that is not a release"
		return out

	var tag := String(parsed.get("tag_name", "")).strip_edges()
	if tag.is_empty():
		out.error = "The newest release has no version on it"
		return out
	out.ok = true
	out.version = tag.trim_prefix("v")
	out.notes = String(parsed.get("body", ""))
	out.url = String(parsed.get("html_url", RELEASES_URL))
	out.newer = compare(out.version, out.current) > 0

	var want := asset_pattern(int(installation().get("kind", Kind.PORTABLE)))
	for a in parsed.get("assets", []):
		var name := String((a as Dictionary).get("name", ""))
		if name.ends_with(want):
			out.asset_name = name
			out.asset_url = String((a as Dictionary).get("browser_download_url", ""))
			out.asset_size = int((a as Dictionary).get("size", 0))
			break
	return out


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------
## Downloads one release file into `dest`. `on_progress` is handed
## (received, total) as it goes. Returns "" on success or why it failed.
static func download(tree: SceneTree, url: String, dest: String,
		on_progress: Callable = Callable()) -> String:
	if not url.begins_with("https://github.com/") \
			and not url.begins_with("https://objects.githubusercontent.com/"):
		return "That download does not come from the release page"
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var req := HTTPRequest.new()
	req.timeout = 0.0
	req.download_file = dest
	req.use_threads = true
	tree.root.add_child(req)
	var err := req.request(url, PackedStringArray(["User-Agent: Cadmium/%s" % current()]))
	if err != OK:
		req.queue_free()
		return "Could not start the download (error %d)" % err
	var done := false
	req.request_completed.connect(func(_r, _c, _h, _b): done = true, CONNECT_ONE_SHOT)
	while not done:
		await tree.process_frame
		if on_progress.is_valid():
			on_progress.call(req.get_downloaded_bytes(), req.get_body_size())
	var code := req.get_http_client_status()
	req.queue_free()
	if not FileAccess.file_exists(dest):
		return "The download did not arrive"
	var size := 0
	var f := FileAccess.open(dest, FileAccess.READ)
	if f != null:
		size = f.get_length()
		f.close()
	if size < MIN_ASSET_BYTES:
		DirAccess.remove_absolute(dest)
		return "The download was only %d bytes, which is not a Cadmium release" % size
	if code == HTTPClient.STATUS_CONNECTION_ERROR:
		return "The connection dropped part way through"
	return ""


# ---------------------------------------------------------------------------
# Installing
# ---------------------------------------------------------------------------
## Sets the update going and returns "" when it has started, or why it could
## not. On "" the caller must quit: the handover script is waiting for this
## process to exit before it touches anything.
##
## Cadmium never overwrites its own files from inside itself. The executable is
## running, the .pck is open, and the engine library is mapped; replacing any of
## them underneath a live process is how an update turns into a program that no
## longer starts. A short script that waits for the exit does the swap instead.
static func apply(tree: SceneTree, archive: String) -> String:
	var where := installation()
	var kind := int(where.kind)
	var dir := String(where.dir)
	if kind == Kind.SOURCE:
		return "This copy runs from the source folder; update it with git."
	if kind == Kind.MANAGED:
		return "This copy belongs to your package manager; update it with that."
	if not DirAccess.dir_exists_absolute(dir):
		return "Cannot find where Cadmium is installed"

	# The Windows installer already knows how to replace an installation, so it
	# is handed the job rather than half of it being done here.
	if kind == Kind.SETUP:
		return await _handover(tree, _windows_setup_script(archive), [])

	var staged: String = await _unpack(tree, archive)
	if staged.is_empty():
		return "The download could not be unpacked"
	if not FileAccess.file_exists(staged.path_join("Cadmium.pck")):
		return "The download does not look like a Cadmium release"

	if OS.get_name() == "Windows":
		return await _handover(tree, _windows_copy_script(staged, dir, archive), [])
	# An installed copy is updated by the new install.sh, in the mode the old
	# one recorded, so the manifest, the desktop entry and the icon are all
	# brought up to date rather than left describing the version before.
	return await _handover(tree, _linux_script(staged, dir, _recorded_mode(dir), archive), [])


## What install.sh recorded about how this copy was put down, or "" if it was
## not put down by install.sh at all.
static func _recorded_mode(dir: String) -> String:
	var f := FileAccess.open(dir.path_join(".install-prefix"), FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("MODE="):
			return line.substr(5).replace("\"", "").strip_edges()
	return ""


## The release zip, opened into a folder of its own beside the download. Godot
## reads zips itself, so this needs nothing installed.
static func _unpack(tree: SceneTree, archive: String) -> String:
	var out := archive.get_base_dir().path_join("staged")
	_wipe(out)
	DirAccess.make_dir_recursive_absolute(out)
	var zip := ZIPReader.new()
	if zip.open(archive) != OK:
		return ""
	# A release zip holds one folder; everything is lifted out of it so the
	# staged copy has the same shape as an installation.
	var names := zip.get_files()
	var root := ""
	for n in names:
		var top := String(n).split("/")[0]
		if root.is_empty():
			root = top
		elif root != top:
			root = ""
			break
	var made := 0
	for n in names:
		var rel := String(n)
		if not root.is_empty():
			rel = rel.substr(root.length() + 1)
		if rel.is_empty() or rel.ends_with("/"):
			continue
		var dest := out.path_join(rel)
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var fh := FileAccess.open(dest, FileAccess.WRITE)
		if fh == null:
			continue
		fh.store_buffer(zip.read_file(n))
		fh.close()
		made += 1
		if made % 64 == 0:
			await tree.process_frame
	zip.close()
	if made == 0:
		return ""
	# The zip carries no permissions, so the two things that have to be
	# runnable are made runnable again.
	if OS.get_name() != "Windows":
		for exe in ["Cadmium.x86_64", "Cadmium.arm64", "install.sh"]:
			var p := out.path_join(exe)
			if FileAccess.file_exists(p):
				OS.execute("chmod", ["+x", ProjectSettings.globalize_path(p)])
	return out


## A folder of ours and everything in it. Only ever called on the staging
## folder Cadmium made itself, one level under the download.
static func _wipe(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var full := path.path_join(name)
		if d.current_is_dir():
			_wipe(full)
		else:
			DirAccess.remove_absolute(full)
		name = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


## Writes the handover script and starts it detached. Returns "" on success.
static func _handover(tree: SceneTree, body: String, args: Array) -> String:
	var win := OS.get_name() == "Windows"
	var path := OS.get_cache_dir().path_join("cadmium-update.%s" % ("cmd" if win else "sh"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not write the update script to %s" % path
	f.store_string(body)
	f.close()
	var native := ProjectSettings.globalize_path(path)
	if not win:
		OS.execute("chmod", ["+x", native])
	var pid := OS.create_process("cmd.exe" if win else "/bin/sh",
			(["/c", native] if win else [native]) + args, false)
	if pid <= 0:
		return "Could not start the update script"
	await tree.process_frame
	return ""


static func _linux_script(staged: String, dir: String, mode: String,
		archive: String) -> String:
	var me := OS.get_process_id()
	var exe := OS.get_executable_path()
	var new_dir := ProjectSettings.globalize_path(staged)
	var old_dir := ProjectSettings.globalize_path(dir)
	# An installed copy is put down again by the *new* install.sh, in exactly
	# the layout the old one recorded, so the manifest, the launcher, the menu
	# entry and the icon all come up to date rather than being left describing
	# the version before. Anything else is a folder somebody unzipped, and the
	# folder is the installation.
	var run := "cp -a \"%s/.\" \"%s/\"" % [new_dir, old_dir]
	match mode:
		"system": run = "\"%s/install.sh\" --system" % new_dir
		"user":   run = "\"%s/install.sh\" --user" % new_dir
		"prefix": run = "\"%s/install.sh\" --prefix \"%s\"" % [new_dir, old_dir]
	return """#!/bin/sh
# Written by Cadmium to finish an update, and deleted by its last line.
#
# It waits for Cadmium to exit before touching anything: replacing a running
# program's own files is how an update becomes a program that will not start.
# There is deliberately no "set -e" -- if the swap goes wrong half way, having
# Cadmium start again matters more than the script's exit code.
i=0
while kill -0 %d 2>/dev/null && [ $i -lt 600 ]; do sleep 0.2; i=$((i+1)); done
%s
rm -rf "%s"
rm -f "%s"
"%s" &
rm -f "$0"
""" % [me, run, new_dir, ProjectSettings.globalize_path(archive), exe]


static func _windows_copy_script(staged: String, dir: String, archive: String) -> String:
	var me := OS.get_process_id()
	var exe := OS.get_executable_path().replace("/", "\\")
	return """@echo off
rem Written by Cadmium to finish an update. It waits for Cadmium to exit first:
rem replacing a running program's own files is how an update becomes a program
rem that will not start.
setlocal
:wait
tasklist /FI "PID eq %d" 2>nul | find "%d" >nul
if not errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto wait
)
robocopy "%s" "%s" /E /IS /NFL /NDL /NJH /NJS /NP >nul
rmdir /s /q "%s"
del /q "%s"
start "" "%s"
del "%%~f0"
""" % [me, me, ProjectSettings.globalize_path(staged).replace("/", "\\"),
		ProjectSettings.globalize_path(dir).replace("/", "\\"),
		ProjectSettings.globalize_path(staged).replace("/", "\\"),
		ProjectSettings.globalize_path(archive).replace("/", "\\"), exe]


static func _windows_setup_script(setup: String) -> String:
	var me := OS.get_process_id()
	return """@echo off
rem Written by Cadmium to finish an update: the installer does the replacing,
rem once Cadmium itself has exited.
setlocal
:wait
tasklist /FI "PID eq %d" 2>nul | find "%d" >nul
if not errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto wait
)
start "" /wait "%s"
del "%%~f0"
""" % [me, me, ProjectSettings.globalize_path(setup).replace("/", "\\")]
