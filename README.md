# Sand Simulation

Falling-Sand-Simulation in Godot 4.7, GDScript. Eine Zelle ist ein Pixel. Drei
zusammenspielende Systeme: eine Bewegungs-FSM pro Zelle, eine
temperaturgetriebene Aggregatzustands-FSM und ein ortsabhaengiges
Gravitationsfeld.

![Screenshot](docs/screenshot.png)

## Zwei getrennte Aufloesungen

| | Aufloesung | Skalierung |
| --- | --- | --- |
| Spielwelt | 320 x 130 (SubViewport) | ganzzahlig hochskaliert, nearest |
| UI | native Fenstergroesse (1280 x 520) | gar nicht - 1:1 gerastert |

Die Spielwelt rendert in einen eigenen SubViewport und wird davon **ganzzahlig**
vergroessert. Nur ganzzahlig: jeder andere Faktor verteilt Weltpixel ungleich auf
Bildschirmpixel und macht das Bild unruhig. Die UI liegt darueber in der nativen
Aufloesung und wird nicht mitskaliert - deshalb ist der Text scharf statt
hochgerechnet.

Die Welt selbst ist mit **1024 x 576** Zellen (589 824) viel groesser als der
sichtbare Ausschnitt von 320 x 130. Man sieht also immer nur einen kleinen Teil
und scrollt.

## Starten

```bash
"D:/Projects/Godot/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64.exe" --path "D:/Projects/Godot/sandsimulation"
```

## Selbsttests

Benchmark, FSM- und Fliesstest laufen headless. Der Eingabetest braucht ein Fenster.

```bash
"D:/Projects/Godot/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe" --headless --path "D:/Projects/Godot/sandsimulation" -- --bench
```

```bash
"D:/Projects/Godot/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe" --headless --path "D:/Projects/Godot/sandsimulation" -- --fsmtest
```

```bash
"D:/Projects/Godot/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe" --headless --path "D:/Projects/Godot/sandsimulation" -- --flowtest
```

```bash
"D:/Projects/Godot/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe" --headless --path "D:/Projects/Godot/sandsimulation" -- --leveltest
```

```bash
"D:/Projects/Godot/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe" --headless --path "D:/Projects/Godot/sandsimulation" -- --displacetest
```

```bash
"D:/Projects/Godot/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe" --path "D:/Projects/Godot/sandsimulation" -- --inputtest
```

`--shot --frames=N` rendert N Frames und schreibt einen Screenshot.

## Steuerung

| Eingabe | Wirkung |
| --- | --- |
| Linke Maustaste | Material zeichnen (genau eine Zelle) |
| Rechte Maustaste | Radieren |
| Mittlere Maustaste ziehen | Ansicht verschieben |
| Pfeiltasten / WASD | Ansicht verschieben |
| Mausrad | Zoomen (1x, 2x, 3x, 4x, 6x, 8x) |
| Leertaste | Pause |
| N | Einzelschritt (bei Pause) |
| R | Zuruecksetzen |
| H | Waermetoenung an/aus |

Der Pinsel ist fest eine Zelle gross. Beim Ziehen wird zwischen den
Mauspositionen interpoliert, damit schnelle Bewegungen keine Luecken lassen.

Der Haken **statisch** setzt das Static-Flag pro Zelle: darauf wirkt keine
Schwerkraft, egal was das lokale Gravitationsfeld sagt. Der Steinboden der Demo
ist genau so gebaut. Das Flag ist bewusst *pro Zelle* und nicht pro Material -
derselbe Stein kann unverrueckbarer Boden oder fallendes Geroell sein.

## Materialien

| Material | Art | Reibung | Besonderheit |
| --- | --- | --- | --- |
| Sand | Pulver | 0,55 | Bildet Schuettkegel |
| Wasser | Fluessigkeit | 0,05 | Gefriert bei 0 C, siedet bei 100 C, laeuft weit |
| Stein | Pulver, statisch | 0,90 | Schmilzt ueber 950 C zu Lava |
| Eis | Feststoff, statisch | 0,90 | Wird mit -60 C platziert, taut ueber 2 C |
| Dampf | Gas | 0,02 | Steigt auf, kondensiert unter 95 C |
| Lava | Fluessigkeit | 0,50 | 1200 C beim Platzieren, erstarrt unter 700 C zu Stein |
| Grav-Blocker | Pulver, statisch | 0,80 | Hebt die Schwerkraft im Umkreis auf |
| Grav-Verstaerker | Pulver, statisch | 0,80 | Verdreifacht die Schwerkraft im Umkreis |
| Grav-Umkehrer | Pulver, statisch | 0,80 | Dreht die Schwerkraft im Umkreis um |

Waerme und Kaelte kommen aus echten Materialien statt aus abstrakten Quellen:
Lava bringt ihre 1200 Grad mit, Eis seine -60 Grad, und die Waermeleitung macht
daraus von selbst Waerme- und Kaeltequellen. Beide verbrauchen sich dabei -
Lava erstarrt zu Stein, Eis taut zu Wasser.

## Aufbau

| Datei | Verantwortung |
| --- | --- |
| `scripts/materials/material_def.gd` | Eigenschaften eines Materialtyps (Resource) |
| `scripts/materials/material_db.gd` | Registry aller Materialtypen |
| `scripts/sim/sim_world.gd` | Zell- und Chunk-Arrays, Zugriff, Aufwachlogik |
| `scripts/sim/simulation.gd` | Simulationsschritt: Bewegung, Waerme, Zustandswechsel |
| `scripts/sim/gravity_field.gd` | Backt das Gravitationsfeld aus abstrahlenden Zellen |
| `scripts/render/world_renderer.gd` | Grid -> Textur, nur geaenderte Bereiche |
| `scripts/ui/toolbar.gd` | Materialauswahl, Static-Flag |
| `scripts/main.gd` | SubViewport, Kamera, Eingabe, HUD, Selbsttests |

Ein Materialtyp existiert genau einmal als Objekt, nie einmal pro Pixel. Das
Grid speichert nur die numerische id in einem `PackedByteArray`.

## Die drei Systeme

**Bewegungs-FSM (pro Zelle).** Zustaende `REST`, `FALLING`, `SLIDING`. Ein
Partikel probiert der Reihe nach: Hauptrichtung der lokalen Gravitation, dann
die beiden Diagonalen, dann - bei Fluiden und Gasen - senkrecht dazu. Gelingt
nichts, geht es nach `REST`. Der Zustand ist nicht nur Deko: ruhende Regionen
lassen ihren Chunk einschlafen, und schlafende Chunks kosten null.

**Aggregatzustands-FSM (pro Materialtyp).** Ein zweites Grid haelt die
Temperatur. Waerme leitet zwischen Nachbarn, gewichtet mit Leitfaehigkeit und
Waermekapazitaet. Uebergaenge sind in `MaterialDef.transitions` deklariert und
werden direkt im Waermepass ausgewertet - Material und neue Temperatur liegen
dort ohnehin vor, ein zweiter Durchlauf ueber dieselben Zellen kostete gemessen
3,4 ms pro Frame. Hysterese verhindert Flackern: Wasser gefriert bei 0 Grad, Eis
taut erst bei +2; Wasser siedet bei 100, Dampf kondensiert erst bei 95; Lava
erstarrt bei 700, Stein schmilzt erst bei 950.

Ein Uebergang kann zusaetzlich eine Zieltemperatur setzen (`"temp"` im
Transition-Eintrag). Lava nutzt das: erstarrter Stein springt auf Normal-
temperatur. Sonst bliebe er bei 700 Grad stehen und wuerde daneben weiter
Wasser verdampfen, ohne dass im Bild noch etwas Heisses zu sehen waere - der
Spieler saehe Dampf ohne erkennbare Ursache. Im `--fsmtest` sinkt die
Dampfmenge jetzt sichtbar mit der schrumpfenden Lava (57 -> 42 -> 26 -> 16 ->
10 -> 8), waehrend der Stein von 0 auf 138 Zellen waechst.

**Gravitationsfeld.** Materialien mit `grav_radius > 0` strahlen ein Feld ab.
Ein Blocker (Faktor 0) hebt die Schwerkraft auf, ein Verstaerker (3) erhoeht
sie, ein Umkehrer (-1) dreht sie um. Das Feld wirkt voll bis `grav_plateau *
radius` und rampt erst danach zurueck - ohne dieses Plateau haette ein Blocker
mit Radius 44 nur rund drei Zellen echte Wirkung, weil ein rein linearer Abfall
den Betrag wie `d/r` wachsen laesst.

## Verdraengung: wer darf durch wen hindurch?

Verdraengt wird **ausschliesslich in Fluiden**, und die Richtung entscheidet:

- Wer **mit** der Gravitation faellt, schiebt sich durch **leichtere** Fluide.
  Sand sinkt durch Wasser, Stein sinkt durch Wasser, Wasser schiebt Dampf weg.
- Wer **gegen** sie steigt - also Gase, deren Auftrieb die Richtung umdreht -
  schiebt sich durch **schwerere** Fluide. Eine Dampfblase unter Wasser tauscht
  mit dem Wasser darueber und steigt auf, statt bis zum Kondensieren
  festzustecken.

**Feste Materialien werden nie verdraengt.** Pulver wie Sand und Stein ebenso
wie echte Feststoffe bleiben aufeinander liegen, egal wie schwer das Material
darueber ist. Ein Kornhaufen ist ein Gefuege, kein Bad: Lava laeuft ueber einen
Sandhaufen statt hindurch, und ein Steinbrocken sinkt nicht darin ein. Auf den
Verursacher kommt es nicht an, nur auf das, was verdraengt werden soll -
`Simulation._can_displace()` ist entsprechend kurz.

Zweite Regel: **verdraengt wird nur im ersten Schritt einer Bewegung.** Eine
Zelle, die mehrere leere Felder weit gefallen ist, tauscht nicht mit dem
Material am Ende ihrer Bahn - sonst landet dieses Material an ihrer
Startposition, also mitten in der Luft. Genau dadurch entstanden beim Lavafall
einzelne Sandkoerner im Nichts. Verdraengung ist nur zwischen direkten Nachbarn
sinnvoll.

`--displacetest` prueft das mit Saeulenprofilen statt mit Summen - Summen ueber
Rechtecke haben hier dreimal Fehlalarm ausgeloest, weil sie Material mitzaehlten,
das seitlich am Messfenster vorbeigelaufen war:

| Fall | Erwartung | Ergebnis |
| --- | --- | --- |
| Lava auf Sandbett | liegt oben auf | 0 fluessige Lava und 0 Steinkoerner unter der Sandoberflaeche |
| Sand in Wasser | sinkt auf den Grund | Sand bei y 380-399, Wasser darueber ab y 336 |
| Lava faellt auf Sandhaufen | keine Koerner in der Luft | 0 schwebende Koerner, Sandmenge exakt erhalten |
| Dampfblase unter Wasser | steigt auf | oberste Zelle steigt genau 1 Zelle pro Frame, 388 -> 328 in 60 Frames |

Typisches Saeulenprofil nach dem Test: `LAVA:4 stein:1 SAND:20 stein:24` - Lava
und ihre Erstarrungskruste liegen auf dem Sand, nichts steckt darin.

### Auch das Verdraengte zaehlt nur einmal

Der Generationszaehler hat urspruenglich nur den Verursacher einer Bewegung
geschuetzt, nicht die Zelle, die dabei verdraengt wurde. Dadurch konnte
dieselbe Zelle in einem einzigen Frame mehrfach weitergereicht werden: jede
nachfallende Wasserzelle ratschte eine Dampfblase eine weitere Stufe hoch, und
die Blase legte eine ganze Wassersaeule in einem Frame zurueck - gemessen 88
Zellen statt einer.

Seit die Bedingung `gens[ni] != gen_now` auch fuer das Ziel gilt, bewegt sich
jede Zelle hoechstens einmal pro Frame, egal ob aus eigenem Antrieb oder weil
sie geschoben wurde. Der Aufstieg ist danach exakt linear mit einer Zelle pro
Frame. Der Fehler betraf nicht nur Gase - auch Wasser unter fallendem Sand
wurde so mehrfach pro Frame verschoben.

## Reibung und Ruhezustand

`MaterialDef.friction` (0 bis 1) steuert, wann eine Zelle liegen bleibt und wann
sie wieder losgeht.

**Gezaehlt werden Richtungswechsel, nicht Schritte.** Jede Fluessigkeitszelle
merkt sich ihre letzte seitliche Fliessrichtung und probiert sie zuerst wieder.
Laeuft sie weiter in dieselbe Richtung, passiert nichts - sie darf beliebig weit
fliessen. Erst wenn sie *umkehrt*, zaehlt ein Zaehler hoch; nach der von der
Reibung bestimmten Zahl an Wechseln (Wasser rund 29, Lava rund 16) hoert sie
auf, seitlich auszuweichen. Faellt die Zelle - auch nur diagonal -, wird der
Zaehler samt Richtungsgedaechtnis geloescht.

Das ist der entscheidende Unterschied zu einer Begrenzung der *Strecke*: eine
Fluessigkeit, die stetig zum tiefsten Punkt laeuft, kehrt dabei nie um und wird
nie gebremst. Nur wer zwischen zwei gleichwertigen Lagen hin und her pendelt,
kommt zur Ruhe. Eine Streckenbegrenzung liess Wasser dagegen mitten im Fliessen
als Haufen stehen, obwohl weiter aussen noch Platz war.

Das settle-Byte pro Zelle traegt beides: Bit 0-5 die Zahl der Wechsel, Bit 6 ob
eine Richtung gemerkt ist, Bit 7 welche.

**Mitgerissen werden.** Ruhende Zellen werden gar nicht mehr simuliert - das ist
der groesste Einzelposten der Ersparnis. Aufgeweckt werden sie auf zwei Wegen:

- Entsteht daneben ein Loch, werden *alle* ruhenden Nachbarn geweckt. Ohne
  Reibungswurf: fehlende Unterlage ist keine Frage der Reibung.
- Kommt eine Zelle vorbei, zieht sie an den ruhenden Zellen *neben ihrer Bahn*.
  Ob die mitgehen, entscheidet ein Wurf gegen deren Reibung. Sand (0,55) wird
  nur manchmal mitgerissen und behaelt dadurch stabile Boeschungen, Wasser
  (0,05) fast immer.

Ein geweckter Nachbar behaelt seinen Wechselzaehler. Er darf also wieder fallen,
faengt aber nicht erneut an, endlos seitlich zu schaukeln.

### Wen betrifft das?

Nur Materialien mit `dispersion > 0` durchlaufen den seitlichen Ausweichschritt.
`--leveltest` prueft alle vier Faelle:

| Material | Art | Erwartung | Ergebnis |
| --- | --- | --- | --- |
| Wasser | Fluessigkeit | flacher Spiegel | 300 von 300 Spalten belegt, Hoehe 13-15, **0 Ausreisser**, zur Ruhe gekommen |
| Lava | Fluessigkeit | fliesst weg, erstarrt dabei | von 40 auf 286 Spalten gelaufen |
| Dampf | Gas | breitet sich unter der Decke aus | von 30 auf 160 Spalten |
| Sand | Pulver (`dispersion = 0`) | Schuettkegel, KEIN Spiegel | Kegel erhalten, Hoehe 1-88 |

Pulver - Sand, Stein und die Gravitationsmaterialien - haben `dispersion = 0`
und sind damit gar nicht betroffen. Das ist auch richtig so: ein Schuettkegel
soll stehen bleiben. Die Gegenprobe im Test stellt sicher, dass sich das nicht
versehentlich mitaendert.

Bei Lava waere ein flacher Spiegel das falsche Ziel: sie erstarrt von vorne weg
zu Stein und friert ihre Form dabei ein. Geprueft wird deshalb nur, dass sie
ueberhaupt wegfliesst statt an der Quelle liegen zu bleiben.

## Neues Material hinzufuegen

Eine Konstante, `COUNT` erhoehen und ein Eintrag in
`scripts/materials/material_db.gd` - sonst nichts. Toolbar, Renderer, Simulation
und Gravitationsfeld lesen alles aus den `MaterialDef`-Eigenschaften.

```gdscript
const OEL := 10
const COUNT := 11

_defs[OEL] = _mk(OEL, "Oel", Color(0.30, 0.24, 0.14), {
    "kind": MaterialDef.Kind.LIQUID, "density": 850.0, "dispersion": 4,
    "conductivity": 0.10, "heat_capacity": 2.0,
})
```

Dichte 850 < Wasser 1000 heisst automatisch: Oel schwimmt oben.

Eine neue *Eigenschaft* braucht ein `@export` in `material_def.gd`, einen
Default, und die Auswertung dort wo sie wirkt. Liegt sie im Schleifenkern von
Bewegung, Waerme oder Renderer, gehoert sie zusaetzlich in die flachen
Lookup-Arrays (`Simulation._build_lookups()` bzw. `WorldRenderer.setup()`).

## Performance

Gemessen auf diesem Rechner, 1024 x 576 Zellen, Godot 4.7 headless
(`-- --bench`), Werte pro Simulationsschritt:

| Szenario | Median | p95 |
| --- | --- | --- |
| Ruhe (alles gesetzt, nichts bewegt sich) | 0,06 ms | 0,06 ms |
| Typische Nutzung (Wasser + Lava + Gravitation) | 20,0 ms | 41,5 ms |
| Stresstest (Grossblock Sand + Wasser in freiem Fall) | 128,4 ms | 196,9 ms |

Im laufenden Spiel, nachdem sich die Demo-Szene gesetzt hat: 60 fps bei
5,3 ms Simulation und 3,2 ms Rendering, 3 von 144 Chunks aktiv.

Das grosszuegige Umkehr-Budget kostet: Fluessigkeiten schwappen laenger, bevor
sie liegen bleiben, und das schlaegt in den bewegten Szenarien mit rund zehn
Prozent zu Buche. Der Gegenwert ist ein wirklich flacher Wasserspiegel statt
eines Haufens - mit einem knapperen Budget bleibt Wasser mitten im Fliessen
stehen. Sobald sich eine Szene gesetzt hat, kostet sie ohnehin fast nichts.

Was den Unterschied macht, in der Reihenfolge der gemessenen Wirkung:

- **Schlafende Chunks und Dirty-Rects.** Ein wacher Chunk wird nur innerhalb des
  Rechtecks simuliert, in dem sich wirklich etwas geaendert hat, plus eine Zelle
  Rand. Ruhe: 175 ms -> 0,05 ms.
- **Nur den sichtbaren Ausschnitt und nur geaenderte Bereiche zeichnen.**
  Rendering: 17,2 ms -> 1,6 ms. Der groesste Einzelposten war dabei nicht der
  Texturupload, wie zuerst vermutet, sondern Property-Zugriffe auf die
  MaterialDef-Resource im Zeichenkern.
- **Distanztransformation statt Kreisstempel** im Gravitationsfeld. Vorher pro
  Quellzelle ein Radius-Kreis, O(Quellen x Flaeche): 98 ms fuer einen
  10x10-Block. Jetzt zwei Chamfer-Durchlaeufe ueber das Einflussrechteck,
  O(Flaeche): 6,5 ms, unabhaengig von der Quellenzahl.
- **Flache Lookup-Arrays statt Resource-Properties** in allen Schleifenkernen.
- **Lokale Aliase auf die Packed-Arrays.** In GDScript teilen sich lokale Aliase
  und Member denselben Puffer - ein Alias forkt beim Schreiben *nicht*, beide
  Seiten sehen dieselben Daten (nachgemessen). Ein Member-Zugriff kostet dabei
  das 2,75-fache eines lokalen Zugriffs.

Wenn mehr noetig ist, liegt der naechste Schritt nicht in weiterer
GDScript-Optimierung, sondern im Wechsel der Sprache: `SimWorld` und
`Simulation` sind die einzigen Stellen, die Zellen anfassen, und lassen sich
geschlossen nach C# oder als GDExtension portieren, ohne dass Renderer, UI oder
Materialdefinitionen sich aendern.

## Behobener Fehler: haengenbleibendes Material

Bei einer Bewegung *innerhalb* eines Chunks wurde nur die Quellzelle in das
Dirty-Rect eingetragen, nicht das Ziel. Solange ganze Chunks gescannt wurden,
war das egal. Mit Dirty-Rects nicht mehr: das Dirty-Rect ist eine Bounding-Box
mit einer Zelle Rand, und Wasser springt bis zu `dispersion` (5) Zellen weit.
Material landete ausserhalb des simulierten Rechtecks und blieb dort stehen -
die Region schlief ein, obwohl noch etwas in der Luft hing.

`--flowtest` deckt das ab und meldet ausdruecklich den Fehlerfall: Material in
der Luft, waehrend niemand mehr simuliert wird. Ohne den Fix bleiben dauerhaft
14 Zellen haengen und die Welt schlaeft komplett ein.

Beim Einbau der Reibung ist derselbe Fehler in anderer Form zurueckgekommen: ein
seitlicher Ausweichschritt kann ueber einem Loch enden, und eine dabei sofort auf
`REST` gesetzte Zelle blieb dort in der Luft stehen. Seitliche Schritte enden
deshalb nie direkt im Ruhezustand - die Bremse ist allein der Ruhezaehler.

## Weg zur unendlichen Welt

Die Welt ist in Chunks von 64 x 64 organisiert und alle Iteration laeuft
chunkweise. Simulation, Renderer und UI greifen ausschliesslich ueber `idx()`,
`in_bounds()`, `set_cell()` und `wake_at()` zu; feste Weltgrenzen stehen nur in
`sim_world.gd`. Fuer Streaming muss das Backing - die flachen Arrays - durch
eine Chunk-Map ersetzt werden, plus Laden und Entladen am Rand.

## Bekannte Grenzen

- Fluessigkeiten brauchen Zeit zum Einebnen: im Spiegeltest sind es rund 3000
  Frames, bis 4000 Wasserzellen ueber 300 Spalten flach liegen. Sie kommen an,
  aber nicht sofort.
- Ein Wasserspiegel, der von zwei Seiten gegen ein Hindernis pendelt, kann nach
  rund 29 Umkehrungen stehen bleiben, bevor er ganz ausgeglichen ist. Die
  Stellschraube ist `friction` von Wasser bzw. die Zuordnung Reibung zu
  Umkehr-Budget in `Simulation._build_lookups()`.
- Bewegung ist auf hoechstens eine Zelle pro Frame pro Zelle begrenzt
  (`MAX_STEPS` erlaubt bei verstaerkter Gravitation bis zu vier).
- Die Waermeleitung laeuft nur jeden dritten Frame (`THERMAL_INTERVAL`).
- Thermisch aktive Chunks werden ganzflaechig neu gezeichnet, weil die
  Waermetoenung sich ueber die ganze Flaeche aendern kann.
- Keine Latentwaerme: Schmelzen und Erstarren kosten keine Energie.
- Lava unter Wasser ist ein Dauerlaeufer: sie verdampft laufend Wasser, der
  Dampf steigt auf und kondensiert oben wieder. Das haelt viele Chunks wach und
  ist mit rund 18 fps das teuerste, was die Demo-Szene zu bieten hat.
- Lava (1200 C beim Platzieren) liegt ueber der Schmelzschwelle von Stein
  (950 C). Sie frisst sich deshalb mit der Zeit durch duenne Steinboeden. Das
  ist eine bewusste Regel, faellt aber leicht als Fehler auf - wer es nicht will,
  setzt die Schwelle in `material_db.gd` bei Stein hoeher.
