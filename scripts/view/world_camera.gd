class_name WorldCamera
extends Camera2D

## Die Kamera im Spiel-SubViewport: schwenken per Tastatur und mittlerer
## Maustaste, zoomen per Mausrad.
##
## Die Zoomstufen sind bewusst ganzzahlig - alles andere liesse die Pixel
## flimmern, weil ein Weltpixel dann ungleich viele Bildschirmpixel bedeckt.

@export_group("Verdrahtung")

## Liefert die Weltgroesse fuer die Kameragrenzen. Im Editor zuweisen.
@export var simulation: SandSimulation

@export_group("Bewegung")

## Zellen pro Sekunde beim Schwenken mit der Tastatur.
@export var pan_speed := 90.0

## Erlaubte Vergroesserungen, aufsteigend.
@export var zoom_steps: Array[int] = [1, 2, 3, 4, 6, 8]

## Startposition der Kamera in Weltzellen, relativ zur Weltmitte oben.
@export var start_offset := Vector2(0.0, 440.0)

var _zoom_index: int = 0


func _ready() -> void:
	simulation.ensure_world()
	var world_size := simulation.grid
	limit_left = 0
	limit_top = 0
	limit_right = world_size.width
	limit_bottom = world_size.height
	position = Vector2(world_size.width * 0.5 + start_offset.x, start_offset.y)
	make_current()
	_apply_zoom()


## Linke obere Ecke des sichtbaren Weltausschnitts. Bei Zoom groesser 1 ist der
## tatsaechlich sichtbare Bereich kleiner als die Ansicht; das Fenster deckt ihn
## dann mit Reserve ab.
func view_origin(view_size: Vector2i) -> Vector2i:
	var centre := get_screen_center_position()
	return Vector2i(
		floori(centre.x - view_size.x * 0.5),
		floori(centre.y - view_size.y * 0.5))


## Schwenkt um einen Fensterversatz, etwa beim Ziehen mit der Maus.
## [param view_scale] ist der Vergroesserungsfaktor der Ansicht - ohne ihn
## schwenkt die Kamera um ein Vielfaches zu weit.
func pan_by_screen_delta(screen_delta: Vector2, view_scale: int) -> void:
	position -= screen_delta / (float(view_scale) * zoom.x)


## Schwenkt mit konstanter Geschwindigkeit, unabhaengig vom Zoom.
func pan_by_direction(direction: Vector2, delta: float) -> void:
	if direction == Vector2.ZERO:
		return
	position += direction.normalized() * pan_speed * delta / zoom.x


func zoom_in() -> void:
	_set_zoom_index(_zoom_index + 1)


func zoom_out() -> void:
	_set_zoom_index(_zoom_index - 1)


func current_zoom() -> int:
	return zoom_steps[_zoom_index]


func _set_zoom_index(index: int) -> void:
	_zoom_index = clampi(index, 0, zoom_steps.size() - 1)
	_apply_zoom()


func _apply_zoom() -> void:
	var factor := float(zoom_steps[_zoom_index])
	zoom = Vector2(factor, factor)
