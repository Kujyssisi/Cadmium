extends SceneTree
## Loads each VST3 instrument and prints what the host actually sees.
func _initialize() -> void:
	var eng = ClassDB.instantiate("CdEngine")
	get_root().add_child(eng)
	eng.start_audio()
	var list: Array = eng.scan_vst3(PackedStringArray())
	print("scanned: ", list.size())
	var seen := {}
	var n := 0
	for e in list:
		if not bool(e.instrument):
			continue
		if seen.has(String(e.path)):
			continue
		seen[String(e.path)] = true
		var h: int = eng.create_vst3(String(e.path), String(e.cid))
		var params: Array = eng.plugin_params(h)
		var groups := {}
		for p in params:
			groups[String(p.group)] = true
		var names := []
		for i in mini(4, params.size()):
			names.append("%s[%s]" % [String(params[i].name), String(params[i].group)])
		var info: Dictionary = eng.plugin_info(h)
		print("%-20s params=%4d groups=%3d  name=%-16s  %s" % [String(e.name), params.size(),
				groups.size(), String(info.get("name","")), ", ".join(names)])
		eng.destroy_plugin(h)
		n += 1
		if n >= 6:
			break
	quit()
