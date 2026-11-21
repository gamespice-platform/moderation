@tool
class_name GSPunishmentStoreFile
extends GSPunishmentStore

## Punishments in a JSON file, which is right for one server and wrong for eight.
##
## The format is a list rather than a map keyed by subject, because a player can have
## several records at once (a gag and a voice mute with different expiries) and because
## the history is worth keeping after a record stops being in force.
##
## [b]Written whole, every time, and that is a deliberate trade.[/b] A community server's
## list is thousands of entries at most, so rewriting it costs milliseconds; an
## append-only log would be faster and would need compaction, a reader that understands
## tombstones, and a recovery path for a half-written record. The failure mode of the
## simple version is bounded and the failure mode of the clever one is a corrupt list
## nobody can moderate with.

const FORMAT_VERSION := 1

var path: String = "user://moderation.json"

## Diagnostics.
var loads: int = 0
var writes: int = 0

## Everything read or written, id -> GSPunishment. The file is the truth; this is a
## cache so a write does not have to re-read.
var _records: Dictionary = {}


func _init(p_path: String = "user://moderation.json") -> void:
	path = p_path


func store_name() -> String:
	return "file"


func is_writable() -> bool:
	return true


func load_all() -> GSResult:
	if not FileAccess.file_exists(path):
		# Not an error. A server that has never punished anybody has no file, and
		# treating that as a failure would make every fresh install look broken.
		_records.clear()
		loads += 1
		return GSResult.success([])

	var read := GSPaths.read_text(path)

	if not read.ok:
		return read.wrap("Could not read the moderation file.")

	var parsed: Variant = JSON.parse_string(str(read.value))

	if not (parsed is Dictionary):
		# [b]Loud, and the caller keeps what it has.[/b] Silently meaning "nobody is
		# punished" turns a typo into an unmoderated server, which is the same reasoning
		# GameSpice Server's admin file uses.
		return GSResult.fail(
			GSError.CODE_INVALID,
			"The moderation file is not a JSON object.",
			path
		)

	var document: Dictionary = parsed
	var version := int(document.get("format_version", 1))

	if version > FORMAT_VERSION:
		return GSResult.fail(
			GSError.CODE_UNSUPPORTED,
			"The moderation file was written by a newer version of gs-moderation.",
			"file says %d, this build reads %d" % [version, FORMAT_VERSION]
		)

	var loaded: Array[GSPunishment] = []
	var skipped := 0

	var entries: Variant = document.get("punishments", [])

	if entries is Array:
		for entry in (entries as Array):
			if not (entry is Dictionary):
				skipped += 1
				continue

			var punishment := GSPunishment.from_dictionary(entry as Dictionary)
			var valid := punishment.validate()

			if not valid.ok:
				# One bad entry does not condemn the file, for the same reason GameSpice Map's
				# catalogue tolerates one: a server with nine hundred good records and
				# one typo should moderate with the nine hundred and say which one it
				# dropped.
				GSLog.warn(CHANNEL, "skipping an unusable punishment", {
					"why": valid.error.message
				})
				skipped += 1
				continue

			loaded.append(punishment)

	_records.clear()
	for punishment in loaded:
		_records[punishment.id] = punishment

	loads += 1

	if skipped > 0:
		GSLog.warn(CHANNEL, "the moderation file had unusable entries", {
			"skipped": skipped, "loaded": loaded.size(), "path": path
		})

	return GSResult.success(loaded)


func put(punishment: GSPunishment) -> GSResult:
	if punishment == null:
		return GSResult.fail(GSError.CODE_INVALID, "No punishment to store.")

	var valid := punishment.validate()
	if not valid.ok:
		return valid

	_records[punishment.id] = punishment
	return _flush()


func remove(id: String) -> GSResult:
	if not _records.has(id):
		return GSResult.fail(
			GSError.CODE_IO, "No punishment with that id.", id
		)
	_records.erase(id)
	return _flush()


func _flush() -> GSResult:
	var entries: Array = []

	for key in _records.keys():
		entries.append((_records[key] as GSPunishment).to_dictionary())

	var document := {
		"format_version": FORMAT_VERSION,
		"written_at": int(Time.get_unix_time_from_system()),
		"punishments": entries,
	}

	var written := GSPaths.write_text(path, JSON.stringify(document, "  "))

	if not written.ok:
		return written.wrap("Could not write the moderation file.")

	writes += 1

	# The browser mirrors `user://` into IndexedDB and needs an explicit flush, and a tab
	# closed before one loses the write. Every write path in this family calls it.
	GSWeb.sync_filesystem()

	return GSResult.success(_records.size())


func count() -> int:
	return _records.size()


func describe() -> Dictionary:
	return {
		"store": store_name(),
		"writable": true,
		"path": path,
		"records": _records.size(),
		"loads": loads,
		"writes": writes,
	}
