class_name TestSupport
extends RefCounted

## Gemeinsame Bausteine der Selbsttests: eine Simulation ohne Szene aufbauen,
## Kaesten mauern, Zellen zaehlen.
##
## Die Selbsttests laufen bewusst auf einer EIGENEN Simulation statt auf der
## des Spielbildschirms. So kann jeder Fall mit einer frisch geleerten Welt
## anfangen, ohne den Demo-Boden mitzuschleppen.

const DEFAULT_WORLD_SIZE := Vector2i(1024, 576)
const LIBRARY_PATH := "res://resources/material_library.tres"

var simulation: SandSimulation
var registry: MaterialRegistry
var grid: CellGrid

# Haeufig gebrauchte Material-ids, damit die Testfaelle lesbar bleiben.
var air: int
var sand: int
var water: int
var stone: int
var ice: int
var steam: int
var lava: int
var gravity_inverter: int


## Baut eine frische Simulation unter [param host] auf. [param host] muss im
## Szenenbaum haengen, damit die Knoten ihr _ready bekommen.
func _init(host: Node, world_size := DEFAULT_WORLD_SIZE) -> void:
	registry = MaterialRegistry.new()
	registry.name = "TestMaterialRegistry"
	registry.library = load(LIBRARY_PATH)
	registry.build()

	var gravity_field := GravityField.new()
	gravity_field.name = "GravityField"

	simulation = SandSimulation.new()
	simulation.name = "TestSimulation"
	simulation.registry = registry
	simulation.gravity_field = gravity_field
	simulation.world_size = world_size
	simulation.add_child(gravity_field)

	host.add_child(registry)
	host.add_child(simulation)
	simulation.ensure_world()
	grid = simulation.grid

	air = MaterialLibrary.EMPTY_ID
	sand = registry.require_id(&"sand")
	water = registry.require_id(&"water")
	stone = registry.require_id(&"stone")
	ice = registry.require_id(&"ice")
	steam = registry.require_id(&"steam")
	lava = registry.require_id(&"lava")
	gravity_inverter = registry.require_id(&"gravity_inverter")


## Leert die Welt fuer den naechsten Fall.
func reset() -> void:
	simulation.reset()


func step(frames: int) -> void:
	for frame in frames:
		simulation.step()


## Fuellt ein Rechteck einschliesslich beider Ecken und liefert die Zahl der
## gesetzten Zellen.
func fill(rect: Rect2i, material: int, make_static := false,
		temperature := CellGrid.USE_MATERIAL_TEMPERATURE) -> int:
	var placed := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			grid.set_cell(x, y, material, make_static, temperature)
			placed += 1
	return placed


## Mauert Boden und zwei Seitenwaende um einen Bereich. Ohne einen
## geschlossenen Kasten laeuft Material seitlich weg und jede Mengenbilanz
## waere wertlos.
func build_box(interior: Rect2i, wall: int, wall_thickness := 4) -> void:
	fill(Rect2i(interior.position.x - wall_thickness, interior.end.y,
		interior.size.x + 2 * wall_thickness, wall_thickness), wall, true)
	fill(Rect2i(interior.position.x - wall_thickness, interior.position.y,
		wall_thickness, interior.size.y), wall, true)
	fill(Rect2i(interior.end.x, interior.position.y,
		wall_thickness, interior.size.y), wall, true)


## Zaehlt alle Zellen eines Materials in der ganzen Welt.
func count(material: int) -> int:
	var found := 0
	for cell in grid.cell_count:
		if grid.material_id[cell] == material:
			found += 1
	return found


## Zaehlt alle Zellen eines Materials in einem Rechteck.
func count_in(rect: Rect2i, material: int) -> int:
	var found := 0
	for y in range(rect.position.y, rect.end.y):
		var row := y * grid.width
		for x in range(rect.position.x, rect.end.x):
			if grid.material_id[row + x] == material:
				found += 1
	return found


func material_at(x: int, y: int) -> int:
	return grid.material_id[y * grid.width + x]


## Lauflaengen einer Materialsaeule von oben nach unten, z.B.
## "LAVA:4 stein:1 SAND:20". Saeulenprofile statt Summen: Summen ueber
## Rechtecke haben hier mehrfach Fehlalarm ausgeloest, weil sie Material
## mitzaehlten, das seitlich am Messfenster vorbeigelaufen war.
func column_profile(x: int, from_y: int, to_y: int) -> String:
	var parts := PackedStringArray()
	var run_material := -1
	var run_length := 0
	for y in range(from_y, to_y):
		var material := material_at(x, y)
		if material == run_material:
			run_length += 1
			continue
		if run_material >= 0 and run_length > 0:
			parts.append("%s:%d" % [registry.get_material(run_material).display_name, run_length])
		run_material = material
		run_length = 1
	if run_material >= 0 and run_length > 0:
		parts.append("%s:%d" % [registry.get_material(run_material).display_name, run_length])
	return " ".join(parts)


static func heading(title: String) -> void:
	print("")
	print(title)


static func verdict(passed: bool, ok_text: String, failure_text: String) -> void:
	print("  %s: %s" % ["OK" if passed else "FEHLGESCHLAGEN",
		ok_text if passed else failure_text])
