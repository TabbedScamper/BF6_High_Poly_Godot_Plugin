@tool
extends SceneTree
func _init():
	var game := "C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6"
	var src = BF6Source.new()
	if not src.open(game): print("open failed: ", src.error); quit(1); return
	var paths: Array = src._find_tocs("MP_Badlands", false)
	# find a toc that actually has bundles (superbundle, not a chunk-only HRES pkg)
	for p in paths:
		var t = BF6Toc.new()
		if not t.parse(FileAccess.get_file_as_bytes(str(p))): continue
		if t.bundles.size() == 0: continue
		print("TOC path=%s" % p)
		print("BUNDLES=%d CHUNKS=%d" % [t.bundles.size(), t.chunks.size()])
		var b0 = t.bundles[0]
		print("BUNDLE0 name=%s offset=%d size=%d" % [b0["name"], int(b0["offset"]), int(b0["size"])])
		if t.chunks.size() > 0:
			var c0 = t.chunks[0]
			var loc = t.chunk_location(c0)
			print("CHUNK0 guid=%s loc=%d,%d,%d,%d" % [c0["guid"], int(loc[0]), int(loc[1]), int(loc[2]), int(loc[3])])
		quit(0); return
	print("no toc with bundles found among %d" % paths.size()); quit(1)
