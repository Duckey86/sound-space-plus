extends Control

# Live fly-brain decision HUD for Godot 3.6.x.
#
# IMPORTANT:
# This listens on a separate debug UDP port (50557).
# It does NOT touch the working cursor-control bridge or command port.

const HOST = "127.0.0.1"
const HUD_PORT = 50557
const STALE_MS = 500

var udp = PacketPeerUDP.new()
var latest = {}
var last_packet_ms = -999999

var panel_pos = Vector2(18, 18)
var panel_size = Vector2(520, 500)

var bg = Color(0.025, 0.035, 0.055, 0.91)
var border = Color(0.23, 0.75, 1.0, 0.80)
var text_main = Color(0.92, 0.96, 1.0, 1.0)
var text_dim = Color(0.58, 0.68, 0.78, 1.0)
var active = Color(0.25, 0.95, 0.68, 1.0)
var warn = Color(1.0, 0.52, 0.34, 1.0)
var bar_bg = Color(0.10, 0.14, 0.20, 0.95)
var pathway_dim = Color(0.20, 0.30, 0.40, 0.80)


func _ready():

	mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect_min_size = Vector2(560, 540)

	var err = udp.listen(
		HUD_PORT,
		HOST
	)

	if err != OK:
		print(
			"[FlyBrainHUD] Could not listen on UDP ",
			HUD_PORT,
			": ",
			err
		)
	else:
		print(
			"[FlyBrainHUD] Listening on UDP ",
			HUD_PORT
		)

	set_process(true)
	update()


func _process(delta):

	var got = false

	while udp.get_available_packet_count() > 0:

		var bytes = udp.get_packet()
		var text = bytes.get_string_from_utf8()
		var parsed = JSON.parse(text)

		if parsed.error == OK:
			latest = parsed.result
			last_packet_ms = OS.get_ticks_msec()
			got = true

	if got:
		update()

	# Keep stale indicator responsive even without new packets.
	if (
		OS.get_ticks_msec()
		- last_packet_ms
		> STALE_MS
	):
		update()


func label_text(
	pos,
	value,
	color = Color(1, 1, 1, 1)
):

	draw_string(
		get_font("font"),
		pos,
		String(value),
		color
	)


func rounded_panel(rect, color):

	draw_rect(
		rect,
		color,
		true
	)

	draw_rect(
		rect,
		border,
		false,
		1.0
	)


func section_title(pos, title):

	label_text(
		pos,
		title,
		border
	)


func score_normalized(
	scores,
	action
):

	var values = [
		float(scores.get("LEFT", 0.0)),
		float(scores.get("RIGHT", 0.0)),
		float(scores.get("UP", 0.0)),
		float(scores.get("DOWN", 0.0))
	]

	var lo = values[0]
	var hi = values[0]

	for v in values:
		lo = min(lo, v)
		hi = max(hi, v)

	var span = max(
		hi - lo,
		0.000001
	)

	return (
		float(scores.get(action, 0.0))
		- lo
	) / span


func draw_mbon_bar(
	y,
	action,
	scores,
	winner,
	mbon_ids
):

	var x = panel_pos.x + 30
	var label_w = 68
	var bar_x = x + label_w
	var bar_w = 245
	var bar_h = 18

	var value = float(
		scores.get(
			action,
			0.0
		)
	)

	var fraction = score_normalized(
		scores,
		action
	)

	var is_winner = (
		action == winner
	)

	var fill_color = (
		active
		if is_winner
		else Color(0.28, 0.56, 0.82, 0.88)
	)

	label_text(
		Vector2(
			x,
			y + 14
		),
		action,
		(
			active
			if is_winner
			else text_main
		)
	)

	draw_rect(
		Rect2(
			bar_x,
			y,
			bar_w,
			bar_h
		),
		bar_bg,
		true
	)

	draw_rect(
		Rect2(
			bar_x,
			y,
			bar_w * fraction,
			bar_h
		),
		fill_color,
		true
	)

	draw_rect(
		Rect2(
			bar_x,
			y,
			bar_w,
			bar_h
		),
		Color(0.35, 0.48, 0.60, 0.75),
		false,
		1.0
	)

	label_text(
		Vector2(
			bar_x + bar_w + 10,
			y + 14
		),
		"%.2f" % value,
		text_dim
	)

	var body_id = String(
		mbon_ids.get(
			action,
			""
		)
	)

	if body_id != "":
		label_text(
			Vector2(
				bar_x,
				y + 34
			),
			"MBON " + body_id,
			Color(
				text_dim.r,
				text_dim.g,
				text_dim.b,
				0.70
			)
		)


func draw_motor_arrow(
	center,
	vx,
	vy
):

	draw_circle(
		center,
		28,
		Color(0.06, 0.10, 0.16, 0.95)
	)

	draw_circle(
		center,
		28,
		border
	)

	var v = Vector2(
		float(vx),
		float(vy)
	)

	if v.length() < 0.001:
		draw_circle(
			center,
			4,
			text_dim
		)
		return

	# HUD screen Y points down, which matches our motor convention:
	# +vy = DOWN.
	var end = (
		center
		+ v.normalized() * 23
	)

	draw_line(
		center,
		end,
		active,
		3.0,
		true
	)

	var side = Vector2(
		-end.y + center.y,
		end.x - center.x
	).normalized()

	var back = (
		end
		- v.normalized() * 8
	)

	draw_line(
		end,
		back + side * 5,
		active,
		3.0,
		true
	)

	draw_line(
		end,
		back - side * 5,
		active,
		3.0,
		true
	)


func draw_kc_dots(
	origin,
	count
):

	var max_dots = 32
	var lit = min(
		int(count),
		max_dots
	)

	for i in range(max_dots):

		var col = i % 8
		var row = int(i / 8)

		var p = (
			origin
			+ Vector2(
				col * 16,
				row * 16
			)
		)

		draw_circle(
			p,
			4.2,
			(
				active
				if i < lit
				else Color(0.14, 0.19, 0.25, 0.85)
			)
		)


func _draw():

	var panel = Rect2(
		panel_pos,
		panel_size
	)

	rounded_panel(
		panel,
		bg
	)

	var x = panel_pos.x + 22
	var y = panel_pos.y + 30

	label_text(
		Vector2(x, y),
		"FLY BRAIN — LIVE",
		text_main
	)

	var stale = (
		OS.get_ticks_msec()
		- last_packet_ms
		> STALE_MS
	)

	if latest.empty() or stale:

		label_text(
			Vector2(
				x,
				y + 28
			),
			"waiting for controller HUD data...",
			warn
		)

		label_text(
			Vector2(
				x,
				y + 50
			),
			"Python must run rhythia_fly_controller_vector_hud.py",
			text_dim
		)

		return

	var fly_enabled = bool(
		latest.get(
			"fly_enabled",
			false
		)
	)

	label_text(
		Vector2(
			x + 340,
			y
		),
		(
			"FLY ON"
			if fly_enabled
			else "FLY OFF"
		),
		(
			active
			if fly_enabled
			else warn
		)
	)

	y += 34

	section_title(
		Vector2(x, y),
		"SENSORY"
	)

	y += 22

	var state = String(
		latest.get(
			"state",
			"CENTERED"
		)
	)

	var priority = String(
		latest.get(
			"priority",
			""
		)
	)

	label_text(
		Vector2(x, y),
		"state: " + state,
		active
	)

	label_text(
		Vector2(
			x + 270,
			y
		),
		"priority: " + priority,
		text_dim
	)

	y += 21

	label_text(
		Vector2(x, y),
		"error: (%+.2f, %+.2f)" % [
			float(latest.get("dx", 0.0)),
			float(latest.get("dy", 0.0))
		],
		text_main
	)

	label_text(
		Vector2(
			x + 270,
			y
		),
		"note %d | %.1f ms" % [
			int(latest.get("note", -1)),
			float(latest.get("time_to_note", 0.0))
		],
		text_dim
	)

	y += 35

	# ---------------------------------------------------------
	# PATHWAY: SENSORY -> KC -> MBON -> MOTOR
	# ---------------------------------------------------------

	section_title(
		Vector2(x, y),
		"ACTIVE PATHWAY"
	)

	var pathway_y = y + 34

	var sensory_rect = Rect2(
		x,
		pathway_y,
		86,
		48
	)

	var kc_rect = Rect2(
		x + 112,
		pathway_y,
		132,
		48
	)

	var mbon_rect = Rect2(
		x + 272,
		pathway_y,
		90,
		48
	)

	var motor_rect = Rect2(
		x + 390,
		pathway_y,
		82,
		48
	)

	for r in [
		sensory_rect,
		kc_rect,
		mbon_rect,
		motor_rect
	]:

		draw_rect(
			r,
			Color(0.07, 0.11, 0.16, 0.95),
			true
		)

		draw_rect(
			r,
			pathway_dim,
			false,
			1.0
		)

	draw_line(
		Vector2(
			sensory_rect.position.x + sensory_rect.size.x,
			pathway_y + 24
		),
		Vector2(
			kc_rect.position.x,
			pathway_y + 24
		),
		active,
		2.0
	)

	draw_line(
		Vector2(
			kc_rect.position.x + kc_rect.size.x,
			pathway_y + 24
		),
		Vector2(
			mbon_rect.position.x,
			pathway_y + 24
		),
		active,
		2.0
	)

	draw_line(
		Vector2(
			mbon_rect.position.x + mbon_rect.size.x,
			pathway_y + 24
		),
		Vector2(
			motor_rect.position.x,
			pathway_y + 24
		),
		active,
		2.0
	)

	label_text(
		Vector2(
			sensory_rect.position.x + 10,
			pathway_y + 19
		),
		"SENSORY",
		text_dim
	)

	label_text(
		Vector2(
			sensory_rect.position.x + 10,
			pathway_y + 37
		),
		"16-state",
		text_main
	)

	var kc_count = int(
		latest.get(
			"kc_count",
			0
		)
	)

	label_text(
		Vector2(
			kc_rect.position.x + 10,
			pathway_y + 19
		),
		"KENYON CELLS",
		text_dim
	)

	label_text(
		Vector2(
			kc_rect.position.x + 10,
			pathway_y + 37
		),
		"%d active KCs" % kc_count,
		active
	)

	var winner = String(
		latest.get(
			"winner",
			"CENTERED"
		)
	)

	label_text(
		Vector2(
			mbon_rect.position.x + 10,
			pathway_y + 19
		),
		"MBON",
		text_dim
	)

	label_text(
		Vector2(
			mbon_rect.position.x + 10,
			pathway_y + 37
		),
		winner,
		active
	)

	label_text(
		Vector2(
			motor_rect.position.x + 8,
			pathway_y + 19
		),
		"MOTOR",
		text_dim
	)

	label_text(
		Vector2(
			motor_rect.position.x + 8,
			pathway_y + 37
		),
		"VECTOR",
		text_main
	)

	y = pathway_y + 78

	# ---------------------------------------------------------
	# KC ACTIVITY
	# ---------------------------------------------------------

	section_title(
		Vector2(x, y),
		"KENYON CELL SENSORY POPULATION"
	)

	draw_kc_dots(
		Vector2(
			x + 5,
			y + 24
		),
		kc_count
	)

	var kc_ids = latest.get(
		"kc_ids",
		[]
	)

	var kc_id_text = ""

	for i in range(
		min(
			kc_ids.size(),
			5
		)
	):

		if i > 0:
			kc_id_text += ", "

		kc_id_text += String(
			int(kc_ids[i])
		)

	label_text(
		Vector2(
			x + 165,
			y + 32
		),
		"real KC indices:",
		text_dim
	)

	label_text(
		Vector2(
			x + 165,
			y + 52
		),
		kc_id_text,
		text_main
	)

	label_text(
		Vector2(
			x + 165,
			y + 72
		),
		"cached full-network response selected live",
		Color(
			text_dim.r,
			text_dim.g,
			text_dim.b,
			0.78
		)
	)

	y += 98

	# ---------------------------------------------------------
	# MBON SCORES
	# ---------------------------------------------------------

	section_title(
		Vector2(x, y),
		"LEARNED MBON OUTPUT"
	)

	var scores = latest.get(
		"scores",
		{}
	)

	var mbon_ids = latest.get(
		"mbon_ids",
		{}
	)

	y += 18

	draw_mbon_bar(
		y,
		"LEFT",
		scores,
		winner,
		mbon_ids
	)

	y += 49

	draw_mbon_bar(
		y,
		"RIGHT",
		scores,
		winner,
		mbon_ids
	)

	y += 49

	draw_mbon_bar(
		y,
		"UP",
		scores,
		winner,
		mbon_ids
	)

	y += 49

	draw_mbon_bar(
		y,
		"DOWN",
		scores,
		winner,
		mbon_ids
	)

	# ---------------------------------------------------------
	# MOTOR VECTOR
	# ---------------------------------------------------------

	var motor_center = Vector2(
		panel_pos.x + 455,
		panel_pos.y + 425
	)

	var vx = float(
		latest.get(
			"vx",
			0.0
		)
	)

	var vy = float(
		latest.get(
			"vy",
			0.0
		)
	)

	draw_motor_arrow(
		motor_center,
		vx,
		vy
	)

	label_text(
		Vector2(
			panel_pos.x + 388,
			panel_pos.y + 468
		),
		"vec (%+.2f, %+.2f)" % [
			vx,
			vy
		],
		text_main
	)
