class_name InputTest
extends Node

## `-- --inputtest`: Selbsttest fuer Zeichnen und Kameraschwenk.
##
## Braucht ein echtes Fenster, laeuft also nicht headless: geprueft wird genau
## der Weg von der Fensterkoordinate ueber die hochskalierte Ansicht und die
## Kamera bis zur Weltzelle.

## Relative Punkte in der Spielansicht, an denen gemalt wird.
const PROBES: Array[Vector2] = [
	Vector2(0.5, 0.12),
	Vector2(0.5, 0.5),
	Vector2(0.85, 0.9),
]

## Ab so viel Versatz gilt ein Schwenk als erfolgreich.
const MIN_DRAG_DISTANCE := 1.0
const MIN_KEY_DISTANCE := 0.3

const DRAG_STEPS := 5
const DRAG_DELTA := Vector2(8, 4)

var _main: Main


func _init(main: Main) -> void:
	_main = main


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var view := _main.world_view
	print("=== Eingabe-Selbsttest ===")
	print("  Root-Viewport %s, Fenster %s" % [
		get_viewport().get_visible_rect().size,
		DisplayServer.window_get_size()])
	print("  Spielansicht %s, Faktor %dx" % [view.screen_rect, view.scale_factor])
	print("  Toolbar belegt %s" % _main.toolbar.get_global_rect())

	var painted_ok := 0
	for probe in PROBES:
		var position := view.screen_rect.position + view.screen_rect.size * probe
		if await _paint_at(position):
			painted_ok += 1

	await _check_mouse_pan()
	await _check_keyboard_pan()
	print("  Zeichnen erfolgreich an %d von %d Stellen" % [painted_ok, PROBES.size()])
	print("=== fertig ===")
	get_tree().quit()


func _paint_at(position: Vector2) -> bool:
	_warp_to(position)
	await get_tree().process_frame
	var landed := get_viewport().get_mouse_position()
	var hovered := get_viewport().gui_get_hovered_control()
	var cell := _main.world_view.screen_to_cell(position)
	# Weltweit zaehlen statt die Zielzelle zu pruefen: bei einem Pinsel von
	# genau einer Zelle faellt frisch gemalter Sand sofort weg, die Zelle waere
	# beim Nachsehen schon wieder leer.
	var before := _count(_main.toolbar.selected_id)

	_send_mouse_button(MOUSE_BUTTON_LEFT, true, position)
	await get_tree().process_frame
	await get_tree().process_frame
	_send_mouse_button(MOUSE_BUTTON_LEFT, false, position)
	await get_tree().process_frame

	var painted := _count(_main.toolbar.selected_id) > before
	print("  Klick %s (Zeiger bei %s) -> Zelle (%d,%d)   UI-Hover: %s   gemalt: %s" % [
		position, landed, cell.x, cell.y,
		"nein" if hovered == null else hovered.get_class(),
		"JA" if painted else "NEIN"])
	return painted


func _check_mouse_pan() -> void:
	var view := _main.world_view
	var centre := view.screen_rect.position + view.screen_rect.size * PROBES[1]
	var before := _main.camera.position

	_warp_to(centre)
	await get_tree().process_frame
	_send_mouse_button(MOUSE_BUTTON_MIDDLE, true, centre)
	await get_tree().process_frame
	for step in DRAG_STEPS:
		var motion := InputEventMouseMotion.new()
		motion.position = _to_window(centre + Vector2(step * DRAG_DELTA.x, 0))
		motion.relative = DRAG_DELTA
		Input.parse_input_event(motion)
		await get_tree().process_frame
	_send_mouse_button(MOUSE_BUTTON_MIDDLE, false, centre)
	await get_tree().process_frame

	var moved := _main.camera.position.distance_to(before)
	print("  Kamera per MMB-Ziehen: Versatz %.1f Weltzellen   %s" % [
		moved, "OK" if moved > MIN_DRAG_DISTANCE else "FEHLGESCHLAGEN"])


func _check_keyboard_pan() -> void:
	var before := _main.camera.position
	var press := InputEventKey.new()
	press.keycode = KEY_D
	press.pressed = true
	Input.parse_input_event(press)
	for frame in 3:
		await get_tree().process_frame
	var release := InputEventKey.new()
	release.keycode = KEY_D
	release.pressed = false
	Input.parse_input_event(release)

	var moved := _main.camera.position.distance_to(before)
	print("  Kamera per Taste D: Versatz %.1f Weltzellen   %s" % [
		moved, "OK" if moved > MIN_KEY_DISTANCE else "FEHLGESCHLAGEN"])


## Alles, was ueber [Input] eingespeist wird - Warp wie synthetische Events -
## rechnet in FENSTERkoordinaten. Mit dem Stretch-Modus "viewport" ist der
## Root-Viewport kleiner als das Fenster; ohne diese Umrechnung landet ein
## Klick um den Skalierungsfaktor daneben, hier also mitten in der Toolbar
## statt auf der Spielflaeche.
## Alles, was ueber [Input] eingespeist wird - Warp wie synthetische Events -
## rechnet in FENSTERkoordinaten. Mit dem Stretch-Modus "viewport" ist der
## Root-Viewport kleiner als das Fenster; ohne diese Umrechnung landet ein
## Klick um den Skalierungsfaktor daneben, hier also mitten in der Toolbar
## statt auf der Spielflaeche.
## Diagnose: welche Controls koennen die Maus abfangen und wie gross sind sie?
func _dump_controls(node: Node, depth: int) -> void:
	if node is Control:
		var control := node as Control
		if control.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			print("    %s%s (%s) rect=%s filter=%d" % [
				"  ".repeat(depth), control.name, control.get_class(),
				control.get_global_rect(), control.mouse_filter])
	for child in node.get_children():
		_dump_controls(child, depth + 1)


func _to_window(view_position: Vector2) -> Vector2:
	return get_viewport().get_screen_transform() * view_position


func _warp_to(view_position: Vector2) -> void:
	Input.warp_mouse(_to_window(view_position))


func _send_mouse_button(button: int, pressed: bool, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = _to_window(position)
	Input.parse_input_event(event)


func _count(material: int) -> int:
	var grid := _main.simulation.grid
	var found := 0
	for cell in grid.cell_count:
		if grid.material_id[cell] == material:
			found += 1
	return found
