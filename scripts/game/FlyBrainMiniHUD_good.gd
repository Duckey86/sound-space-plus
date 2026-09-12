extends Control

# FlyBrainMiniHUD.gd
# Mini live morphology HUD for Godot 3.6.x.
#
# IMPORTANT:
# - No SubViewport / ViewportContainer.
# - It does NOT mirror the Rhythia playfield.
# - It draws a 2D projection of the real FlyWire v783 neuron skeletons.
# - UDP 50557 is visualization-only; gameplay remains on the existing bridge.
#
# Display:
#   dim blue   = inactive KC morphology
#   cyan       = KCs active for the current 16-state sensory pattern
#   dim purple = inactive action MBONs
#   white/pink = winning MBON
#
# F9 = hide/show mini HUD

const HOST = "127.0.0.1"
const HUD_PORT = 50557
const STALE_MS = 750
const CACHE_PATH = "res://data/flybrain_visual/flybrain_policy_skeletons.json"

const PANEL_POS = Vector2(16, 16)
const PANEL_SIZE = Vector2(455, 292)
const HEADER_H = 38.0
const FOOTER_H = 31.0
const BRAIN_PAD = 12.0

var udp = PacketPeerUDP.new()

var latest = {}
var last_packet_ms = -999999
var last_redraw_ms = -999999

# rid -> PoolVector2Array containing disconnected segment pairs:
# [a0,b0,a1,b1,...]
var neuron_lines = {}
var neuron_info = {}

var loaded_neurons = 0
var loaded_segments = 0

var active_kcs = {}
var winner_mbon = ""
var current_state = "CENTERED"
var current_winner = "CENTERED"

var bg = Color(0.010, 0.016, 0.024, 0.92)
var border = Color(0.13, 0.28, 0.37, 0.90)

var text_main = Color(0.91, 0.96, 1.0, 1.0)
var text_dim = Color(0.48, 0.61, 0.70, 1.0)

var kc_inactive = Color(0.18, 0.34, 0.43, 0.20)
var kc_active = Color(0.05, 0.92, 1.0, 0.96)

var mbon_inactive = Color(0.70, 0.25, 0.65, 0.30)
var mbon_winner_outer = Color(1.0, 0.25, 0.82, 0.88)
var mbon_winner_inner = Color(1.0, 1.0, 1.0, 1.0)

var live_color = Color(0.15, 1.0, 0.72, 1.0)
var waiting_color = Color(1.0, 0.55, 0.30, 1.0)


func _ready():
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect_min_size = PANEL_POS + PANEL_SIZE + Vector2(8, 8)
	rect_size = rect_min_size

	_load_morphology_cache()

	var err = udp.listen(HUD_PORT, HOST)

	if err == OK:
		print("[FlyBrainMiniHUD] UDP 50557 ready")
	else:
		print("[FlyBrainMiniHUD] UDP listen error: ", err)

	set_process(true)
	set_process_unhandled_input(true)
	update()


func _brain_rect():
	return Rect2(
		PANEL_POS + Vector2(BRAIN_PAD, HEADER_H),
		Vector2(
			PANEL_SIZE.x - BRAIN_PAD * 2.0,
			PANEL_SIZE.y - HEADER_H - FOOTER_H
		)
	)


func _load_morphology_cache():
	var f = File.new()

	if not f.file_exists(CACHE_PATH):
		print("[FlyBrainMiniHUD] Cache missing: ", CACHE_PATH)
		return

	var err = f.open(CACHE_PATH, File.READ)
	if err != OK:
		print("[FlyBrainMiniHUD] Could not open cache: ", err)
		return

	var raw_text = f.get_as_text()
	f.close()

	print(
		"[FlyBrainMiniHUD] Parsing FlyWire morphology cache (",
		raw_text.length(),
		" bytes)..."
	)

	var parsed = JSON.parse(raw_text)

	if parsed.error != OK:
		print(
			"[FlyBrainMiniHUD] JSON error line ",
			parsed.error_line,
			": ",
			parsed.error_string
		)
		return

	var cache = parsed.result
	var neurons = cache.get("neurons", [])

	# First pass: project 3D -> 2D and find global projected bounds.
	var raw_projected = {}

	var min_x = INF
	var min_y = INF
	var max_x = -INF
	var max_y = -INF

	for n in neurons:
		var rid = String(n.get("id", ""))
		var role = String(n.get("role", "KC"))
		var action = String(n.get("action", ""))
		var vertices = n.get("vertices", [])

		if rid == "" or vertices.size() < 6:
			continue

		var pts = []

		for i in range(0, vertices.size(), 3):
			var x = float(vertices[i])

			# Match the old 3D camera's front view:
			# 3D world +Y points upward, while CanvasItem +Y points downward.
			var y = -float(vertices[i + 1])

			pts.append(Vector2(x, y))

			min_x = min(min_x, x)
			min_y = min(min_y, y)
			max_x = max(max_x, x)
			max_y = max(max_y, y)

		raw_projected[rid] = pts

		neuron_info[rid] = {
			"role": role,
			"action": action,
			"segments": int(n.get("segments", vertices.size() / 6))
		}

		loaded_neurons += 1
		loaded_segments += int(n.get("segments", vertices.size() / 6))

	if raw_projected.empty():
		print("[FlyBrainMiniHUD] No drawable neurons in cache.")
		return

	# Second pass: fit the complete real morphology into the mini HUD.
	var br = _brain_rect()

	var span_x = max(max_x - min_x, 0.000001)
	var span_y = max(max_y - min_y, 0.000001)

	var usable_w = br.size.x - 12.0
	var usable_h = br.size.y - 10.0

	var scale = min(
		usable_w / span_x,
		usable_h / span_y
	)

	var src_cx = (min_x + max_x) * 0.5
	var src_cy = (min_y + max_y) * 0.5

	var dst_center = br.position + br.size * 0.5

	for rid in raw_projected.keys():
		var pool = PoolVector2Array()

		for p in raw_projected[rid]:
			pool.append(
				Vector2(
					dst_center.x + (p.x - src_cx) * scale,
					dst_center.y + (p.y - src_cy) * scale
				)
			)

		neuron_lines[rid] = pool

	print(
		"[FlyBrainMiniHUD] Loaded ",
		loaded_neurons,
		" real neurons / ",
		loaded_segments,
		" segments"
	)


func _process(_delta):
	var got_packet = false

	while udp.get_available_packet_count() > 0:
		var bytes = udp.get_packet()
		var text = bytes.get_string_from_utf8()
		var parsed = JSON.parse(text)

		if parsed.error == OK:
			latest = parsed.result
			last_packet_ms = OS.get_ticks_msec()
			got_packet = true

	if got_packet:
		_consume_live_packet()
		last_redraw_ms = OS.get_ticks_msec()
		update()

	# Only refresh occasionally when idle, so the LIVE/WAITING label updates
	# without redrawing 270 morphologies at the game's full FPS.
	elif OS.get_ticks_msec() - last_redraw_ms > 250:
		last_redraw_ms = OS.get_ticks_msec()
		update()


func _consume_live_packet():
	active_kcs.clear()

	for rid in latest.get("active_kcs", []):
		active_kcs[String(rid)] = true

	winner_mbon = String(latest.get("winner_mbon", ""))
	current_state = String(latest.get("state", "CENTERED"))
	current_winner = String(latest.get("winner", "CENTERED"))


func _unhandled_input(event):
	if not (event is InputEventKey):
		return

	if not event.pressed or event.echo:
		return

	if event.scancode == KEY_F9:
		visible = not visible


func _font():
	return get_font("font")


func _label(pos, value, color = Color(1, 1, 1, 1)):
	draw_string(
		_font(),
		pos,
		String(value),
		color
	)


func _draw_neuron(rid, color, width):
	if not neuron_lines.has(rid):
		return

	var pts = neuron_lines[rid]

	if pts.size() < 2:
		return

	# draw_multiline interprets [a0,b0,a1,b1,...] as disconnected lines,
	# which exactly matches the skeleton cache's segment representation.
	draw_multiline(
		pts,
		color,
		width,
		true
	)


func _draw():
	var panel = Rect2(PANEL_POS, PANEL_SIZE)
	var br = _brain_rect()

	# Compact HUD background only. There is no subviewport and therefore
	# absolutely no gameplay texture inside this panel.
	draw_rect(panel, bg, true)
	draw_rect(panel, border, false, 1.0)

	# Header.
	_label(
		PANEL_POS + Vector2(14, 23),
		"FLY BRAIN — LIVE NEURONS",
		text_main
	)

	var stale = OS.get_ticks_msec() - last_packet_ms > STALE_MS
	var status = "WAITING" if stale else "NEEGY"
	var status_color = waiting_color if stale else live_color

	draw_circle(
		PANEL_POS + Vector2(PANEL_SIZE.x - 58, 18),
		3.0,
		status_color
	)

	_label(
		PANEL_POS + Vector2(PANEL_SIZE.x - 48, 23),
		status,
		status_color
	)

	# Very subtle inner viewing region.
	draw_rect(
		br,
		Color(0.015, 0.025, 0.034, 0.72),
		true
	)

	# 1) Entire real policy morphology as a dim anatomical background.
	for rid in neuron_lines.keys():
		var info = neuron_info.get(rid, {})
		var role = String(info.get("role", "KC"))

		if role == "MBON":
			_draw_neuron(rid, mbon_inactive, 1.0)
		else:
			_draw_neuron(rid, kc_inactive, 1.0)

	# 2) Current active KC population on top.
	for rid in active_kcs.keys():
		_draw_neuron(rid, kc_active, 1.6)

	# 3) Winning real MBON, with a wider colored halo + white core.
	if winner_mbon != "" and neuron_lines.has(winner_mbon):
		_draw_neuron(winner_mbon, mbon_winner_outer, 3.2)
		_draw_neuron(winner_mbon, mbon_winner_inner, 1.6)

	# Tiny footer only: no score bars, no mirrored playfield.
	var footer_y = PANEL_POS.y + PANEL_SIZE.y - 11

	_label(
		Vector2(PANEL_POS.x + 13, footer_y),
		"state: " + current_state,
		kc_active
	)

	_label(
		Vector2(PANEL_POS.x + 214, footer_y),
		"KCs: " + String(active_kcs.size()),
		text_dim
	)

	_label(
		Vector2(PANEL_POS.x + 287, footer_y),
		"MBON: " + current_winner,
		mbon_winner_inner
	)
