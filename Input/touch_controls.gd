extends Control
## Multi-touch HUD controls: joystick, action buttons, drag-to-look, gyro aiming.
## Every finger is tracked by its index, so thumbs never interfere with each other.

signal settings_requested

const CFG_PATH := "user://hud.cfg"
# Bump this number whenever the default button layout changes.
# Old saved layouts with a different version are ignored automatically.
const LAYOUT_VERSION := 3
const STICK_R := 85.0
const R_MIN := 20.0
const R_MAX := 120.0

# ---- Gyro tuning ----
# If gyro looks reversed on your phone, change the matching sign to -1.0
const GYRO_YAW_SIGN := 1.0
const GYRO_PITCH_SIGN := 1.0
# Higher = faster gyro turning
const GYRO_PX_PER_RAD := 450.0

var active := false
var edit_mode := false
var hud_scale := 1.0
var sens := 1.0
var gyro_enabled := true
var gyro_sens := 1.0

var move_vec := Vector2.ZERO
var sprint := false
var look_delta := Vector2.ZERO

var buttons := {
	"fire": {"pos": Vector2(0.84, 0.60), "r": 66.0, "label": "FIRE", "look": true, "col": Color(1.0, 0.45, 0.1)},
	"fire_l": {"pos": Vector2(0.08, 0.42), "r": 44.0, "label": "FIRE", "look": false, "col": Color(1.0, 0.45, 0.1)},
	"aim": {"pos": Vector2(0.72, 0.38), "r": 40.0, "label": "AIM", "look": true, "col": Color(0.4, 0.8, 1.0)},
	"jump": {"pos": Vector2(0.92, 0.82), "r": 46.0, "label": "JUMP", "look": false, "col": Color(1, 1, 1)},
	"slide": {"pos": Vector2(0.94, 0.36), "r": 40.0, "label": "SLIDE", "look": false, "col": Color(0.5, 1.0, 0.6)},
	"reload": {"pos": Vector2(0.70, 0.78), "r": 34.0, "label": "RELOAD", "look": false, "col": Color(1, 1, 1)},
	"switch": {"pos": Vector2(0.60, 0.68), "r": 30.0, "label": "SWAP", "look": false, "col": Color(1, 1, 1)},
	"gyro": {"pos": Vector2(0.955, 0.22), "r": 26.0, "label": "GYRO", "look": false, "col": Color(0.9, 0.6, 1.0)},
	"gear": {"pos": Vector2(0.955, 0.09), "r": 24.0, "label": "II", "look": false, "col": Color(1, 1, 1)},
}
var _defaults := {}
var _fingers := {}      # finger index -> role ("stick", "look", button name, "edit:<name>")
var _btn_finger := {}   # button name -> finger index
var _stick_finger := -1
var _stick_center := Vector2.ZERO
var _stick_pos := Vector2.ZERO
var _stick_home := Vector2(0.13, 0.74)
var _jump_edge := false
var _reload_edge := false
var _switch_edge := false
var _selected := ""     # button selected in edit mode

var fire_held: bool:
	get:
		return _btn_finger.has("fire") or _btn_finger.has("fire_l")
var aim_held: bool:
	get:
		return _btn_finger.has("aim")
var slide_held: bool:
	get:
		return _btn_finger.has("slide")

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fit()
	get_viewport().size_changed.connect(_fit)
	_defaults = buttons.duplicate(true)

func _fit() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = get_viewport_rect().size

func consume_look() -> Vector2:
	var d := look_delta
	look_delta = Vector2.ZERO
	return d

func consume_jump() -> bool:
	var v := _jump_edge
	_jump_edge = false
	return v

func consume_reload() -> bool:
	var v := _reload_edge
	_reload_edge = false
	return v

func consume_switch() -> bool:
	var v := _switch_edge
	_switch_edge = false
	return v

func reset_state() -> void:
	_fingers.clear()
	_btn_finger.clear()
	_stick_finger = -1
	move_vec = Vector2.ZERO
	sprint = false
	look_delta = Vector2.ZERO
	_jump_edge = false
	_reload_edge = false
	_switch_edge = false

func _center(b: Dictionary) -> Vector2:
	var p: Vector2 = b["pos"]
	return Vector2(p.x * size.x, p.y * size.y)

func _hit_button(p: Vector2) -> String:
	var best := ""
	var best_d := 1e9
	for k in buttons.keys():
		var b: Dictionary = buttons[k]
		var d: float = p.distance_to(_center(b))
		var r: float = float(b["r"]) * hud_scale + 10.0
		if d <= r and d < best_d:
			best = k
			best_d = d
	return best

# Edit-mode resize buttons ("-" left, "+" right, bottom center).
func _size_pad(sign_: int) -> Vector2:
	return Vector2(size.x * (0.5 + 0.07 * sign_), size.y * 0.90)

func _hit_size_pad(p: Vector2) -> int:
	if p.distance_to(_size_pad(-1)) <= 40.0:
		return -1
	if p.distance_to(_size_pad(1)) <= 40.0:
		return 1
	return 0

func _resize_selected(dir: int) -> void:
	if _selected != "" and buttons.has(_selected):
		var r: float = float(buttons[_selected]["r"])
		buttons[_selected]["r"] = clampf(r + 6.0 * dir, R_MIN, R_MAX)
	else:
		hud_scale = clampf(hud_scale + 0.05 * dir, 0.6, 1.6)
	save_layout()

func _input(event: InputEvent) -> void:
	if not (active or edit_mode):
		return
	if event is InputEventScreenTouch:
		if event.pressed and not event.canceled:
			# Clear any stale state for a reused finger index, then press.
			_release(event.index)
			_press(event.index, event.position)
		else:
			_release(event.index)
	elif event is InputEventScreenDrag:
		_drag(event.index, event.position, event.relative)

func _press(idx: int, pos: Vector2) -> void:
	if edit_mode:
		var sp := _hit_size_pad(pos)
		if sp != 0:
			_resize_selected(sp)
			return
		var eb := _hit_button(pos)
		if eb != "":
			_selected = eb
			_fingers[idx] = "edit:" + eb
		return
	var bn := _hit_button(pos)
	if bn != "":
		# If this button was held by another (stale) finger, free that one.
		if _btn_finger.has(bn):
			_fingers.erase(_btn_finger[bn])
		_btn_finger[bn] = idx
		_fingers[idx] = bn
		match bn:
			"jump":
				_jump_edge = true
			"reload":
				_reload_edge = true
			"switch":
				_switch_edge = true
			"gyro":
				_btn_finger.erase(bn)
				_fingers.erase(idx)
				gyro_enabled = not gyro_enabled
				save_layout()
			"gear":
				_btn_finger.erase(bn)
				_fingers.erase(idx)
				settings_requested.emit()
		return
	if pos.x < size.x * 0.42 and _stick_finger < 0:
		_stick_finger = idx
		_stick_center = pos
		_stick_pos = pos
		_fingers[idx] = "stick"
		_update_stick()
	else:
		_fingers[idx] = "look"

func _drag(idx: int, pos: Vector2, rel: Vector2) -> void:
	if not _fingers.has(idx):
		return
	var role: String = _fingers[idx]
	if edit_mode:
		if role.begins_with("edit:"):
			var bn := role.substr(5)
			buttons[bn]["pos"] = Vector2(clampf(pos.x / size.x, 0.04, 0.96), clampf(pos.y / size.y, 0.06, 0.94))
		return
	if role == "stick":
		_stick_pos = pos
		_update_stick()
	elif role == "look":
		look_delta += rel
	elif buttons.has(role) and buttons[role]["look"]:
		look_delta += rel

func _release(idx: int) -> void:
	if not _fingers.has(idx):
		return
	var role: String = _fingers[idx]
	_fingers.erase(idx)
	if role == "stick":
		_stick_finger = -1
		move_vec = Vector2.ZERO
		sprint = false
	elif role.begins_with("edit:"):
		save_layout()
	elif _btn_finger.has(role) and _btn_finger[role] == idx:
		_btn_finger.erase(role)

# Joystick is now fixed where you first touch: it no longer follows your finger,
# so pushing forward keeps the same center and sprint/slide stay reliable.
func _update_stick() -> void:
	var r := STICK_R * hud_scale
	var d := _stick_pos - _stick_center
	var v := Vector2(d.x, -d.y) / r
	if v.length() < 0.12:
		v = Vector2.ZERO
	move_vec = v.limit_length(1.0)
	var m := move_vec.length()
	if m > 0.85:
		sprint = true
	elif m < 0.35:
		sprint = false

func _apply_gyro(delta: float) -> void:
	if not gyro_enabled:
		return
	var g := Input.get_gyroscope()
	if g == Vector3.ZERO:
		return
	var flip := 1.0
	if DisplayServer.screen_get_orientation() == DisplayServer.SCREEN_REVERSE_LANDSCAPE:
		flip = -1.0
	var k := GYRO_PX_PER_RAD * gyro_sens * delta * flip
	# In landscape, device X axis = screen vertical (yaw), device Y axis = screen horizontal (pitch).
	look_delta.x += -g.x * GYRO_YAW_SIGN * k
	look_delta.y += -g.y * GYRO_PITCH_SIGN * k

func _process(delta: float) -> void:
	if active and not edit_mode:
		_apply_gyro(delta)
	if active or edit_mode:
		queue_redraw()

func _draw() -> void:
	if not (active or edit_mode):
		return
	var font := ThemeDB.fallback_font
	var r := STICK_R * hud_scale
	var c0 := Vector2(size.x * _stick_home.x, size.y * _stick_home.y)
	var off := Vector2.ZERO
	if _stick_finger >= 0:
		c0 = _stick_center
		off = (_stick_pos - _stick_center).limit_length(r)
	draw_circle(c0, r, Color(1, 1, 1, 0.07))
	var ring_col := Color(1.0, 0.6, 0.15, 0.7) if sprint else Color(1, 1, 1, 0.35)
	draw_arc(c0, r, 0.0, TAU, 48, ring_col, 2.5, true)
	draw_circle(c0 + off, r * 0.38, Color(1, 1, 1, 0.45 if _stick_finger >= 0 else 0.22))
	var fs := int(15.0 * hud_scale)
	for k in buttons.keys():
		var b: Dictionary = buttons[k]
		var c := _center(b)
		var br: float = float(b["r"]) * hud_scale
		var col: Color = b["col"]
		var down: bool = _btn_finger.has(k)
		if k == "gyro":
			down = gyro_enabled
		draw_circle(c, br, Color(col.r, col.g, col.b, 0.38 if down else 0.14))
		draw_arc(c, br, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.9 if down else 0.55), 2.5, true)
		if edit_mode and k == _selected:
			draw_arc(c, br + 5.0, 0.0, TAU, 40, Color(1, 1, 0.3, 1.0), 3.5, true)
		draw_string(font, c + Vector2(-br, fs * 0.35), String(b["label"]), HORIZONTAL_ALIGNMENT_CENTER, br * 2.0, fs, Color(1, 1, 1, 0.95))
	if edit_mode:
		draw_string(font, Vector2(0, size.y * 0.2), "DRAG BUTTONS TO MOVE THEM", HORIZONTAL_ALIGNMENT_CENTER, size.x, 28, Color(1, 0.8, 0.3))
		var tip := "TAP A BUTTON, THEN USE - / + TO RESIZE IT"
		if _selected != "":
			tip = "SELECTED: %s   (- / + to resize)" % String(buttons[_selected]["label"])
		draw_string(font, Vector2(0, size.y * 0.27), tip, HORIZONTAL_ALIGNMENT_CENTER, size.x, 20, Color(1, 1, 1, 0.85))
		for sgn in [-1, 1]:
			var pc := _size_pad(sgn)
			draw_circle(pc, 34.0, Color(1, 1, 1, 0.18))
			draw_arc(pc, 34.0, 0.0, TAU, 32, Color(1, 1, 1, 0.8), 2.5, true)
			draw_string(font, pc + Vector2(-34.0, 12.0), "+" if sgn > 0 else "-", HORIZONTAL_ALIGNMENT_CENTER, 68.0, 36, Color.WHITE)

func save_layout() -> void:
	var cf := ConfigFile.new()
	cf.set_value("meta", "layout_version", LAYOUT_VERSION)
	for k in buttons.keys():
		var p: Vector2 = buttons[k]["pos"]
		cf.set_value("buttons", String(k), p)
		cf.set_value("radius", String(k), float(buttons[k]["r"]))
	cf.set_value("settings", "hud_scale", hud_scale)
	cf.set_value("settings", "sens", sens)
	cf.set_value("settings", "gyro_enabled", gyro_enabled)
	cf.set_value("settings", "gyro_sens", gyro_sens)
	cf.save(CFG_PATH)

func load_layout() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) != OK:
		return
	# Always keep user settings.
	hud_scale = clampf(float(cf.get_value("settings", "hud_scale", 1.0)), 0.6, 1.6)
	sens = clampf(float(cf.get_value("settings", "sens", 1.0)), 0.3, 2.5)
	gyro_enabled = bool(cf.get_value("settings", "gyro_enabled", true))
	gyro_sens = clampf(float(cf.get_value("settings", "gyro_sens", 1.0)), 0.2, 3.0)
	# Only restore saved button positions/sizes if they match the current layout version.
	if int(cf.get_value("meta", "layout_version", 0)) != LAYOUT_VERSION:
		return
	for k in buttons.keys():
		var p = cf.get_value("buttons", String(k), buttons[k]["pos"])
		if p is Vector2:
			buttons[k]["pos"] = p
		var rr = cf.get_value("radius", String(k), buttons[k]["r"])
		buttons[k]["r"] = clampf(float(rr), R_MIN, R_MAX)

func reset_layout() -> void:
	for k in buttons.keys():
		buttons[k]["pos"] = _defaults[k]["pos"]
		buttons[k]["r"] = _defaults[k]["r"]
	hud_scale = 1.0
	_selected = ""
	save_layout()
