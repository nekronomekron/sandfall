class_name MaterialTransition
extends Resource

## Ein temperaturgetriebener Aggregatzustandswechsel, z.B. "Wasser gefriert
## unter 0 Grad zu Eis".
##
## Das Ziel wird ueber [member becomes] beim NAMEN angesprochen, nicht ueber
## eine Resource-Referenz. Grund: Wasser verweist auf Eis und Eis zurueck auf
## Wasser - solche Ringe kann Godot zwischen zwei .tres-Dateien nicht laden.
## [MaterialLibrary] loest den Namen einmal beim Start in eine Material-id auf.
##
## HYSTERESE entsteht durch unterschiedliche Schwellen fuer Hin- und
## Rueckweg: Wasser gefriert bei 0 Grad, Eis taut erst bei +2. Ohne diesen
## Abstand flackert eine Zelle an der Schwelle in jedem Frame hin und her.

enum Trigger {
	ABOVE,  ## Loest aus, sobald die Temperatur die Schwelle erreicht oder ueberschreitet.
	BELOW,  ## Loest aus, sobald die Temperatur die Schwelle erreicht oder unterschreitet.
}

@export var trigger: Trigger = Trigger.ABOVE

## Schwelle in Grad Celsius.
@export var threshold_celsius: float = 100.0

## Name des Zielmaterials, siehe [member SandMaterial.material_name].
@export var becomes: StringName = &""

## Setzt die Zelle beim Wechsel auf [member result_celsius], statt ihre
## Temperatur zu behalten. Erstarrende Lava braucht das: bliebe der frische
## Stein auf seiner Erstarrungstemperatur, wuerde er daneben weiter Wasser
## verdampfen, ohne dass im Bild noch etwas Heisses zu sehen waere.
@export var resets_temperature: bool = false
@export var result_celsius: float = 20.0

## Von [method MaterialLibrary.resolve] gefuellt. -1 = Name unbekannt.
var target_id: int = -1
