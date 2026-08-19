class_name MaterialRegistry
extends Node

## Zentrale Materialverwaltung als Knoten in der Szene. Die [MaterialLibrary]
## wird im Editor an [member library] gehaengt; alle anderen Knoten holen sich
## Materialien und Lookups von hier.
##
## Aufgebaut wird in [method _enter_tree], also bevor irgendein anderer Knoten
## sein [method Node._ready] bekommt. Damit ist die Reihenfolge im Szenenbaum
## egal.

@export var library: MaterialLibrary

## Flache Lookup-Arrays fuer die Schleifenkerne von Simulation und Renderer.
var lookups := MaterialLookups.new()

var _built: bool = false


func _enter_tree() -> void:
	build()


## Idempotent - Aufrufer duerfen das absichern, ohne die Baumreihenfolge zu kennen.
func build() -> void:
	if _built:
		return
	if library == null:
		push_error("MaterialRegistry: keine MaterialLibrary zugewiesen.")
		return
	_built = true
	library.resolve()
	lookups.build(library)


func count() -> int:
	return library.size()


func get_material(id: int) -> SandMaterial:
	return library.get_material(id)


## Material-id zu einem Namen, oder -1 wenn es den Namen nicht gibt.
func id_of(material_name: StringName) -> int:
	return library.id_of(material_name)


## Wie [method id_of], bricht aber laut ab statt still -1 zu liefern. Fuer
## Stellen, die einen festen Namen erwarten (Demo-Aufbau, Selbsttests).
func require_id(material_name: StringName) -> int:
	var id := library.id_of(material_name)
	assert(id >= 0, "Unbekanntes Material: %s" % material_name)
	return id
