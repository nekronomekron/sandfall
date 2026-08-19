class_name Main
extends Node2D

## Der Spielbildschirm. Alle Bausteine sind Knoten in main.tscn und im Editor
## miteinander verdrahtet; dieses Skript treibt nur die Schleife an und
## verarbeitet die Tastenkuerzel.
##
## Startparameter (jeweils nach `--`) landen bei [SelfTests]:
## [br]  --bench --fsmtest --flowtest --leveltest --displacetest --inputtest
## [br]  --shot [--frames=N]

@export_group("Verdrahtung")

@export var simulation: SandSimulation
@export var renderer: WorldRenderer
@export var world_view: WorldView
@export var camera: WorldCamera
@export var demo_world: DemoWorld
@export var toolbar: Toolbar
@export var hud: Hud
@export var paint_tool: PaintTool

var paused: bool = false

var _step_once: bool = false
var _panning: bool = false


func _ready() -> void:
	# Ein Selbsttest darf die Schleife uebernehmen, bevor der Renderer seine
	# Puffer anlegt - headless braucht niemand ein Bild.
	if SelfTests.take_over(self):
		return
	toolbar.reset_pressed.connect(reset_world)
	renderer.attach(simulation)


## Setzt die Welt auf den Startzustand zurueck.
func reset_world() -> void:
	simulation.reset()
	demo_world.build()
	renderer.redraw_all()


## Haelt die Simulation an oder laesst sie weiterlaufen.
func set_paused(value: bool) -> void:
	paused = value
	hud.paused = value


## Genau einen Schritt rechnen, auch wenn pausiert ist.
func step_once() -> void:
	_step_once = true


func _process(delta: float) -> void:
	_handle_keyboard_pan(delta)

	if not paused or _step_once:
		simulation.step()
		_step_once = false

	renderer.redraw(camera.view_origin(renderer.view_size()))


func _handle_keyboard_pan(delta: float) -> void:
	var direction := Input.get_vector(&"pan_left", &"pan_right", &"pan_up", &"pan_down")
	camera.pan_by_direction(direction, delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion and _panning:
		var motion := event as InputEventMouseMotion
		camera.pan_by_screen_delta(motion.relative, world_view.scale_factor)
	elif event.is_action_pressed(&"pause"):
		set_paused(not paused)
	elif event.is_action_pressed(&"step"):
		step_once()
	elif event.is_action_pressed(&"reset"):
		reset_world()
	elif event.is_action_pressed(&"toggle_heat"):
		renderer.show_heat = not renderer.show_heat


func _handle_mouse_button(button: InputEvent) -> void:
	if button.is_action(&"pan_drag"):
		_panning = button.is_pressed()
	elif button.is_action_pressed(&"zoom_in"):
		camera.zoom_in()
	elif button.is_action_pressed(&"zoom_out"):
		camera.zoom_out()
