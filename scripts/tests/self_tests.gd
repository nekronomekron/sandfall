class_name SelfTests
extends RefCounted

## Verteilt die Startparameter auf die Selbsttests.
##
## Zwei Sorten:
## [br]- HEADLESS-Suiten rechnen auf einer eigenen Simulation und brauchen
##   weder Fenster noch Renderer. Sie uebernehmen die Kontrolle vollstaendig.
## [br]- Die BILDSCHIRM-Tests pruefen genau den Spielbildschirm und laufen
##   deshalb neben der normalen Schleife mit.

const FRAMES_PREFIX := "--frames="
const DEFAULT_SHOT_FRAMES := 90


## Wird als Erstes aus [method Main._ready] gerufen.
##
## Liefert [code]true[/code], wenn ein Selbsttest die Kontrolle uebernommen hat
## und die normale Spielschleife NICHT starten darf.
static func take_over(main: Main) -> bool:
	var arguments := OS.get_cmdline_user_args()

	if _has(arguments, "--bench") or OS.get_cmdline_args().has("--bench"):
		return _run_headless(main, BenchmarkTest.run)
	if _has(arguments, "--fsmtest"):
		return _run_headless(main, PhaseTest.run)
	if _has(arguments, "--flowtest"):
		return _run_headless(main, FlowTest.run)
	if _has(arguments, "--leveltest"):
		return _run_headless(main, LevelTest.run)
	if _has(arguments, "--displacetest"):
		return _run_headless(main, DisplacementTest.run)

	if _has(arguments, "--inputtest"):
		main.add_child(InputTest.new(main))
	elif _has(arguments, "--shot"):
		main.add_child(ScreenshotTest.new(main, _shot_frames(arguments)))
	return false


## Legt die Spielschleife still und laesst die Suite auf einer eigenen
## Simulation rechnen. Die UI-Knoten muessen mit abgeschaltet werden - sie
## greifen in ihrem [method Node._process] auf den Renderer zu, den es hier
## bewusst nicht gibt.
static func _run_headless(main: Main, suite: Callable) -> bool:
	main.set_process(false)
	main.hud.set_process(false)
	main.paint_tool.set_process(false)
	suite.call(main)
	main.get_tree().quit()
	return true


static func _has(arguments: PackedStringArray, flag: String) -> bool:
	return arguments.has(flag)


static func _shot_frames(arguments: PackedStringArray) -> int:
	for argument in arguments:
		if argument.begins_with(FRAMES_PREFIX):
			return int(argument.substr(FRAMES_PREFIX.length()))
	return DEFAULT_SHOT_FRAMES
