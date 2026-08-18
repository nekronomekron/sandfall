extends Node2D

## Demo-Screen: Steinboden, verschiebbare und zoombare Kamera, Toolbar zum Malen.
##
## ZWEI GETRENNTE AUFLOESUNGEN:
##   - Die Spielwelt rendert in einen SubViewport mit VIEW_W x VIEW_H (320x130)
##     und wird davon GANZZAHLIG hochskaliert. Nur ganzzahlig - jeder andere
##     Faktor verteilt Weltpixel ungleichmaessig auf Bildschirmpixel und laesst
##     das Bild unruhig wirken.
##   - Die UI liegt darueber in der nativen Fensteraufloesung und wird gar nicht
##     skaliert. Deshalb ist der Text scharf statt hochgerechnet.
##
## Startparameter (jeweils nach `--`):
##   --bench              Performance-Durchlauf, headless moeglich
##   --fsmtest            Selbsttest der Aggregatzustands-FSM, headless moeglich
##   --flowtest           Regressionstest: bleibt fliessendes Material haengen?
##   --inputtest          Selbsttest fuer Zeichnen und Kameraschwenk
##   --shot [--frames=N]  Screenshot nach N Frames

## Interne Aufloesung der Spielwelt.
const VIEW_W := 320
const VIEW_H := 130

const WORLD_W := 1024
const WORLD_H := 576

const FLOOR_TOP := 480
const FLOOR_THICKNESS := 12

## Pinsel: genau eine Zelle. Radius 0 = 1 Pixel.
const BRUSH_RADIUS := 0

## Ganzzahlige Zoomstufen - alles andere liesse die Pixel flimmern.
const ZOOM_STEPS: Array[int] = [1, 2, 3, 4, 6, 8]
const PAN_SPEED := 90.0

var world: SimWorld
var sim: Simulation
var renderer: WorldRenderer
var cam: Camera2D
var sub: SubViewport
var view: TextureRect
var toolbar: Toolbar
var hud: Label

var paused: bool = false
var _zoom_step: int = 0
var _step_once: bool = false
var _panning: bool = false
var _last_paint := Vector2i(-9999, -9999)
var _sim_usec: int = 0
var _render_usec: int = 0
var _shot_frames: int = -1
var _shot_target: int = 90
var _input_test: bool = false

## Bildschirmrechteck und Skalierungsfaktor der hochskalierten Spielansicht.
## Wird fuer die Umrechnung Maus -> Weltzelle gebraucht.
var _view_rect := Rect2()
var _view_scale: int = 1

func _ready() -> void:
	var user_args := OS.get_cmdline_user_args()
	if user_args.has("--bench") or OS.get_cmdline_args().has("--bench"):
		_run_benchmark()
		return
	if user_args.has("--fsmtest"):
		_run_fsm_test()
		return
	if user_args.has("--flowtest"):
		_run_flow_test()
		return
	if user_args.has("--leveltest"):
		_run_level_test()
		return
	if user_args.has("--displacetest"):
		_run_displace_test()
		return
	if user_args.has("--inputtest"):
		_input_test = true

	world = SimWorld.new(WORLD_W, WORLD_H)
	sim = Simulation.new(world)
	_build_demo()

	if user_args.has("--shot"):
		_seed_shot_content()
		_shot_frames = 0
		for arg in user_args:
			if arg.begins_with("--frames="):
				_shot_target = int(arg.substr(9))

	_build_view()
	_build_ui()
	get_viewport().size_changed.connect(_layout_view)
	_layout_view()

	if _input_test:
		_run_input_test.call_deferred()

## Spielwelt in einen eigenen SubViewport mit niedriger Aufloesung.
func _build_view() -> void:
	sub = SubViewport.new()
	sub.size = Vector2i(VIEW_W, VIEW_H)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.transparent_bg = false
	sub.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	add_child(sub)

	renderer = WorldRenderer.new()
	sub.add_child(renderer)
	renderer.setup(world, VIEW_W, VIEW_H)

	cam = Camera2D.new()
	cam.position = Vector2(WORLD_W * 0.5, FLOOR_TOP - 40)
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = WORLD_W
	cam.limit_bottom = WORLD_H
	sub.add_child(cam)
	cam.make_current()
	_apply_zoom()

	# Anzeige der SubViewport-Textur, ganzzahlig skaliert.
	var layer := CanvasLayer.new()
	layer.layer = 0
	add_child(layer)
	view = TextureRect.new()
	view.texture = sub.get_texture()
	view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	view.stretch_mode = TextureRect.STRETCH_SCALE
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# Wie das ColorRect frueher waere auch das hier ein Control ueber der
	# Spielflaeche - ohne IGNORE wuerde es Maus-Hover und _unhandled_input
	# schlucken und damit Zeichnen und Kameraschwenk blockieren.
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(view)

## Groesster ganzzahliger Skalierungsfaktor, der noch ins Fenster passt.
func _layout_view() -> void:
	if view == null:
		return
	var win := Vector2(get_viewport().get_visible_rect().size)
	var s := mini(int(win.x) / VIEW_W, int(win.y) / VIEW_H)
	_view_scale = maxi(s, 1)
	var size := Vector2(VIEW_W, VIEW_H) * float(_view_scale)
	var pos := ((win - size) * 0.5).floor()
	view.position = pos
	view.size = size
	_view_rect = Rect2(pos, size)

func _build_demo() -> void:
	# Steinboden: eine Linie aus Stein mit gesetztem Static-Flag. Darauf wirkt
	# keine Schwerkraft, unabhaengig vom lokalen Gravitationsfeld.
	for y in range(FLOOR_TOP, mini(FLOOR_TOP + FLOOR_THICKNESS, WORLD_H)):
		for x in range(WORLD_W):
			world.set_cell(x, y, MaterialDB.STONE, true)

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	add_child(layer)

	toolbar = Toolbar.new()
	toolbar.set_anchors_preset(Control.PRESET_TOP_LEFT)
	toolbar.position = Vector2(10, 10)
	toolbar.reset_pressed.connect(_reset)
	layer.add_child(toolbar)

	hud = Label.new()
	hud.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hud.position = Vector2(10, -48)
	hud.add_theme_font_size_override("font_size", 13)
	hud.add_theme_color_override("font_color", Color(0.88, 0.91, 0.95))
	hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	hud.add_theme_constant_override("shadow_offset_x", 1)
	hud.add_theme_constant_override("shadow_offset_y", 1)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud)

func _reset() -> void:
	world.clear()
	sim.gravity.reset()
	_build_demo()
	renderer.redraw_all()

## Linke obere Ecke des sichtbaren Weltausschnitts. Bei Zoom > 1 ist der
## tatsaechlich sichtbare Bereich kleiner als VIEW_W x VIEW_H; das Fenster deckt
## ihn dann mit Reserve ab.
func _view_origin() -> Vector2i:
	var center := cam.get_screen_center_position()
	return Vector2i(
		floori(center.x - VIEW_W * 0.5),
		floori(center.y - VIEW_H * 0.5))

# --- Schleife ----------------------------------------------------------------

func _process(delta: float) -> void:
	if renderer == null:
		return
	_handle_keyboard_pan(delta)
	_handle_painting()

	if _shot_frames >= 0:
		_shot_frames += 1
		if _shot_frames == _shot_target:
			sim.step()
			renderer.update_dirty(_view_origin().x, _view_origin().y)
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var out := "res://selbsttest_%d.png" % _shot_target
			img.save_png(out)
			print("Screenshot geschrieben: %s" % out)
			get_tree().quit()
			return

	if not paused or _step_once:
		var t0 := Time.get_ticks_usec()
		sim.step()
		_sim_usec = Time.get_ticks_usec() - t0
		_step_once = false

	var tr := Time.get_ticks_usec()
	var o := _view_origin()
	renderer.update_dirty(o.x, o.y)
	_render_usec = Time.get_ticks_usec() - tr
	_update_hud()

func _handle_keyboard_pan(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S):
		dir.y += 1.0
	if dir != Vector2.ZERO:
		cam.position += dir.normalized() * PAN_SPEED * delta / cam.zoom.x

func _handle_painting() -> void:
	if _mouse_over_ui():
		_last_paint = Vector2i(-9999, -9999)
		return
	var erase := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	var draw := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not draw and not erase:
		_last_paint = Vector2i(-9999, -9999)
		return
	var cell := _mouse_cell()
	if cell.x < -9000:
		_last_paint = Vector2i(-9999, -9999)
		return
	var id := MaterialDB.EMPTY if erase else toolbar.selected_id
	var make_static := false if erase else toolbar.place_static
	if _last_paint.x > -9000:
		_paint_line(_last_paint, cell, id, make_static)
	else:
		_paint_dab(cell, id, make_static)
	_last_paint = cell

## Zieht eine Linie zwischen zwei Mauspositionen. Bei einem Pinsel von genau
## einer Zelle ist das der einzige Grund, warum schnelles Ziehen keine Luecken
## hinterlaesst.
func _paint_line(from: Vector2i, to: Vector2i, id: int, make_static: bool) -> void:
	var d := to - from
	var n := maxi(absi(d.x), absi(d.y))
	if n == 0:
		_paint_dab(to, id, make_static)
		return
	for s in range(n + 1):
		var p := Vector2(from) + Vector2(d) * (float(s) / float(n))
		_paint_dab(Vector2i(roundi(p.x), roundi(p.y)), id, make_static)

func _paint_dab(center: Vector2i, id: int, make_static: bool) -> void:
	var r := BRUSH_RADIUS
	if r <= 0:
		if world.in_bounds(center.x, center.y):
			world.set_cell(center.x, center.y, id, make_static)
		return
	var rr := r * r
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > rr:
				continue
			var x := center.x + dx
			var y := center.y + dy
			if world.in_bounds(x, y):
				world.set_cell(x, y, id, make_static)

## Fensterkoordinate -> Weltzelle. Der Weg fuehrt ueber das Rechteck der
## hochskalierten Ansicht in SubViewport-Koordinaten und von dort ueber die
## Canvas-Transformation (also die Kamera) in Weltkoordinaten.
func _mouse_cell() -> Vector2i:
	var m := get_viewport().get_mouse_position()
	if not _view_rect.has_point(m):
		return Vector2i(-99999, -99999)
	var local := (m - _view_rect.position) / float(_view_scale)
	var wp := sub.get_canvas_transform().affine_inverse() * local
	return Vector2i(floori(wp.x), floori(wp.y))

func _mouse_over_ui() -> bool:
	return get_viewport().gui_get_hovered_control() != null

# --- Eingabe -----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if renderer == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_set_zoom_step(_zoom_step + 1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_set_zoom_step(_zoom_step - 1)
	elif event is InputEventMouseMotion and _panning:
		var mm := event as InputEventMouseMotion
		# relative ist in Fensterpixeln, die Ansicht ist um _view_scale
		# vergroessert - sonst schwenkt die Kamera um ein Vielfaches zu weit.
		cam.position -= mm.relative / (float(_view_scale) * cam.zoom.x)
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_SPACE:
				paused = not paused
			KEY_N:
				_step_once = true
			KEY_R:
				_reset()
			KEY_H:
				renderer.show_heat = not renderer.show_heat
				renderer.redraw_all()

func _set_zoom_step(step: int) -> void:
	_zoom_step = clampi(step, 0, ZOOM_STEPS.size() - 1)
	_apply_zoom()

func _apply_zoom() -> void:
	var z := float(ZOOM_STEPS[_zoom_step])
	cam.zoom = Vector2(z, z)

# --- HUD ---------------------------------------------------------------------

func _update_hud() -> void:
	var c := _mouse_cell()
	var line := "%d fps   sim %.1f ms   render %.1f ms   Chunks %d/%d   Bewegungen %d   Ansicht %dx%d, %dx skaliert, Zoom %dx%s" % [
		Engine.get_frames_per_second(), _sim_usec / 1000.0, _render_usec / 1000.0,
		sim.stat_awake_chunks, world.chunk_count, sim.stat_moved,
		VIEW_W, VIEW_H, _view_scale, ZOOM_STEPS[_zoom_step],
		"   [PAUSE]" if paused else "",
	]
	var line2 := "LMB malen   RMB radieren   MMB/WASD schieben   Mausrad Zoom   Leertaste Pause   N Schritt   H Waerme"
	if world.in_bounds(c.x, c.y):
		var i := world.idx(c.x, c.y)
		var d := MaterialDB.get_def(world.mat[i])
		var g := world.grav[i]
		line2 = "Zelle (%d, %d)   %s%s   %s   %.0f C   Gravitation %.2f" % [
			c.x, c.y, d.display_name,
			" [statisch]" if (world.flags[i] & SimWorld.F_STATIC) != 0 else "",
			_state_name(world.state[i]), world.temp[i], g.length(),
		]
	hud.text = line + "\n" + line2

func _state_name(s: int) -> String:
	match s:
		SimWorld.MoveState.FALLING:
			return "fallend"
		SimWorld.MoveState.SLIDING:
			return "rutschend"
		_:
			return "ruhend"

# --- Screenshot-Selbsttest ---------------------------------------------------

## Inhalt so gelegt, dass er in den 320x130-Ausschnitt um die Startkamera passt.
func _seed_shot_content() -> void:
	var cx := WORLD_W / 2
	var top := FLOOR_TOP - 40
	# Wasserbecken mit Steinwaenden, Lava darunter
	for y in range(top + 20, FLOOR_TOP):
		for x in range(cx - 90, cx - 86):
			world.set_cell(x, y, MaterialDB.STONE, true)
		for x in range(cx - 10, cx - 6):
			world.set_cell(x, y, MaterialDB.STONE, true)
	for y in range(top + 26, FLOOR_TOP):
		for x in range(cx - 86, cx - 10):
			world.set_cell(x, y, MaterialDB.WATER, false)
	for y in range(FLOOR_TOP - 12, FLOOR_TOP):
		for x in range(cx - 76, cx - 56):
			world.set_cell(x, y, MaterialDB.LAVA, false)
	for y in range(top + 30, top + 46):
		for x in range(cx - 36, cx - 16):
			world.set_cell(x, y, MaterialDB.ICE, true)
	# Sandhaufen
	for y in range(top - 10, top + 14):
		for x in range(cx + 6, cx + 40):
			world.set_cell(x, y, MaterialDB.SAND, false)
	# Sandbett mit Lava obenauf: die Lava muss aufliegen, nicht durchsinken.
	for y in range(FLOOR_TOP - 22, FLOOR_TOP):
		for x in range(cx + 130, cx + 250):
			world.set_cell(x, y, MaterialDB.SAND, false)
	for y in range(FLOOR_TOP - 34, FLOOR_TOP - 24):
		for x in range(cx + 160, cx + 215):
			world.set_cell(x, y, MaterialDB.LAVA, false)
	# Grav-Umkehrer mit Sandkuppel darueber
	for y in range(top + 40, top + 50):
		for x in range(cx + 84, cx + 96):
			world.set_cell(x, y, MaterialDB.G_INVERT, true)
	for y in range(top + 10, top + 32):
		for x in range(cx + 70, cx + 110):
			world.set_cell(x, y, MaterialDB.SAND, false)

# --- Regressionstest: bleibt fliessendes Material haengen? -------------------

## Deckt den Fehler ab, dass bei einer Bewegung innerhalb eines Chunks nur die
## Quelle ins Dirty-Rect eingetragen wurde. Weit springendes Material - Wasser
## streut bis zu `dispersion` Zellen - landete dann ausserhalb des simulierten
## Rechtecks und blieb stehen.
func _run_flow_test() -> void:
	print("=== Fliess-Regressionstest ===")
	world = SimWorld.new(WORLD_W, WORLD_H)
	sim = Simulation.new(world)
	_build_demo()

	var placed := 0
	for y in range(120, 170):
		for x in range(480, 540):
			world.set_cell(x, y, MaterialDB.WATER, false)
			placed += 1
	for y in range(200, 240):
		for x in range(300, 360):
			world.set_cell(x, y, MaterialDB.SAND, false)
			placed += 1

	for phase in range(1, 7):
		for f in range(400):
			sim.step()
		var floating := 0
		var total := 0
		for y in range(WORLD_H - 1):
			var row := y * WORLD_W
			for x in range(WORLD_W):
				var m := world.mat[row + x]
				if m != MaterialDB.WATER and m != MaterialDB.SAND:
					continue
				total += 1
				# Schwebend: direkt darunter ist Luft. In einer zur Ruhe
				# gekommenen Ansammlung darf es das nicht geben.
				if world.mat[row + WORLD_W + x] == 0:
					floating += 1
		print("  nach %4d Frames: Material %d/%d   schwebend %d   wache Chunks %d" % [
			phase * 400, total, placed, floating, sim.stat_awake_chunks])
	# Das eigentliche Kriterium: Material in der Luft, waehrend niemand mehr
	# simuliert wird. Genau das ist der Fehlerfall - haengengebliebene Zellen,
	# die nie wieder betrachtet werden.
	var stuck := 0
	for y in range(WORLD_H - 1):
		var row := y * WORLD_W
		for x in range(WORLD_W):
			var m := world.mat[row + x]
			if m != MaterialDB.WATER and m != MaterialDB.SAND:
				continue
			if world.mat[row + WORLD_W + x] == 0:
				stuck += 1
	if stuck > 0 and sim.stat_awake_chunks == 0:
		print("  FEHLGESCHLAGEN: %d Zellen haengen in der Luft, aber nichts wird mehr simuliert" % stuck)
	elif stuck > 0:
		print("  OK: %d Zellen noch in Bewegung, %d Chunks aktiv" % [stuck, sim.stat_awake_chunks])
	else:
		print("  OK: nichts haengt, Welt vollstaendig zur Ruhe gekommen")
	print("=== fertig ===")
	get_tree().quit()

# --- Spiegeltest: finden Fluessigkeiten den tiefsten Punkt? ---------------

## Kippt eine Saeule Material an EIN Ende einer breiten Wanne und misst danach
## das Hoehenprofil. Fluessigkeiten muessen einen flachen Spiegel bilden;
## Pulver darf und soll einen Kegel bilden - deshalb laeuft Sand als Gegenprobe
## mit.
func _run_level_test() -> void:
	print("=== Spiegeltest: sucht Material den tiefsten Punkt? ===")
	# Laufzeit je Fall unterschiedlich: Lava erstarrt unterwegs zu Stein, sie
	# muss also gemessen werden, solange sie noch fluessig ist.
	_level_case("Wasser (Fluessigkeit) - flacher Spiegel erwartet", MaterialDB.WATER, "spiegel", 3000)
	# Lava breitet sich aus, erstarrt dabei aber von vorne weg zu Stein. Ein
	# flacher Spiegel waere hier das FALSCHE Ziel - geprueft wird, dass sie
	# ueberhaupt wegfliesst statt an der Quelle liegen zu bleiben.
	_level_case("Lava (erstarrt unterwegs) - Wegfliessen erwartet", MaterialDB.LAVA, "ausbreitung", 1200)
	_level_case("Sand (Pulver) - Schuettkegel erwartet, KEIN Spiegel", MaterialDB.SAND, "kegel", 3000)
	_gas_case()
	get_tree().quit()

func _level_case(title: String, material_id: int, mode: String, frames_total: int) -> void:
	var left := 200
	var right := 500
	var floor_y := 400
	world = SimWorld.new(WORLD_W, WORLD_H)
	sim = Simulation.new(world)
	# Wanne: Boden und zwei Waende
	for x in range(left - 4, right + 4):
		for y in range(floor_y, floor_y + 6):
			world.set_cell(x, y, MaterialDB.STONE, true)
	for y in range(floor_y - 120, floor_y):
		for x in range(left - 4, left):
			world.set_cell(x, y, MaterialDB.STONE, true)
		for x in range(right, right + 4):
			world.set_cell(x, y, MaterialDB.STONE, true)
	# Saeule ganz am linken Ende
	var placed := 0
	for y in range(floor_y - 100, floor_y):
		for x in range(left, left + 40):
			world.set_cell(x, y, material_id, false)
			placed += 1

	for f in range(frames_total):
		sim.step()
	var frames := frames_total

	# Hoehenprofil ueber die Wanne
	var heights := PackedInt32Array()
	var filled_min := right
	var filled_max := left
	var total := 0
	for x in range(left, right):
		var h := 0
		for y in range(floor_y - 130, floor_y):
			if world.mat[y * WORLD_W + x] == material_id:
				h += 1
		heights.append(h)
		total += h
		if h > 0:
			filled_min = mini(filled_min, x)
			filled_max = maxi(filled_max, x)
	# Min/Max waere zu empfindlich - eine einzelne Spalte kippt das Urteil.
	# Gezaehlt wird deshalb, wie viele Spalten deutlich vom Mittel abweichen.
	var hmin := 9999
	var hmax := 0
	var cols := 0
	var sum := 0
	for k in range(heights.size()):
		var x := left + k
		if x < filled_min or x > filled_max:
			continue
		hmin = mini(hmin, heights[k])
		hmax = maxi(hmax, heights[k])
		sum += heights[k]
		cols += 1
	var mean := float(sum) / float(maxi(cols, 1))
	var outliers := 0
	for k in range(heights.size()):
		var x := left + k
		if x < filled_min or x > filled_max:
			continue
		if absf(float(heights[k]) - mean) > 3.0:
			outliers += 1
	var spread := hmax - hmin

	print("")
	print(title)
	print("  nach %d Frames: %d von %d Zellen erhalten" % [frames, total, placed])
	print("  belegt x %d..%d (%d Spalten von %d), Hoehe %d..%d, Mittel %.1f" % [
		filled_min, filled_max, filled_max - filled_min + 1, right - left,
		hmin, hmax, mean])
	print("  Spalten mit mehr als 3 Zellen Abweichung: %d von %d" % [outliers, cols])
	print("  wache Chunks: %d" % sim.stat_awake_chunks)
	var start_cols := 40
	match mode:
		"spiegel":
			var flat := outliers * 20 <= cols  # hoechstens 5 Prozent Ausreisser
			if flat and sim.stat_awake_chunks == 0:
				print("  OK: flacher Spiegel, zur Ruhe gekommen")
			elif flat:
				print("  OK: flacher Spiegel, noch %d Chunks in Bewegung" % sim.stat_awake_chunks)
			else:
				print("  FEHLGESCHLAGEN: %d Spalten weichen ab - Material bleibt aufgetuermt" % outliers)
		"ausbreitung":
			if cols >= start_cols * 3:
				print("  OK: von %d auf %d Spalten gelaufen, bevor es erstarrt" % [start_cols, cols])
			else:
				print("  FEHLGESCHLAGEN: nur %d Spalten - bleibt an der Quelle liegen" % cols)
		_:
			if spread > 10:
				print("  OK: Kegel erhalten (Pulver soll sich nicht einebnen)")
			else:
				print("  UNERWARTET: Pulver hat sich eingeebnet wie eine Fluessigkeit")

## Gase laufen durch denselben Ausweich-Code, nur entgegen der Gravitation.
## Statt eines Spiegels am Boden zaehlt hier die Breite unter der Decke: bleibt
## Dampf als Saeule stehen, belegt er nur wenige Spalten.
func _gas_case() -> void:
	var left := 200
	var right := 500
	var ceil_y := 300
	world = SimWorld.new(WORLD_W, WORLD_H)
	sim = Simulation.new(world)
	for x in range(left - 4, right + 4):
		for y in range(ceil_y - 6, ceil_y):
			world.set_cell(x, y, MaterialDB.STONE, true)
		for y in range(ceil_y + 120, ceil_y + 126):
			world.set_cell(x, y, MaterialDB.STONE, true)
	for y in range(ceil_y, ceil_y + 126):
		for x in range(left - 4, left):
			world.set_cell(x, y, MaterialDB.STONE, true)
		for x in range(right, right + 4):
			world.set_cell(x, y, MaterialDB.STONE, true)
	# Deutlich ueber der Kondensationsschwelle platzieren, sonst ist der Dampf
	# schon wieder Wasser, bevor er sich ausbreiten konnte.
	for y in range(ceil_y + 60, ceil_y + 120):
		for x in range(left, left + 30):
			world.set_cell(x, y, MaterialDB.STEAM, false, 600.0)

	for f in range(200):
		sim.step()

	var cols := 0
	for x in range(left, right):
		for y in range(ceil_y, ceil_y + 126):
			if world.mat[y * WORLD_W + x] == MaterialDB.STEAM:
				cols += 1
				break
	print("")
	print("Dampf (Gas) - Ausbreitung unter der Decke erwartet")
	print("  nach 200 Frames: %d von %d Spalten belegt (Start: 30)" % [cols, right - left])
	if cols > 60:
		print("  OK: breitet sich aus statt als Saeule stehen zu bleiben")
	else:
		print("  FEHLGESCHLAGEN: Dampf bleibt auf %d Spalten stehen" % cols)

# --- Verdraengungstest -------------------------------------------------------

## Prueft die zwei gemeldeten Beobachtungen: sinkt Lava durch Sand, und
## entstehen beim Lavafall Sandkoerner in der Luft? Dazu die Gegenprobe, dass
## Sand weiterhin durch Wasser sinkt - die Regel darf nicht zu scharf werden.
func _run_displace_test() -> void:
	print("=== Verdraengungstest ===")
	_case_lava_on_sand()
	_case_sand_in_water()
	_case_lava_falling_on_sand()
	_case_steam_bubble()
	get_tree().quit()

func _case_lava_on_sand() -> void:
	var floor_y := 400
	var sand_top := 380
	world = SimWorld.new(WORLD_W, WORLD_H)
	sim = Simulation.new(world)
	# Geschlossener Kasten - sonst laeuft Material seitlich weg und jede
	# Mengenbilanz waere wertlos.
	# Dicker Boden, damit ein etwaiges Anschmelzen den Kasten nicht sofort
	# leerlaufen laesst und die Messung im Sandbett sauber bleibt.
	for x in range(240, 380):
		for y in range(floor_y, floor_y + 24):
			world.set_cell(x, y, MaterialDB.STONE, true)
	for y in range(320, floor_y):
		for x in range(236, 240):
			world.set_cell(x, y, MaterialDB.STONE, true)
		for x in range(380, 384):
			world.set_cell(x, y, MaterialDB.STONE, true)
	var floor_before := 140 * 24
	var sand_before := 0
	for y in range(sand_top, floor_y):
		for x in range(240, 380):
			world.set_cell(x, y, MaterialDB.SAND, false)
			sand_before += 1
	var lava_before := 0
	for y in range(sand_top - 14, sand_top):
		for x in range(290, 330):
			world.set_cell(x, y, MaterialDB.LAVA, false)
			lava_before += 1

	for f in range(800):
		sim.step()

	# Echte Durchdringung: pro Spalte die oberste Sandzelle suchen und zaehlen,
	# ob DARUNTER Lava oder daraus erstarrter Stein liegt. Lava, die seitlich
	# am Bett vorbei nach unten gelaufen ist, zaehlt damit nicht mit.
	# Weder fluessige Lava noch erstarrter Stein duerfen unter der
	# Sandoberflaeche landen: Feststoffe werden nicht verdraengt, sie bleiben
	# aufeinander liegen.
	var deepest := 0
	var intruders := 0
	var sunk_stone := 0
	for x in range(240, 380):
		var top_sand := -1
		for y in range(sand_top - 20, floor_y):
			if world.mat[y * WORLD_W + x] == MaterialDB.SAND:
				top_sand = y
				break
		if top_sand < 0:
			continue
		for y in range(top_sand + 1, floor_y):
			var m := world.mat[y * WORLD_W + x]
			if m == MaterialDB.LAVA:
				intruders += 1
				deepest = maxi(deepest, y - top_sand)
			elif m == MaterialDB.STONE:
				sunk_stone += 1

	var sand_after := 0
	var lava_after := 0
	var stone_extra := 0
	for y in range(300, floor_y):
		for x in range(240, 380):
			var m := world.mat[y * WORLD_W + x]
			if m == MaterialDB.SAND:
				sand_after += 1
			elif m == MaterialDB.LAVA:
				lava_after += 1
			elif m == MaterialDB.STONE:
				stone_extra += 1

	# Statt Summen: die tatsaechlichen Materialsaeulen ansehen.
	print("")
	print("  Saeulenprofil (Lauflaengen von oben nach unten):")
	for probe_x in [250, 300, 320, 370]:
		var parts := PackedStringArray()
		var run_m := -1
		var run_n := 0
		for y in range(sand_top - 30, floor_y + 26):
			var mm := world.mat[y * WORLD_W + probe_x]
			if mm == run_m:
				run_n += 1
			else:
				if run_m >= 0 and run_n > 0:
					parts.append("%s%d" % [_short_name(run_m), run_n])
				run_m = mm
				run_n = 1
		if run_m >= 0 and run_n > 0:
			parts.append("%s%d" % [_short_name(run_m), run_n])
		print("    x=%d (ab y=%d): %s" % [probe_x, sand_top - 30, " ".join(parts)])
	var floor_now := 0
	for y in range(floor_y, floor_y + 24):
		for x in range(240, 380):
			if world.mat[y * WORLD_W + x] == MaterialDB.STONE:
				floor_now += 1
	print("  Boden: %d von %d Steinzellen noch da (geschmolzen: %d)" % [
		floor_now, floor_before, floor_before - floor_now])
	var wsand := 0
	for i in range(world.cell_count):
		if world.mat[i] == MaterialDB.SAND:
			wsand += 1
	print("  Sand weltweit: %d von %d (Erhaltung)" % [wsand, sand_before])
	print("Lava auf Sandbett - Lava soll oben aufliegen")
	print("  Fluessige Lava unter der Sandoberflaeche: %d (tiefste %d Zellen)" % [
		intruders, deepest])
	print("  Erstarrte Steinkoerner im Sand: %d (muss 0 sein - Feststoffe bleiben aufeinander)" % sunk_stone)
	print("  Bilanz: Sand %d von %d, Lava %d + erstarrter Stein %d von %d" % [
		sand_after, sand_before, lava_after, stone_extra, lava_before])
	if intruders == 0 and sunk_stone == 0:
		print("  OK: nichts sinkt in den Sand ein")
	elif intruders > 0:
		print("  FEHLGESCHLAGEN: Lava %d Zellen tief im Sandbett" % deepest)
	else:
		print("  FEHLGESCHLAGEN: %d Steinkoerner in den Sand eingesunken" % sunk_stone)

func _case_sand_in_water() -> void:
	var floor_y := 400
	world = SimWorld.new(WORLD_W, WORLD_H)
	sim = Simulation.new(world)
	for x in range(240, 380):
		for y in range(floor_y, floor_y + 6):
			world.set_cell(x, y, MaterialDB.STONE, true)
	for y in range(340, floor_y):
		for x in range(240, 380):
			world.set_cell(x, y, MaterialDB.STONE, true) if (x < 244 or x >= 376) else world.set_cell(x, y, MaterialDB.WATER, false)
	for y in range(300, 320):
		for x in range(295, 325):
			world.set_cell(x, y, MaterialDB.SAND, false)

	for f in range(800):
		sim.step()

	# Tiefster und hoechster Sand: der Sand muss unten liegen, das Wasser oben.
	var sand_min := 9999
	var sand_max := 0
	var water_min := 9999
	for y in range(280, floor_y):
		for x in range(244, 376):
			var m := world.mat[y * WORLD_W + x]
			if m == MaterialDB.SAND:
				sand_min = mini(sand_min, y)
				sand_max = maxi(sand_max, y)
			elif m == MaterialDB.WATER:
				water_min = mini(water_min, y)
	print("")
	print("Sand in Wasser - Sand soll absinken (Gegenprobe)")
	print("  Sand liegt bei y %d..%d, Wasseroberflaeche bei y %d" % [sand_min, sand_max, water_min])
	if sand_max >= floor_y - 4 and sand_min > water_min:
		print("  OK: Sand ist bis auf den Grund gesunken")
	else:
		print("  FEHLGESCHLAGEN: Sand sinkt nicht mehr durch Wasser")

func _case_lava_falling_on_sand() -> void:
	var floor_y := 400
	var pile_top := 370
	world = SimWorld.new(WORLD_W, WORLD_H)
	sim = Simulation.new(world)
	for x in range(240, 380):
		for y in range(floor_y, floor_y + 6):
			world.set_cell(x, y, MaterialDB.STONE, true)
	var sand_before := 0
	for y in range(pile_top, floor_y):
		for x in range(280, 340):
			world.set_cell(x, y, MaterialDB.SAND, false)
			sand_before += 1
	# Lava faellt aus deutlicher Hoehe darauf
	for y in range(300, 316):
		for x in range(300, 320):
			world.set_cell(x, y, MaterialDB.LAVA, false)

	var floating := 0
	var sand_after := 0
	for f in range(800):
		sim.step()
		# Waehrend des Falls pruefen: taucht Sand oberhalb des Haufens auf?
		# Nur Koerner, unter denen wirklich Luft ist - ein Korn, das von einem
		# absinkenden Steinbrocken um eine Zelle nach oben geschoben wurde,
		# liegt weiter auf etwas auf und ist kein Fehler.
		for y in range(280, pile_top - 2):
			var row := y * WORLD_W
			for x in range(240, 380):
				if world.mat[row + x] == MaterialDB.SAND and world.mat[row + WORLD_W + x] == 0:
					floating += 1
	for y in range(280, floor_y):
		for x in range(240, 380):
			if world.mat[y * WORLD_W + x] == MaterialDB.SAND:
				sand_after += 1
	print("")
	print("Lava faellt auf Sandhaufen - keine Koerner in der Luft erwartet")
	print("  Sand oberhalb des Haufens (ueber alle 800 Frames summiert): %d" % floating)
	print("  Sand: %d von %d erhalten" % [sand_after, sand_before])
	if floating == 0 and sand_after == sand_before:
		print("  OK: keine Koerner in der Luft, Sandmenge unveraendert")
	elif floating == 0:
		print("  FEHLGESCHLAGEN: Sandmenge veraendert (%d statt %d)" % [sand_after, sand_before])
	else:
		print("  FEHLGESCHLAGEN: %d Sandvorkommen ueber dem Haufen" % floating)

## Auftrieb: eine Dampfblase am Boden einer Wassersaeule muss aufsteigen.
## Sie darf dabei schwereres Wasser verdraengen - die Gegenrichtung zur
## normalen Regel, deshalb ein eigener Fall.
var _bubble_frames: int = 0

func _case_steam_bubble() -> void:
	_bubble_frames = 0
	var floor_y := 400
	var top := 300
	world = SimWorld.new(WORLD_W, WORLD_H)
	sim = Simulation.new(world)
	for x in range(280, 344):
		for y in range(floor_y, floor_y + 6):
			world.set_cell(x, y, MaterialDB.STONE, true)
	for y in range(top, floor_y):
		for x in range(276, 280):
			world.set_cell(x, y, MaterialDB.STONE, true)
		for x in range(344, 348):
			world.set_cell(x, y, MaterialDB.STONE, true)
	for y in range(top, floor_y):
		for x in range(280, 344):
			world.set_cell(x, y, MaterialDB.WATER, false)
	# Blase ganz unten, heiss genug um waehrend des Aufstiegs Dampf zu bleiben.
	var placed := 0
	for y in range(floor_y - 12, floor_y):
		for x in range(300, 324):
			world.set_cell(x, y, MaterialDB.STEAM, false, 900.0)
			placed += 1
	var start_mean := float(floor_y - 6)

	# Zwischenstaende: der Aufstieg muss gemessen werden, BEVOR die Blase im
	# kalten Wasser auskondensiert - genau das passiert in dieser Simulation
	# nach gut hundert Frames, und es ist richtig so.
	for checkpoint in [20, 40, 60]:
		while _bubble_frames < checkpoint:
			sim.step()
			_bubble_frames += 1
		var c := 0
		var sy := 0
		for y in range(top - 40, floor_y):
			var row := y * WORLD_W
			for x in range(280, 344):
				if world.mat[row + x] == MaterialDB.STEAM:
					c += 1
					sy += y
		var topmost := 9999
		for y in range(top - 40, floor_y):
			var row2 := y * WORLD_W
			var found := false
			for x in range(280, 344):
				if world.mat[row2 + x] == MaterialDB.STEAM:
					found = true
					break
			if found:
				topmost = y
				break
		print("  nach %3d Frames: %3d Dampfzellen, Mittel y %.1f, oberste y %d" % [
			checkpoint, c, float(sy) / float(maxi(c, 1)), topmost])

	var count := 0
	var sum_y := 0
	var trapped := 0
	for y in range(top - 40, floor_y):
		var row := y * WORLD_W
		for x in range(280, 344):
			if world.mat[row + x] != MaterialDB.STEAM:
				continue
			count += 1
			sum_y += y
			if world.mat[row - WORLD_W + x] == MaterialDB.WATER:
				trapped += 1
	var mean_y := float(sum_y) / float(maxi(count, 1))
	print("")
	print("Dampfblase unter Wasser - Aufstieg erwartet")
	print("  %d von %d Dampfzellen uebrig, mittlere Hoehe y %.1f (Start %.1f)" % [
		count, placed, mean_y, start_mean])
	print("  davon noch mit Wasser direkt darueber: %d" % trapped)
	if count == 0:
		print("  FEHLGESCHLAGEN: Dampf komplett kondensiert, Aufstieg nicht messbar")
	elif mean_y < start_mean - 30.0:
		print("  OK: Blase um %.0f Zellen aufgestiegen" % (start_mean - mean_y))
	else:
		print("  FEHLGESCHLAGEN: Blase haengt bei y %.1f fest" % mean_y)

# --- Eingabe-Selbsttest ------------------------------------------------------

func _run_input_test() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	print("=== Eingabe-Selbsttest ===")
	print("  Fenster %s, Ansicht %s, Faktor %dx" % [
		get_viewport().get_visible_rect().size, _view_rect, _view_scale])

	var probes := [
		_view_rect.position + _view_rect.size * Vector2(0.5, 0.12),
		_view_rect.position + _view_rect.size * Vector2(0.5, 0.5),
		_view_rect.position + _view_rect.size * Vector2(0.85, 0.9),
	]
	var ok_paint := 0
	for pos in probes:
		Input.warp_mouse(pos)
		await get_tree().process_frame
		var hovered := get_viewport().gui_get_hovered_control()
		var cell := _mouse_cell()
		# Weltweit zaehlen statt die Zielzelle zu pruefen: bei einem Pinsel von
		# genau einer Zelle faellt frisch gemalter Sand sofort weg, die Zelle
		# waere beim Nachsehen schon wieder leer.
		var before := _count(toolbar.selected_id)

		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = pos
		Input.parse_input_event(press)
		await get_tree().process_frame
		await get_tree().process_frame
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = pos
		Input.parse_input_event(release)
		await get_tree().process_frame

		var painted := _count(toolbar.selected_id) > before
		if painted:
			ok_paint += 1
		print("  Klick %s -> Zelle (%d,%d)   UI-Hover: %s   gemalt: %s" % [
			pos, cell.x, cell.y,
			"nein" if hovered == null else hovered.get_class(),
			"JA" if painted else "NEIN"])

	var cam_before := cam.position
	var mpress := InputEventMouseButton.new()
	mpress.button_index = MOUSE_BUTTON_MIDDLE
	mpress.pressed = true
	mpress.position = probes[1]
	Input.parse_input_event(mpress)
	await get_tree().process_frame
	for i in range(5):
		var motion := InputEventMouseMotion.new()
		motion.position = probes[1] + Vector2(i * 8, 0)
		motion.relative = Vector2(8, 4)
		Input.parse_input_event(motion)
		await get_tree().process_frame
	var mrelease := InputEventMouseButton.new()
	mrelease.button_index = MOUSE_BUTTON_MIDDLE
	mrelease.pressed = false
	mrelease.position = probes[1]
	Input.parse_input_event(mrelease)
	await get_tree().process_frame
	var moved := cam.position.distance_to(cam_before)
	print("  Kamera per MMB-Ziehen: Versatz %.1f Weltzellen   %s" % [
		moved, "OK" if moved > 1.0 else "FEHLGESCHLAGEN"])

	var cam2 := cam.position
	var key := InputEventKey.new()
	key.keycode = KEY_D
	key.pressed = true
	Input.parse_input_event(key)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var key_up := InputEventKey.new()
	key_up.keycode = KEY_D
	key_up.pressed = false
	Input.parse_input_event(key_up)
	var moved2 := cam.position.distance_to(cam2)
	print("  Kamera per Taste D: Versatz %.1f Weltzellen   %s" % [
		moved2, "OK" if moved2 > 0.3 else "FEHLGESCHLAGEN"])
	print("  Zeichnen erfolgreich an %d von %d Stellen" % [ok_paint, probes.size()])
	print("=== fertig ===")
	get_tree().quit()

# --- Selbsttest der Aggregatzustands-FSM -------------------------------------

func _run_fsm_test() -> void:
	print("=== FSM-Test: Temperaturgetriebene Aggregatzustaende ===")
	_fsm_case("Lava in Wasser -> Dampf + erstarrter Stein erwartet", MaterialDB.LAVA)
	_fsm_case("Eis in Wasser -> mehr Eis erwartet", MaterialDB.ICE)
	get_tree().quit()

func _fsm_case(title: String, source_id: int) -> void:
	world = SimWorld.new(WORLD_W, WORLD_H)
	sim = Simulation.new(world)
	for x in range(180, 260):
		for y in range(300, 306):
			world.set_cell(x, y, MaterialDB.STONE, true)
	for y in range(240, 306):
		for x in range(180, 186):
			world.set_cell(x, y, MaterialDB.STONE, true)
		for x in range(254, 260):
			world.set_cell(x, y, MaterialDB.STONE, true)
	for y in range(260, 300):
		for x in range(186, 254):
			world.set_cell(x, y, MaterialDB.WATER, false)
	var stone_before := _count(MaterialDB.STONE)
	for y in range(288, 296):
		for x in range(210, 230):
			world.set_cell(x, y, source_id, source_id == MaterialDB.ICE)

	print("")
	print(title)
	for step_i in range(1, 7):
		for f in range(100):
			sim.step()
		print("  nach %4d Frames: Wasser %5d  Dampf %4d  Eis %4d  Lava %4d  Stein(neu) %4d" % [
			step_i * 100,
			_count(MaterialDB.WATER), _count(MaterialDB.STEAM),
			_count(MaterialDB.ICE), _count(MaterialDB.LAVA),
			_count(MaterialDB.STONE) - stone_before])

func _count(material_id: int) -> int:
	var n := 0
	for i in range(world.cell_count):
		if world.mat[i] == material_id:
			n += 1
	return n

# --- Benchmark ---------------------------------------------------------------

## Drei Szenarien statt einem: der Stresstest allein waere irrefuehrend, weil er
## dauerhaft fast jede Zelle in Bewegung haelt - ein Zustand, den normale
## Interaktion nie erreicht.
func _run_benchmark() -> void:
	print("=== Sand Simulation Benchmark: %dx%d = %d Zellen ===" % [
		WORLD_W, WORLD_H, WORLD_W * WORLD_H])
	_bench_case("Ruhe (nur Boden, alles gesetzt)", 200, func() -> void:
		pass)
	_bench_case("Typisch (Pinselgroesse, Wasser + Lava + Gravitation)", 400, func() -> void:
		for y in range(240, 280):
			for x in range(300, 340):
				world.set_cell(x, y, MaterialDB.SAND, false)
		for y in range(440, 470):
			for x in range(180, 280):
				world.set_cell(x, y, MaterialDB.WATER, false)
		for y in range(465, 478):
			for x in range(360, 380):
				world.set_cell(x, y, MaterialDB.LAVA, false)
		for y in range(350, 362):
			for x in range(420, 432):
				world.set_cell(x, y, MaterialDB.G_INVERT, true))
	_bench_case("Stress (Grossblock Sand + Wasser in freiem Fall)", 300, func() -> void:
		for y in range(80, 180):
			for x in range(280, 430):
				world.set_cell(x, y, MaterialDB.SAND, false)
		for y in range(340, 420):
			for x in range(120, 300):
				world.set_cell(x, y, MaterialDB.WATER, false)
		for y in range(465, 475):
			for x in range(500, 520):
				world.set_cell(x, y, MaterialDB.LAVA, false)
		for y in range(250, 260):
			for x in range(520, 530):
				world.set_cell(x, y, MaterialDB.G_INVERT, true))
	print("=== fertig ===")
	get_tree().quit()

func _bench_case(title: String, frames: int, setup: Callable) -> void:
	world = SimWorld.new(WORLD_W, WORLD_H)
	sim = Simulation.new(world)
	_build_demo()
	setup.call()

	var total := 0
	var worst := 0
	var samples := PackedInt32Array()
	var t_grav := 0
	var t_therm := 0
	var t_trans := 0
	var t_move := 0
	for f in range(frames):
		var t0 := Time.get_ticks_usec()
		sim.step()
		var dt := Time.get_ticks_usec() - t0
		total += dt
		worst = maxi(worst, dt)
		samples.append(dt)
		t_grav += sim.stat_grav_usec
		t_therm += sim.stat_thermal_usec
		t_trans += sim.stat_trans_usec
		t_move += sim.stat_move_usec
	var sorted_us := Array(samples)
	sorted_us.sort()
	var median: int = sorted_us[sorted_us.size() / 2]
	var p95: int = sorted_us[int(sorted_us.size() * 0.95)]
	var avg := float(total) / float(frames)
	print("")
	print("%s  (%d Frames)" % [title, frames])
	print("  Mittel  %6.2f ms  (%5.1f fps)" % [avg / 1000.0, 1000000.0 / maxf(avg, 1.0)])
	print("  Median  %6.2f ms  (%5.1f fps)" % [median / 1000.0, 1000000.0 / maxf(float(median), 1.0)])
	print("  p95     %6.2f ms   Maximum %6.2f ms" % [p95 / 1000.0, worst / 1000.0])
	print("  davon im Mittel: Gravitation %.2f  Waerme %.2f  Zustands-FSM %.2f  Bewegung %.2f ms" % [
		t_grav / 1000.0 / frames, t_therm / 1000.0 / frames,
		t_trans / 1000.0 / frames, t_move / 1000.0 / frames])
	print("  letzter Frame: wache Chunks %d/%d, Bewegungen %d" % [
		sim.stat_awake_chunks, world.chunk_count, sim.stat_moved])

func _short_name(m: int) -> String:
	match m:
		MaterialDB.EMPTY: return "leer:"
		MaterialDB.SAND: return "SAND:"
		MaterialDB.WATER: return "wasser:"
		MaterialDB.STONE: return "stein:"
		MaterialDB.LAVA: return "LAVA:"
		MaterialDB.ICE: return "eis:"
		MaterialDB.STEAM: return "dampf:"
		_: return "m%d:" % m
