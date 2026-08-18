class_name Toolbar
extends PanelContainer

## Materialauswahl und Static-Flag.
##
## Die Toolbar liegt in der nativen Fensteraufloesung, nicht im
## hochskalierten Spiel-SubViewport. Deshalb darf hier eine normale Schriftgroesse
## stehen und der Text wird 1:1 gerastert - scharf statt hochskaliert.
##
## Die Buttonliste wird aus MaterialDB erzeugt: ein neues Material taucht hier
## automatisch auf, sobald es in der Registry steht und selectable ist.

signal material_selected(id: int)
signal reset_pressed()

const FONT_SIZE := 13
const PANEL_WIDTH := 150

var selected_id: int = MaterialDB.SAND
var place_static: bool = false

var _static_box: CheckBox
var _buttons: Dictionary = {}

func _ready() -> void:
	custom_minimum_size = Vector2(PANEL_WIDTH, 0)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)

	var title := Label.new()
	title.text = "MATERIAL"
	title.add_theme_font_size_override("font_size", FONT_SIZE)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(title)

	var group := ButtonGroup.new()
	for d in MaterialDB.defs():
		if not d.selectable:
			continue
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.text = "Radierer" if d.id == MaterialDB.EMPTY else d.display_name
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", FONT_SIZE)
		var col := _label_color(d)
		b.add_theme_color_override("font_color", col)
		b.add_theme_color_override("font_hover_color", col)
		b.add_theme_color_override("font_pressed_color", col)
		b.pressed.connect(_on_material_pressed.bind(d.id))
		box.add_child(b)
		_buttons[d.id] = b
	if _buttons.has(selected_id):
		_buttons[selected_id].button_pressed = true

	box.add_child(HSeparator.new())

	_static_box = CheckBox.new()
	_static_box.text = "statisch"
	_static_box.add_theme_font_size_override("font_size", FONT_SIZE)
	_static_box.tooltip_text = "Static-Flag pro Zelle: Schwerkraft wirkt nicht."
	_static_box.toggled.connect(func(on: bool) -> void: place_static = on)
	box.add_child(_static_box)
	_sync_static_default()

	var reset := Button.new()
	reset.text = "Zuruecksetzen"
	reset.add_theme_font_size_override("font_size", FONT_SIZE)
	reset.pressed.connect(func() -> void: reset_pressed.emit())
	box.add_child(reset)

func _label_color(d: MaterialDef) -> Color:
	if d.id == MaterialDB.EMPTY:
		return Color(0.80, 0.80, 0.83)
	return d.color.lightened(0.3)

func _on_material_pressed(id: int) -> void:
	selected_id = id
	_sync_static_default()
	material_selected.emit(id)

## Beim Materialwechsel den Static-Haken auf die Materialvorgabe stellen -
## Stein und Gravitationsbloecke sind per Default statisch, Sand nicht.
func _sync_static_default() -> void:
	if _static_box == null:
		return
	var d := MaterialDB.get_def(selected_id)
	_static_box.set_pressed_no_signal(d.default_static)
	place_static = d.default_static
