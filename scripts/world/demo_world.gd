class_name DemoWorld
extends Node

## Baut den Startinhalt der Welt auf: bisher nur ein Steinboden.
##
## Der Boden ist eine Linie aus Stein mit gesetztem Static-Flag. Darauf wirkt
## keine Schwerkraft, unabhaengig vom oertlichen Gravitationsfeld. Das Flag
## sitzt bewusst pro Zelle und nicht pro Material - derselbe Stein kann
## unverrueckbarer Boden oder fallendes Geroell sein.

@export_group("Verdrahtung")

## Welche Welt aufgebaut wird. Im Editor zuweisen.
@export var simulation: SandSimulation

@export_group("Boden")

@export var build_floor := true

## Material des Bodens, ueber seinen [member SandMaterial.material_name].
@export var floor_material := &"stone"

## Oberkante des Bodens in Zellen.
@export var floor_top := 480

@export var floor_thickness := 12


func _ready() -> void:
	simulation.ensure_world()
	build()


## Legt den Startinhalt an. Erwartet eine leere Welt.
func build() -> void:
	if not build_floor:
		return
	var grid := simulation.grid
	var material := simulation.registry.require_id(floor_material)
	var bottom := mini(floor_top + floor_thickness, grid.height)
	for y in range(floor_top, bottom):
		for x in grid.width:
			grid.set_cell(x, y, material, true)
