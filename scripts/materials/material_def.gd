class_name MaterialDef
extends Resource

## Definition EINES Materialtyps. Es existiert genau eine Instanz pro Typ -
## niemals eine pro Pixel. Das Grid speichert nur die numerische id.
##
## Neues Material hinzufuegen: einen Eintrag in MaterialDB._build() ergaenzen.
## Neue Eigenschaft hinzufuegen: hier ein @export ergaenzen, Default setzen,
## und dort auswerten wo sie wirkt (Simulation / GravityField / WorldRenderer).

enum Kind {
	EMPTY,   ## Luft. Bewegt sich nicht, kann verdraengt werden.
	SOLID,   ## Bewegt sich nie, auch ohne Static-Flag (z.B. Eis).
	POWDER,  ## Faellt entlang der Gravitation, rutscht diagonal ab (Sand, Stein).
	LIQUID,  ## Wie POWDER, breitet sich zusaetzlich senkrecht zur Gravitation aus.
	GAS,     ## Wie LIQUID, aber ENTGEGEN der Gravitation (Auftrieb).
}

@export var id: int = 0
@export var display_name: String = ""
@export var color: Color = Color.MAGENTA
@export var grain: float = 0.05          ## Farbrauschen pro Zelle, rein optisch
@export var kind: Kind = Kind.SOLID
@export var density: float = 1.0         ## Dichteres verdraengt leichteres
@export var dispersion: int = 0          ## Zellen pro Schritt seitlich (Fluide)
@export var default_static: bool = false ## Vorgabe fuer das Per-Zelle-Static-Flag
## Reibung, 0 bis 1. Zwei Wirkungen:
##  - Wie lange sich das Material seitlich ausbreitet, bevor es zur Ruhe kommt.
##    Wasser (niedrig) laeuft weit, Lava (hoeher) bleibt eher liegen. Ohne das
##    schiebt sich eine stehende Fluessigkeitsoberflaeche endlos hin und her.
##  - Wie wahrscheinlich eine bereits ruhende Zelle von einer vorbeifallenden
##    Nachbarzelle wieder mitgerissen wird. Hohe Reibung = bleibt liegen.
@export_range(0.0, 1.0) var friction: float = 0.35
@export var selectable: bool = true      ## In der Toolbar anwaehlbar

# --- Thermik -----------------------------------------------------------------
@export var conductivity: float = 0.08   ## Anteil des Temperaturausgleichs pro Schritt
## Traegheit gegen Temperaturaenderung. Hoch = das Material haelt seine
## Temperatur lange. Lava braucht das, sonst waere sie nach wenigen Frames
## unter ihrer Erstarrungsschwelle und damit sofort wieder Stein.
@export var heat_capacity: float = 1.0
## Temperatur, mit der eine Zelle dieses Materials platziert wird. Damit sind
## Lava (heiss) und Eis (kalt) echte Waerme- bzw. Kaeltequellen ohne kuenstliche
## Emitter-Materialien - die Waermeleitung erledigt den Rest.
@export var default_temp: float = 20.0
## Optionale Dauerquelle, haelt die Zelle aktiv auf emit_temp. Von keinem der
## mitgelieferten Materialien benutzt, aber fuer eigene Erweiterungen da.
@export var emits_heat: bool = false
@export var emit_temp: float = 20.0
@export var emit_power: float = 0.0

## Aggregatzustands-FSM. Jeder Eintrag: { "above": float, "to": int }
## oder { "below": float, "to": int }. Optional zusaetzlich { "temp": float } -
## dann bekommt die Zelle beim Uebergang diese Temperatur. Erstarrende Lava
## braucht das: bliebe der Stein auf 700 Grad, wuerde daneben weiter Wasser
## verdampfen, ohne dass im Bild noch etwas Heisses zu sehen ist.
## Ausgewertet wird das direkt im Waermepass (Simulation._step_thermal()).
## Hysterese entsteht dadurch, dass Hin- und Rueckuebergang unterschiedliche
## Schwellen benutzen (Wasser friert bei 0, Eis taut erst bei +2).
@export var transitions: Array[Dictionary] = []

# --- Gravitation -------------------------------------------------------------
## Zellen mit grav_radius > 0 strahlen ein Gravitationsfeld in ihre Umgebung ab.
## Gewichtung faellt linear mit der Distanz auf 0 ab.
@export var grav_radius: int = 0
@export var grav_factor: float = 1.0     ## multiplikativ: 0 = blockt, 3 = verstaerkt, -1 = kehrt um
## Anteil des Radius mit voller Wirkung. Ohne Plateau waere ein rein linearer
## Abfall irrefuehrend: bei Faktor 0 waechst der Gravitationsbetrag dann wie
## d/r, ein "Blocker" mit Radius 44 haette also nur ~3 Zellen echte Wirkung.
## Mit Plateau wirkt das Feld voll bis grav_plateau * radius und rampt erst
## danach auf die Grundgravitation zurueck.
@export_range(0.0, 0.95) var grav_plateau: float = 0.65
@export var grav_add: Vector2 = Vector2.ZERO  ## additiv, z.B. fuer seitlichen "Wind"

func is_movable() -> bool:
	return kind == Kind.POWDER or kind == Kind.LIQUID or kind == Kind.GAS

func is_grav_source() -> bool:
	return grav_radius > 0
