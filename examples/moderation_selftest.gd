extends "res://examples/moderation_selftest_mid.gd"

## Proves punishments persist, expire, respect immunity, and are actually consulted.
##
## [codeblock]
## godot --headless --path . res://examples/moderation_selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]The section that matters most is the last one.[/b] Everything before it checks this
## addon against itself, which is the kind of testing that has never once found a bug in
## this family. The last one connects a real [GSVoiceRouter] to a real
## [GSModerationManager] through the registry and asks whether a muted player is actually
## silenced, because "the two ends have never met" is how every expensive bug here has
## started: GameSpice Map calling `ensure` on a client that offered `acquire`, the leaderboard
## reporter sending its file format as the wire, four call sites all finding a null cloud
## client and none of them erroring.


const CHECKS := 256


func _ready() -> void:
	GSLog.set_level(
		GSLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else GSLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("gs-moderation self-test")

	GSPaths.remove_tree(DATA)

	_test_record()
	_test_durations()
	await _test_issue_and_ask()
	await _test_expiry()
	await _test_revoke()
	await _test_immunity()
	await _test_persistence()
	await _test_store_refusals()
	await _test_scope()
	await _test_address_bans()
	await _test_voice_actually_asks()
	_test_schema()
	await _test_sql_store()
	await _test_rest_store()
	await _test_mod_tools()
	await _test_mod_abilities()
	await _test_mod_commands()

	GSPaths.remove_tree(DATA)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _test_mod_tools() -> void:
	_section("moving players around")

	var places := {
		&"admin:sarah": Vector3(0, 0, 0),
		&"uid:bob": Vector3(100, 0, 0),
		&"uid:carol": Vector3(-50, 0, 0),
	}

	var tools := GSModTools.new()
	tools.register_service = false
	tools.record_actions = false
	tools.position_fn = func(id: StringName) -> Vector3:
		return places.get(id, Vector3.ZERO)
	tools.teleport_fn = func(id: StringName, to: Variant) -> void:
		places[id] = to
	add_child(tools)
	await get_tree().process_frame

	# Teleport to a coordinate.
	var to_spot: GSResult = await tools.teleport(
		&"admin:sarah", &"uid:bob", Vector3(10, 5, 10)
	)
	_check(to_spot.ok, "a player is teleported", str(to_spot.error))
	_check(places[&"uid:bob"] == Vector3(10, 5, 10), "and is where they were sent")

	# The one that makes the rest safe to use.
	_check(tools.can_return(&"uid:bob"), "and can be put back")
	var back: GSResult = await tools.return_player(&"admin:sarah", &"uid:bob")
	_check(back.ok, "returning works", str(back.error))
	_check(
		places[&"uid:bob"] == Vector3(100, 0, 0),
		"and puts them exactly where they were (%s)" % places[&"uid:bob"],
		"the position is saved BEFORE the move; saving after would record the "
		+ "destination and a return would put them where they already are"
	)
	_check(not tools.can_return(&"uid:bob"), "and the history is consumed")

	# Bring: the player comes to the moderator.
	var brought: GSResult = await tools.bring(&"admin:sarah", &"uid:bob")
	_check(brought.ok, "a player is brought", str(brought.error))
	_check(places[&"uid:bob"] == Vector3(0, 0, 0), "to the moderator")

	await _tools_goto_send(tools, places)

	await _tools_2d()

	await _tools_immunity(tools, places)

	await _tools_unwired()

	# The history is bounded, or a long-running server leaks a position per action.
	tools.return_depth = 3
	for i in range(10):
		await tools.teleport(&"admin:senior", &"uid:bob", Vector3(i, 0, 0))
	var depth := 0
	while tools.can_return(&"uid:bob"):
		await tools.return_player(&"admin:senior", &"uid:bob")
		depth += 1
		if depth > 20:
			break
	_check(depth == 3, "the return history is capped at its depth (%d)" % depth)

	tools.forget(&"uid:bob")
	_check(not tools.can_return(&"uid:bob"), "and a disconnect can clear it")

	await _tools_recorded(tools, places)

	tools.queue_free()
	await get_tree().process_frame
	_done()


func _tools_unwired() -> void:
	# Wiring that is not there refuses rather than half-working.
	var unwired := GSModTools.new()
	unwired.register_service = false
	add_child(unwired)
	await get_tree().process_frame
	var nowhere: GSResult = await unwired.bring(&"a", &"b")
	_check(not nowhere.ok, "with no callables set, every action refuses")
	var lines := unwired.describe_lines()
	var warned := false
	for line in lines:
		if line.contains("WARNING"):
			warned = true
	_check(warned, "and describe_lines says so where an operator will see it")
	unwired.queue_free()


func _tools_recorded(tools: GSModTools, places: Dictionary) -> void:
	# Every action on the record, which is what makes "an admin moved me" answerable.
	var manager := GSModerationManager.new()
	manager.store = GSPunishmentStoreFile.new(DATA.path_join("tools.json"))
	manager.register_mute_source = false
	add_child(manager)
	await get_tree().process_frame
	await manager.load_all()

	tools.manager = manager
	tools.record_actions = true
	places[&"uid:dave"] = Vector3(1, 1, 1)
	await tools.bring(&"admin:senior", &"uid:dave")

	var history := manager.history_for("uid:dave")
	_check(history.size() == 1, "a teleport goes on the player's history (%d)" % history.size())
	_check(
		history.size() == 1 and history[0].kind == GSPunishment.Kind.WARN,
		"as a warning, which enforces nothing",
		"a teleport is not a punishment and must not read as one"
	)
	_check(
		history.size() == 1 and not manager.is_banned_key("uid:dave"),
		"so it punishes nobody"
	)
	_check(
		history.size() == 1 and str(history[0].evidence.get("action", "")) == "bring",
		"and records which action it was"
	)
	manager.queue_free()


func _tools_goto_send(tools: GSModTools, places: Dictionary) -> void:
	# Goto: the moderator goes to the player, and stops short.
	places[&"uid:carol"] = Vector3(-50, 0, 0)
	var went: GSResult = await tools.goto(&"admin:sarah", &"uid:carol")
	_check(went.ok, "a moderator goes to a player", str(went.error))
	var landed: Vector3 = places[&"admin:sarah"]
	var gap := landed.distance_to(Vector3(-50, 0, 0))
	_check(
		gap > 0.1,
		"and lands short of them (%.2f m away)" % gap,
		"two bodies in the same place is a stuck player at best"
	)
	_check(
		absf(gap - tools.goto_standoff) < 0.01,
		"by the configured stand-off (%.2f)" % gap
	)
	_check(
		tools.can_return(&"admin:sarah"),
		"and the moderator can put themselves back too"
	)

	# Two players in the same spot: the stand-off has no direction to work with, and
	# normalising a zero vector is how that turns into a NaN position.
	places[&"admin:sarah"] = Vector3(7, 7, 7)
	places[&"uid:carol"] = Vector3(7, 7, 7)
	var overlapped: GSResult = await tools.goto(&"admin:sarah", &"uid:carol")
	var after: Vector3 = places[&"admin:sarah"]
	_check(overlapped.ok, "going to somebody standing on you works")
	_check(
		not (is_nan(after.x) or is_nan(after.y) or is_nan(after.z)),
		"and does not produce a NaN position (%s)" % after,
		"normalising a zero-length direction is how it would"
	)

	# Send: one player to another.
	places[&"uid:bob"] = Vector3(100, 0, 0)
	places[&"uid:carol"] = Vector3(-50, 0, 0)
	var sent: GSResult = await tools.send(&"admin:sarah", &"uid:bob", &"uid:carol")
	_check(sent.ok, "a player is sent to another", str(sent.error))
	_check(
		(places[&"uid:bob"] as Vector3).distance_to(Vector3(-50, 0, 0)) < 5.0,
		"and arrives near them"
	)


func _tools_immunity(tools: GSModTools, places: Dictionary) -> void:
	# Immunity: a junior cannot move a senior.
	var ranks := {&"admin:junior": 10, &"admin:senior": 90, &"uid:bob": 0}
	tools.immunity_fn = func(id: StringName) -> int: return ranks.get(id, 0)

	var blocked: GSResult = await tools.bring(&"admin:junior", &"admin:senior")
	_check(not blocked.ok, "a junior cannot move a senior")
	_check(
		blocked.error != null and blocked.error.code == GSError.CODE_FORBIDDEN,
		"as a refusal rather than a failure"
	)
	var permitted: GSResult = await tools.bring(&"admin:senior", &"uid:bob")
	_check(permitted.ok, "and a senior can move a player")

	# Going to look at somebody is not something to be immune from: a moderator who
	# cannot observe a senior admin cannot do their job.
	places[&"admin:senior"] = Vector3(400, 0, 0)
	var observe: GSResult = await tools.goto(&"admin:junior", &"admin:senior")
	_check(
		observe.ok,
		"but anybody may go and watch anybody",
		"a moderator who cannot observe a senior cannot do their job"
	)


func _tools_2d() -> void:
	# 2D is a first-class user of this, which is why positions are Variant.
	var flat := {&"admin:sarah": Vector2(0, 0), &"uid:bob": Vector2(50, 50)}
	var tools_2d := GSModTools.new()
	tools_2d.register_service = false
	tools_2d.record_actions = false
	tools_2d.position_fn = func(id: StringName) -> Vector2:
		return flat.get(id, Vector2.ZERO)
	tools_2d.teleport_fn = func(id: StringName, to: Variant) -> void:
		flat[id] = to
	add_child(tools_2d)
	await get_tree().process_frame

	var flat_bring: GSResult = await tools_2d.bring(&"admin:sarah", &"uid:bob")
	_check(flat_bring.ok, "the same tools work in 2D", str(flat_bring.error))
	_check(flat[&"uid:bob"] == Vector2(0, 0), "and move a Vector2")
	await tools_2d.return_player(&"admin:sarah", &"uid:bob")
	_check(flat[&"uid:bob"] == Vector2(50, 50), "and return one")


# --- The live admin set ----------------------------------------------------

## A game's handler table, recorded, so a check can ask what the game was told to do.
	tools_2d.queue_free()


class FakeWorld extends RefCounted:
	var calls: Array = []
	var fail_next := false

	func handler(action: StringName) -> Callable:
		return func(id: StringName, args: Dictionary) -> GSResult:
			calls.append([action, id, args.duplicate()])
			if fail_next:
				fail_next = false
				return GSResult.fail(GSError.CODE_STATE, "That player is dead.")
			if action == GSModTools.ACTION_SPEED:
				# A game whose speeds are a ladder applies the nearest step.
				return GSResult.success(snappedf(float(args["scale"]), 1.0))
			return GSResult.success(args.get("on", true))

	func last(action: StringName) -> Array:
		for i in range(calls.size() - 1, -1, -1):
			if calls[i][0] == action:
				return calls[i]
		return []


func _abilities_tools(world: FakeWorld, manager: GSModerationManager = null) -> GSModTools:
	var tools := GSModTools.new()
	tools.register_service = false
	tools.record_actions = manager != null
	tools.manager = manager
	for action in [
		GSModTools.ACTION_NOCLIP, GSModTools.ACTION_GOD, GSModTools.ACTION_FREEZE,
		GSModTools.ACTION_SLAY, GSModTools.ACTION_SLAP, GSModTools.ACTION_HEALTH,
		GSModTools.ACTION_SPEED, GSModTools.ACTION_RESPAWN, GSModTools.ACTION_RENAME,
	]:
		tools.handlers[action] = world.handler(action)
	tools.unsupported_reasons[GSModTools.ACTION_GIVE] = "There is nothing to give here."
	var ranks := {&"junior": 10, &"senior": 90, &"bob": 0, &"carol": 0}
	tools.immunity_fn = func(id: StringName) -> int: return ranks.get(id, 0)
	add_child(tools)
	return tools


func _test_mod_abilities() -> void:
	_section("the live admin set: a handler per ability")

	var manager := _manager(DATA.path_join("abilities.json"))
	var world := FakeWorld.new()
	var tools := _abilities_tools(world, manager)
	await get_tree().process_frame

	await _abilities_refusals(tools, world)

	var zero: GSResult = await tools.set_health(&"senior", &"bob", 0.0)
	_check(not zero.ok and zero.error.code == GSError.CODE_INVALID,
		"health 0 is refused rather than being a second way to slay")

	var fast: GSResult = await tools.set_speed(&"senior", &"bob", 2.2)
	_check(fast.ok and is_equal_approx(tools.multiplier_of(&"bob", GSModTools.ACTION_SPEED), 2.0),
		"a multiplier is tracked as what the game applied, not what was typed",
		str(tools.multiplier_of(&"bob", GSModTools.ACTION_SPEED)))

	world.fail_next = true
	var refused: GSResult = await tools.freeze(&"senior", &"carol")
	_check(not refused.ok and not tools.is_active(&"carol", GSModTools.ACTION_FREEZE),
		"a handler's refusal is passed back and nothing is tracked")

	await _abilities_respawn(tools, world)

	await _abilities_history(tools, manager)

	var infinite: GSResult = await tools.slap(&"senior", &"carol", INF)
	_check(not infinite.ok and infinite.error.code == GSError.CODE_INVALID,
		"an infinite slap is refused, not a way round god")

	tools.subject_fn = func(id: StringName) -> String: return "uid:%s" % String(id)
	var _filed: GSResult = await tools.slap(&"senior", &"carol", 1.0)
	tools.subject_fn = Callable()
	_check(not manager.history_for("uid:carol").is_empty(),
		"a record is filed against the person subject_fn names, not the session id")

	var lines := tools.describe_lines()
	var listed := false
	var reasoned := false
	for line in lines:
		if line.begins_with("abilities") and line.contains("noclip") and line.contains("slay"):
			listed = true
		if line.begins_with("refused") and line.contains("give (There is nothing to give here.)"):
			reasoned = true
	_check(listed, "describe_lines lists what this game supports")
	_check(reasoned, "and what it refuses, with the reason")

	var _c: GSResult = await tools.freeze(&"senior", &"carol", true)
	tools.release_after(&"carol", GSModTools.ACTION_FREEZE, 0.1)
	await get_tree().create_timer(0.3).timeout
	_check(not tools.is_active(&"carol", GSModTools.ACTION_FREEZE),
		"a timed freeze lets go when its time is up")

	tools.queue_free()
	manager.queue_free()
	await get_tree().process_frame
	_done()


func _abilities_refusals(tools: GSModTools, world: FakeWorld) -> void:
	var give: GSResult = await tools.give(&"senior", &"bob", "rifle")
	_check(
		not give.ok and give.error.code == GSError.CODE_UNSUPPORTED
		and give.error.message.contains("nothing to give"),
		"an ability with no handler is refused, with the game's own reason",
		str(give.error)
	)
	var buddha: GSResult = await tools.buddha(&"senior", &"bob", true)
	_check(
		not buddha.ok and buddha.error.message.contains("does not support buddha"),
		"and one with no reason either still says which ability", str(buddha.error)
	)

	var on: GSResult = await tools.noclip(&"senior", &"bob")
	var call := world.last(GSModTools.ACTION_NOCLIP)
	_check(on.ok and call.size() == 3 and call[2]["on"] == true,
		"a toggle with no state given turns it on, through the game's handler")
	_check(tools.is_active(&"bob", GSModTools.ACTION_NOCLIP), "and is tracked as on")
	_check(tools.applied_by(&"bob", GSModTools.ACTION_NOCLIP) == &"senior",
		"with who turned it on")
	_check(call[2].get("actor", "") == "senior", "and the handler is told who acted")

	var _off: GSResult = await tools.noclip(&"senior", &"bob")
	_check(not tools.is_active(&"bob", GSModTools.ACTION_NOCLIP),
		"the same toggle again turns it off")

	var before := world.calls.size()
	var blocked: GSResult = await tools.god(&"junior", &"senior", true)
	_check(not blocked.ok and blocked.error.code == GSError.CODE_FORBIDDEN,
		"a junior cannot god a senior")
	_check(world.calls.size() == before, "and the game was never asked to")

	var self_on: GSResult = await tools.god(&"junior", &"junior", true)
	_check(self_on.ok, "but anybody may act on themselves",
		"equal cannot act on equal, and everybody is equal to themselves")

	var console_on: GSResult = await tools.perform(
		&"console", &"senior", GSModTools.ACTION_FREEZE, {"on": true}, 100
	)
	_check(console_on.ok, "a caller that states its own immunity is judged on it",
		"the console is not a player immunity_fn has heard of")


func _abilities_history(tools: GSModTools, manager: GSModerationManager) -> void:
	var slapped: GSResult = await tools.slap(&"senior", &"carol", 25.0)
	var history := manager.history_for("carol")
	var recorded := false
	for punishment in history:
		if punishment.evidence.get("action", "") == "slap" and float(punishment.evidence.get("damage", 0)) == 25.0:
			recorded = true
	_check(slapped.ok and recorded,
		"every action goes on the target's history, with what was done",
		"%d records" % history.size())

	# What was done reaches the STORE, not only the object in memory: read back cold.
	var reread := _manager(DATA.path_join("abilities.json"))
	var _loaded: GSResult = await reread.load_all()
	var stored := false
	for punishment in reread.history_for("carol"):
		if punishment.evidence.get("action", "") == "slap" and float(punishment.evidence.get("damage", 0)) == 25.0:
			stored = true
	_check(stored, "and what was done is in the store, not only on the record in memory",
		"the evidence was set after the store had written the record")
	reread.queue_free()


func _abilities_respawn(tools: GSModTools, world: FakeWorld) -> void:
	# A respawn: noclip and freeze are a body's and go with it; god outlives it.
	var _a: GSResult = await tools.god(&"senior", &"bob", true)
	var _b: GSResult = await tools.freeze(&"senior", &"bob", true)
	world.calls.clear()
	tools.respawned(&"bob")
	var freeze_call := world.last(GSModTools.ACTION_FREEZE)
	var god_call := world.last(GSModTools.ACTION_GOD)
	var speed_call := world.last(GSModTools.ACTION_SPEED)
	_check(freeze_call.size() == 3 and freeze_call[2]["on"] == false
		and not tools.is_active(&"bob", GSModTools.ACTION_FREEZE),
		"a respawn switches freeze off, through the handler, and stops tracking it")
	_check(god_call.size() == 3 and god_call[2]["on"] == true
		and tools.is_active(&"bob", GSModTools.ACTION_GOD),
		"and re-applies god to the new body")
	_check(speed_call.size() == 3 and is_equal_approx(float(speed_call[2]["scale"]), 1.0)
		and is_equal_approx(tools.multiplier_of(&"bob", GSModTools.ACTION_SPEED), 1.0),
		"and puts their speed back to normal")

	tools.forget(&"bob")
	_check(tools.active_on(&"bob").is_empty(), "leaving forgets every toggle they had")


# --- The commands, against a console that is not GameSpice Server's --------------

class FakeSession extends RefCounted:
	var userid := 0
	var display_name := ""
	var immunity := 0

	func _init(p_id: int, p_name: String, p_immunity: int = 0) -> void:
		userid = p_id
		display_name = p_name
		immunity = p_immunity


class FakeCommand extends RefCounted:
	var name := ""
	var handler: Callable
	var permission := ""
	var chat := false
	var completer: Callable

	func with_usage(_u: String) -> FakeCommand: return self
	func with_args(_a: int, _b: int = -1) -> FakeCommand: return self
	func with_chat(_c: bool = true) -> FakeCommand:
		chat = true
		return self
	func with_completer(c: Callable) -> FakeCommand:
		completer = c
		return self


class FakeConsole extends RefCounted:
	var commands := {}

	func command(n: String, h: Callable, _d: String = "", p: String = "") -> FakeCommand:
		var c := FakeCommand.new()
		c.name = n
		c.handler = h
		c.permission = p
		commands[n] = c
		return c

	func has_name(n: String) -> bool:
		return commands.has(n)

	func unregister_command(n: String) -> void:
		commands.erase(n)


class FakeChat extends RefCounted:
	var told: Array = []
	var announced := PackedStringArray()

	func send_system_to(session: Object, text: String) -> void:
		told.append([session, text])

	func announce_action(text: String) -> void:
		announced.append(text)


class FakeAudit extends RefCounted:
	var entries: Array = []

	func record(action: String, actor: String, target: String = "", details: Dictionary = {}) -> void:
		entries.append([action, actor, target, details])


class FakeServer extends RefCounted:
	var everyone: Array = []
	var chat := FakeChat.new()
	var audit := FakeAudit.new()

	func playing_sessions() -> Array:
		return everyone

	func find_sessions(text: String, caller: Object = null) -> Array:
		if text == "@me":
			return [caller] if caller != null else []
		var out: Array = []
		for s: Variant in everyone:
			if str((s as Object).get("display_name")).to_lower() == text.to_lower():
				out.append(s)
		return out

	func resolve_target(ctx: Object, text: String) -> GSResult:
		var found := find_sessions(text, ctx.get("session"))
		if found.size() != 1:
			return GSResult.fail(GSError.CODE_INVALID, "No player matching '%s'." % text)
		if not bool(ctx.call("outranks", int((found[0] as Object).get("immunity")))):
			return GSResult.fail(GSError.CODE_FORBIDDEN, "They have equal or higher immunity than you.")
		return GSResult.success(found[0])


class FakeContext extends RefCounted:
	var args := PackedStringArray()
	var session: Object = null
	var immunity := 0
	var root := false
	var output := PackedStringArray()

	func reply(text: String) -> void:
		output.append(text)

	func reply_lines(lines: PackedStringArray) -> void:
		output.append_array(lines)

	func has_permission(flag: String) -> bool:
		return root and flag == "root"

	func outranks(level: int) -> bool:
		return root or immunity > level

	func caller_label() -> String:
		return "console" if session == null else str(session.get("display_name"))


func _run_command(console: FakeConsole, line: String, session: Object, immunity: int = 0, root := false) -> FakeContext:
	var parts := line.split(" ", false)
	var ctx := FakeContext.new()
	ctx.args = parts.slice(1)
	ctx.session = session
	ctx.immunity = immunity
	ctx.root = root
	var command: FakeCommand = console.commands[parts[0]]
	await command.handler.call(ctx)
	return ctx


func _test_mod_commands() -> void:
	_section("the live admin set as commands, with no gs-server in the project")

	var world := FakeWorld.new()
	var tools := _abilities_tools(world)
	await get_tree().process_frame

	var server := FakeServer.new()
	var admin := FakeSession.new(1, "Admin", 50)
	var bob := FakeSession.new(2, "Bob")
	var carol := FakeSession.new(3, "Carol")
	var boss := FakeSession.new(4, "Boss", 90)
	server.everyone = [admin, bob, carol, boss]

	var console := FakeConsole.new()
	console.command("respawn", func(_c: Object) -> void: pass)   # a game's own, first

	var commands := GSModToolCommands.install(console, tools, server)
	_check(
		commands.registered.size() == GSModToolCommands.COMMANDS.size() - 1
		and commands.collided.has("respawn"),
		"every command is registered except one a game already had",
		"%d registered, collided %s" % [commands.registered.size(), str(commands.collided)]
	)
	_check(
		console.commands["slay"].permission == "slay"
		and console.commands["noclip"].permission == "cheats"
		and console.commands["bring"].permission == "teleport",
		"slay is a moderator's flag, noclip is cheats, bring is teleport"
	)
	_check(console.commands["noclip"].chat, "and every one is typable in chat")

	var bare := await _run_command(console, "noclip", admin, 50)
	_check(tools.is_active(&"1", GSModTools.ACTION_NOCLIP),
		"a bare !noclip acts on whoever typed it", " / ".join(bare.output))

	var _off := await _run_command(console, "noclip off", admin, 50)
	_check(not tools.is_active(&"1", GSModTools.ACTION_NOCLIP), "and 'noclip off' turns it off")

	var from_console := await _run_command(console, "noclip", null, 100, true)
	_check(" ".join(from_console.output).contains("no body"),
		"the console with no target is told to name somebody")

	await _commands_selectors(console, admin, world, commands)

	await _commands_speed_blind(console, admin, tools, world)

	await _commands_refusals(console, admin, world)

	var _renamed := await _run_command(console, "rename Carol Not Rude", admin, 50)
	_check(carol.display_name == "Not Rude", "a rename reaches the server's name for them too")

	_check(not server.chat.announced.is_empty() and not server.audit.entries.is_empty(),
		"actions are announced and audited")
	var named := false
	for pair: Array in server.chat.told:
		if str(pair[1]).contains("Admin"):
			named = true
	_check(not server.chat.told.is_empty() and not named,
		"the target is told, and never who did it")

	var offered: PackedStringArray = console.commands["slay"].completer.call("", 0)
	_check(offered.has("@all") and offered.has("Bob") and offered.has("@alive"),
		"completion offers the selectors and the players", ", ".join(offered))

	commands.unbind(console)
	_check(not console.commands.has("slay") and console.commands.has("respawn"),
		"unbind removes its own commands and leaves the game's")

	tools.queue_free()
	await get_tree().process_frame
	_done()


func _commands_selectors(console: FakeConsole, admin: FakeSession, world: FakeWorld, commands: GSModToolCommands) -> void:
	var all := await _run_command(console, "slay @all", admin, 50)
	var slain := 0
	for c: Array in world.calls:
		if c[0] == GSModTools.ACTION_SLAY:
			slain += 1
	_check(slain == 3 and " ".join(all.output).contains("1 player skipped"),
		"@all acts on everybody the caller outranks and says how many it skipped",
		" / ".join(all.output))

	var no_alive := await _run_command(console, "freeze @alive", admin, 50)
	_check(" ".join(no_alive.output).contains("does not say who is alive"),
		"@alive is refused by a game that has not said who is alive")

	commands.alive_fn = func(id: StringName) -> bool: return id != &"3"
	world.calls.clear()
	var _alive := await _run_command(console, "freeze @alive", admin, 50)
	var frozen := PackedStringArray()
	for c: Array in world.calls:
		if c[0] == GSModTools.ACTION_FREEZE:
			frozen.append(String(c[1]))
	_check(not frozen.has("3") and frozen.has("2"), "and uses the game's answer when it has one",
		", ".join(frozen))


func _commands_refusals(console: FakeConsole, admin: FakeSession, world: FakeWorld) -> void:
	var give := await _run_command(console, "give Bob rifle", admin, 50)
	_check(" ".join(give.output).contains("nothing to give"),
		"an unsupported ability answers with the game's reason", " / ".join(give.output))

	var protected := await _run_command(console, "slap Boss", admin, 50)
	_check(" ".join(protected.output).contains("immunity"),
		"a single protected target is refused by the server's own rule")

	world.calls.clear()
	var boost := await _run_command(console, "slap @me", admin, 50)
	var self_slapped := false
	for c: Array in world.calls:
		if c[0] == GSModTools.ACTION_SLAP:
			self_slapped = true
	_check(not self_slapped and " ".join(boost.output).contains("needs the cheats flag"),
		"slapping yourself — a shove where you want it — needs cheats", " / ".join(boost.output))
	var as_root := await _run_command(console, "slap @me", admin, 50, true)
	_check(not " ".join(as_root.output).contains("needs the cheats flag"),
		"and somebody holding it may", " / ".join(as_root.output))


func _commands_speed_blind(console: FakeConsole, admin: FakeSession, tools: GSModTools, world: FakeWorld) -> void:
	var speed := await _run_command(console, "speed Bob 2.2", admin, 50)
	_check(is_equal_approx(tools.multiplier_of(&"2", GSModTools.ACTION_SPEED), 2.0)
		and " ".join(speed.output).contains("Bob"),
		"speed goes through the tools", " / ".join(speed.output))
	# The ladder in the fake world above puts 2.2 on 2. The reply has to say the step, or
	# the admin is told a number the player is not on.
	_check(" ".join(speed.output).contains("2×") and not " ".join(speed.output).contains("2.2"),
		"and the reply names the step the game applied, not the number typed",
		" / ".join(speed.output))

	# A blind for a spell: a number of seconds in place of on|off, released by the tools'
	# own timer, as a timed freeze is. `1` is still the switch word, not one second.
	tools.handlers[GSModTools.ACTION_BLIND] = world.handler(GSModTools.ACTION_BLIND)
	var _spell := await _run_command(console, "blind Bob 0.5", admin, 50)
	_check(tools.is_active(&"2", GSModTools.ACTION_BLIND), "blind takes a number of seconds")
	await get_tree().create_timer(0.9).timeout
	_check(not tools.is_active(&"2", GSModTools.ACTION_BLIND)
		and world.last(GSModTools.ACTION_BLIND).size() == 3
		and world.last(GSModTools.ACTION_BLIND)[2]["on"] == false,
		"and lifts it through the handler when they run out")
	var _held := await _run_command(console, "blind Bob 1", admin, 50)
	await get_tree().create_timer(0.25).timeout
	_check(tools.is_active(&"2", GSModTools.ACTION_BLIND),
		"while `1` is the switch word, and holds until somebody lifts it")
	var _lift := await _run_command(console, "blind Bob off", admin, 50)
	var nonsense := await _run_command(console, "blind Bob soon", admin, 50)
	_check(not tools.is_active(&"2", GSModTools.ACTION_BLIND)
		and " ".join(nonsense.output).contains("number of seconds"),
		"and anything else is refused, naming what it takes", " / ".join(nonsense.output))
