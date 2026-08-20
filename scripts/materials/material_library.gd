class_name MaterialLibrary
extends Resource

## Die Liste aller Materialtypen. Die POSITION IN DER LISTE IST DIE ID, mit der
## das Gitter arbeitet - deshalb muss niemand von Hand ids vergeben oder eine
## COUNT-Konstante pflegen.
##
## NEUES MATERIAL: .tres anlegen und hier hinten anhaengen. Fertig.
##
## Der erste Eintrag muss das leere Material (Luft) sein: die Simulation prueft
## millionenfach pro Frame auf "id == 0" statt auf eine Eigenschaft.

const EMPTY_ID := 0

@export var materials: Array[SandMaterial] = []

## Material-id je [member SandMaterial.material_name].
var _id_by_name: Dictionary = {}
var _resolved: bool = false


## Vergibt die ids, baut den Namensindex und loest die Ziele der
## Zustandsuebergaenge auf. Mehrfachaufrufe sind harmlos.
func resolve() -> void:
	if _resolved:
		return
	_resolved = true

	_id_by_name.clear()
	for index in materials.size():
		var material := materials[index]
		if material == null:
			push_error("MaterialLibrary: Eintrag %d ist leer." % index)
			continue
		material.id = index
		if material.material_name.is_empty():
			push_error("MaterialLibrary: Material %d hat keinen material_name." % index)
			continue
		if _id_by_name.has(material.material_name):
			push_error("MaterialLibrary: material_name '%s' ist doppelt vergeben." % material.material_name)
			continue
		_id_by_name[material.material_name] = index

	if materials.is_empty() or materials[EMPTY_ID].phase != SandMaterial.Phase.EMPTY:
		push_error("MaterialLibrary: Der erste Eintrag muss das leere Material (Phase EMPTY) sein.")

	for material in materials:
		if material == null:
			continue
		for transition in material.transitions:
			transition.target_id = _resolve(material, transition.becomes, "wechselt zu")
		if material.burning != null:
			var burning := material.burning
			# Leerer Name heisst hier "nichts bleibt uebrig", nicht "unbekannt" -
			# die Zelle wird dann zu Luft.
			if burning.residue.is_empty():
				burning.residue_id = EMPTY_ID
			else:
				burning.residue_id = _resolve(material, burning.residue, "hinterlaesst")
			if burning.emits.is_empty():
				burning.emits_id = -1
			else:
				burning.emits_id = _resolve(material, burning.emits, "entzuendet")
		if material.pressure != null:
			material.pressure.target_id = _resolve(
				material, material.pressure.becomes, "wird unter Druck zu")


## Einen Materialnamen in eine id aufloesen und einen unbekannten Namen melden.
func _resolve(material: SandMaterial, target: StringName, relation: String) -> int:
	var id := id_of(target)
	if id < 0:
		push_error("MaterialLibrary: '%s' %s unbekanntem Material '%s'." % [
			material.material_name, relation, target])
	return id


func size() -> int:
	return materials.size()


func get_material(id: int) -> SandMaterial:
	return materials[id]


## Material-id zu einem Namen, oder -1 wenn es den Namen nicht gibt.
func id_of(material_name: StringName) -> int:
	return _id_by_name.get(material_name, -1)
