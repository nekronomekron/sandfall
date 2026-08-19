class_name Toolbar
extends PanelContainer

## Materialauswahl und Static-Flag.
##
## Die Toolbar liegt in der nativen Fensteraufloesung, nicht im hochskalierten
## Spiel-SubViewport. Deshalb darf hier eine normale Schriftgroesse stehen und
## der Text wird 1:1 gerastert - scharf statt hochskaliert.
##
## Die Knopfliste entsteht zur Laufzeit aus der [MaterialRegistry]: ein neues
## Material taucht hier von selbst auf, sobald es in der Bibliothek steht und
## [member SandMaterial.selectable] gesetzt ist.

signal material_selected(id: int)
signal reset_pressed()

@export_group("Verdrahtung")

## Woher die Materialliste kommt. Im Editor zuweisen.
@export var registry: MaterialRegistry

@export_group("Darstellung")

@export var font_size := 13

## Wie stark die Materialfarbe fuer die Beschriftung aufgehellt wird.
@export_range(0.0, 1.0, 0.05) var label_lightening := 0.3

## Beschriftungsfarbe des Radierers, der keine sinnvolle eigene Farbe hat.
@export var eraser_label_color := Color(0.80, 0.80, 0.83)

## Welches Material beim Start ausgewaehlt ist.
@export var default_material := &"sand"

var selected_id: int = MaterialLibrary.EMPTY_ID
var place_static: bool = false

@onready var _material_list: VBoxContainer = %MaterialList
@onready var _static_check: CheckBox = %StaticCheck
@onready var _reset_button: Button = %ResetButton

var _buttons: Dictionary = {}


func _ready() -> void:
	registry.build()
	_static_check.toggled.connect(_on_static_toggled)
	_reset_button.pressed.connect(func() -> void: reset_pressed.emit())
	_build_material_buttons()
	select(registry.id_of(default_material))


## Waehlt ein Material aus, als haette der Nutzer den Knopf gedrueckt.
func select(id: int) -> void:
	if id < 0 or not _buttons.has(id):
		return
	_buttons[id].button_pressed = true
	_apply_selection(id)


func _build_material_buttons() -> void:
	var group := ButtonGroup.new()
	for id in registry.count():
		var material := registry.get_material(id)
		if not material.selectable:
			continue
		var button := Button.new()
		button.toggle_mode = true
		button.button_group = group
		button.text = _label_of(material)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_font_size_override("font_size", font_size)
		var colour := _label_colour(material)
		for state in ["font_color", "font_hover_color", "font_pressed_color"]:
			button.add_theme_color_override(state, colour)
		button.pressed.connect(_apply_selection.bind(id))
		_material_list.add_child(button)
		_buttons[id] = button


func _label_of(material: SandMaterial) -> String:
	return material.toolbar_label if not material.toolbar_label.is_empty() \
		else material.display_name


func _label_colour(material: SandMaterial) -> Color:
	if material.phase == SandMaterial.Phase.EMPTY:
		return eraser_label_color
	return material.color.lightened(label_lightening)


func _apply_selection(id: int) -> void:
	selected_id = id
	# Beim Materialwechsel den Static-Haken auf die Materialvorgabe stellen:
	# Stein und die Gravitationsbloecke sind per Default statisch, Sand nicht.
	place_static = registry.get_material(id).starts_static
	_static_check.set_pressed_no_signal(place_static)
	material_selected.emit(id)


func _on_static_toggled(pressed: bool) -> void:
	place_static = pressed
