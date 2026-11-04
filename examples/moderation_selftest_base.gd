extends Node

## First half of the self-test: the harness and the record, store and admission sections.
## [code]moderation_selftest.gd[/code] extends this and runs everything.

const DATA := "user://dot_moderation_selftest"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _manager(path: String = "", scope: String = "") -> DotModerationManager:
	var manager := DotModerationManager.new()
	manager.store = DotPunishmentStoreFile.new(
		path if path != "" else DATA.path_join("m.json")
	)
	manager.server_scope = scope
	# Off by default in the tests so two managers in one process do not fight over the
	# registry name. The section that needs it turns it on.
	manager.register_mute_source = false
	manager.register_ban_source = false
	add_child(manager)
	return manager


func _test_record() -> void:
	_section("a punishment is a record, not a flag")

	var mute := DotPunishment.create(
		DotPunishment.Kind.VOICE_MUTE, "uid:1", "mic spam", "admin:sarah", 3600
	)

	_check(mute.validate().ok, "a well-formed punishment validates")
	_check(mute.id != "", "and gets an id, so a revoke can name one record")
	_check(mute.is_active(), "it is in force")
	_check(not mute.is_permanent(), "and is not permanent")
	_check(mute.remaining() > 3500, "with time left (%d)" % mute.remaining())

	var forever := DotPunishment.create(DotPunishment.Kind.BAN, "uid:2", "cheating")
	_check(forever.is_permanent(), "a zero duration is permanent")
	_check(
		forever.remaining() == -1,
		"and reports -1 rather than 0",
		"0 would read as expired, which is the bug that lets everybody back in"
	)
	_check(forever.is_active(), "and is in force")

	# A kick is an event. It happened; it is not still happening, and a kick that read as
	# active would keep a player out for ever.
	var kick := DotPunishment.create(DotPunishment.Kind.KICK, "uid:3", "afk")
	_check(not kick.is_active(), "a kick is history rather than a state")
	var warn := DotPunishment.create(DotPunishment.Kind.WARN, "uid:3", "language")
	_check(not warn.is_active(), "and so is a warning")

	var nameless := DotPunishment.create(DotPunishment.Kind.BAN, "", "no subject")
	_check(not nameless.validate().ok, "a punishment against nobody is refused")

	var backwards := DotPunishment.create(DotPunishment.Kind.BAN, "uid:4", "x")
	backwards.expires_at = backwards.issued_at - 10
	_check(
		not backwards.validate().ok,
		"and one that expires before it was issued"
	)

	# The player-facing message must never name the moderator: that is how a moderator
	# gets harassed, and it is not information a player needs in order to appeal.
	var message := mute.player_message()
	_check(message.contains("mic spam"), "the player is told why (%s)" % message)
	_check(not message.contains("sarah"), "and not by whom")

	# A Dictionary is a reference in GDScript, and this family has shipped that bug more
	# than once: every scoped leaderboard and the template it came from were one object.
	mute.evidence = {"demo": "round3.dem"}
	var dict := mute.to_dictionary()
	(dict["evidence"] as Dictionary)["demo"] = "tampered"
	_check(
		str(mute.evidence["demo"]) == "round3.dem",
		"to_dictionary hands out a copy of its evidence, not the original"
	)

	var back := DotPunishment.from_dictionary(mute.to_dictionary())
	_check(back.id == mute.id, "a record round-trips its id")
	_check(back.kind == mute.kind, "its kind (%s)" % DotPunishment.kind_name(back.kind))
	_check(back.subject == mute.subject and back.reason == mute.reason, "and its content")
	_check(back.expires_at == mute.expires_at, "and its expiry")
	_done()


func _test_durations() -> void:
	_section("durations a person reads")

	_check(DotPunishment.format_duration(45) == "45s", "seconds")
	_check(DotPunishment.format_duration(90) == "1m", "minutes")
	_check(DotPunishment.format_duration(3700).begins_with("1h"), "hours")
	_check(DotPunishment.format_duration(90000).begins_with("1d"), "days")
	_check(DotPunishment.format_duration(0) == "0s", "and zero does not crash")
	_done()


func _test_issue_and_ask() -> void:
	_section("issuing, and the questions a server asks")

	var manager := _manager()
	await get_tree().process_frame
	await manager.load_all()

	var issued: DotResult = await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:1", "mic spam", "admin:sarah", 600
	)
	_check(issued.ok, "a mute is issued", str(issued.error))

	_check(manager.is_voice_muted_key("uid:1"), "and the player is voice muted")
	_check(not manager.is_gagged_key("uid:1"), "but not gagged")
	_check(not manager.is_banned_key("uid:1"), "and not banned")
	_check(not manager.is_voice_muted_key("uid:2"), "and nobody else is muted")

	await manager.issue(DotPunishment.Kind.GAG, "uid:1", "spam", "admin:sarah", 600)
	_check(manager.is_gagged_key("uid:1"), "a gag is a separate record")
	_check(
		manager.active_for("uid:1").size() == 2,
		"so a player can hold both at once (%d)" % manager.active_for("uid:1").size()
	)

	await manager.issue(DotPunishment.Kind.WARN, "uid:1", "first warning")
	_check(
		manager.active_for("uid:1").size() == 2,
		"a warning enforces nothing"
	)
	_check(
		manager.history_for("uid:1").size() == 3,
		"but is on the history (%d)" % manager.history_for("uid:1").size(),
		"which is what makes the next decision defensible"
	)

	var found := manager.search("mic")
	_check(found.size() == 1, "records are searchable by reason (%d)" % found.size())

	var nobody: DotResult = await manager.issue(DotPunishment.Kind.BAN, "  ", "x")
	_check(not nobody.ok, "a punishment against nobody is refused")

	manager.queue_free()
	await get_tree().process_frame
	_done()


func _test_expiry() -> void:
	_section("expiry is answered on read, never swept")

	var manager := _manager(DATA.path_join("expiry.json"))
	await get_tree().process_frame
	await manager.load_all()

	await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:9", "short", "console", 3600
	)
	_check(manager.is_voice_muted_key("uid:9"), "a mute is in force")

	# Reached into rather than waited for: a test that slept an hour is a test nobody
	# runs. What is being checked is that the READ notices, which is the whole design.
	var record := manager.active_of_kind("uid:9", DotPunishment.Kind.VOICE_MUTE)
	record.expires_at = int(Time.get_unix_time_from_system()) - 1

	var noticed := [false]
	manager.expired.connect(func(_p: DotPunishment) -> void: noticed[0] = true)

	_check(
		not manager.is_voice_muted_key("uid:9"),
		"and stops being in force the moment it expires",
		"a sweep on a timer means a server that was off overnight enforces yesterday"
	)
	_check(noticed[0], "the expiry is announced")
	_check(
		manager.history_for("uid:9").size() == 1,
		"and the record stays on the history"
	)

	manager.queue_free()
	await get_tree().process_frame
	_done()


func _test_revoke() -> void:
	_section("lifting a punishment keeps the record")

	var manager := _manager(DATA.path_join("revoke.json"))
	await get_tree().process_frame
	await manager.load_all()

	var issued: DotResult = await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:5", "mic spam", "admin:sarah", 600
	)
	var punishment: DotPunishment = issued.value

	var lifted: DotResult = await manager.revoke(punishment.id, "admin:tom", "appealed")
	_check(lifted.ok, "a mute is lifted", str(lifted.error))
	_check(not manager.is_voice_muted_key("uid:5"), "and the player can speak")
	_check(
		manager.history_for("uid:5").size() == 1,
		"the record is kept rather than deleted",
		"the history is the point"
	)
	_check(punishment.revoked_by == "admin:tom", "with who lifted it")
	_check(punishment.revoke_reason == "appealed", "and why")

	var again: DotResult = await manager.revoke(punishment.id, "admin:tom")
	_check(not again.ok, "lifting it twice is refused")

	var missing: DotResult = await manager.revoke("nope", "admin:tom")
	_check(not missing.ok, "and so is lifting one that does not exist")

	# What `unmute <player>` calls, which is the shape a console command wants.
	await manager.issue(DotPunishment.Kind.VOICE_MUTE, "uid:6", "a", "console", 600)
	await manager.issue(DotPunishment.Kind.VOICE_MUTE, "uid:6", "b", "console", 600)
	var all: DotResult = await manager.revoke_all(
		"uid:6", DotPunishment.Kind.VOICE_MUTE, "console"
	)
	_check(all.ok and int(all.value) == 2, "every active mute can be lifted at once")
	_check(not manager.is_voice_muted_key("uid:6"), "and the player can speak")

	var nothing: DotResult = await manager.revoke_all(
		"uid:7", DotPunishment.Kind.VOICE_MUTE, "console"
	)
	_check(not nothing.ok, "lifting nothing says so rather than reporting success")

	manager.queue_free()
	await get_tree().process_frame
	_done()


func _test_immunity() -> void:
	_section("immunity, in both directions")

	var manager := _manager(DATA.path_join("immunity.json"))
	await get_tree().process_frame
	await manager.load_all()

	# A senior mutes somebody.
	var senior: DotResult = await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:8", "spam", "admin:senior", 600, 80
	)
	_check(senior.ok, "a senior moderator issues a mute")

	# A junior cannot undo it. This is the half of immunity that usually gets left out,
	# and without it a junior can quietly reverse every decision above them.
	var junior: DotResult = await manager.revoke(
		(senior.value as DotPunishment).id, "admin:junior", "", 10
	)
	_check(
		not junior.ok,
		"a junior cannot lift it",
		"immunity is about who may be acted on, not only who may act"
	)

	var higher: DotResult = await manager.revoke(
		(senior.value as DotPunishment).id, "admin:root", "", 100
	)
	_check(higher.ok, "somebody above them can")

	# Equal cannot act on equal. Two moderators at the same level muting each other in a
	# loop has no correct resolution, so it is forbidden rather than raced.
	await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:11", "spam", "admin:a", 600, 50
	)
	var equal: DotResult = await manager.issue(
		DotPunishment.Kind.GAG, "uid:11", "more", "admin:b", 600, 50
	)
	_check(not equal.ok, "equal immunity cannot act on equal by default")

	manager.equal_immunity_may_act = true
	var permitted: DotResult = await manager.issue(
		DotPunishment.Kind.GAG, "uid:11", "more", "admin:b", 600, 50
	)
	_check(permitted.ok, "unless a community says otherwise")

	manager.queue_free()
	await get_tree().process_frame
	_done()


func _test_persistence() -> void:
	_section("the whole reason this exists: a mute survives a reconnect")

	var path := DATA.path_join("persist.json")

	var first := _manager(path)
	await get_tree().process_frame
	await first.load_all()
	await first.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:99", "mic spam", "admin:sarah", 3600
	)
	_check(first.is_voice_muted_key("uid:99"), "a player is muted")
	first.queue_free()
	await get_tree().process_frame

	# A different manager reading the same file is what "they reconnected", "the server
	# restarted" and "they joined the other server" all look like from here.
	var second := _manager(path)
	await get_tree().process_frame
	var loaded: DotResult = await second.load_all()

	_check(loaded.ok, "a second server loads the same list", str(loaded.error))
	_check(
		second.is_voice_muted_key("uid:99"),
		"and the player is STILL muted",
		"dot-server's mute is a boolean on a session object, so it is gone the moment "
		+ "they disconnect. That is the complaint this addon exists to answer."
	)

	var record := second.active_of_kind("uid:99", DotPunishment.Kind.VOICE_MUTE)
	_check(record != null and record.reason == "mic spam", "with the reason intact")
	_check(record != null and record.remaining() > 3500, "and the time left")

	second.queue_free()
	await get_tree().process_frame
	_done()


func _test_store_refusals() -> void:
	_section("what the store refuses, and what it keeps")

	var path := DATA.path_join("broken.json")
	DotPaths.write_text(path, "this is not json")

	var store := DotPunishmentStoreFile.new(path)
	var loaded: DotResult = await store.load_all()
	_check(
		not loaded.ok,
		"a corrupt file is a loud failure",
		"silently meaning nobody is punished turns a typo into an unmoderated server"
	)

	# And the manager keeps what it already had rather than clearing.
	var manager := _manager(DATA.path_join("keep.json"))
	await get_tree().process_frame
	await manager.load_all()
	await manager.issue(DotPunishment.Kind.BAN, "uid:20", "cheating", "console")
	_check(manager.is_banned_key("uid:20"), "a ban is in force")

	manager.store = DotPunishmentStoreFile.new(path)
	var failed: DotResult = await manager.load_all()
	_check(not failed.ok, "a failed reload reports the failure")
	_check(
		manager.is_banned_key("uid:20"),
		"and keeps what was already in force",
		"starting empty on a read error readmits everybody who was ever removed"
	)

	# One bad entry does not condemn the file.
	var mixed := DATA.path_join("mixed.json")
	DotPaths.write_text(mixed, JSON.stringify({
		"format_version": 1,
		"punishments": [
			{"id": "a", "kind": "ban", "subject": "uid:30", "reason": "ok",
			 "issued_at": 1, "expires_at": 0},
			{"id": "", "kind": "ban", "subject": "", "reason": "broken"},
			{"id": "c", "kind": "mute", "subject": "uid:31", "reason": "ok",
			 "issued_at": 1, "expires_at": 0},
		],
	}))
	var partial: DotResult = await DotPunishmentStoreFile.new(mixed).load_all()
	_check(partial.ok, "a file with one bad entry still loads")
	_check(
		partial.ok and (partial.value as Array).size() == 2,
		"with the good ones (%d)" % ((partial.value as Array).size() if partial.ok else -1)
	)

	# A read-only store is a legitimate configuration, said plainly.
	var readonly := _manager(DATA.path_join("ro.json"))
	await get_tree().process_frame
	readonly.store = DotPunishmentStore.new()
	var refused: DotResult = await readonly.issue(
		DotPunishment.Kind.BAN, "uid:40", "x", "console"
	)
	_check(
		not refused.ok,
		"a read-only store refuses rather than pretending",
		"appearing to work and losing the record on the next refresh is worse"
	)
	_check(not readonly.is_banned_key("uid:40"), "and nothing is applied locally")

	manager.queue_free()
	readonly.queue_free()
	await get_tree().process_frame
	_done()


func _test_scope() -> void:
	_section("a community with more than one server")

	var path := DATA.path_join("scope.json")

	var surf := _manager(path, "surf")
	await get_tree().process_frame
	await surf.load_all()
	await surf.issue(DotPunishment.Kind.VOICE_MUTE, "uid:50", "spam", "console", 600)
	_check(surf.is_voice_muted_key("uid:50"), "a mute applies on the server that set it")
	surf.queue_free()
	await get_tree().process_frame

	var dm := _manager(path, "deathmatch")
	await get_tree().process_frame
	await dm.load_all()
	_check(
		not dm.is_voice_muted_key("uid:50"),
		"and not on a server with a different scope",
		"a surf mute need not be a deathmatch mute"
	)

	var everywhere := _manager(path, "")
	await get_tree().process_frame
	await everywhere.load_all()
	_check(
		everywhere.is_voice_muted_key("uid:50"),
		"a server with no scope sees every punishment"
	)

	dm.queue_free()
	everywhere.queue_free()
	await get_tree().process_frame
	_done()


## The join, run rather than assumed.
## dot-voice's router calls `is_voice_muted(peer)` on whatever [DotRegistry] holds under
## `dot_mute_source`; neither addon imports the other, so only running both halves proves it.
func _test_address_bans() -> void:
	_section("banning a machine rather than a person")

	_address_spelling()

	var manager := _manager(DATA.path_join("address.json"))
	await get_tree().process_frame
	await manager.load_all()

	var banned: DotResult = await manager.ban_address(
		"203.0.113.9:40000", "ban evasion", "admin:sarah", 0, 0
	)
	_check(banned.ok, "an address is banned", str(banned.error))
	_check(
		manager.is_banned_address("203.0.113.9:51111"),
		"and matches the same address on a different port"
	)
	_check(
		not manager.is_banned_address("203.0.113.10"),
		"and nobody else"
	)

	var loopback: DotResult = await manager.ban_address("127.0.0.1", "oops", "console")
	_check(not loopback.ok, "loopback is refused rather than recorded")

	await _address_admission(manager)

	# A kick is history, not a state, so it must never refuse a connection — which is
	# the whole reason a kick and a ban are one record with a different kind.
	await manager.issue(
		DotPunishment.Kind.KICK, "ip:198.51.100.2", "language", "admin:sarah"
	)
	_check(
		manager.check_admission("", "198.51.100.2").ok,
		"a kick against an address keeps nobody out"
	)

	var temporary: DotResult = await manager.ban_address(
		"198.51.100.3", "cooling off", "admin:sarah", 1, 0
	)
	_check(temporary.ok, "a temporary address ban is recorded")
	_check(
		not manager.check_admission("", "198.51.100.3").ok,
		"and refuses while it is in force"
	)
	var record: DotPunishment = temporary.value
	record.expires_at = int(Time.get_unix_time_from_system()) - 1
	_check(
		manager.check_admission("", "198.51.100.3").ok,
		"and admits the moment it runs out",
		"expiry is answered on read, never swept"
	)

	# An unregistered ban source is a ban nothing enforces, and the moderator who
	# issued one has no way to tell. It has to be said where an operator looks.
	var lines := manager.describe_lines()
	var warned := false
	for line in lines:
		if line.contains("nothing is enforcing them"):
			warned = true
	_check(
		warned,
		"an unregistered ban source is reported in describe_lines",
		"nothing here can refuse a connection; dot-server has to ask"
	)

	manager.queue_free()
	await get_tree().process_frame
	_done()


func _address_admission(manager: DotModerationManager) -> void:
	# What dot-server calls. Everything above is unreachable from a server without it.
	var refused: DotResult = manager.check_admission("", "203.0.113.9:51111")
	_check(not refused.ok, "check_admission refuses the banned address")
	_check(
		not refused.ok and refused.error.message.to_lower().contains("banned"),
		"with the message the player is shown",
		"a player told nothing reconnects immediately"
	)
	_check(
		manager.check_admission("uid:nobody", "198.51.100.1").ok,
		"and admits everybody else"
	)

	await manager.ban_uid("backbone:evil", "cheating", "admin:sarah", 0, 0)
	_check(
		not manager.check_admission("backbone:evil", "198.51.100.1").ok,
		"an account ban is refused from an unbanned address"
	)
	_check(
		not manager.check_admission("uid:backbone:evil", "198.51.100.1").ok,
		"and either spelling of the same person is refused",
		"a deployment writing bare ids and one writing prefixed ids are both legal"
	)


func _address_spelling() -> void:
	# How a subject is spelled decides whether the two ends ever meet. A ban filed
	# against "1.2.3.4" and checked against what a transport actually reports —
	# "1.2.3.4:51234" — is two strings and no error.
	_check(
		DotPunishmentSubject.for_address("1.2.3.4:51234") == "ip:1.2.3.4",
		"the port is not part of the subject"
	)
	_check(
		DotPunishmentSubject.for_address("[2001:db8::1]:9999") == "ip:2001:db8::1",
		"nor is a bracketed IPv6 port"
	)
	_check(
		DotPunishmentSubject.for_address("ip:1.2.3.4") == "ip:1.2.3.4",
		"a subject that is already one is left alone"
	)
	_check(
		DotPunishmentSubject.for_uid("uid:alice") == "uid:alice"
			and DotPunishmentSubject.for_uid("alice") == "uid:alice",
		"and the same holds for a person"
	)
	_check(
		not DotPunishmentSubject.is_bannable_address("127.0.0.1")
			and not DotPunishmentSubject.is_bannable_address("::1"),
		"loopback is not a bannable address",
		"banning it locks the operator out of their own listen server"
	)
	_check(
		not DotPunishmentSubject.is_bannable_address("unknown"),
		"and neither is an address the transport could not report",
		"that is every client at once"
	)
