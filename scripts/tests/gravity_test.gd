class_name GravityTest
extends RefCounted

## `-- --gravitytest`: wirkt das statische Gravitationsfeld?
##
## Das Feld ist statisch - ein Level traegt es beim Aufbau ein, danach liest die
## Simulation es nur noch. Geprueft wird, dass es innerhalb der Karte
## tatsaechlich unterschiedlich wirken darf und dass die Bewegungslogik nicht
## heimlich doch "unten" fest verdrahtet hat.

const FRAMES := 400

## Kammern nebeneinander, jede mit eigener Schwerkraft. Alle gleich gebaut,
## damit nur das Feld den Unterschied macht.
const CHAMBER_TOP := 200
const CHAMBER_HEIGHT := 120
const CHAMBER_WIDTH := 60
const CHAMBER_GAP := 20
const FIRST_LEFT := 200

## Der Klumpen startet mittig in der Kammer, damit er in jede Richtung fallen
## kann, ohne schon an einer Wand zu liegen.
const BLOB_SIZE := Vector2i(20, 16)


static func run(host: Node) -> void:
	print("=== Gravitationstest: statisches Feld je Bereich ===")
	var world := TestSupport.new(host)

	_case(world, 0, "Normal (0, 1) - Sand faellt nach unten", Vector2.DOWN, "unten")
	_case(world, 1, "Umgekehrt (0, -1) - Sand faellt nach oben", Vector2.UP, "oben")
	_case(world, 2, "Schwerelos (0, 0) - Sand bleibt schweben", Vector2.ZERO, "mitte")
	_case(world, 3, "Seitlich (1, 0) - Sand faellt nach rechts", Vector2.RIGHT, "rechts")

	print("=== fertig ===")


static func _case(world: TestSupport, index: int, title: String, gravity: Vector2,
		expected: String) -> void:
	world.reset()
	var left := FIRST_LEFT + index * (CHAMBER_WIDTH + CHAMBER_GAP)
	var chamber := Rect2i(left, CHAMBER_TOP, CHAMBER_WIDTH, CHAMBER_HEIGHT)

	# Geschlossene Kammer: Boden, Waende und Decke. Ohne Decke faellt der Sand
	# bei umgekehrter Schwerkraft aus der Welt.
	world.build_box(chamber, world.stone, 4)
	world.fill(Rect2i(chamber.position.x - 4, chamber.position.y - 4,
		chamber.size.x + 8, 4), world.stone, true)

	# Die Zone deckt genau die Kammer ab.
	world.set_gravity(chamber, gravity)

	var blob_x := chamber.position.x + (chamber.size.x - BLOB_SIZE.x) / 2
	var blob_y := chamber.position.y + (chamber.size.y - BLOB_SIZE.y) / 2
	var start_centre := float(blob_y) + BLOB_SIZE.y * 0.5
	var start_centre_x := float(blob_x) + BLOB_SIZE.x * 0.5
	var placed := world.fill(Rect2i(blob_x, blob_y, BLOB_SIZE.x, BLOB_SIZE.y), world.sand)
	world.step(FRAMES)

	var measured := _centre_of_mass(world, chamber)
	var count := int(measured.z)
	var centre_x := measured.x
	var centre_y := measured.y

	TestSupport.heading(title)
	print("  Kammer x %d..%d, y %d..%d" % [
		chamber.position.x, chamber.end.x - 1, chamber.position.y, chamber.end.y - 1])
	print("  Sand %d von %d, Schwerpunkt (%.1f, %.1f), Start (%.1f, %.1f)" % [
		count, placed, centre_x, centre_y, start_centre_x, start_centre])
	print("  wache Chunks: %d" % world.simulation.stat_awake_chunks)

	var drift_y := centre_y - start_centre
	var drift_x := centre_x - start_centre_x
	var passed := false
	var detail := ""
	match expected:
		"unten":
			passed = drift_y > 20.0
			detail = "um %.1f Zellen nach unten gesackt" % drift_y
		"oben":
			passed = drift_y < -20.0
			detail = "um %.1f Zellen nach oben gestiegen" % -drift_y
		"rechts":
			passed = drift_x > 10.0
			detail = "um %.1f Zellen nach rechts gewandert" % drift_x
		_:
			passed = absf(drift_y) < 2.0 and absf(drift_x) < 2.0
			detail = "kaum bewegt (%.1f, %.1f)" % [drift_x, drift_y]

	if count != placed:
		print("  FEHLGESCHLAGEN: %d von %d Sandzellen verloren" % [placed - count, placed])
	else:
		TestSupport.verdict(passed, detail,
			"Schwerpunkt wanderte um (%.1f, %.1f) - das passt nicht zu %s" % [
				drift_x, drift_y, expected])


## Schwerpunkt und Anzahl der Sandzellen in der Kammer.
static func _centre_of_mass(world: TestSupport, chamber: Rect2i) -> Vector3:
	var count := 0
	var sum_x := 0
	var sum_y := 0
	for y in range(chamber.position.y, chamber.end.y):
		for x in range(chamber.position.x, chamber.end.x):
			if world.material_at(x, y) != world.sand:
				continue
			count += 1
			sum_x += x
			sum_y += y
	if count == 0:
		return Vector3(0.0, 0.0, 0.0)
	return Vector3(float(sum_x) / count, float(sum_y) / count, count)
