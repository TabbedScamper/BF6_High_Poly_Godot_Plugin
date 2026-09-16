extends SceneTree

const MeshReader = preload("res://bf6_meshset.gd")

func _init() -> void:
	var reader = MeshReader.new()
	var data := PackedFloat32Array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0]).to_byte_array()
	var result: Array = reader._read_attr(data, 0, 2, [1, 3, 0, 0], [[12, 0]])
	var methods: Array = []
	if ClassDB.class_exists("BF6Oodle"):
		for method in ClassDB.class_get_method_list("BF6Oodle", true):
			methods.append(str(method["name"]))
	var ok := result.size() == 2
	if ok:
		ok = result[0].to_byte_array() == data
	print(JSON.stringify({"ok": ok, "native": reader.native_attribute_reads,
		"script": reader.script_attribute_reads, "oodle_methods": methods}))
	quit(0 if ok else 1)
