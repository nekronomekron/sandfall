class_name MaterialLookups
extends RefCounted

## Materialeigenschaften als flache Arrays, indiziert mit der Material-id.
##
## WARUM: Ein Property-Zugriff auf eine Resource kostet in GDScript ein
## Vielfaches eines Packed-Array-Zugriffs, und genau diese Zugriffe liegen im
## innersten Schleifenkern von Bewegung, Waermeleitung und Renderer. Beim
## Renderer war das gemessen der groesste Einzelposten - groesser als der
## Texturupload.
##
## Die [SandMaterial]-Resourcen bleiben die einzige Quelle der Wahrheit; diese
## Arrays werden in [method build] daraus abgeleitet.

## Waermekapazitaet daempft die Aenderungsrate. 0.24 ist die Stabilitaetsgrenze
## der expliziten Waermeleitung - darueber schwingt sie auf.
const MAX_HEAT_TRANSFER := 0.24

## Angleichung an die Umgebungstemperatur pro Waermeschritt, vor der Teilung
## durch die Waermekapazitaet. Luft folgt schnell, Materie traege.
const AMBIENT_PULL_AIR := 0.02
const AMBIENT_PULL_MATTER := 0.002

## Umkehr-Budget beim seitlichen Ausbreiten, aus der Reibung abgeleitet.
## Reibung 0 -> MAX Wechsel (Wasser laeuft weit), Reibung 1 -> MIN Wechsel.
const MAX_DIRECTION_CHANGES := 30
const MIN_DIRECTION_CHANGES := 1

## Obergrenze fuer den Wechselzaehler im settle-Byte, siehe [SandSimulation].
const DIRECTION_CHANGE_LIMIT := 0x3F

# --- Physik ------------------------------------------------------------------
var movable: PackedByteArray
## Rutscht diagonal ab. Feststoffe nicht - die stapeln sich in Saeulen.
var slides: PackedByteArray
var is_gas: PackedByteArray
## Fluessigkeit oder Gas. Entscheidet, WER verdraengt werden darf.
var is_fluid: PackedByteArray
var density: PackedFloat32Array
var dispersion: PackedByteArray
## Vorgabe fuer das Static-Flag beim Platzieren und beim Zustandswechsel.
var starts_static: PackedByteArray
## Reibung als 0..255, damit im Schleifenkern kein Float-Vergleich noetig ist.
var friction_u8: PackedByteArray
## Wie viele Richtungswechsel eine Zelle beim seitlichen Ausweichen macht,
## bevor sie liegen bleibt.
var direction_change_budget: PackedByteArray

# --- Waerme ------------------------------------------------------------------
var heat_transfer: PackedFloat32Array
var ambient_pull: PackedFloat32Array
var default_celsius: PackedFloat32Array
var emits_heat: PackedByteArray
var emit_celsius: PackedFloat32Array
var emit_power: PackedFloat32Array

# --- Aggregatzustands-FSM ----------------------------------------------------
## Die Uebergaenge aller Materialien liegen hintereinander in einem flachen
## Block; je Material zeigen Start und Anzahl in diesen Block. Damit kommt der
## Waermepass ohne Resource-Zugriff aus.
var transition_start: PackedInt32Array
var transition_count: PackedInt32Array
var transition_above: PackedByteArray
var transition_threshold: PackedFloat32Array
var transition_target: PackedInt32Array
var transition_resets_temperature: PackedByteArray
var transition_result: PackedFloat32Array

# --- Renderer ----------------------------------------------------------------
var color_red: PackedFloat32Array
var color_green: PackedFloat32Array
var color_blue: PackedFloat32Array
## Bereits mit 2 vorskaliert, weil der Renderer um 0.5 zentriertes Rauschen
## addiert.
var grain_amount: PackedFloat32Array


func build(library: MaterialLibrary) -> void:
	var count := library.size()
	_resize_all(count)

	var flat_transitions: Array[MaterialTransition] = []
	for id in count:
		var material := library.get_material(id)
		movable[id] = 1 if material.is_movable() else 0
		slides[id] = 1 if material.slides_diagonally() else 0
		is_gas[id] = 1 if material.is_gas() else 0
		is_fluid[id] = 1 if material.is_fluid() else 0
		density[id] = material.density
		dispersion[id] = clampi(material.dispersion, 0, 255)
		starts_static[id] = 1 if material.starts_static else 0
		friction_u8[id] = int(clampf(material.friction, 0.0, 1.0) * 255.0)
		direction_change_budget[id] = _budget_for(material.friction)

		var capacity := maxf(material.heat_capacity, 0.1)
		heat_transfer[id] = clampf(material.conductivity / capacity, 0.0, MAX_HEAT_TRANSFER)
		var pull := AMBIENT_PULL_AIR if material.phase == SandMaterial.Phase.EMPTY else AMBIENT_PULL_MATTER
		ambient_pull[id] = pull / capacity
		default_celsius[id] = material.default_celsius
		emits_heat[id] = 1 if material.emits_heat else 0
		emit_celsius[id] = material.emit_celsius
		emit_power[id] = material.emit_power

		transition_start[id] = flat_transitions.size()
		transition_count[id] = material.transitions.size()
		flat_transitions.append_array(material.transitions)

		color_red[id] = material.color.r
		color_green[id] = material.color.g
		color_blue[id] = material.color.b
		grain_amount[id] = material.grain * 2.0

	_flatten_transitions(flat_transitions)


## Reibung 0..1 auf ein Umkehr-Budget abbilden.
func _budget_for(friction: float) -> int:
	var changes := lerpf(float(MAX_DIRECTION_CHANGES), float(MIN_DIRECTION_CHANGES),
		clampf(friction, 0.0, 1.0))
	return clampi(roundi(changes), MIN_DIRECTION_CHANGES, DIRECTION_CHANGE_LIMIT)


func _flatten_transitions(flat_transitions: Array[MaterialTransition]) -> void:
	var count := flat_transitions.size()
	transition_above.resize(count)
	transition_threshold.resize(count)
	transition_target.resize(count)
	transition_resets_temperature.resize(count)
	transition_result.resize(count)
	for index in count:
		var transition := flat_transitions[index]
		transition_above[index] = 1 if transition.trigger == MaterialTransition.Trigger.ABOVE else 0
		transition_threshold[index] = transition.threshold_celsius
		transition_target[index] = transition.target_id
		transition_resets_temperature[index] = 1 if transition.resets_temperature else 0
		transition_result[index] = transition.result_celsius


func _resize_all(count: int) -> void:
	movable.resize(count)
	slides.resize(count)
	is_gas.resize(count)
	is_fluid.resize(count)
	density.resize(count)
	dispersion.resize(count)
	starts_static.resize(count)
	friction_u8.resize(count)
	direction_change_budget.resize(count)
	heat_transfer.resize(count)
	ambient_pull.resize(count)
	default_celsius.resize(count)
	emits_heat.resize(count)
	emit_celsius.resize(count)
	emit_power.resize(count)
	transition_start.resize(count)
	transition_count.resize(count)
	color_red.resize(count)
	color_green.resize(count)
	color_blue.resize(count)
	grain_amount.resize(count)
