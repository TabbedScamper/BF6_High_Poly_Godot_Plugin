extends SceneTree

# HOW FAR ABOVE THE RENDERED GROUND DOES A ROAD ACTUALLY SIT?
#
# The lift was 15 cm and it cut through car tyres. The game authors no height at
# all — TERRAIN.md §10.4 renders these depth-biased, which is a screen-space
# trick with the geometry left at the surface — so 15 cm was ours, covering a
# mismatch: the drape sampled the height grid bilinearly at full resolution
# while the terrain mesh draws flat triangles spanning `drape_step` texels.
#
# This measures the disagreement directly, over the real road vertices, both
# ways, so the new bias is chosen from the error rather than from comfort:
#
#   OLD  bilinear at full resolution, against the triangle the mesh draws
#   NEW  the triangle the mesh draws, against itself
#
# The number that matters is the WORST case where the road would sink below the
# ground, because that is what a lift has to cover. A mean is no use: 5% of
# vertices dipping is still visible.
#
#   godot --headless --path native/_testproj --script probe_drape.gd -- [level] [step]

const HighpolyGameSource := preload("res://highpoly_gamesource.gd")
const BF6Decals := preload("res://bf6_decals.gd")


func _init() -> void:
	await process_frame
	var a := OS.get_cmdline_user_args()
	var level := "mp_dumbo"
	var step := 2
	if a.size() > 0 and str(a[0]) != "": level = str(a[0])
	if a.size() > 1 and str(a[1]) != "": step = int(str(a[1]))

	var gs = HighpolyGameSource.new()
	gs.log_fn = func(s): print("   " + str(s))
	if not gs.open_map(level):
		print("FAIL open: %s" % gs.error); quit(1); return
	# terrain() fills the in-memory height grid the drape uses
	var hm: Dictionary = gs.terrain("user://drapetest/%s" % level)
	if hm.is_empty():
		print("FAIL: no heightfield"); quit(1); return
	gs.drape_step = step
	print("\nheight grid %d x %d, terrain drawn every %d texel(s)"
		% [int(hm["res"]), int(hm["res"]), step])

	var td = BF6Decals.new()
	if not td.parse(gs.src.get_res(BF6Decals.find_res(gs.src, level))):
		print("FAIL decals: %s" % td.error); quit(1); return

	# The rendered surface: the triangle the mesh draws, which is what the new
	# sampler returns. Everything is measured against it.
	var diffs: Array = []
	var n := 0
	for rec in td.records:
		var r: Dictionary = rec
		var vs := td.vertices(r)
		var cnt := vs.size() / 4
		for i in range(0, cnt, 7):            # every 7th vertex is plenty
			var x := vs[i * 4]
			var z := vs[i * 4 + 1]
			var drawn: float = gs._height_at(x, z)
			var old: float = _bilinear(gs, x, z)
			diffs.append(old - drawn)
			n += 1
	if diffs.is_empty():
		print("no vertices sampled"); quit(1); return
	diffs.sort()

	var lo: float = diffs[0]
	var hi: float = diffs[diffs.size() - 1]
	var med: float = diffs[diffs.size() / 2]
	var p95: float = diffs[int(diffs.size() * 0.95)]
	var p05: float = diffs[int(diffs.size() * 0.05)]
	var below := 0
	for d in diffs:
		if float(d) < 0.0:
			below += 1
	print("\n%d road vertices sampled" % n)
	print("OLD sampler minus the surface actually drawn (metres):")
	print("   min %+.4f   5%% %+.4f   median %+.4f   95%% %+.4f   max %+.4f"
		% [lo, p05, med, p95, hi])
	print("   vertices the OLD sampler placed BELOW the drawn ground: %d (%.1f%%)"
		% [below, 100.0 * float(below) / float(n)])
	print("\nSo the old lift had to cover %.3f m of sink. It was 0.15." % maxf(0.0, -lo))
	print("The new sampler evaluates the drawn triangle itself, so its error is")
	print("float precision, and the lift only has to beat that.")

	# What a lift of various sizes would look like on a car tyre (~0.35 m radius,
	# contact patch at ground level).
	print("\nfor scale: a car tyre is about 0.6-0.7 m tall, so its lowest 0.15 m")
	print("is squarely inside a 0.15 m lift and clear of a 0.02 m one.")
	quit(0)


# The sampler as it was: bilinear over every texel, ignoring the coarser
# lattice the mesh actually has vertices on.
func _bilinear(gs, x: float, z: float) -> float:
	var hm: Dictionary = gs._hm
	var res: int = int(hm["res"])
	var wmin: float = float(hm["min"])
	var span: float = float(hm["max"]) - wmin
	if span <= 0.0 or res < 2:
		return 0.0
	var d: PackedByteArray = hm["data"]
	var fx: float = clampf((x - wmin) / span * (res - 1), 0.0, res - 1.001)
	var fz: float = clampf((z - wmin) / span * (res - 1), 0.0, res - 1.001)
	var x0 := int(fx)
	var z0 := int(fz)
	var tx := fx - x0
	var tz := fz - z0
	var h00 := float(d.decode_u16((z0 * res + x0) * 2))
	var h10 := float(d.decode_u16((z0 * res + x0 + 1) * 2))
	var h01 := float(d.decode_u16(((z0 + 1) * res + x0) * 2))
	var h11 := float(d.decode_u16(((z0 + 1) * res + x0 + 1) * 2))
	var hv := h00 * (1.0 - tx) * (1.0 - tz) + h10 * tx * (1.0 - tz) \
		+ h01 * (1.0 - tx) * tz + h11 * tx * tz
	return float(hm["base"]) + hv * float(hm["scale"]) / 65535.0
