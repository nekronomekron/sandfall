class_name BenchmarkTest
extends RefCounted

## `-- --bench`: Leistungsmessung, laeuft headless.
##
## Drei Szenarien statt einem: der Stresstest allein waere irrefuehrend, weil er
## dauerhaft fast jede Zelle in Bewegung haelt - ein Zustand, den normale
## Interaktion nie erreicht.

const FLOOR := Rect2i(0, 480, 1024, 12)

## Anteil der Messwerte, unter dem der p95-Wert liegt.
const P95 := 0.95


static func run(host: Node) -> void:
	var world := TestSupport.new(host)
	print("=== Sand Simulation Benchmark: %dx%d = %d Zellen ===" % [
		world.grid.width, world.grid.height, world.grid.cell_count])

	_case(world, "Ruhe (nur Boden, alles gesetzt)", 200,
		func(_w: TestSupport) -> void: pass)

	_case(world, "Typisch (Pinselgroesse, Wasser + Lava + Gravitation)", 400,
		func(w: TestSupport) -> void:
			w.fill(Rect2i(300, 240, 40, 40), w.sand)
			w.fill(Rect2i(180, 440, 100, 30), w.water)
			w.fill(Rect2i(360, 465, 20, 13), w.lava)
			w.fill(Rect2i(420, 350, 12, 12), w.gravity_inverter, true))

	_case(world, "Stress (Grossblock Sand + Wasser in freiem Fall)", 300,
		func(w: TestSupport) -> void:
			w.fill(Rect2i(280, 80, 150, 100), w.sand)
			w.fill(Rect2i(120, 340, 180, 80), w.water)
			w.fill(Rect2i(500, 465, 20, 10), w.lava)
			w.fill(Rect2i(520, 250, 10, 10), w.gravity_inverter, true))

	print("=== fertig ===")


static func _case(world: TestSupport, title: String, frames: int, setup: Callable) -> void:
	world.reset()
	world.fill(FLOOR, world.stone, true)
	setup.call(world)

	var samples := PackedInt32Array()
	var total_usec := 0
	var worst_usec := 0
	var gravity_usec := 0
	var heat_usec := 0
	var move_usec := 0

	for frame in frames:
		var started := Time.get_ticks_usec()
		world.simulation.step()
		var elapsed := Time.get_ticks_usec() - started
		samples.append(elapsed)
		total_usec += elapsed
		worst_usec = maxi(worst_usec, elapsed)
		gravity_usec += world.simulation.stat_gravity_usec
		heat_usec += world.simulation.stat_heat_usec
		move_usec += world.simulation.stat_move_usec

	var sorted_samples := Array(samples)
	sorted_samples.sort()
	var median: int = sorted_samples[sorted_samples.size() / 2]
	var p95: int = sorted_samples[int(sorted_samples.size() * P95)]
	var average := float(total_usec) / float(frames)

	TestSupport.heading("%s  (%d Frames)" % [title, frames])
	print("  Mittel  %6.2f ms  (%5.1f fps)" % [
		average / 1000.0, 1000000.0 / maxf(average, 1.0)])
	print("  Median  %6.2f ms  (%5.1f fps)" % [
		median / 1000.0, 1000000.0 / maxf(float(median), 1.0)])
	print("  p95     %6.2f ms   Maximum %6.2f ms" % [p95 / 1000.0, worst_usec / 1000.0])
	print("  davon im Mittel: Gravitation %.2f  Waerme %.2f  Bewegung %.2f ms" % [
		gravity_usec / 1000.0 / frames, heat_usec / 1000.0 / frames,
		move_usec / 1000.0 / frames])
	print("  letzter Frame: wache Chunks %d/%d, Bewegungen %d" % [
		world.simulation.stat_awake_chunks, world.grid.chunk_count,
		world.simulation.stat_moved])
