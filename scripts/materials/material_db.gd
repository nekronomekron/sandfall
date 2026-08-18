class_name MaterialDB
extends RefCounted

## Registry aller Materialtypen. Die Array-Position ist die id.
##
## ERWEITERN: unten in _build() eine Zeile ergaenzen, oben eine Konstante
## vergeben und _defs.resize() erhoehen. Sonst ist nichts anzupassen - Toolbar,
## Renderer, Simulation und Gravitationsfeld lesen alles aus den
## MaterialDef-Eigenschaften.
##
## Waerme und Kaelte kommen aus echten Materialien statt aus abstrakten
## Quellen: Lava wird mit 1200 Grad platziert und erstarrt beim Abkuehlen zu
## Stein, Eis wird mit -60 Grad platziert und taut ueber 2 Grad zu Wasser. Die
## Waermeleitung macht daraus von selbst Waerme- und Kaeltequellen.

const EMPTY := 0
const SAND := 1
const WATER := 2
const STONE := 3
const ICE := 4
const STEAM := 5
const LAVA := 6
const G_BLOCK := 7
const G_BOOST := 8
const G_INVERT := 9

const COUNT := 10

static var _defs: Array[MaterialDef] = []

static func defs() -> Array[MaterialDef]:
	if _defs.is_empty():
		_build()
	return _defs

static func get_def(id: int) -> MaterialDef:
	return defs()[id]

static func _mk(id: int, name: String, color: Color, props: Dictionary) -> MaterialDef:
	var m := MaterialDef.new()
	m.id = id
	m.display_name = name
	m.color = color
	for key in props:
		m.set(key, props[key])
	return m

static func _build() -> void:
	_defs = []
	_defs.resize(COUNT)

	_defs[EMPTY] = _mk(EMPTY, "Leer", Color(0.055, 0.06, 0.085), {
		"kind": MaterialDef.Kind.EMPTY, "density": 0.0, "grain": 0.0,
		"conductivity": 0.09, "heat_capacity": 0.4,
		"friction": 0.0,
	})

	_defs[SAND] = _mk(SAND, "Sand", Color(0.84, 0.70, 0.36), {
		"kind": MaterialDef.Kind.POWDER, "density": 1600.0, "grain": 0.11,
		"conductivity": 0.05, "heat_capacity": 1.5,
		# Koernig: rutscht, reisst Nachbarn aber nur maessig mit.
		"friction": 0.55,
	})

	_defs[WATER] = _mk(WATER, "Wasser", Color(0.16, 0.42, 0.85), {
		"kind": MaterialDef.Kind.LIQUID, "density": 1000.0, "dispersion": 5,
		"grain": 0.04, "conductivity": 0.13, "heat_capacity": 2.5,
		# Sehr niedrig: laeuft weit, bevor es liegen bleibt.
		"friction": 0.05,
		"transitions": [
			{"below": 0.0, "to": ICE},
			{"above": 100.0, "to": STEAM},
		] as Array[Dictionary],
	})

	_defs[STONE] = _mk(STONE, "Stein", Color(0.42, 0.42, 0.47), {
		"kind": MaterialDef.Kind.POWDER, "density": 2600.0, "grain": 0.07,
		"default_static": true, "conductivity": 0.09, "heat_capacity": 3.0,
		"friction": 0.90,
		"transitions": [
			{"above": 950.0, "to": LAVA},
		] as Array[Dictionary],
	})

	# Kaeltequelle: wird mit -25 Grad platziert und kuehlt die Umgebung durch
	# Leitung ab. Taut mit Hysterese erst bei +2 Grad (Wasser gefriert bei 0).
	_defs[ICE] = _mk(ICE, "Eis", Color(0.64, 0.85, 0.96), {
		"kind": MaterialDef.Kind.SOLID, "density": 900.0, "grain": 0.05,
		"default_static": true, "conductivity": 0.17, "heat_capacity": 8.0,
		"friction": 0.90,
		"default_temp": -60.0,
		"transitions": [
			{"above": 2.0, "to": WATER},
		] as Array[Dictionary],
	})

	_defs[STEAM] = _mk(STEAM, "Dampf", Color(0.76, 0.79, 0.86), {
		"kind": MaterialDef.Kind.GAS, "density": 60.0, "dispersion": 3,
		"grain": 0.06, "conductivity": 0.04, "heat_capacity": 0.8,
		"friction": 0.02,
		"default_temp": 110.0,
		"transitions": [
			{"below": 95.0, "to": WATER},
		] as Array[Dictionary],
	})

	# Waermequelle: wird mit 1200 Grad platziert, fliesst traege und erstarrt
	# unter 700 Grad zu Stein. Die hohe Waermekapazitaet sorgt dafuer, dass sie
	# lange genug heiss bleibt, um Wasser zu verdampfen.
	_defs[LAVA] = _mk(LAVA, "Lava", Color(0.94, 0.35, 0.08), {
		"kind": MaterialDef.Kind.LIQUID, "density": 2400.0, "dispersion": 2,
		"grain": 0.08, "conductivity": 0.16, "heat_capacity": 8.0,
		# Zaehfluessig: kommt deutlich frueher zur Ruhe als Wasser.
		"friction": 0.50,
		"default_temp": 1200.0,
		# Beim Erstarren faellt die Temperatur auf Normalwert. Sonst bliebe der
		# frische Stein bei 700 Grad stehen und wuerde daneben weiter Wasser
		# verdampfen - fuer den Spieler unerklaerlich, weil nichts Heisses mehr
		# zu sehen ist.
		"transitions": [
			{"below": 700.0, "to": STONE, "temp": 20.0},
		] as Array[Dictionary],
	})

	_defs[G_BLOCK] = _mk(G_BLOCK, "Grav-Blocker", Color(0.36, 0.29, 0.58), {
		"kind": MaterialDef.Kind.POWDER, "density": 2400.0, "grain": 0.05,
		"default_static": true, "conductivity": 0.08, "heat_capacity": 3.0,
		"friction": 0.80,
		"grav_radius": 44, "grav_factor": 0.0,
	})

	_defs[G_BOOST] = _mk(G_BOOST, "Grav-Verstaerker", Color(0.86, 0.42, 0.86), {
		"kind": MaterialDef.Kind.POWDER, "density": 2400.0, "grain": 0.05,
		"default_static": true, "conductivity": 0.08, "heat_capacity": 3.0,
		"friction": 0.80,
		"grav_radius": 44, "grav_factor": 3.0,
	})

	_defs[G_INVERT] = _mk(G_INVERT, "Grav-Umkehrer", Color(0.28, 0.86, 0.52), {
		"kind": MaterialDef.Kind.POWDER, "density": 2400.0, "grain": 0.05,
		"default_static": true, "conductivity": 0.08, "heat_capacity": 3.0,
		"friction": 0.80,
		"grav_radius": 44, "grav_factor": -1.0,
	})
