class_name PhaseTest
extends RefCounted

## `-- --fsmtest`: Selbsttest der temperaturgetriebenen Aggregatzustands-FSM.
##
## Waerme und Kaelte kommen aus echten Materialien statt aus abstrakten
## Quellen: Lava bringt ihre 1200 Grad mit, Eis seine -60, und die
## Waermeleitung macht daraus von selbst Waerme- und Kaeltequellen. Beide
## verbrauchen sich dabei - Lava erstarrt zu Stein, Eis taut zu Wasser.

## Die Wanne ist hoeher als der Wasserstand: ohne diesen Freibord laeuft sie
## ueber, sobald die Quelle Wasser verdraengt, und die Mengenbilanz waere hin.
const BASIN := Rect2i(186, 240, 68, 60)
const WATER := Rect2i(186, 260, 68, 40)
const SOURCE := Rect2i(210, 288, 20, 8)
const FRAMES_PER_SAMPLE := 100
const SAMPLES := 6


static func run(host: Node) -> void:
	print("=== FSM-Test: Temperaturgetriebene Aggregatzustaende ===")
	var world := TestSupport.new(host)
	_case(world, "Lava in Wasser -> Dampf + erstarrter Stein erwartet", world.lava)
	_case(world, "Eis in Wasser -> mehr Eis erwartet", world.ice)
	print("=== fertig ===")


static func _case(world: TestSupport, title: String, source_material: int) -> void:
	world.reset()
	world.build_box(BASIN, world.stone, 6)
	world.fill(WATER, world.water)
	var stone_before := world.count(world.stone)
	# Eis wird statisch platziert, damit es als Kaeltequelle liegen bleibt,
	# statt im Wasser aufzuschwimmen.
	world.fill(SOURCE, source_material, source_material == world.ice)

	TestSupport.heading(title)
	for sample in range(1, SAMPLES + 1):
		world.step(FRAMES_PER_SAMPLE)
		print("  nach %4d Frames: Wasser %5d  Dampf %4d  Eis %4d  Lava %4d  Stein(neu) %4d" % [
			sample * FRAMES_PER_SAMPLE,
			world.count(world.water), world.count(world.steam),
			world.count(world.ice), world.count(world.lava),
			world.count(world.stone) - stone_before])
