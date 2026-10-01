extends Control

var _clicks := 0


func _ready() -> void:
	OGDLog.set_endpoint("https://t-v3-t---ogd-api-logger-test-3rlcoyes6a-uc.a.run.app/log.php")
	OGDLog.set_debug(true)
	OGDLog.initialize("OGD_GODOT_EXAMPLE", "0.1.0")
	OGDLog.set_game_segment({"level": "example"})


func _on_button_pressed() -> void:
	_clicks += 1
	OGDLog.log("button_clicked", {"clicks": _clicks})
