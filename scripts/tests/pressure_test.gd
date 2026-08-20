class_name PressureTest
extends RefCounted

## `-- --pressuretest`: wird Holz unter Last zu Kohle und Kohle zu Diamant?
##
## Vier Saeulen nebeneinander, alle im selben Chunk-Streifen, damit ein
## Durchlauf des [PressurePass] kurz bleibt. Sie unterscheiden sich nur in der
## Last darueber:
## [br]- WENIG: unter der Schwelle von Holz, es bleibt Holz.
## [br]- MITTEL: ueber Holz, unter Kohle - Holz wird Kohle und bleibt es.
## [br]- VIEL: ueber beiden Schwellen - die Kette laeuft bis zum Diamanten durch.
## [br]- LUECKE: viel Last, aber eine Luftschicht dazwischen. Eine Hoehlendecke
##   traegt, was ueber ihr liegt, also darf unten nichts ankommen.

const FLOOR_Y := 400
const FLOOR := Rect2i(190, FLOOR_Y, 70, 8)

## Die Probe: eine Zelle hoch, ein paar breit, direkt auf dem Boden.
const SAMPLE_HEIGHT := 4
const SAMPLE_WIDTH := 8

## Sand wiegt 1,6 je Zelle (Dichte 1600, Skala 1/1000).
const SAND_LOAD_PER_CELL := 1.6

const FRAMES := 1600


static func run(host: Node) -> void:
	print("=== Drucktest: Holz -> Kohle -> Diamant ===")
	var world := TestSupport.new(host)
	_case(world, "wenig Last - Holz bleibt Holz", 200, 10.0, false, world.wood)
	_case(world, "mittlere Last - Holz wird Kohle", 210, 60.0, false, world.coal)
	_case(world, "hohe Last - Kohle wird Diamant", 220, 200.0, false, world.diamond)
	_case(world, "hohe Last, aber Luftspalt - nichts passiert", 230, 200.0, true, world.wood)
	print("=== fertig ===")


## Baut eine Saeule und prueft, was aus der Probe geworden ist.
##
## [param gap] legt eine Luftschicht zwischen Last und Probe.
static func _case(world: TestSupport, title: String, left: int, load: float,
		gap: bool, expected: int) -> void:
	world.reset()
	world.fill(FLOOR, world.stone, true)

	var sample := Rect2i(left, FLOOR_Y - SAMPLE_HEIGHT, SAMPLE_WIDTH, SAMPLE_HEIGHT)
	world.fill(sample, world.wood, true)

	var sand_cells := int(ceil(load / SAND_LOAD_PER_CELL))
	var sand_bottom := sample.position.y - (2 if gap else 0)
	# Statischer Sand: gemessen wird der Druck, nicht das Nachrutschen.
	world.fill(Rect2i(left, sand_bottom - sand_cells, SAMPLE_WIDTH, sand_cells),
		world.sand, true)

	var probe_x := left + SAMPLE_WIDTH / 2
	var probe_y := FLOOR_Y - 1
	var measured := world.grid.pressure_at(probe_x, probe_y)

	world.step(FRAMES)

	var result := world.material_at(probe_x, probe_y)
	var names := world.registry
	TestSupport.heading(title)
	print("  Last ueber der Probe: %.1f (%d Zellen Sand%s)" % [
		measured, sand_cells, ", Luftspalt" if gap else ""])
	print("  Saeule: %s" % world.column_profile(probe_x, sand_bottom - sand_cells - 2, FLOOR_Y + 2))
	TestSupport.verdict(result == expected,
		"aus der Probe ist %s geworden" % names.get_material(result).display_name,
		"erwartet %s, gefunden %s" % [
			names.get_material(expected).display_name,
			names.get_material(result).display_name])
