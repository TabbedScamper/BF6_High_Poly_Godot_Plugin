@tool
extends RefCounted
class_name BF6Scatter

# MeshScatteringDatabase (RES 0x2AB067B5) — which ground clutter a level
# scatters, straight from the game.
#
# One resource per level, at
# game/<branch>/levels/<level>/<level>/meshscatteringdatabaseasset. It names the
# MeshSets a level strews across its ground — pebbles, asphalt chunks, brick
# rubble, litter, grass kits, weeds, shrubs, desert rock — with per-mesh
# parameters.
#
# THIS CONTRADICTS WHAT THE PIPELINE ASSUMED. The scatter generator was built on
# the belief that scatter data is not shipped, so it invented a kit list and
# placed it with a greenness heuristic read off the map photo. The catalogue IS
# shipped, and this reads it.
#
# WHAT IS NOT IN HERE, and the reason the placement heuristic survives: the
# per-square-metre placement mask. This resource says WHICH meshes and with what
# parameters, not WHERE each blade goes. That is a separate question and it is
# not answered by this resource — nor, per the terrain research, by the
# per-node DensityMap, which is not a scatter mask either.
#
# Layout from dfanz0r's meshscatteringdatabase-layout, which lands on the exact
# final byte of four different levels. Everything is BYTE PACKED: each record
# starts with a variable-length string, so the numbers after it are not 4-byte
# aligned and have to be read unaligned.

const RES_TYPE := 0x2AB067B5

# Record: name NUL, then 45 bytes, then N*16 bytes of points, then a 24-byte
# trailer. 45 + 24 = the 69 fixed bytes the layout quotes.
const FIXED_HEAD := 45
const FIXED_TAIL := 24
const POINT_SIZE := 16
const OFF_DISTANCE := 33     # f32, {30, 50, 55, 75, 100, 150, 200, 300, ...}
const OFF_RATIO := 37        # f32, {0, 0.1, 0.15, 0.2, 0.25}
const OFF_COUNT := 41        # u32, 0..215

var records: Array = []      # [{name, distance, ratio, points: PackedVector3Array}]
var header: Array = []       # the ten header u32s, only the first is decoded
var consumed := 0            # where the walk finished; should equal the payload size
var error := ""


static func find_res(src: BF6Source, level: String) -> String:
	var low := level.to_lower()
	var fallback := ""
	for rn in src.res.keys():
		var e = src.res[rn]
		if int(e[5]) != RES_TYPE:
			continue
		var n := str(rn)
		if n.to_lower().contains(low):
			return n
		if fallback == "":
			fallback = n
	return fallback


func parse(d: PackedByteArray) -> bool:
	records.clear()
	header.clear()
	error = ""
	if d.size() < 0x28:
		error = "too small (%d bytes)" % d.size()
		return false
	for i in range(10):
		header.append(int(d.decode_u32(i * 4)))
	var count: int = header[0]
	if count < 0 or count > 100000:
		error = "record count %d outside the guard range" % count
		return false

	var p := 0x28
	for i in range(count):
		var start := p
		# The name runs to its NUL. Reading it as a length-prefixed string, or
		# assuming alignment after it, desynchronises the whole walk — which is
		# exactly why landing on the final byte is the check that matters.
		var end := p
		while end < d.size() and d[end] != 0:
			end += 1
		if end >= d.size():
			error = "record %d: unterminated name at %d" % [i, start]
			return false
		var name := d.slice(p, end).get_string_from_utf8()
		p = end + 1
		if p + FIXED_HEAD > d.size():
			error = "record %d: fixed block runs past the end" % i
			return false
		var dist := d.decode_float(p + OFF_DISTANCE)
		var ratio := d.decode_float(p + OFF_RATIO)
		var n := int(d.decode_u32(p + OFF_COUNT))
		if n < 0 or p + FIXED_HEAD + n * POINT_SIZE + FIXED_TAIL > d.size():
			error = "record %d (%s): %d points do not fit" % [i, name, n]
			return false
		var pts := PackedVector3Array()
		var q := p + FIXED_HEAD
		for k in range(n):
			# float3 then four zero bytes. Read as u32 the same bytes are
			# meaningless, which is how the point list was told from padding.
			pts.push_back(Vector3(d.decode_float(q), d.decode_float(q + 4),
				d.decode_float(q + 8)))
			q += POINT_SIZE
		p = q + FIXED_TAIL
		records.append({"name": name, "distance": dist, "ratio": ratio,
			"points": pts})
	consumed = p
	return not records.is_empty()


# Did the walk land exactly on the end of the payload?
#
# The strongest check available for a variable-length format: a wrong field
# offset or element stride desynchronises within a record or two and cannot
# finish on the byte.
func exact(payload_size: int) -> bool:
	return consumed == payload_size


# Just the MeshSet names, in order.
func names() -> Array:
	var out: Array = []
	for r in records:
		out.append(str((r as Dictionary)["name"]))
	return out


func stats() -> Dictionary:
	var with_points := 0
	var total_points := 0
	for r in records:
		var n: int = ((r as Dictionary)["points"] as PackedVector3Array).size()
		if n > 0:
			with_points += 1
		total_points += n
	return {"records": records.size(), "declared": header[0] if header else 0,
		"with_points": with_points, "points": total_points,
		"consumed": consumed}
