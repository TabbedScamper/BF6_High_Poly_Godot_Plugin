@tool
extends SceneTree
# Capture one real CAS read from the working plugin, so the C port can be
# validated against it byte-for-byte. Mounts one level, picks a resource,
# resolves its (cas path, offset, size), reads + decompresses it, writes the
# exact bytes to a file, and prints the triple for the C harness.
const SC := "C:/Users/mwalt/AppData/Local/Temp/claude/C--Users-mwalt/9b036b50-aae1-4310-8139-063d65d55375/scratchpad"
func _init():
	var game := "C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6"
	var src = BF6Source.new()
	if not src.open(game):
		print("open failed: ", src.error); quit(1); return
	if not src.mount("MP_Badlands", Callable(), true, 0, false):
		print("mount failed: ", src.error); quit(1); return
	var res: Dictionary = src.snap_res()
	# Pick a mid-sized resource: skip the tiniest (headers) so a multi-block span
	# is likely, but nothing huge. First key with a declared size in a good range.
	var pick := ""
	var e = null
	for k in res.keys():
		var ee = res[k]
		var dsize := int(ee[4])
		if dsize > 40000 and dsize < 400000:
			pick = str(k); e = ee; break
	if e == null:
		print("no suitable resource found"); quit(1); return
	var path: String = src._loc.cas_path(int(e[0]), int(e[1]))
	var off := int(e[2]); var size := int(e[3]); var dsize := int(e[4])
	var bytes := src.get_res(pick)
	if bytes.is_empty():
		print("get_res failed: ", src.error); quit(1); return
	var outp := SC + "/gd_cas_out.bin"
	var f := FileAccess.open(outp, FileAccess.WRITE)
	f.store_buffer(bytes); f.close()
	# The line the C harness is fed. Printed with clear markers to grep.
	print("PICK res=%s" % pick)
	print("TRIPLE path=%s" % path)
	print("TRIPLE offset=%d" % off)
	print("TRIPLE size=%d" % size)
	print("RESULT len=%d declared=%d wrote=%s" % [bytes.size(), dsize, outp])
	quit(0)
