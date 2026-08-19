class_name DemoWorld
extends Node

## Baut den Startinhalt der Welt auf: den Steinboden und das Gravitationsfeld.
##
## Der Boden ist eine Linie aus Stein mit gesetztem Static-Flag. Darauf wirkt
## keine Schwerkraft, unabhaengig vom oertlichen Feld. Das Flag sitzt bewusst
## pro Zelle und nicht pro Material - derselbe Stein kann unverrueckbarer Boden
## oder fallendes Geroell sein.
##
## Das Gravitationsfeld ist statisch. Die Grundschwerkraft steht an
## [member SandSimulation.base_gravity]; abweichende Bereiche kommen als
## [GravityZone] aus [member gravity_zones] und werden hier einmal beim Aufbau
## eingetragen.

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

@export_group("Gravitation")

## Bereiche mit abweichender Schwerkraft. Spaetere Eintraege ueberschreiben
## fruehere dort, wo sie sich ueberlappen.
@export var gravity_zones: Array[GravityZone] = []


func _ready() -> void:
	simulation.ensure_world()
	build()


## Legt den Startinhalt an. Erwartet eine leere Welt.
func build() -> void:
	apply_gravity_zones()
	build_ground()


## Traegt die Zonen in das Gravitationsfeld ein. Muss vor dem Material laufen:
## `set_gravity_area` weckt den Bereich auf, damit ruhende Zellen ihre Lage
## unter dem neuen Feld neu bewerten.
func apply_gravity_zones() -> void:
	var grid := simulation.grid
	for zone in gravity_zones:
		if zone == null:
			continue
		grid.set_gravity_area(zone.area, zone.gravity)


func build_ground() -> void:
	if not build_floor:
		return
	var grid := simulation.grid
	var material := simulation.registry.require_id(floor_material)
	var bottom := mini(floor_top + floor_thickness, grid.height)
	for y in range(floor_top, bottom):
		for x in grid.width:
			grid.set_cell(x, y, material, true)
