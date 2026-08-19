class_name ScreenshotTest
extends Node

## `-- --shot [--frames=N]`: setzt eine Demo-Szene, laesst sie N Frames laufen
## und schreibt danach einen Screenshot.
##
## Der Inhalt ist so gelegt, dass er in den sichtbaren Ausschnitt um die
## Startkamera passt.

@export var frames_to_capture := 90

var _main: Main
var _frames_seen := 0


func _init(main: Main, frames := 90) -> void:
	_main = main
	frames_to_capture = frames


func _ready() -> void:
	_main.simulation.ensure_world()
	_seed_content()


func _process(_delta: float) -> void:
	_frames_seen += 1
	if _frames_seen < frames_to_capture:
		return
	set_process(false)
	_capture.call_deferred()


func _capture() -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "res://selbsttest_%d.png" % frames_to_capture
	image.save_png(path)
	print("Screenshot geschrieben: %s" % path)
	get_tree().quit()


func _seed_content() -> void:
	var grid := _main.simulation.grid
	var registry := _main.simulation.registry
	var stone := registry.require_id(&"stone")
	var water := registry.require_id(&"water")
	var lava := registry.require_id(&"lava")
	var ice := registry.require_id(&"ice")
	var sand := registry.require_id(&"sand")
	var inverter := registry.require_id(&"gravity_inverter")

	var centre_x := grid.width / 2
	var floor_top := _main.demo_world.floor_top
	var top := floor_top - 40

	# Wasserbecken mit Steinwaenden, Lava darunter.
	_fill(grid, Rect2i(centre_x - 90, top + 20, 4, floor_top - top - 20), stone, true)
	_fill(grid, Rect2i(centre_x - 10, top + 20, 4, floor_top - top - 20), stone, true)
	_fill(grid, Rect2i(centre_x - 86, top + 26, 76, floor_top - top - 26), water)
	_fill(grid, Rect2i(centre_x - 76, floor_top - 12, 20, 12), lava)
	_fill(grid, Rect2i(centre_x - 36, top + 30, 20, 16), ice, true)

	# Sandhaufen.
	_fill(grid, Rect2i(centre_x + 6, top - 10, 34, 24), sand)

	# Sandbett mit Lava obenauf: die Lava muss aufliegen, nicht durchsinken.
	_fill(grid, Rect2i(centre_x + 130, floor_top - 22, 120, 22), sand)
	_fill(grid, Rect2i(centre_x + 160, floor_top - 34, 55, 10), lava)

	# Grav-Umkehrer mit Sandkuppel darueber.
	_fill(grid, Rect2i(centre_x + 84, top + 40, 12, 10), inverter, true)
	_fill(grid, Rect2i(centre_x + 70, top + 10, 40, 22), sand)


func _fill(grid: CellGrid, rect: Rect2i, material: int, make_static := false) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			grid.set_cell(x, y, material, make_static)
