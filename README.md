# opengamedata-godot

A Godot addon for logging gameplay events to OpenGameData's servers, using the OGD Event Standard v1.0.

## Version Log

1. Initial version

## Setup

Requires Godot 4.3 or newer. GDScript only, so it works in every export, including the web.

1. Copy `addons/opengamedata` into your project's `addons` folder.
2. Enable **OpenGameData** under Project > Project Settings > Plugins. This adds the `OGDLog` autoload.

## Logging

Call `initialize` once, before logging any events:

```gdscript
OGDLog.initialize("MY_GAME", "1.2.0")
```

- `app_id`: the game's id in the database (ex. "AQUALAB")
- `app_version`: the current version of the game
- `log_version` (optional): the version of the game's logging, as an int. Defaults to 0.
- `app_branch` (optional): the branch of the game, for games running more than one version at once

### Events

```gdscript
OGDLog.log("open_map")
OGDLog.log_event(OGDEvents.PlayerAction.POINT_AND_CLICK_SELECT_OBJECT, "select_crate", {"crate": 3})
```

`log_event` takes the event's code from the OGD event standard first. `OGDEvents` has every code in the standard, with
one enum per category. It's generated from the standard in ogd-standards, so don't edit `ogd_events.gd` by hand.
Game-specific events can use a code from the `X900`-`X999` range of any block, or from the `9000` block. Events logged
with `log` are sent with an `event_id` of `0`.
Event data is a Dictionary, and is sent as JSON.

### Game State and Other Context

These are attached to every event until they change. Each takes a Dictionary, and an empty Dictionary clears it.

```gdscript
OGDLog.set_game_state({"money": 120})
OGDLog.set_game_segment({"level": "reef-3"})
OGDLog.set_player_history({"games_played": 4})
OGDLog.set_game_configuration({"difficulty": "hard"})
OGDLog.set_private_metadata({"classroom": "7b"})
```

### Sessions and Players

A session starts when the game starts. `OGDLog.reset_session_id()` starts a new one, with a new session id, and the
sequence index and game time starting from 0 again. `OGDLog.set_user_id(id)` and `OGDLog.set_instance_id(id)` are
sent with every event logged after they're set. Events already waiting to be sent keep the session and ids they were
logged with.

### Sending

Events are sent in batches of up to 100, starting 0.2 seconds after the first one is logged. If a batch fails, it's
sent again after a growing delay, and after repeated failures the logger waits 10 seconds before trying again. The
timings match the Unity package. A batch the server rejects with a 4xx status (other than 408 or 429) is dropped
instead, since sending it again won't help. `OGDLog.flush()` sends whatever is waiting right away, and the logger calls it when
the game loses focus or goes to the background. By default, closing the window quits the game in the same frame, so
anything not sent yet is lost. To give it time to send, call `get_tree().set_auto_accept_quit(false)` and quit a moment
after `NOTIFICATION_WM_CLOSE_REQUEST`.

## Schema Version

This addon only sends the v1.0 event schema, as `schema_version=1.0-alpha`. The production `log.php` doesn't accept
v1.0 yet, so until it does, point the logger at the testing endpoint:

```gdscript
OGDLog.set_endpoint("https://t-v3-t---ogd-api-logger-test-3rlcoyes6a-uc.a.run.app/log.php")
```

Use the endpoint's final URL. The logger doesn't follow redirects, and in web exports, where the browser follows them
instead, a redirect can turn the upload into a GET without its data.

## Platform Notes

- **Android:** enable the Internet permission in the export preset.
- **macOS:** if the export preset enables App Sandbox, also enable its network client entitlement.
- **Web:** browsers pause the game in background tabs, so events logged just before a tab is hidden are sent once
it's visible again, and are lost if the tab is closed first. `log.php` allows requests from any origin.

## Debugging

`OGDLog.set_debug(true)` prints each request and response.

## Testing

The tests need Python 3 and Godot 4.3 or newer. From the repo root:

```
python tests/capture_server.py 8765 &
godot --headless --path . --import
godot --headless --path . -s tests/test_ogd_log.gd
```

`tests/capture_server.py` stands in for `log.php`: it decodes every request the same way, checks each v1.0 field,
and records what it received. `example/main.tscn` is a small scene that logs a button click.

## Removal

Disable the plugin, then delete `addons/opengamedata`.
