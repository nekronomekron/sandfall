class_name Toolbar
extends PanelContainer

## Materialauswahl und Static-Flag.
##
## Die Toolbar liegt im Root-Viewport, nicht im groeberen Spiel-SubViewport.
## Der ganze Viewport wird danach noch einmal ganzzahlig aufs Fenster
## vergroessert; die Schrift wird dabei mitvergroessert statt neu gerastert -
## Pixelart, aber scharf.
##
## Die Materialfarbe steckt in einem Farbfeld links neben der Beschriftung,
## nicht in der Schriftfarbe. Eingefaerbte Schrift war bei dunklen Materialien
## wie Stein kaum zu lesen.
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

@export var font_size := 12

## Kantenlaenge des Farbfelds vor der Beschriftung, in UI-Pixeln.
@export_range(4, 32) var swatch_size := 12

## Beschriftungsfarbe. Bewusst neutral und hell - die Materialfarbe traegt das
## Farbfeld.
@export var label_color := Color(0.88, 0.90, 0.94)

## Fuellung des Farbfelds beim Radierer, der keine eigene Farbe hat.
@export var eraser_swatch_color := Color(0.22, 0.22, 0.26)

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
		button.icon = _swatch_for(material)
		button.expand_icon = false
		for state in ["font_color", "font_hover_color", "font_pressed_color",
				"font_focus_color", "font_disabled_color"]:
			button.add_theme_color_override(state, label_color)
		button.pressed.connect(_apply_selection.bind(id))
		_material_list.add_child(button)
		_buttons[id] = button


func _label_of(material: SandMaterial) -> String:
	return material.toolbar_label if not material.toolbar_label.is_empty() \
		else material.display_name


## Ein einfarbiges Quadrat in der Materialfarbe, mit dunklem Rand, damit auch
## helle Materialien sich vom Knopf abheben.
func _swatch_for(material: SandMaterial) -> ImageTexture:
	var fill := eraser_swatch_color if material.phase == SandMaterial.Phase.EMPTY 		else material.color
	var image := Image.create_empty(swatch_size, swatch_size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.08, 0.08, 0.10))
	image.fill_rect(Rect2i(1, 1, swatch_size - 2, swatch_size - 2), fill)
	return ImageTexture.create_from_image(image)


func _apply_selection(id: int) -> void:
	selected_id = id
	# Beim Materialwechsel den Static-Haken auf die Materialvorgabe stellen:
	# Stein und die Gravitationsbloecke sind per Default statisch, Sand nicht.
	place_static = registry.get_material(id).starts_static
	_static_check.set_pressed_no_signal(place_static)
	material_selected.emit(id)


func _on_static_toggled(pressed: bool) -> void:
	place_static = pressed
