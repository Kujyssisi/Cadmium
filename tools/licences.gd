extends SceneTree
## Writes THIRD-PARTY-GODOT.txt out of the engine itself.
##
## Godot bundles around forty libraries -- FreeType, Harfbuzz, zlib, Thorvg and
## the rest -- and every one of them wants its notice shipped. Rather than keep a
## copy of that list here, where it would rot the first time the engine is
## updated, this asks the engine that is actually being built with.
##
##   godot-beta --headless --path . --script res://tools/licences.gd
##
## tools/package.sh runs it. Writes to build/THIRD-PARTY-GODOT.txt, or to the
## path given as the first user argument.

func _initialize() -> void:
	var out := "build/THIRD-PARTY-GODOT.txt"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0 and not String(args[0]).is_empty():
		out = String(args[0])

	var text := "Cadmium is built on the Godot Engine. Godot and the libraries it\n"
	text += "bundles are used under the licences below.\n\n"
	text += "Generated from Godot %s\n" % Engine.get_version_info().get("string", "?")
	text += "=".repeat(78) + "\n\n"

	text += "Godot Engine\n" + "-".repeat(78) + "\n"
	text += Engine.get_license_text() + "\n\n"

	text += "Bundled third-party components\n" + "=".repeat(78) + "\n\n"
	for component in Engine.get_copyright_info():
		text += "%s\n" % String(component.get("name", "?"))
		text += "-".repeat(78) + "\n"
		for part in component.get("parts", []):
			for holder in part.get("copyright", []):
				text += "Copyright (c) %s\n" % String(holder)
			text += "License: %s\n\n" % String(part.get("license", "?"))

	var licences: Dictionary = Engine.get_license_info()
	var names: Array = licences.keys()
	names.sort()
	text += "\nLicence texts\n" + "=".repeat(78) + "\n\n"
	for name in names:
		text += "%s\n%s\n%s\n\n" % [String(name), "-".repeat(78), String(licences[name])]

	var f := FileAccess.open(out if out.begins_with("res://") or out.begins_with("/") \
			else "res://" + out, FileAccess.WRITE)
	if f == null:
		push_error("licences: could not write %s" % out)
		quit(1)
		return
	f.store_string(text)
	f.close()
	print("licences: wrote %s (%d components, %d licence texts, %d bytes)" % [
			out, Engine.get_copyright_info().size(), names.size(), text.length()])
	quit()
