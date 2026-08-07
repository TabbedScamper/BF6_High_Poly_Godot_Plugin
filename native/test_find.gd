extends SceneTree

# Does the native byte search work, and is it fast enough to justify existing?
#
# It exists so that resolving a Frostbite type — locating its 16-byte GUID in
# the exe's 5.3 MB `typeinfo` section — is affordable from GDScript. If it is
# not decisively faster than a script loop then the honest answer is to ship a
# pre-generated type database instead, so this measures both and says so.

func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var exe := str(a[0]) if a.size() > 0 else \
			"C:/Program Files (x86)/Steam/steamapps/common/Battlefield 6/SP/bf6.exe"

	var oo = ClassDB.instantiate("BF6Oodle")
	if oo == null:
		print("BF6Oodle is not registered — the extension did not load")
		quit(1); return
	if not oo.has_method("find"):
		print("BF6Oodle has no find() — an OLD build of the dll is loaded")
		quit(1); return

	# Correctness first, on data whose answer is known by construction.
	var hay := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9])
	var checks := [
		[PackedByteArray([4, 5, 6]), 0, -1, 3, "middle"],
		[PackedByteArray([1, 2]), 0, -1, 0, "at the start"],
		[PackedByteArray([8, 9]), 0, -1, 7, "at the end"],
		[PackedByteArray([9, 10]), 0, -1, -1, "absent"],
		[PackedByteArray([4, 5, 6]), 4, -1, -1, "starts after the match"],
		[PackedByteArray([4, 5, 6]), 0, 5, -1, "ends before the match completes"],
		[PackedByteArray([4, 5, 6]), 0, 6, 3, "ends exactly at the match end"],
		[PackedByteArray(), 0, -1, -1, "empty needle"],
	]
	var bad := 0
	for c in checks:
		var got: int = oo.find(hay, c[0], c[1], c[2])
		if got != int(c[3]):
			print("  FAIL %-32s expected %d, got %d" % [c[4], int(c[3]), got])
			bad += 1
	print("correctness: %d of %d cases" % [checks.size() - bad, checks.size()])
	if bad > 0:
		quit(1); return

	if not FileAccess.file_exists(exe):
		print("\nno exe at %s — skipping the speed check" % exe)
		quit(0); return

	var t0 := Time.get_ticks_msec()
	var d := FileAccess.get_file_as_bytes(exe)
	print("\nread %.1f MB in %d ms" % [d.size() / 1048576.0,
			Time.get_ticks_msec() - t0])

	# A needle that is genuinely in there, taken from the file itself so the
	# search cannot be flattered by an early hit: something near the END.
	var at := d.size() - 4096
	var needle := d.slice(at, at + 16)

	t0 = Time.get_ticks_usec()
	var hit: int = oo.find(d, needle, 0, -1)
	var native_us := Time.get_ticks_usec() - t0
	print("native find over the whole exe: %d us  (hit at %d, expected <= %d)"
			% [native_us, hit, at])

	# The same search in GDScript, over a bounded slice — the whole file would
	# take long enough to make the point without finishing.
	const SLICE := 2_000_000
	t0 = Time.get_ticks_usec()
	var found := -1
	var n0 := needle[0]
	var lim: int = mini(SLICE, d.size() - 16)
	for i in range(lim):
		if d[i] == n0:
			var ok := true
			for j in range(1, 16):
				if d[i + j] != needle[j]:
					ok = false
					break
			if ok:
				found = i
				break
	var script_us := Time.get_ticks_usec() - t0
	print("GDScript loop over %d bytes: %d us" % [lim, script_us])

	# Scale the script figure to the same work the native call did, so the two
	# are comparable rather than merely both printed.
	var scaled := float(script_us) * float(d.size()) / float(lim)
	print("\nscaled to the whole file: GDScript ~%.0f ms, native %.1f ms  (%.0fx)"
			% [scaled / 1000.0, native_us / 1000.0,
			   scaled / maxf(1.0, float(native_us))])
	quit(0)
