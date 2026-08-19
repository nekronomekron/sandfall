class_name PaintTool
extends Node

## Zeichnen und Radieren mit der Maus.
##
## Beim Ziehen wird zwischen den Mauspositionen interpoliert. Bei einem Pinsel
## von genau einer Zelle ist das der einzige Grund, warum schnelles Ziehen keine
## Luecken hinterlaesst.

## Kein gueltiger letzter Punkt - der naechste Strich faengt neu an.
const NO_LAST_POINT := Vector2i(-99999, -99999)

@export_group("Verdrahtung")

## Wohin gezeichnet wird. Im Editor zuweisen.
@export var simulation: SandSimulation

## Woher Mausposition und Zellumrechnung kommen. Im Editor zuweisen.
@export var world_view: WorldView

## Liefert das gewaehlte Material und das Static-Flag. Im Editor zuweisen.
@export var toolbar: Toolbar

@export_group("Pinsel")

## Radius in Zellen. 0 ergibt einen Pinsel von genau einer Zelle.
@export_range(0, 16) var brush_radius := 0

var _last_point := NO_LAST_POINT


func _process(_delta: float) -> void:
	if _is_mouse_over_ui():
		_last_point = NO_LAST_POINT
		return

	var erasing := Input.is_action_pressed(&"erase")
	var drawing := Input.is_action_pressed(&"paint")
	if not drawing and not erasing:
		_last_point = NO_LAST_POINT
		return

	var cell := world_view.screen_to_cell(get_viewport().get_mouse_position())
	if WorldView.is_outside(cell):
		_last_point = NO_LAST_POINT
		return

	var material := MaterialLibrary.EMPTY_ID if erasing else toolbar.selected_id
	var make_static := false if erasing else toolbar.place_static
	if _last_point == NO_LAST_POINT:
		paint_dab(cell, material, make_static)
	else:
		paint_line(_last_point, cell, material, make_static)
	_last_point = cell


## Zieht einen Strich zwischen zwei Zellen.
func paint_line(from: Vector2i, to: Vector2i, material: int, make_static: bool) -> void:
	var span := to - from
	var steps := maxi(absi(span.x), absi(span.y))
	if steps == 0:
		paint_dab(to, material, make_static)
		return
	for step in range(steps + 1):
		var point := Vector2(from) + Vector2(span) * (float(step) / float(steps))
		paint_dab(Vector2i(roundi(point.x), roundi(point.y)), material, make_static)


## Setzt einen runden Klecks um eine Zelle.
func paint_dab(centre: Vector2i, material: int, make_static: bool) -> void:
	var grid := simulation.grid
	if brush_radius <= 0:
		grid.set_cell(centre.x, centre.y, material, make_static)
		return
	var radius_squared := brush_radius * brush_radius
	for offset_y in range(-brush_radius, brush_radius + 1):
		for offset_x in range(-brush_radius, brush_radius + 1):
			if offset_x * offset_x + offset_y * offset_y > radius_squared:
				continue
			grid.set_cell(centre.x + offset_x, centre.y + offset_y, material, make_static)


func _is_mouse_over_ui() -> bool:
	return get_viewport().gui_get_hovered_control() != null
