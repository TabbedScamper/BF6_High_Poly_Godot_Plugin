@tool
extends RefCounted

# Read scene headers, not scene resources: scanning priorities must never load
# models, run scripts, or count every shipped SDK map as a creator save.
static func scene_levels(path: String, allowed: Array) -> Array:
	var found: Array = []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return found
	var attribute := RegEx.new()
	attribute.compile('(?:path|name)="([^"]+)"')
	while not file.eof_reached() and file.get_position() < 262144:
		var line := file.get_line()
		if line.begins_with("[ext_resource") and not line.contains('type="PackedScene"'):
			continue
		if line.begins_with("[ext_resource") or line.begins_with("[node "):
			for match_ in attribute.search_all(line):
				var value := str(match_.get_string(1)).to_lower()
				var level := ""
				if line.begins_with("[node "):
					level = value
				elif value.begins_with("res://static/") or value.begins_with("res://levels/"):
					level = value.get_file().trim_suffix(".tscn").trim_suffix("_terrain").trim_suffix("_assets")
				if level in allowed and level not in found:
					found.append(level)
		if line.begins_with("[node "):
			break
	return found

static func saved_levels(allowed: Array) -> Dictionary:
	var result := {}
	var pending: Array = ["res://User_Created/levels", "res://levels/Custom_Maps"]
	while not pending.is_empty():
		var path := str(pending.pop_back())
		var directory := DirAccess.open(path)
		if directory == null:
			continue
		for name in directory.get_directories():
			if not name.begins_with(".") and not directory.is_link(name):
				pending.append(path.path_join(name))
		for name in directory.get_files():
			if not name.to_lower().ends_with(".tscn") or directory.is_link(name):
				continue
			var file := path.path_join(name)
			var when := FileAccess.get_modified_time(file)
			for level in scene_levels(file, allowed):
				result[level] = maxi(int(result.get(level, 0)), when)
	var recent := ConfigFile.new()
	if recent.load("res://.godot/editor/project_metadata.cfg") == OK:
		var scenes: Variant = recent.get_value("recent_files", "scenes", [])
		if scenes is Array or scenes is PackedStringArray:
			var when := int(Time.get_unix_time_from_system())
			for scene in scenes:
				for level in scene_levels(str(scene), allowed):
					result[level] = maxi(int(result.get(level, 0)), when)
				when -= 1
	return result

static func ordered(queue: Array, current: String, preferred: Dictionary) -> Array:
	var result: Array = []
	for level in queue:
		if level not in result:
			result.append(level)
	result.sort_custom(func(a, b):
		if a == current or b == current:
			return a == current and b != current
		var a_saved := preferred.has(a)
		var b_saved := preferred.has(b)
		if a_saved != b_saved:
			return a_saved
		if int(preferred.get(a, 0)) != int(preferred.get(b, 0)):
			return int(preferred.get(a, 0)) > int(preferred.get(b, 0))
		return str(a) < str(b))
	return result
