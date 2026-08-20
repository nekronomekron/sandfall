class_name PressureChange
extends Resource

## Macht ein Material druckempfindlich. Haengt als optionale Resource an
## [member SandMaterial.pressure] - fehlt sie, laesst sich das Material durch
## Druck nicht veraendern.
##
## DRUCK ist die Last des Materials, das entlang der Schwerkraft darueber
## liegt. Gemessen wird sie als Summe der Dichten geteilt durch 1000, also in
## "Metern Wassersaeule": 100 Zellen Wasser ergeben 100, 100 Zellen Sand rund
## 160. Damit stehen im Inspektor lesbare Zahlen statt Zehntausendern.
##
## Eine Luftzelle setzt die Last auf 0 zurueck - eine Hoehlendecke traegt, was
## ueber ihr liegt, nicht der Boden darunter. Dasselbe gilt an der Grenze zu
## einem Bereich mit abweichender Schwerkraft.
##
## Ausgewertet wird das in [PressurePass], nicht im Waermepass: Druck aendert
## sich langsam, und der Durchlauf laeuft deshalb ueber viele Frames verteilt.

## Ab dieser Last beginnt die Umwandlung. 0 bedeutet: sofort, auch ohne Last.
@export var threshold: float = 40.0

## Fortschritt pro Druckschritt, von 0 bis 255. Das ist die "gewisse Zeit":
## bei 8 dauert die Umwandlung 32 Schritte, und ein Schritt braucht einen
## vollen Durchlauf des [PressurePass] ueber diese Spalte.
@export_range(1, 255) var rate: int = 8

## Name des Zielmaterials, siehe [member SandMaterial.material_name].
@export var becomes: StringName = &""

## Von [method MaterialLibrary.resolve] gefuellt. -1 = Name unbekannt.
var target_id: int = -1
