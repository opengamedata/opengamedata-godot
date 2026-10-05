extends SceneTree
## Tests for the OGD logger.
##
## Run from the repo root with tests/capture_server.py running on port 8765, and port 8766 free:
## godot --headless --path . -s tests/test_ogd_log.gd

const LOGGER := preload("res://addons/opengamedata/ogd_log.gd")
const SERVER := "http://127.0.0.1:8765"
const EVENT_FIELDS := [
	"event_name",
	"session_sequence_index",
	"timestamp",
	"client_offset",
	"event_id",
	"game_time",
	"event_data",
]

var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_json()
	_test_offset()
	_test_session_and_timestamp()
	_test_query()
	_test_event()
	_test_schedule()
	await _test_upload()
	await _test_retry()
	await _test_paused()
	await _test_redirect()
	await _test_rejected()
	await _test_offline()
	await _test_no_answer()
	await _test_leave_tree()
	await _test_stall()
	await _test_bad_endpoint()
	print("all tests passed" if _failed == 0 else "%d tests failed" % _failed)
	quit(1 if _failed > 0 else 0)


func _check(test_name: String, ok: bool, detail := "") -> void:
	print(("PASS " if ok else "FAIL ") + test_name + ("  " + detail if detail else ""))
	if not ok:
		_failed += 1


func _new_logger() -> Node:
	var logger: Node = LOGGER.new()
	root.add_child(logger)
	return logger


func _test_json() -> void:
	var data := {"z": 1, "a": [1, 2.5, "x"], "n": null, "t": true, 3: "key"}
	var expected := '{"z":1,"a":[1,2.5,"x"],"n":null,"t":true,"3":"key"}'
	_check("objects keep their key order", LOGGER._to_json(data) == expected, LOGGER._to_json(data))
	_check("NaN and INF become null", LOGGER._to_json([NAN, INF, -INF]) == "[null,null,null]")
	_check(
		"packed arrays become arrays", LOGGER._to_json(PackedStringArray(["a", "b"])) == '["a","b"]'
	)
	_check("snapped floats keep 3 decimals", LOGGER._to_json(snappedf(12.3456, 0.001)) == "12.346")
	# Godot's parser accepts raw control characters, so also check that none are left
	var control := RegEx.create_from_string("[\\x00-\\x1f]")
	for text in ["a\vb", "tab\tnew\nline", 'quote " and \\', "Zoë 👋 日本 “q”", char(1) + char(31)]:
		var quoted: String = LOGGER._quote(text)
		var valid: bool = JSON.parse_string(quoted) == text and not control.search(quoted)
		_check("string round-trips through JSON: " + text.c_escape(), valid, quoted)
	var nested := {"a": 1}
	nested["self"] = nested
	nested["again"] = [nested]
	var json: String = LOGGER._to_json(nested)
	nested.clear()
	_check(
		"a container inside itself is written as null",
		json == '{"a":1,"self":null,"again":[null]}',
		json
	)


func _test_offset() -> void:
	var cases := {
		-210: "-03:30:00",
		330: "05:30:00",
		-300: "-05:00:00",
		0: "00:00:00",
		345: "05:45:00",
		-570: "-09:30:00",
		840: "14:00:00",
	}
	for minutes in cases:
		_check("offset %d minutes" % minutes, LOGGER._format_offset(minutes) == cases[minutes])
	# CI runs the tests in this zone, where Time.get_time_zone_from_system() gets the offset wrong
	if OS.get_environment("TZ") == "Pacific/Marquesas":
		_check("client offset in a -09:30 zone", LOGGER._client_offset() == "-09:30:00")


func _test_session_and_timestamp() -> void:
	var logger := _new_logger()
	var session := str(logger.get_session_id())
	var now := Time.get_datetime_dict_from_system()
	var date := "%02d%02d%02d" % [now["year"] % 100, now["month"], now["day"]]
	_check("session id has 17 digits", session.length() == 17, session)
	_check("session id starts with today's date", session.begins_with(date), session)
	var timestamp: String = LOGGER._timestamp()
	var pattern := RegEx.create_from_string("^\\d{4}-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d\\.\\d{3}Z$")
	_check("timestamp format", pattern.search(timestamp) != null, timestamp)
	var parsed := Time.get_unix_time_from_datetime_string(timestamp.substr(0, 19).replace(" ", "T"))
	_check("timestamp is UTC", absf(parsed - Time.get_unix_time_from_system()) < 2.0)
	logger.free()


func _test_query() -> void:
	var logger := _new_logger()
	logger.initialize("wake", "1.2.3 beta/x", 5, "research b")
	logger.set_user_id("u 1")
	logger.set_instance_id("inst&1")
	var expected := (
		"?game_id=WAKE&log_version=5&game_version=1.2.3%20beta%2Fx&source_version=1.2.3%20beta%2Fx"
		+ "&schema_version=1.0-alpha&session_id="
		+ str(logger.get_session_id())
		+ "&app_branch=research%20b&player_id=u%201&instance_id=inst%261"
	)
	_check("query string", logger._query == expected, logger._query)
	logger.set_user_id("")
	logger.set_instance_id("")
	_check(
		"cleared ids are left out",
		not "player_id" in logger._query and not "instance_id" in logger._query
	)
	logger.free()


func _test_event() -> void:
	var logger := _new_logger()
	logger.log("too_early")
	_check("events logged before initialize are dropped", logger._queue.is_empty())

	logger.initialize("wake", "1.0")
	# set in a different order than they're sent in
	logger.set_private_metadata({"class": "b"})
	logger.set_game_configuration({"hard_mode": true})
	logger.set_game_segment({"level": "reef-3"})
	logger.set_game_state({"money": 5})
	logger.set_player_history({"sessions": 2})
	logger.log("first", {"a": 1})
	logger.set_game_state({})
	logger.log_event(4200, "second")
	var first: Dictionary = JSON.parse_string(logger._queue[0]["json"])
	var second: Dictionary = JSON.parse_string(logger._queue[1]["json"])
	var expected_context := {
		"player_history": '{"sessions":2}',
		"game_state": '{"money":5}',
		"game_segment": '{"level":"reef-3"}',
		"game_configuration": '{"hard_mode":true}',
		"private_metadata": '{"class":"b"}',
	}
	var fields := EVENT_FIELDS + expected_context.keys() + ["platform"]
	_check("fields in Unity's order", first.keys() == fields, str(first.keys()))
	_check(
		"name-only events send event_id 0",
		first["event_id"] == 0 and first["event_data"] == '{"a":1}'
	)
	var context := {}
	for field in expected_context:
		context[field] = first.get(field)
	_check("context is sent as JSON strings", context == expected_context, str(context))
	var game_time := RegEx.create_from_string('"game_time":\\d+(\\.\\d{1,3})?,')
	var raw: String = logger._queue[0]["json"]
	_check("game_time has at most 3 decimals", game_time.search(raw) != null, raw)
	_check(
		"event codes are sent", second["event_id"] == 4200 and second["session_sequence_index"] == 1
	)
	_check(
		"event codes from the standard",
		OGDEvents.PlayerAction.POINT_AND_CLICK_SELECT_OBJECT == 4200
	)
	_check("empty event data is {}", second["event_data"] == "{}")
	_check(
		"cleared context is left out", not second.has("game_state") and second.has("game_segment")
	)
	var platform: Dictionary = JSON.parse_string(second["platform"])
	_check(
		"platform has os, device and engine",
		platform.keys() == ["os", "device", "engine"],
		str(platform)
	)
	logger.free()


func _test_schedule() -> void:
	var logger := _new_logger()
	logger.set_endpoint("http://127.0.0.1:9/log.php")
	logger.initialize("wake", "1.0")
	logger.log("first")
	var wait: int = logger._next_flush_msec - Time.get_ticks_msec()
	_check("the first event waits 0.2s", wait > 150 and wait <= 200, str(wait))
	for i in 5:
		logger._sending = true
		logger._on_request_completed(
			HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()
		)
	wait = logger._next_flush_msec - Time.get_ticks_msec()
	_check(
		"10s pause after 10 failure points",
		logger._failure_count == 6 and wait > 9900,
		"%d %d" % [logger._failure_count, wait]
	)
	logger.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check("losing focus sends right away", logger._sending)
	logger.free()
	var notifications := {
		"closing the window": Node.NOTIFICATION_WM_CLOSE_REQUEST,
		"going to the background": Node.NOTIFICATION_APPLICATION_PAUSED,
	}
	for event in notifications:
		logger = _new_logger()
		logger.set_endpoint("http://127.0.0.1:9/log.php")
		logger.initialize("wake", "1.0")
		logger.log("first")
		logger.notification(notifications[event])
		_check(event + " sends right away", logger._sending)
		logger.free()


func _test_upload() -> void:
	await _server("/reset")
	var logger := _new_logger()
	logger.set_endpoint(SERVER + "/log.php")
	logger.initialize("wake", "1.0")
	for i in 150:
		logger.log("event_%d" % i, {"text": "Zoë 👋 日本 \v" if i == 0 else "plain"})
	var first_session: int = logger.get_session_id()
	logger.reset_session_id()
	for i in 30:
		logger.log("new_session_%d" % i)
	logger.set_user_id("p2")
	for i in 5:
		logger.log("new_player_%d" % i)
	_check("everything sent", await _sent(logger))

	var stats := await _stats()
	var events: Array = stats["events"]
	var sizes := _sizes(stats)
	_check("server saw no errors", stats["errors"].is_empty(), str(stats["errors"]))
	_check("185 events arrived once each", events.size() == 185)
	_check(
		"batches split at 100 and at each session or player change",
		sizes == [100, 50, 30, 5],
		str(sizes)
	)
	var text: String = JSON.parse_string(events[0]["event_data"])["text"]
	_check("non-ASCII and control characters arrive intact", text == "Zoë 👋 日本 \v")
	_check("events keep their session", events[149]["query"]["session_id"] == str(first_session))
	_check("sequence restarts with the new session", events[150]["session_sequence_index"] == 0)
	_check(
		"player id only on events logged after it was set",
		not events[179]["query"].has("player_id")
	)
	_check("player id on later events", events[180]["query"].get("player_id", "") == "p2")
	logger.free()


func _test_retry() -> void:
	await _server("/reset")
	await _server("/control?fail=2&status=500")
	var logger := _new_logger()
	var delays := _record_delays(logger)
	logger.set_endpoint(SERVER + "/log.php")
	logger.initialize("wake", "1.0")
	for i in 3:
		logger.log("retry_%d" % i)
	while logger._failure_count == 0 and not logger._queue.is_empty():
		await process_frame
	for i in 2:
		logger.log("late_%d" % i)
	_check("sent after two server errors", await _sent(logger))
	var stats := await _stats()
	var requests: Array = stats["requests"]
	var sizes := _sizes(stats)
	_check("a failed batch is sent again unchanged", sizes == [0, 0, 3, 2], str(sizes))
	_check("each event arrived once", stats["events"].size() == 5 and stats["errors"].is_empty())
	_check(
		"an error response counts as one failure",
		delays.size() >= 2 and absi(delays[0] - 400) <= 2 and absi(delays[1] - 600) <= 2,
		str(delays)
	)
	if requests.size() == 4:
		var first_gap: float = requests[1]["time"] - requests[0]["time"]
		var second_gap: float = requests[2]["time"] - requests[1]["time"]
		_check(
			"retries wait for the backoff",
			first_gap >= 0.38 and second_gap >= 0.58,
			"%.3f %.3f" % [first_gap, second_gap]
		)
	logger.free()


func _test_paused() -> void:
	await _server("/reset")
	var logger := _new_logger()
	logger.set_endpoint(SERVER + "/log.php")
	logger.initialize("wake", "1.0")
	paused = true
	logger.log("paused")
	var sent: bool = await _sent(logger)
	paused = false
	_check("sent while the game is paused", sent)
	logger.free()


func _test_redirect() -> void:
	for status in [302, 307]:
		await _server("/reset")
		await _server("/control?fail=1&status=%d" % status)
		var logger := _new_logger()
		logger.set_endpoint(SERVER + "/log.php")
		logger.initialize("wake", "1.0")
		logger.log("redirected")
		_check("sent after a %d" % status, await _sent(logger))
		var sizes := _sizes(await _stats())
		_check("a %d redirect counts as a failure" % status, sizes == [0, 1], str(sizes))
		logger.free()


func _test_rejected() -> void:
	for status in [400, 408, 429]:
		await _server("/reset")
		await _server("/control?fail=1&status=%d" % status)
		var logger := _new_logger()
		logger.set_endpoint(SERVER + "/log.php")
		logger.initialize("wake", "1.0")
		logger.log("rejected")
		await _sent(logger)
		var stats := await _stats()
		var sizes := _sizes(stats)
		if status == 400:
			_check(
				"a batch rejected with a 400 is dropped, not retried",
				sizes == [0] and logger._queue.is_empty() and logger._failure_count == 0,
				str(sizes)
			)
		else:
			_check(
				"a %d is retried" % status,
				sizes == [0, 1] and stats["events"].size() == 1,
				str(sizes)
			)
		logger.free()


func _test_offline() -> void:
	await _server("/reset")
	var logger := _new_logger()
	var delays := _record_delays(logger)
	logger.set_endpoint("http://127.0.0.1:9/log.php")
	logger.initialize("wake", "1.0")
	logger.log("offline")
	await create_timer(1.5).timeout
	_check(
		"no response counts as two failures",
		not delays.is_empty() and absi(delays[0] - 600) <= 2,
		str(delays)
	)
	_check("the event is kept while offline", logger._queue.size() == 1)
	logger.set_endpoint(SERVER + "/log.php")
	_check("sent once the server is reachable", await _sent(logger))
	var stats := await _stats()
	_check("it arrived once", stats["events"].size() == 1 and stats["errors"].is_empty())
	logger.free()


func _test_no_answer() -> void:
	await _server("/reset")
	# takes the connection but never answers
	var silent := TCPServer.new()
	silent.listen(8766, "127.0.0.1")
	var logger := _new_logger()
	logger.set_endpoint("http://127.0.0.1:8766/log.php")
	logger.initialize("wake", "1.0")
	logger.log("no_answer")
	logger.flush()
	var timeout: int = logger._request_deadline_msec - Time.get_ticks_msec()
	_check("requests time out after 30s", timeout > 29900 and timeout <= 30000, str(timeout))
	Engine.time_scale = 0.0
	await create_timer(0.3, true, false, true).timeout
	var waited: bool = logger._sending
	logger._request_deadline_msec = Time.get_ticks_msec()
	await create_timer(0.1, true, false, true).timeout
	Engine.time_scale = 1.0
	_check(
		"a request with no answer times out while time is paused",
		(
			waited
			and not logger._sending
			and logger._failure_count == 2
			and logger._http.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED
		),
		"%s %s %d" % [waited, logger._sending, logger._failure_count]
	)
	logger._http.request_completed.emit(
		HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), PackedByteArray()
	)
	_check(
		"a late answer to a timed out request is ignored",
		logger._failure_count == 2 and logger._queue.size() == 1
	)
	silent.stop()
	logger.set_endpoint(SERVER + "/log.php")
	_check("sent after the timeout", await _sent(logger))
	var stats := await _stats()
	_check(
		"the timed out event arrived once",
		stats["events"].size() == 1 and stats["errors"].is_empty()
	)
	logger.free()


func _test_leave_tree() -> void:
	await _server("/reset")
	var logger := _new_logger()
	logger.set_endpoint(SERVER + "/log.php")
	logger.initialize("wake", "1.0")
	logger.log("moved")
	logger.flush()
	root.remove_child(logger)
	root.add_child(logger)
	_check("sent after leaving the tree mid-request", await _sent(logger))
	var stats := await _stats()
	_check(
		"the moved logger's event arrived once",
		stats["events"].size() == 1 and stats["errors"].is_empty()
	)
	# HTTPRequest can read the answer and then leave the tree before the logger gets it
	logger.log("answered")
	logger.flush()
	root.remove_child(logger)
	logger._http.request_completed.emit(
		HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), PackedByteArray()
	)
	root.add_child(logger)
	_check(
		"an answer read just before leaving the tree still counts",
		logger._queue.is_empty() and not logger._sending
	)
	logger.free()


func _test_stall() -> void:
	await _server("/reset")
	var logger := _new_logger()
	logger.set_endpoint(SERVER + "/log.php")
	logger.initialize("wake", "1.0")
	logger.log("stalled")
	logger.flush()
	var frames := 0
	while logger._http.get_http_client_status() != HTTPClient.STATUS_REQUESTING and frames < 300:
		frames += 1
		await process_frame
	# HTTPRequest sends the request on its next poll
	await process_frame
	# the game freezes past the deadline, while the answer arrives
	logger._request_deadline_msec = Time.get_ticks_msec() + 100
	OS.delay_msec(1500)
	_check("sent after a stall", await _sent(logger))
	var stats := await _stats()
	_check(
		"an answer that arrived during a stall isn't thrown away",
		frames < 300 and _sizes(stats) == [1] and stats["errors"].is_empty(),
		"%d frames, %s" % [frames, _sizes(stats)]
	)
	logger.free()


func _test_bad_endpoint() -> void:
	var logger := _new_logger()
	logger.set_endpoint("ftp://example.org/log.php")
	logger.initialize("wake", "1.0")
	logger.log("bad_endpoint")
	await create_timer(0.5).timeout
	_check("a bad URL counts as a failure", logger._failure_count > 0 and logger._queue.size() == 1)
	logger.free()


# the backoff delay the logger schedules after each response
func _record_delays(logger: Node) -> Array:
	var delays := []
	logger._http.request_completed.connect(
		func(_r, _c, _h, _b): delays.append(logger._next_flush_msec - Time.get_ticks_msec())
	)
	return delays


func _sent(logger: Node, timeout_msec := 15000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while (not logger._queue.is_empty() or logger._sending) and Time.get_ticks_msec() < deadline:
		await process_frame
	return logger._queue.is_empty()


func _sizes(stats: Dictionary) -> Array:
	var sizes := []
	for request in stats["requests"]:
		sizes.append(int(request["size"]))
	return sizes


func _server(path: String) -> void:
	var http := HTTPRequest.new()
	root.add_child(http)
	http.request(SERVER + path, PackedStringArray(), HTTPClient.METHOD_POST)
	await http.request_completed
	http.queue_free()


func _stats() -> Dictionary:
	var http := HTTPRequest.new()
	root.add_child(http)
	http.request(SERVER + "/stats")
	var response: Array = await http.request_completed
	http.queue_free()
	return JSON.parse_string(response[3].get_string_from_utf8())
