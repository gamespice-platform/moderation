extends Node

## The SQL store against a real database, through GameSpice SQL's gateway.
##
## The self-test proves which statements the store sends; this proves a database accepts
## them, in all three dialects. Run by GameSpice SQL's runner, which starts a gateway per
## dialect and sets GS_SQL_URL, GS_SQL_DIALECT and GS_SQL_TOKEN_FILE:
##
## [codeblock]
## ../gs-sql/tools/test_live.sh . res://examples/moderation_sql_live.tscn
## [/codeblock]

const CHECKS := 10

var _passed := 0
var _failed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)

	var dialect := GSSqlDialect.from_name(OS.get_environment("GS_SQL_DIALECT"))
	var made := GSSql.from_config({
		"driver": "gateway",
		"url": OS.get_environment("GS_SQL_URL"),
		"dialect": GSSqlDialect.name_of(dialect),
		"token": FileAccess.get_file_as_string(OS.get_environment("GS_SQL_TOKEN_FILE")).strip_edges(),
	}, self)
	if not made.ok or made.value == null:
		print("set GS_SQL_URL, GS_SQL_DIALECT and GS_SQL_TOKEN_FILE; see gs-sql/tools/test_live.sh")
		get_tree().quit(2)
		return

	var driver: GSSqlDriverGateway = made.value
	print("gs-moderation live: %s" % GSSqlDialect.name_of(dialect))

	# A clean table every run.
	await driver.open()
	await driver.execute("DROP TABLE IF EXISTS gs_punishments_live")
	await driver.execute("DELETE FROM gs_sql_migrations WHERE component = ?", ["gs_moderation:gs_punishments_live"])

	var store := GSPunishmentStoreSql.new(driver)
	store.table = "gs_punishments_live"

	var opened: GSResult = await store.open()
	_check("the store creates its table", opened.ok, opened)

	var ban := GSPunishment.create(GSPunishment.Kind.BAN, "uid:42", "cheating; said 'hi' 🙃", "admin:sarah", 86400)
	ban.evidence = {"demo": "r3.dem"}
	var put: GSResult = await store.put(ban)
	_check("a ban is written", put.ok, put)

	ban.revoked = true
	ban.revoked_by = "admin:tom"
	var again: GSResult = await store.put(ban)
	_check("writing it again updates rather than duplicates", again.ok, again)

	var mute := GSPunishment.create(GSPunishment.Kind.VOICE_MUTE, "uid:7", "mic spam", "admin:sarah", 600)
	await store.put(mute)

	var all: GSResult = await store.load_all()
	_check("both come back", all.ok and (all.value as Array).size() == 2, all)

	var mine: GSResult = await store.load_for("uid:42")
	var read: GSPunishment = (mine.value as Array)[0] if mine.ok and not (mine.value as Array).is_empty() else null
	_check("one subject's come back alone", mine.ok and (mine.value as Array).size() == 1, mine)
	_check("with the reason, quotes and all", read != null and read.reason == "cheating; said 'hi' 🙃")
	_check("revoked, as written the second time", read != null and read.revoked and read.revoked_by == "admin:tom")
	_check("and the evidence", read != null and read.evidence.get("demo", "") == "r3.dem")

	var removed: GSResult = await store.remove(ban.id)
	var after: GSResult = await store.load_for("uid:42")
	_check("a removal removes", removed.ok and after.ok and (after.value as Array).is_empty(), removed)

	var reopened: GSResult = await GSPunishmentStoreSql.new(driver).open()
	var reopened_store := GSPunishmentStoreSql.new(driver)
	reopened_store.table = "gs_punishments_live"
	var reopen: GSResult = await reopened_store.open()
	_check("opening an existing table again is harmless", reopened.ok and reopen.ok, reopen)

	print("%d passed, %d failed" % [_passed, _failed])
	await driver.execute("DROP TABLE IF EXISTS gs_punishments_live")
	get_tree().quit(1 if _failed > 0 or _passed + _failed != CHECKS else 0)


func _check(what: String, passed: bool, res: GSResult = null) -> void:
	if passed:
		_passed += 1
		print("  %-52s ok" % what)
		return
	_failed += 1
	var why := ""
	if res != null and not res.ok and res.error != null:
		why = " — %s (%s)" % [res.error.message, res.error.detail]
	print("  %-52s FAILED%s" % [what, why])
