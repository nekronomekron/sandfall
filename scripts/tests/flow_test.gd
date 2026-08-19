class_name FlowTest
extends RefCounted

## `-- --flowtest`: bleibt fliessendes Material haengen?
##
## Deckt den Fehler ab, dass bei einer Bewegung innerhalb eines Chunks nur die
## Quelle ins Dirty-Rect eingetragen wurde. Weit springendes Material - Wasser
## streut bis zu seiner Dispersion - landete dann ausserhalb des simulierten
## Rechtecks und blieb dort stehen, waehrend die Region einschlief.
##
## Das eigentliche Kriterium ist nicht "es schwebt etwas", sondern "es schwebt
## etwas, obwohl niemand mehr simuliert wird". Genau das sind haengengebliebene
## Zellen, die nie wieder betrachtet werden.

const FLOOR := Rect2i(0, 480, 1024, 12)
const WATER_BLOCK := Rect2i(480, 120, 60, 50)
const SAND_BLOCK := Rect2i(300, 200, 60, 40)
const FRAMES_PER_PHASE := 400
const PHASES := 6


static func run(host: Node) -> void:
	print("=== Fliess-Regressionstest ===")
	var world := TestSupport.new(host)
	world.fill(FLOOR, world.stone, true)
	var placed := world.fill(WATER_BLOCK, world.water) + world.fill(SAND_BLOCK, world.sand)

	for phase in range(1, PHASES + 1):
		world.step(FRAMES_PER_PHASE)
		var floating := _count_floating(world)
		print("  nach %4d Frames: Material %d/%d   schwebend %d   wache Chunks %d" % [
			phase * FRAMES_PER_PHASE, _count_loose(world), placed, floating,
			world.simulation.stat_awake_chunks])

	var stuck := _count_floating(world)
	var awake := world.simulation.stat_awake_chunks
	if stuck > 0 and awake == 0:
		print("  FEHLGESCHLAGEN: %d Zellen haengen in der Luft, aber nichts wird mehr simuliert" % stuck)
	elif stuck > 0:
		print("  OK: %d Zellen noch in Bewegung, %d Chunks aktiv" % [stuck, awake])
	else:
		print("  OK: nichts haengt, Welt vollstaendig zur Ruhe gekommen")
	print("=== fertig ===")


## Zellen, unter denen direkt Luft liegt. In einer zur Ruhe gekommenen
## Ansammlung darf es die nicht geben.
static func _count_floating(world: TestSupport) -> int:
	var grid := world.grid
	var floating := 0
	for y in grid.height - 1:
		var row := y * grid.width
		for x in grid.width:
			var material := grid.material_id[row + x]
			if material != world.water and material != world.sand:
				continue
			if grid.material_id[row + grid.width + x] == world.air:
				floating += 1
	return floating


static func _count_loose(world: TestSupport) -> int:
	return world.count(world.water) + world.count(world.sand)
