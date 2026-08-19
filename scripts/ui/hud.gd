class_name Hud
extends Label

## Zwei Zeilen unten links: Leistungsdaten und die Zelle unter der Maus.
##
## Der HUD holt sich alles selbst von den Knoten, an die er im Editor gehaengt
## wird - er wird nicht von aussen gefuettert.

@export_group("Verdrahtung")

@export var simulation: SandSimulation
@export var renderer: WorldRenderer
@export var world_view: WorldView
@export var camera: WorldCamera

@export_group("Text")

## Zweite Zeile, solange die Maus nicht ueber der Spielflaeche ist.
@export_multiline var controls_hint := "LMB malen   RMB radieren   MMB/WASD schieben   Mausrad Zoom   Leertaste Pause   N Schritt   H Waerme"

## Wird von [Main] gesetzt.
var paused: bool = false


func _process(_delta: float) -> void:
	text = "%s\n%s" % [_status_line(), _cell_line()]


func _status_line() -> String:
	var view_size := renderer.view_size()
	return "%d fps   sim %.1f ms   render %.1f ms   Chunks %d/%d   Bewegungen %d   Ansicht %dx%d, %dx skaliert, Zoom %dx%s" % [
		Engine.get_frames_per_second(),
		simulation.last_step_usec / 1000.0,
		renderer.last_draw_usec / 1000.0,
		simulation.stat_awake_chunks, simulation.grid.chunk_count,
		simulation.stat_moved,
		view_size.x, view_size.y, world_view.scale_factor, camera.current_zoom(),
		"   [PAUSE]" if paused else "",
	]


func _cell_line() -> String:
	var cell := world_view.screen_to_cell(get_viewport().get_mouse_position())
	var grid := simulation.grid
	if not grid.in_bounds(cell.x, cell.y):
		return controls_hint

	var index := grid.index_of(cell.x, cell.y)
	var material := simulation.registry.get_material(grid.material_id[index])
	var is_static := (grid.cell_flags[index] & CellGrid.FLAG_STATIC) != 0
	return "Zelle (%d, %d)   %s%s   %s   %.0f C   Gravitation %.2f" % [
		cell.x, cell.y, material.display_name,
		" [statisch]" if is_static else "",
		_state_name(grid.move_state[index]),
		grid.celsius[index],
		grid.gravity[index].length(),
	]


func _state_name(state: int) -> String:
	match state:
		CellGrid.MoveState.FALLING:
			return "fallend"
		CellGrid.MoveState.SLIDING:
			return "rutschend"
		_:
			return "ruhend"
