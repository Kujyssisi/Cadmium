extends Window
## Help ▸ Check for Updates.
##
## One window that goes through the whole thing in place: asks github.com what
## the newest release is, says whether this copy is behind, shows what changed,
## downloads the right file for how Cadmium was installed, and hands over to a
## script that does the swap once Cadmium has exited.
##
## It never checks on its own. A DAW that phones home on startup is a DAW that
## phones home on startup; this one only goes out when the menu item is used.

const CdUpdateScript = preload("res://core/cd_update.gd")

var _found := {}
var _busy := false
var _archive := ""

@onready var _title: Label = $Root/Col/Head
@onready var _state: Label = $Root/Col/State
@onready var _notes: RichTextLabel = $Root/Col/Notes
@onready var _bar: ProgressBar = $Root/Col/Bar
@onready var _action: Button = $Root/Col/Row/Action
@onready var _page: Button = $Root/Col/Row/Page
@onready var _close: Button = $Root/Col/Row/Close


func _ready() -> void:
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(520.0 * sc), int(420.0 * sc))
	close_requested.connect(_leave)
	_close.pressed.connect(_leave)
	_page.pressed.connect(func(): OS.shell_open(String(_found.get("url", CdUpdateScript.RELEASES_URL))))
	_action.pressed.connect(_on_action)
	_bar.visible = false
	_notes.visible = false
	_title.text = "Cadmium %s" % CdUpdateScript.current()
	Cd.place_window(self, self)
	_look()


func _leave() -> void:
	# A download in flight is left to finish or fail on its own rather than
	# being torn out from under the HTTPRequest.
	if _busy:
		return
	queue_free()


# ---------------------------------------------------------------------------
func _look() -> void:
	_busy = true
	_action.disabled = true
	_action.text = "Checking..."
	_state.text = "Asking github.com what the newest release is..."
	_found = await CdUpdateScript.check(get_tree())
	_busy = false
	if not is_inside_tree():
		return
	if not bool(_found.get("ok", false)):
		_state.text = String(_found.get("error", "Could not check"))
		_action.text = "Try again"
		_action.disabled = false
		return
	var latest := String(_found.version)
	if not bool(_found.newer):
		_state.text = "This is the newest release. Nothing to do."
		_action.text = "Check again"
		_action.disabled = false
		return

	_title.text = "Cadmium %s is out" % latest
	var where: Dictionary = CdUpdateScript.installation()
	var kind := int(where.kind)
	var notes := String(_found.get("notes", "")).strip_edges()
	if not notes.is_empty():
		_notes.visible = true
		_notes.text = notes
	var size_mb := float(_found.get("asset_size", 0)) / 1048576.0

	match kind:
		CdUpdateScript.Kind.SOURCE:
			_state.text = ("You are running from the source folder, so there is nothing here "
					+ "to replace. Pull it with git instead.")
			_action.visible = false
		CdUpdateScript.Kind.MANAGED:
			_state.text = ("This copy was installed by your package manager, which is what "
					+ "should update it. Cadmium will not go behind its back.")
			_action.visible = false
		_:
			if String(_found.get("asset_url", "")).is_empty():
				_state.text = ("Release %s has no download for this platform. The release "
						+ "page has the rest.") % latest
				_action.visible = false
				return
			_state.text = "You have %s. Downloading %s is %.0f MB." % [
					String(_found.current), String(_found.asset_name), size_mb]
			_action.text = "Download and install"
			_action.disabled = false


func _on_action() -> void:
	if _busy:
		return
	if not bool(_found.get("ok", false)) or not bool(_found.get("newer", false)):
		_look()
		return
	_fetch_and_install()


func _fetch_and_install() -> void:
	_busy = true
	_action.disabled = true
	_action.text = "Downloading..."
	_bar.visible = true
	_bar.value = 0.0
	var name := String(_found.asset_name)
	_archive = OS.get_cache_dir().path_join("cadmium-update").path_join(name)
	var problem: String = await CdUpdateScript.download(get_tree(),
			String(_found.asset_url), _archive,
			func(got, total):
				if not is_inside_tree():
					return
				_bar.max_value = maxf(1.0, float(total))
				_bar.value = float(got)
				_state.text = "Downloading %s -- %.0f of %.0f MB" % [name,
						float(got) / 1048576.0, maxf(1.0, float(total)) / 1048576.0])
	if not is_inside_tree():
		return
	if not problem.is_empty():
		_busy = false
		_bar.visible = false
		_state.text = problem
		_action.text = "Try again"
		_action.disabled = false
		return

	_state.text = "Unpacking and handing over..."
	_bar.visible = false
	var failed: String = await CdUpdateScript.apply(get_tree(), _archive)
	if not failed.is_empty():
		_busy = false
		_state.text = failed
		_action.text = "Try again"
		_action.disabled = false
		return
	# From here the handover script is waiting for this process to exit, so the
	# only correct next move is to exit.
	_state.text = "Cadmium will close and reopen on %s." % String(_found.version)
	App.status.emit("Updating to %s" % String(_found.version))
	await get_tree().create_timer(1.2).timeout
	get_tree().quit()
