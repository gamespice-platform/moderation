extends "res://examples/moderation_selftest_base.gd"

## Second part of the self-test: voice, schema, SQL and REST sections.

func _test_voice_actually_asks() -> void:
	_section("dot-voice asks this addon, and this addon answers")

	if not ClassDB.class_exists("Node") or not _voice_is_present():
		# Said out loud rather than skipped quietly. "0 failures" from a suite that ran
		# nothing is how a family gets to a release with two ends that never met.
		_check(
			false,
			"dot-voice is present so the join can be run",
			"addons/dot_voice is not linked; the integration below is NOT covered"
		)
		_done()
		return

	var manager := DotModerationManager.new()
	manager.store = DotPunishmentStoreFile.new(DATA.path_join("join.json"))
	# On, because publishing under `dot_mute_source` IS the integration.
	manager.register_mute_source = true
	add_child(manager)
	await get_tree().process_frame
	await manager.load_all()

	_check(
		DotRegistry.get_service(&"dot_mute_source") == manager,
		"the manager publishes itself where dot-voice looks",
		"one registration, and four call sites in this family have found null before"
	)

	# A transport peer is not a durable identity. Something has to map one to the other,
	# and only the host knows how.
	var peers := {1: "uid:alice", 2: "uid:bob"}
	manager.key_for_peer = func(peer: int) -> String:
		return str(peers.get(peer, "peer:%d" % peer))

	var config := DotVoiceConfig.new()
	config.sample_rate = 24000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"

	var router := DotVoiceRouter.new()
	router.name = "Router"
	router.config = config
	router.max_bytes_per_second = 0
	add_child(router)
	await get_tree().process_frame

	router.add_peer(1)
	router.add_peer(2)
	router.add_peer(3)

	var delivered: Array[int] = []
	router.send_fn = func(peer: int, _bytes: PackedByteArray) -> void:
		delivered.append(peer)

	var codec := DotVoiceCodec.instance_for(&"adpcm")
	var frame := DotVoiceSourceBuffer.tone(300.0, 0.02, config.sample_rate, 0.4)

	var speak := func(from: int) -> void:
		var packet := DotVoicePacket.new()
		packet.speaker = from
		packet.sample_count = config.frame_samples()
		packet.channel = DotVoiceRouter.Channel.ALL
		packet.codec_id = &"adpcm"
		packet.payload = codec.encode(frame)
		router.relay(from, packet.to_bytes())

	delivered.clear()
	speak.call(1)
	_check(delivered.size() == 2, "alice is heard (%d listeners)" % delivered.size())

	await _voice_mute(manager, speak, delivered, router)

	await _voice_reconnect(manager, peers, speak, delivered)

	router.queue_free()
	await get_tree().process_frame
	_done()


func _voice_mute(manager: DotModerationManager, speak: Callable, delivered: Array[int], router: Node) -> void:
	# Now mute her through moderation, and nothing about the router changes.
	var issued: DotResult = await manager.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:alice", "mic spam", "admin:sarah", 600
	)
	_check(issued.ok, "a moderator mutes her", str(issued.error))

	delivered.clear()
	speak.call(1)
	_check(
		delivered.is_empty(),
		"and the voice router silences her without being told",
		"the two addons meet through one registry name and one method"
	)
	_check(router.refused_muted > 0, "the router counts the refusal")

	delivered.clear()
	speak.call(2)
	_check(delivered.size() == 2, "bob is unaffected (%d)" % delivered.size())


func _voice_reconnect(manager: DotModerationManager, peers: Dictionary, speak: Callable, delivered: Array[int]) -> void:
	# The mute has to survive the thing every muted player tries.
	manager.queue_free()
	await get_tree().process_frame

	var rejoined := DotModerationManager.new()
	rejoined.store = DotPunishmentStoreFile.new(DATA.path_join("join.json"))
	rejoined.register_mute_source = true
	rejoined.key_for_peer = func(peer: int) -> String:
		return str(peers.get(peer, "peer:%d" % peer))
	add_child(rejoined)
	await get_tree().process_frame
	await rejoined.load_all()

	delivered.clear()
	speak.call(1)
	_check(
		delivered.is_empty(),
		"she is still silenced after a reconnect",
		"which is the entire point of the addon"
	)

	await _voice_unmapped(rejoined, speak, delivered)
	rejoined.queue_free()


func _voice_unmapped(rejoined: DotModerationManager, speak: Callable, delivered: Array[int]) -> void:
	# And lifting it restores her, through the same seam.
	await rejoined.revoke_all("uid:alice", DotPunishment.Kind.VOICE_MUTE, "admin:sarah")
	delivered.clear()
	speak.call(1)
	_check(delivered.size() == 2, "lifting the mute lets her talk again")

	# The mapping is the part that fails silently, so it is asserted rather than trusted.
	var unmapped := DotModerationManager.new()
	unmapped.store = DotPunishmentStoreFile.new(DATA.path_join("unmapped.json"))
	unmapped.register_mute_source = false
	add_child(unmapped)
	await get_tree().process_frame
	await unmapped.load_all()
	await unmapped.issue(
		DotPunishment.Kind.VOICE_MUTE, "uid:alice", "spam", "console", 600
	)
	_check(
		not unmapped.is_voice_muted(1),
		"with no key_for_peer, a peer id does not match a durable subject",
		"which is correct, silent, and enforces nothing: hence the warning it prints"
	)
	var lines := unmapped.describe_lines()
	var warned := false
	for line in lines:
		if line.contains("WARNING"):
			warned = true
	_check(
		warned,
		"so describe_lines says so where an operator will see it",
		"a mapping nobody set is a moderation system punishing the wrong people"
	)
	unmapped.queue_free()


## Whether GameSpice Voice is linked into this project.
## Checked by path, not by class name: naming an absent `class_name` makes the suite fail
## to parse, and a scene that fails to parse hangs.
func _voice_is_present() -> bool:
	return ResourceLoader.exists("res://addons/dot_voice/runtime/dot_voice_router.gd")


func _test_schema() -> void:
	_section("the punishment table, as a spec dot-sql renders")

	# The spec, not the DDL: rendering it per dialect is GameSpice SQL's job and is tested
	# there, against real SQLite, Postgres and MySQL. What this addon owns is which
	# columns exist, which are keys, and which are indexed.
	var spec := DotPunishmentSchema.table_spec()
	_check(DotSqlSchema.validate(spec).ok, "the table spec is valid", str(DotSqlSchema.validate(spec).error))

	var columns := {}
	for column in spec["columns"]:
		columns[column["name"]] = column["type"]

	# Named individually rather than by counting, because a count passes when two of
	# them are swapped.
	for column in ["subject", "reason", "expires_at", "issuer", "kind", "revoked"]:
		_check(columns.has(column), "has %s" % column)
	_check(
		columns.size() == DotPunishmentSchema.COLUMNS.size(),
		"one column per mapped field (%d)" % columns.size()
	)
	_check(
		spec["primary_key"] == ["id"],
		"the id is the primary key",
		"which is what makes a write idempotent rather than duplicating a ban"
	)
	_check(
		columns["subject"] == "key" and columns["id"] == "key",
		"indexed strings are keys, not text",
		"MySQL cannot index a TEXT column without a prefix length"
	)
	_check(
		columns["expires_at"] == "bigint",
		"expiry is Unix seconds in a BIGINT, not a timestamp"
	)
	var index_names := []
	for index in spec["indexes"]:
		index_names.append(index["name"])
	_check(
		index_names.has("subject_idx"),
		"subject is indexed",
		"every question this table is asked is 'what is against this person', on "
		+ "the join path, while a player waits"
	)
	_check(index_names.has("active_idx"), "and so is what is still in force")

	# Rendered for MySQL, the one with the traps.
	var mysql := DotSqlSchema.ddl(spec, DotSqlDialect.Kind.MYSQL)
	_check(
		mysql.size() == 1 and mysql[0].contains("KEY dot_punishments_subject_idx"),
		"mysql: indexes inside the CREATE TABLE",
		"MySQL 8 has no CREATE INDEX IF NOT EXISTS"
	)
	_check(
		not DotPunishmentSchema.select_by_subject().contains("$"),
		"statements use ? in every dialect"
	)

	_check_schema_rows()
	_done()


func _check_schema_rows() -> void:
	# The row mapping, both directions, including the trap that already bit this addon.
	var mute := DotPunishment.create(
		DotPunishment.Kind.VOICE_MUTE, "uid:1", "mic spam", "admin:sarah", 600
	)
	mute.evidence = {"demo": "r3.dem"}
	var row := DotPunishmentSchema.to_row(mute)

	_check(
		row.size() == DotPunishmentSchema.COLUMNS.size(),
		"a row has one value per column (%d)" % row.size()
	)
	_check(
		row[1] == "voice_mute",
		"and stores the machine token (%s)" % str(row[1]),
		"writing the player-facing name is the bug that made every stored mute load "
		+ "back as a warning"
	)

	var back := DotPunishmentSchema.from_row(row)
	_check(back.kind == DotPunishment.Kind.VOICE_MUTE, "a row round-trips its kind")
	_check(back.subject == "uid:1" and back.reason == "mic spam", "and its content")
	_check(back.expires_at == mute.expires_at, "and its expiry")
	_check(
		back.evidence.get("demo", "") == "r3.dem",
		"and its evidence, through JSON in a text column"
	)

	# A driver may hand a boolean back as a bool, an int or a string, and only one of
	# those is what any given backend does.
	for revoked_value in [true, 1, "1"]:
		var mapped := DotPunishmentSchema.from_row({
			"id": "x", "subject": "uid:2", "kind": "ban", "revoked": revoked_value
		})
		_check(mapped.revoked, "revoked reads as true from %s" % type_string(typeof(revoked_value)))
	for falsey in [false, 0, "0", ""]:
		var mapped := DotPunishmentSchema.from_row({
			"id": "x", "subject": "uid:2", "kind": "ban", "revoked": falsey
		})
		_check(not mapped.revoked, "and false from %s" % type_string(typeof(falsey)))

	# Rows come back as a Dictionary from some drivers and an Array from others.
	var as_array := DotPunishmentSchema.from_row(row)
	_check(as_array != null and as_array.id == mute.id, "an array row maps too")
	_check(DotPunishmentSchema.from_row("nonsense") == null, "and nonsense maps to null")


func _test_sql_store() -> void:
	_section("the SQL store, against a driver that records what it is asked")

	# The store's job is to send the right statements, bind values in the right order
	# and map rows back. None of that needs a real engine; examples/moderation_sql_live
	# runs the same store against real databases through GameSpice SQL's gateway.
	var driver := DotSqlDriverRecording.new(DotSqlDialect.Kind.POSTGRES)
	driver.answers = {"SELECT version FROM": []}
	var store := DotPunishmentStoreSql.new(driver)

	var opened: DotResult = await store.open()
	_check(opened.ok, "the store opens and creates its schema", str(opened.error))
	_check(
		driver.matching("CREATE TABLE IF NOT EXISTS dot_punishments").size() == 1,
		"the table is created"
	)
	_check(driver.matching("CREATE INDEX").size() >= 2, "and the indexes")
	_check(
		driver.matching("INSERT INTO dot_sql_migrations").size() == 1,
		"and its schema version recorded",
		"so a build that meets a newer database refuses it rather than misreading it"
	)
	_check(store.is_writable(), "and reports itself writable")

	driver.clear()

	var ban := DotPunishment.create(
		DotPunishment.Kind.BAN, "uid:42", "cheating; said 'hi'", "admin:sarah", 86400
	)
	var written: DotResult = await store.put(ban)
	_check(written.ok, "a ban is written", str(written.error))

	var inserts := driver.matching("INSERT INTO")
	if _check(inserts.size() == 1, "as one statement (%d)" % inserts.size()):
		var statement: Dictionary = inserts[0]
		var params: Array = statement["params"]

		_check(
			params.size() == DotPunishmentSchema.COLUMNS.size(),
			"with one bound parameter per column (%d)" % params.size()
		)
		# The reason contains a quote. If it reached the statement text rather than the
		# parameters, this is where it would show.
		_check(
			not str(statement["sql"]).contains("cheating"),
			"and the reason is bound, never interpolated",
			"the whole point of parameterised statements"
		)
		_check(
			params.has("cheating; said 'hi'"),
			"so a quote in a ban reason is just a value"
		)
		_check(
			str(statement["sql"]).contains("ON CONFLICT"),
			"a write is an upsert",
			"a retry after a timeout must not produce two records for one ban"
		)

	await _sql_reads(driver, store, ban)

	await _sql_edges()

	_done()


func _sql_edges() -> void:
	# A database written by a newer build is refused, not read.
	var newer := DotSqlDriverRecording.new(DotSqlDialect.Kind.SQLITE)
	newer.answers = {"SELECT version FROM": [{"version": 99}]}
	var refused: DotResult = await DotPunishmentStoreSql.new(newer).open()
	_check(
		not refused.ok,
		"a database from a newer build is refused",
		"columns that changed meaning underneath an old build are a ban that reads wrong"
	)

	# And the driver nobody has installed says so rather than failing later.
	var missing := DotSqlDriverSqlite.new("user://never.db")
	var available := missing.is_available()
	_check(
		not available.ok,
		"the SQLite driver reports the extension is absent",
		"rather than failing on the first write"
	)


func _sql_reads(driver: DotSqlDriverRecording, store: DotPunishmentStoreSql, ban: DotPunishment) -> void:
	# Reading back, through the real row mapping.
	driver.clear()
	driver.rows = [DotPunishmentSchema.to_row(ban)]
	var loaded: DotResult = await store.load_all()
	_check(loaded.ok, "the store reads", str(loaded.error))
	_check(
		loaded.ok and (loaded.value as Array).size() == 1,
		"one record comes back"
	)
	if loaded.ok and (loaded.value as Array).size() == 1:
		var read: DotPunishment = (loaded.value as Array)[0]
		_check(read.subject == "uid:42", "with its subject")
		_check(read.kind == DotPunishment.Kind.BAN, "its kind")
		_check(read.reason == "cheating; said 'hi'", "and its reason intact")

	# The query a live server makes on the join path.
	driver.clear()
	driver.rows = [DotPunishmentSchema.to_row(ban)]
	var one: DotResult = await store.load_for("uid:42")
	_check(one.ok, "a single subject can be looked up")
	_check(
		driver.statements.size() == 1
			and str(driver.statements[0]["sql"]).contains("WHERE subject"),
		"with a WHERE rather than by reading the whole table"
	)
	_check(
		(driver.statements[0]["params"] as Array) == ["uid:42"],
		"and the subject bound"
	)

	# A row the table should not have had does not condemn the rest.
	driver.clear()
	driver.rows = [
		DotPunishmentSchema.to_row(ban),
		{"id": "", "subject": "", "kind": "ban"},
	]
	var partial: DotResult = await store.load_all()
	_check(
		partial.ok and (partial.value as Array).size() == 1,
		"one unusable row does not condemn the table (%d loaded)"
			% ((partial.value as Array).size() if partial.ok else -1)
	)

	# A driver failure is a failure, not an empty list.
	driver.clear()
	driver.fail_next = "connection reset"
	var failed: DotResult = await store.load_all()
	_check(
		not failed.ok,
		"a read failure is reported rather than read as 'nobody is punished'"
	)


func _test_rest_store() -> void:
	_section("the REST store, against a real HTTP server")

	var api: Node = preload("res://examples/punishment_api_server.gd").new()
	api.name = "PunishmentApi"
	add_child(api)

	var started: DotResult = api.start(0)
	if not _check(started.ok, "a punishment API is listening", str(started.error)):
		api.queue_free()
		_done()
		return

	var http := DotHttp.new()
	http.name = "Http"
	add_child(http)
	await get_tree().process_frame

	var store := DotPunishmentStoreRest.new(api.base_url(), http)
	store.token = "secret-token"
	api.require_token = "secret-token"

	var ban := DotPunishment.create(
		DotPunishment.Kind.BAN, "uid:77", "aimbot", "admin:sarah", 86400
	)

	var written: DotResult = await store.put(ban)
	_check(written.ok, "a ban is PUT to the API", str(written.error))
	_check(api.records.has(ban.id), "and the API has it")
	_check(
		api.log.size() > 0 and str(api.log[0]).begins_with("PUT /punishments/"),
		"to the record's own URL (%s)" % [api.log[0] if api.log.size() > 0 else "-"],
		"so a retry after a timeout cannot create a second record"
	)

	var loaded: DotResult = await store.load_all()
	_check(loaded.ok, "the list is read back", str(loaded.error))
	_check(
		loaded.ok and (loaded.value as Array).size() == 1,
		"with the record in it"
	)
	if loaded.ok and (loaded.value as Array).size() == 1:
		var read: DotPunishment = (loaded.value as Array)[0]
		_check(read.subject == "uid:77" and read.reason == "aimbot", "intact")
		_check(read.kind == DotPunishment.Kind.BAN, "and still a ban")
		_check(read.expires_at == ban.expires_at, "with its expiry")

	# The query a live server makes.
	await store.put(DotPunishment.create(
		DotPunishment.Kind.GAG, "uid:88", "spam", "console", 600
	))
	var filtered: DotResult = await store.load_for("uid:77")
	_check(
		filtered.ok and (filtered.value as Array).size() == 1,
		"one subject can be asked for (%d)"
			% ((filtered.value as Array).size() if filtered.ok else -1)
	)

	# A whole manager on top of the API, which is the shape a deployment runs.
	var manager := DotModerationManager.new()
	manager.store = store
	manager.register_mute_source = false
	add_child(manager)
	await get_tree().process_frame
	var pulled: DotResult = await manager.load_all()
	_check(pulled.ok, "a manager loads from the API")
	_check(manager.is_banned_key("uid:77"), "and enforces what it found")
	_check(manager.is_gagged_key("uid:88"), "for every record")

	await _check_rest_failures(api, store, manager, ban)

	manager.queue_free()
	http.queue_free()
	api.stop()
	api.queue_free()
	await get_tree().process_frame
	_done()


func _check_rest_failures(
	api: Node, store: DotPunishmentStoreRest, manager: DotModerationManager, ban: DotPunishment
) -> void:
	# The failures, which are the reason a real server is worth the hundred lines.
	api.fail_all = true
	var broke: DotResult = await store.load_all()
	_check(not broke.ok, "a 500 is a failure")
	var still: DotResult = await manager.load_all()
	_check(not still.ok, "which reaches the manager")
	_check(
		manager.is_banned_key("uid:77"),
		"and the manager keeps what was already in force",
		"an API outage must never read as 'nobody is banned'"
	)
	api.fail_all = false

	api.serve_garbage = true
	var garbage: DotResult = await store.load_all()
	_check(not garbage.ok, "a body that is not JSON is a failure")
	api.serve_garbage = false

	api.serve_wrong_shape = true
	var wrong: DotResult = await store.load_all()
	_check(
		not wrong.ok,
		"and so is JSON with no punishments array",
		"which would otherwise read as an empty list, so nobody is banned"
	)
	api.serve_wrong_shape = false

	store.token = "wrong"
	var refused: DotResult = await store.load_all()
	_check(not refused.ok, "a bad token is refused by the API")
	store.token = "secret-token"

	store.writable = false
	var readonly: DotResult = await store.put(ban)
	_check(
		not readonly.ok,
		"a read-only API refuses a write rather than pretending",
		"for a community that issues bans on its website"
	)
	store.writable = true

	var removed: DotResult = await store.remove(ban.id)
	_check(removed.ok, "a record can be deleted")
	_check(not api.records.has(ban.id), "and is gone from the API")
