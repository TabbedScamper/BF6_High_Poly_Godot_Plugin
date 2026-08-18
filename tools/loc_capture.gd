@tool
extends SceneTree
func _init():
	var game := "C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6"
	var src = BF6Source.new()
	if not src.open(game): print("open failed: ", src.error); quit(1); return
	if not src.mount("MP_Badlands", Callable(), true, 0, false): print("mount failed: ", src.error); quit(1); return
	var res: Dictionary = src.snap_res()
	# a few resources across different install chunks, to exercise the index
	var n := 0
	for k in res.keys():
		var e = res[k]
		var chunk := int(e[0]); var index := int(e[1])
		var path: String = src._loc.cas_path(chunk, index)
		if path == "": continue
		print("CASE chunk=%d index=%d PATH=%s" % [chunk, index, path])
		n += 1
		if n >= 5: break
	quit(0)
