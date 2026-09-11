class_name CdCrashDialog
extends Window
## The reports Cadmium leaves when it stops unexpectedly, where they can be
## read without going hunting through a data folder.

var _reports: Array = []

@onready var _list: ItemList = $Root/Col/Split/List
@onready var _text: TextEdit = $Root/Col/Split/Body/Text
@onready var _count: Label = $Root/Col/Foot/Count


func _ready() -> void:
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(780.0 * sc), int(520.0 * sc))
	close_requested.connect(queue_free)
	($Root/Col/Foot/Close as Button).pressed.connect(queue_free)
	($Root/Col/Foot/Copy as Button).pressed.connect(func():
		DisplayServer.clipboard_set(_text.text)
		App.status.emit("Report copied"))
	($Root/Col/Foot/Folder as Button).pressed.connect(func():
		OS.shell_open(CdCrash.dir()))
	($Root/Col/Foot/Delete as Button).pressed.connect(_delete)
	_list.item_selected.connect(_show)
	_refresh()


func _input(event: InputEvent) -> void:
	Shortcuts.feed(event, get_viewport())


func _refresh() -> void:
	_reports = CdCrash.list()
	_list.clear()
	for r in _reports:
		# What it was doing matters more than when it was: a list of dates is
		# no help, a list of plugin names is.
		var what := CdCrash.doing(String(r.path))
		var when := Time.get_datetime_string_from_unix_time(int(r.when)).replace("T", "  ")
		# The ones from the scan were contained on purpose: the plugin took a
		# process that exists to be taken down, and nothing of yours was lost.
		if bool(r.get("scan", false)):
			when += "   (while checking plugins -- nothing was lost)"
		_list.add_item("%s\n%s" % [when, what if not what.is_empty() else String(r.name)])
	_count.text = "%d report%s in %s" % [_reports.size(), "" if _reports.size() == 1 else "s",
			CdCrash.dir()]
	if _reports.is_empty():
		_text.text = "Nothing here, which is the way it should be.\n\n" \
				+ "If Cadmium stops unexpectedly -- which is nearly always a plugin taking the\n" \
				+ "program with it -- a report lands in this folder saying what was being done\n" \
				+ "at the time, and which plugin it was."
		return
	_list.select(0)
	_show(0)


func _show(i: int) -> void:
	if i < 0 or i >= _reports.size():
		return
	_text.text = CdCrash.read(String(_reports[i].path))


func _delete() -> void:
	var picked := _list.get_selected_items()
	if picked.is_empty():
		return
	CdCrash.remove(String(_reports[int(picked[0])].path))
	_refresh()
