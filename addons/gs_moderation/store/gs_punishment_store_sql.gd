@tool
class_name GSPunishmentStoreSql
extends GSPunishmentStore

## Punishments in a real table, in whichever SQL a GameSpice SQL driver speaks.
##
## [codeblock]
## var store := GSPunishmentStoreSql.new(GSSqlDriverSqlite.new("user://moderation.db"))
## var opened := await store.open()      # creates or migrates the table
## [/codeblock]
##
## [b]The driver is duck-typed[/b] — held untyped and asked for `query`, `execute`,
## `upsert_sql` and `migrate` — so GameSpice Moderation does not depend on GameSpice SQL and parses in
## a project without it. Any object with those methods will do; GameSpice SQL's are the ones that
## exist. The table is [method GSPunishmentSchema.table_spec], rendered by the driver for
## its own dialect, so this class contains no `if postgres` anywhere.
##
## [b]Statements are parameterised, always.[/b] A ban reason is typed by a moderator and
## half of them quote the name the offender was using, so it is exactly the string that
## must never reach SQL by concatenation. Nothing here builds a WHERE clause out of a
## value.

## Where statements go: a GameSpice SQL driver, or anything shaped like one.
var driver = null

## Table name, in case an operator already owns `punishments`.
var table: String = GSPunishmentSchema.DEFAULT_TABLE

## Create or migrate the table on [method open].
##
## On, because creation is `IF NOT EXISTS` and an operator who made the table by hand is
## not fought with. Off for a deployment whose schema is managed elsewhere and which
## would rather this touched nothing.
var create_schema: bool = true

## Diagnostics.
var loads: int = 0
var writes: int = 0


func _init(p_driver = null) -> void:
	driver = p_driver


func store_name() -> String:
	return "sql/%s" % (driver.driver_name() if driver != null else "none")


func is_writable() -> bool:
	return driver != null and driver.is_open()


## Opens the driver and, unless told not to, creates the table.
func open() -> GSResult:
	if driver == null:
		return GSResult.fail(GSError.CODE_STATE, "No SQL driver.")

	var available: GSResult = driver.is_available()
	if not available.ok:
		return available

	var opened: GSResult = await driver.open()
	if not opened.ok:
		return opened

	if not create_schema:
		return GSResult.success(true)

	# Versioned rather than "create if missing": a database from an older build is
	# brought forward, and one from a NEWER build is refused rather than read with
	# columns that have changed meaning underneath it. One component per table, so two
	# stores with different table names in one database keep separate versions.
	var migrated: GSResult = await driver.migrate(
		"%s:%s" % [GSPunishmentSchema.MIGRATION_COMPONENT, table],
		GSPunishmentSchema.migration_steps(table)
	)

	if not migrated.ok:
		return migrated.wrap("Could not prepare the punishment table.")

	GSLog.info(CHANNEL, "punishment table ready", {
		"dialect": GSPunishmentSchema.dialect_name(int(driver.dialect())),
		"table": table,
	})

	return GSResult.success(true)


func close() -> void:
	if driver != null:
		driver.close()


func load_all() -> GSResult:
	if driver == null or not driver.is_open():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	var result: GSResult = await driver.query(
		GSPunishmentSchema.select_all(table), []
	)

	if not result.ok:
		return result.wrap("Could not read the punishment table.")

	var loaded: Array[GSPunishment] = []
	var skipped := 0

	for row in (result.value as Array):
		var punishment := GSPunishmentSchema.from_row(row)

		if punishment == null:
			skipped += 1
			continue

		var valid := punishment.validate()

		if not valid.ok:
			# One bad row does not condemn the table, for the same reason one bad entry
			# does not condemn the JSON file: a community with fifty thousand records
			# and one hand-edited row should moderate with the rest and be told which.
			GSLog.warn(CHANNEL, "skipping an unusable row", {
				"why": valid.error.message, "id": punishment.id
			})
			skipped += 1
			continue

		loaded.append(punishment)

	loads += 1

	if skipped > 0:
		GSLog.warn(CHANNEL, "the punishment table had unusable rows", {
			"skipped": skipped, "loaded": loaded.size()
		})

	return GSResult.success(loaded)


## Reads only what is against one subject.
##
## [b]The one query a live server makes.[/b] `load_all` is a boot-time operation; this is
## what a join asks, while a player waits, and it is why `subject` is indexed. A
## deployment with a shared database uses this rather than caching everything, so a mute
## set on another server is in force here on the next connection rather than on the next
## restart.
func load_for(subject: String) -> GSResult:
	if driver == null or not driver.is_open():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	var result: GSResult = await driver.query(
		GSPunishmentSchema.select_by_subject(table), [subject]
	)

	if not result.ok:
		return result.wrap("Could not read punishments for a player.")

	var loaded: Array[GSPunishment] = []

	for row in (result.value as Array):
		var punishment := GSPunishmentSchema.from_row(row)
		if punishment != null and punishment.validate().ok:
			loaded.append(punishment)

	return GSResult.success(loaded)


func put(punishment: GSPunishment) -> GSResult:
	if punishment == null:
		return GSResult.fail(GSError.CODE_INVALID, "No punishment to store.")

	var valid := punishment.validate()
	if not valid.ok:
		return valid

	if driver == null or not driver.is_open():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	# An upsert, not an insert. A retry after a network failure must not produce two
	# records for one action, which is how a duplicate ban ends up in somebody's history
	# and how a revoke ends up applying to only one of them.
	var result: GSResult = await driver.execute(
		driver.upsert_sql(table, PackedStringArray(GSPunishmentSchema.COLUMNS), PackedStringArray(["id"])),
		GSPunishmentSchema.to_row(punishment)
	)

	if not result.ok:
		return result.wrap("Could not write the punishment.")

	writes += 1
	return GSResult.success(true)


func remove(id: String) -> GSResult:
	if driver == null or not driver.is_open():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	var result: GSResult = await driver.execute(
		GSPunishmentSchema.delete_by_id(table), [id]
	)

	if not result.ok:
		return result.wrap("Could not remove the punishment.")

	writes += 1
	return GSResult.success(true)


func describe() -> Dictionary:
	return {
		"store": store_name(),
		"writable": is_writable(),
		"table": table,
		"dialect": GSPunishmentSchema.dialect_name(int(driver.dialect()) if driver != null else -1),
		"loads": loads,
		"writes": writes,
		"driver": driver.describe() if driver != null else {},
	}
