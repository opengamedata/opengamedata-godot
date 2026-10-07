extends Node
## Logs gameplay events to the Open Game Data servers, using the OGD Event Standard v1.0.
##
## Enabling the OpenGameData plugin adds this script as the [code]OGDLog[/code] autoload.
## Call [method initialize] once, then [method log] or [method log_event] for each event.

const DEFAULT_ENDPOINT := "https://ogdlogger.fielddaylab.wisc.edu/logger/log.php"

# flush timings in milliseconds, and failure counts, matching the Unity package
const FLUSH_DELAY := 200
const FLUSH_FAILURE_DELAY := 400
const REPEATED_FAILURE_DELAY := 200
const RECONNECT_DELAY := 10000
const ENDPOINT_FAILURE_COUNT_CAP := 10
const ENDPOINT_FAILURE_COUNT_RESET := 6

const REQUEST_TIMEOUT := 30000  # milliseconds
const MAX_BATCH_SIZE := 100
const FLUSH_NOTIFICATIONS := [
	NOTIFICATION_WM_CLOSE_REQUEST,
	NOTIFICATION_APPLICATION_FOCUS_OUT,
	NOTIFICATION_APPLICATION_PAUSED,
]

static var _control_characters := RegEx.create_from_string("[\\x01-\\x1f]")

var _app_id := ""
var _app_version := ""
var _log_version := 0
var _condition := ""
var _endpoint := DEFAULT_ENDPOINT
var _debug := false

var _session_id := 0
var _session_start_usec := 0
var _event_sequence := 0
var _user_id := ""
var _instance_id := ""
var _query := ""
# context that shouldn't change during a session goes in the query string, the rest with each event
var _session_context := {
	"game_configuration": "",
	"platform": "",
	"player_history": "",
}
var _context := {
	"game_state": "",
	"game_segment": "",
	"private_metadata": "",
}

# each event keeps the query string it was logged with, so a later reset doesn't relabel it
var _queue: Array[Dictionary] = []
var _batch_size := 0
var _sending := false
var _failure_count := 0
var _next_flush_msec := -1
var _request_deadline_msec := 0
var _last_process_msec := 0

var _http: HTTPRequest
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()
	_session_context["platform"] = _to_json(
		{
			"os": (OS.get_name() + " " + OS.get_version()).strip_edges(),
			"device": OS.get_model_name(),
			"engine": "Godot " + Engine.get_version_info()["string"],
		}
	)
	reset_session_id()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = HTTPRequest.new()
	# a followed redirect can turn the POST into a GET, which log.php answers with a 200
	_http.max_redirects = 0
	_http.accept_gzip = false
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	# after the game stalls (a hidden web tab, a suspended app), give an answer that's already
	# waiting time to be read before timing out
	if _sending and now - _last_process_msec > 1000:
		_request_deadline_msec = maxi(_request_deadline_msec, now + 1000)
	_last_process_msec = now
	# not HTTPRequest.timeout, which on Godot 4.3 never runs out while Engine.time_scale is 0
	if _sending and now >= _request_deadline_msec:
		_http.cancel_request()
		_on_request_completed(HTTPRequest.RESULT_TIMEOUT, 0, PackedStringArray(), PackedByteArray())
	elif _next_flush_msec >= 0 and now >= _next_flush_msec:
		flush()


func _notification(what: int) -> void:
	if what in FLUSH_NOTIFICATIONS:
		flush()
	elif what == NOTIFICATION_EXIT_TREE:
		# HTTPRequest cancels without emitting request_completed when it leaves the tree, unless
		# it already read the answer, so time the request out once the logger is back
		_request_deadline_msec = 0


## Sets the game's id and version. Call this once before logging any events.
func initialize(app_id: String, app_version: String, log_version := 0, condition := "") -> void:
	_app_id = app_id
	_app_version = app_version
	_log_version = log_version
	_condition = condition
	_refresh_query()


## Sends events to a different log.php, such as a testing endpoint.
## Use its final URL, since an upload can't go through a redirect.
func set_endpoint(endpoint := DEFAULT_ENDPOINT) -> void:
	_endpoint = endpoint


## Prints each request and response.
func set_debug(enabled: bool) -> void:
	_debug = enabled


## Sets the player id sent with every event. An empty string clears it.
func set_user_id(user_id: String) -> void:
	_user_id = user_id
	_refresh_query()


## Sets the instance id sent with every event. An empty string clears it.
func set_instance_id(instance_id: String) -> void:
	_instance_id = instance_id
	_refresh_query()


## Sets the player history, sent once per request. An empty Dictionary clears it.
func set_player_history(player_history: Dictionary) -> void:
	_set_session_context("player_history", player_history)


## Sets the game state sent with every event. An empty Dictionary clears it.
func set_game_state(game_state: Dictionary) -> void:
	_set_context("game_state", game_state)


## Sets where the player is in the game (level, quest, region), sent with every event.
## An empty Dictionary clears it.
func set_game_segment(game_segment: Dictionary) -> void:
	_set_context("game_segment", game_segment)


## Sets the game configuration, sent once per request. An empty Dictionary clears it.
func set_game_configuration(game_configuration: Dictionary) -> void:
	_set_session_context("game_configuration", game_configuration)


## Sets private metadata sent with every event. An empty Dictionary clears it.
func set_private_metadata(private_metadata: Dictionary) -> void:
	_set_context("private_metadata", private_metadata)


## Starts a new session, with a new session id, sequence index and game time.
func reset_session_id() -> void:
	_session_id = _new_session_id()
	_session_start_usec = Time.get_ticks_usec()
	_event_sequence = 0
	_refresh_query()


## Returns the current session id.
func get_session_id() -> int:
	return _session_id


## Logs an event without an event code, so it's sent with an event_id of 0.
func log(event_name: String, event_data := {}) -> void:
	log_event(0, event_name, event_data)


## Logs an event with its code from the OGD event standard.
func log_event(event_id: int, event_name: String, event_data := {}) -> void:
	if _app_id.is_empty():
		push_error("[OGDLog] Call initialize() before logging events")
		return

	var event := {
		"event_name": event_name,
		"session_sequence_index": _event_sequence,
		"timestamp": _timestamp(),
		"event_id": event_id,
		"game_time": snappedf((Time.get_ticks_usec() - _session_start_usec) / 1000000.0, 0.001),
		"event_data": _to_json(event_data),
	}
	_event_sequence += 1
	for field in _context:
		if not _context[field].is_empty():
			event[field] = _context[field]

	_queue.append({"query": _query, "json": _to_json(event)})
	if not _sending and _next_flush_msec < 0:
		_next_flush_msec = Time.get_ticks_msec() + FLUSH_DELAY


## Sends queued events now instead of waiting for the next scheduled flush.
func flush() -> void:
	if _sending or _queue.is_empty() or not is_node_ready():
		return
	_next_flush_msec = -1

	# a batch that failed is sent again unchanged, so events logged since then go in the next one
	if _batch_size <= 0:
		_batch_size = 1
		var limit := mini(_queue.size(), MAX_BATCH_SIZE)
		while _batch_size < limit and _queue[_batch_size]["query"] == _queue[0]["query"]:
			_batch_size += 1

	var events := PackedStringArray()
	for i in _batch_size:
		events.append(_queue[i]["json"])
	var url: String = _endpoint + _queue[0]["query"]
	var body := "data=" + Marshalls.utf8_to_base64("[" + ",".join(events) + "]").uri_encode()
	if _debug:
		print("[OGDLog] Sending %d events to %s" % [_batch_size, url])

	_sending = true
	_request_deadline_msec = Time.get_ticks_msec() + REQUEST_TIMEOUT
	var headers := PackedStringArray(["Content-Type: application/x-www-form-urlencoded"])
	var error := _http.request(url, headers, HTTPClient.METHOD_POST, body)
	# ERR_CANT_CONNECT still emits request_completed, other errors don't
	if error != OK and error != ERR_CANT_CONNECT:
		_on_request_completed(
			HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()
		)


func _on_request_completed(
	result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	# a request the logger already gave up on can still report back
	if not _sending:
		return
	_sending = false
	var answered := result == HTTPRequest.RESULT_SUCCESS
	var delivered := answered and response_code >= 200 and response_code < 300
	# sending a batch the server rejected again won't help, unless it timed out or was rate limited
	var rejected := (
		answered
		and response_code >= 400
		and response_code < 500
		and response_code not in [408, 429]
	)
	if delivered or rejected:
		if rejected:
			var warning := "[OGDLog] Dropped a batch the server rejected (status %d): %s"
			push_warning(warning % [response_code, body.get_string_from_utf8().left(200)])
		elif _debug:
			print("[OGDLog] Response: ", body.get_string_from_utf8())
		_queue = _queue.slice(_batch_size)
		_batch_size = 0
		_failure_count = 0
	else:
		if _debug:
			print("[OGDLog] Upload failed (result %d, status %d)" % [result, response_code])
		# no response at all (offline, timed out) counts double
		_failure_count += 2 if response_code == 0 else 1

	if _queue.is_empty():
		return
	if _failure_count == 0:
		flush()
	elif _failure_count >= ENDPOINT_FAILURE_COUNT_CAP:
		push_warning(
			"[OGDLog] Can't reach the logging server, retrying in %ds" % (RECONNECT_DELAY / 1000.0)
		)
		_failure_count = ENDPOINT_FAILURE_COUNT_RESET
		_next_flush_msec = Time.get_ticks_msec() + RECONNECT_DELAY
	else:
		var delay := FLUSH_FAILURE_DELAY + (_failure_count - 1) * REPEATED_FAILURE_DELAY
		_next_flush_msec = Time.get_ticks_msec() + delay


func _refresh_query() -> void:
	_query = "?game_id=" + _app_id.to_upper().uri_encode()
	_query += "&log_version=" + str(_log_version)
	# source_version mirrors game_version: this library only logs events the game itself produced
	_query += "&game_version=" + _app_version.uri_encode()
	_query += "&source_version=" + _app_version.uri_encode()
	_query += "&schema_version=1.0-alpha"
	_query += "&session_id=" + str(_session_id)
	if not _condition.is_empty():
		_query += "&condition=" + _condition.uri_encode()
	if not _user_id.is_empty():
		_query += "&player_id=" + _user_id.uri_encode()
	if not _instance_id.is_empty():
		_query += "&instance_id=" + _instance_id.uri_encode()
	for field in _session_context:
		if not _session_context[field].is_empty():
			_query += "&" + field + "=" + _session_context[field].uri_encode()


func _set_context(field: String, value: Dictionary) -> void:
	_context[field] = "" if value.is_empty() else _to_json(value)


func _set_session_context(field: String, value: Dictionary) -> void:
	_session_context[field] = "" if value.is_empty() else _to_json(value)
	_refresh_query()


func _new_session_id() -> int:
	var now := Time.get_datetime_dict_from_system()
	var date := (
		"%02d%02d%02d%02d%02d%02d"
		% [now["year"] % 100, now["month"], now["day"], now["hour"], now["minute"], now["second"]]
	)
	return int(date + "%05d" % _rng.randi_range(0, 99999))


# local time with its offset from UTC, e.g. 2026-10-06 18:55:00.123-05:00
static func _timestamp() -> String:
	var now := Time.get_unix_time_from_system()
	var seconds := floori(now)
	var msec := mini(floori((now - seconds) * 1000.0), 999)
	var offset := _utc_offset()
	var local := Time.get_datetime_string_from_unix_time(seconds + offset * 60, true)
	return local + ".%03d" % msec + _format_offset(offset)


# the offset from UTC in minutes, found by comparing local and UTC time, since
# Time.get_time_zone_from_system() is wrong for -HH:30 zones
static func _utc_offset() -> int:
	var local := Time.get_unix_time_from_datetime_dict(Time.get_datetime_dict_from_system())
	var utc := Time.get_unix_time_from_datetime_dict(Time.get_datetime_dict_from_system(true))
	return roundi((local - utc) / 60.0)


static func _format_offset(minutes: int) -> String:
	if minutes == 0:
		return "Z"
	var prefix := "-" if minutes < 0 else "+"
	minutes = absi(minutes)
	return "%s%02d:%02d" % [prefix, floori(minutes / 60.0), minutes % 60]


# JSON.stringify sorts keys and writes some control characters as invalid JSON
static func _to_json(value: Variant, parents := []) -> String:
	var type := typeof(value)
	if type == TYPE_NIL or type == TYPE_BOOL or type == TYPE_INT:
		return JSON.stringify(value)
	if type == TYPE_FLOAT:
		return JSON.stringify(value) if is_finite(value) else "null"
	if type != TYPE_DICTIONARY and type < TYPE_ARRAY:  # TYPE_ARRAY and up are the array types
		return _quote(str(value))

	# a Dictionary or Array inside itself is written as null, instead of recursing forever
	for parent in parents:
		if is_same(parent, value):
			return "null"
	parents.append(value)
	var items := PackedStringArray()
	if type == TYPE_DICTIONARY:
		for key in value:
			items.append(_quote(str(key)) + ":" + _to_json(value[key], parents))
	else:
		for item in value:
			items.append(_to_json(item, parents))
	parents.pop_back()
	if type == TYPE_DICTIONARY:
		return "{" + ",".join(items) + "}"
	return "[" + ",".join(items) + "]"


static func _quote(text: String) -> String:
	text = text.replace("\\", "\\\\").replace('"', '\\"')
	if not _control_characters.search(text):
		return '"' + text + '"'
	for code in range(1, 32):
		text = text.replace(char(code), "\\u%04x" % code)
	return '"' + text + '"'
