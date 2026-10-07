"""A stand-in for log.php that checks each request strictly and records the events it receives.

Run from the repo root: python tests/capture_server.py [port]

- POST /log.php decodes the body the way log.php does, checks the v1.0 fields, and records the events.
- GET /stats returns everything received so far as JSON.
- POST /control?fail=N&status=S makes the next N requests fail with status S. A 3xx redirects to /log.php.
- POST /reset clears everything.
"""
# import standard libraries
import base64
import json
import re
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List
from urllib.parse import parse_qs, urlsplit

TIMESTAMP     : re.Pattern = re.compile(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}(Z|[+-]\d\d:[0-5]\d)")
FIELDS        : List[str]  = ["event_name", "session_sequence_index", "timestamp", "event_id", "game_time", "event_data"]
CONTEXT       : List[str]  = ["game_state", "game_segment", "private_metadata"]
QUERY_CONTEXT : List[str]  = ["game_configuration", "platform", "player_history"]

_lock  : threading.Lock = threading.Lock()
_state : Dict[str, Any] = {}


def _reset() -> None:
    _state.update({"requests": [], "events": [], "errors": [], "seen": set(), "fail": 0, "fail_status": 500})


def _rejectConstant(name:str) -> None:
    raise ValueError(f"{name} isn't valid JSON")


def _checkRequest(query:Dict[str, List[str]], content_type:str, body:bytes) -> List[Dict[str, Any]]:
    """Decodes and checks one upload, raising ValueError on the first problem.

    :param query: The parsed query string.
    :type query: Dict[str, List[str]]
    :param content_type: The request's Content-Type header.
    :type content_type: str
    :param body: The raw request body.
    :type body: bytes
    :return: The decoded events.
    :rtype: List[Dict[str, Any]]
    """
    if content_type != "application/x-www-form-urlencoded":
        raise ValueError(f"Content-Type is {content_type!r}")
    params = {key: values[0] for key, values in query.items()}
    if params.get("schema_version") != "1.0-alpha" or not params.get("game_id") or params["game_id"] != params["game_id"].upper():
        raise ValueError(f"bad schema_version or game_id in {params}")
    if params.get("game_version") is None or params.get("source_version") != params["game_version"]:
        raise ValueError("source_version doesn't match game_version")
    if not re.fullmatch(r"\d{17}", params.get("session_id", "")) or not re.fullmatch(r"\d+", params.get("log_version", "")):
        raise ValueError(f"bad session_id or log_version in {params}")
    if "app_branch" in params or "platform" not in params:
        raise ValueError(f"app_branch sent, or platform missing, in {params}")
    for key in QUERY_CONTEXT:
        if key in params and not isinstance(json.loads(params[key], parse_constant=_rejectConstant), dict):
            raise ValueError(f"{key} isn't a JSON object: {params[key]}")

    form = parse_qs(body.decode("ascii"), strict_parsing=True)
    if list(form.keys()) != ["data"] or len(form["data"]) != 1:
        raise ValueError("body isn't a single data= field")
    text = base64.b64decode(form["data"][0], validate=True).decode("utf-8")
    events = json.loads(text, parse_constant=_rejectConstant)

    for event in events:
        keys = list(event.keys())
        if keys[:len(FIELDS)] != FIELDS or [key for key in keys[len(FIELDS):] if key not in CONTEXT]:
            raise ValueError(f"unexpected fields or order: {keys}")
        if keys[len(FIELDS):] != [key for key in CONTEXT if key in keys]:
            raise ValueError(f"context fields out of order: {keys}")
        if not TIMESTAMP.fullmatch(event["timestamp"]) or event["timestamp"].endswith(("+00:00", "-00:00")):
            raise ValueError(f"bad timestamp: {event}")
        # local time minus its offset has to be the current UTC time
        sent = datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00"))
        if abs((sent - datetime.now(timezone.utc)).total_seconds()) > 60:
            raise ValueError(f"timestamp isn't the current time: {event}")
        if type(event["session_sequence_index"]) is not int or type(event["event_id"]) is not int:
            raise ValueError(f"session_sequence_index and event_id must be ints: {event}")
        if type(event["game_time"]) not in (int, float) or event["game_time"] < 0:
            raise ValueError(f"bad game_time: {event}")
        for key in ["event_data"] + [key for key in CONTEXT if key in event]:
            if not isinstance(json.loads(event[key], parse_constant=_rejectConstant), dict):
                raise ValueError(f"{key} isn't a JSON object string: {event}")
        event["query"] = params
    return events


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, format:str, *args:Any) -> None:
        pass

    def _reply(self, status:int, text:str) -> None:
        data = text.encode("utf-8")
        self.send_response(status)
        if 300 <= status < 400:
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/log.php")
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        with _lock:
            stats = {key: value for key, value in _state.items() if key != "seen"}
            self._reply(200, json.dumps(stats, ensure_ascii=False))

    def do_POST(self) -> None:
        url = urlsplit(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with _lock:
            if url.path == "/reset":
                _reset()
                return self._reply(200, "OK")
            if url.path == "/control":
                params = parse_qs(url.query)
                _state["fail"] = int(params["fail"][0])
                _state["fail_status"] = int(params.get("status", ["500"])[0])
                return self._reply(200, "OK")

            request = {"time": time.monotonic(), "size": 0, "status": 200}
            _state["requests"].append(request)
            if _state["fail"] > 0:
                _state["fail"] -= 1
                request["status"] = _state["fail_status"]
                return self._reply(_state["fail_status"], "FAIL: test failure")
            try:
                events = _checkRequest(parse_qs(url.query), self.headers.get("Content-Type", ""), body)
            except Exception as error:
                _state["errors"].append(str(error))
                return self._reply(200, f"FAIL: {error}")
            for event in events:
                key = (event["query"]["session_id"], event["session_sequence_index"])
                if key in _state["seen"]:
                    _state["errors"].append(f"duplicate event {key}")
                _state["seen"].add(key)
            request["size"] = len(events)
            _state["events"].extend(events)
            return self._reply(200, f"SUCCESS: {len(events)} events")


def Main() -> None:
    """Serves until stopped."""
    _reset()
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ThreadingHTTPServer(("127.0.0.1", port), _Handler).serve_forever()


if __name__ == "__main__":
    Main()
