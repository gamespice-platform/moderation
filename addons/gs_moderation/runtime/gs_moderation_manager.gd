@tool
class_name GSModerationManager
extends Node

## Issues, revokes and answers questions about punishments.
##
## [codeblock]
## var mod := GSModerationManager.new()
## mod.store = GSPunishmentStoreFile.new("user://moderation.json")
## add_child(mod)
## await mod.load_all()
##
## await mod.issue(GSPunishment.Kind.VOICE_MUTE, "uid:1234", "mic spam", "admin:sarah", 3600)
## mod.is_voice_muted_key("uid:1234")   # true, and still true after they reconnect
## [/codeblock]
##
## [b]The reason this exists next to GameSpice Server's ban manager, which already bans.[/b]
## GameSpice Server's bans are durable and its mutes are not: `GSClientSession.silence()` sets
## two booleans on a session object, and a session is destroyed when its player
## disconnects. So a muted player reconnects and can talk, which is the first thing
## anybody who has been muted tries, and it is the most common complaint on any community
## server. Bans persisting and mutes not is not a design, it is an accident of where the
## state happened to live.
##
## Here a mute is the same kind of record a ban is: stored, expiring, scoped, revocable
## and on the player's history. GameSpice Server keeps its own ban list and nothing about it
## changes; this is what a deployment adds when it wants a mute to mean something.
##
## [b]It publishes itself as [code]gs_mute_source[/code][/b], which is the name
## [GSVoiceRouter] looks up. That is the whole integration: neither addon imports the
## other, and a project with only one of them works.

const CHANNEL := "moderation"
const SERVICE := &"gs_moderation"

## The registry name GameSpice Voice's router asks for. Answering it is the integration.
const MUTE_SERVICE := &"gs_mute_source"

## The registry name GameSpice Server's admission check looks for.
##
## Same shape as [constant MUTE_SERVICE] and for the same reason: GameSpice Server asks whether
## a connecting client may be admitted, this answers, and neither addon names the other.
## What is registered here answers
## [code]check_admission(uid: String, address: String) -> GSResult[/code].
const BAN_SERVICE := &"gs_ban_source"

## A punishment was issued.
signal punished(punishment: GSPunishment)

## A punishment was lifted early.
signal revoked(punishment: GSPunishment, by: String)

## A punishment ran out. Emitted when a read notices, not on a timer.
signal expired(punishment: GSPunishment)

@export_group("Scope")

## What this server calls itself, matched against [member GSPunishment.scope].
##
## Empty means every punishment applies here, which is what one server wants. A community
## running a surf server and a deathmatch server sets it so a mute on one need not be a
## mute on the other.
@export var server_scope: String = ""

@export_group("Limits")

## Longest punishment a caller with no explicit allowance may issue, in seconds.
##
## 0 removes the ceiling. It exists because "permanent" is a decision a community makes
## deliberately and a junior moderator's first week is not the moment to make it by
## typing a zero.
@export var max_duration_sec: int = 0

## Whether equal immunity may act on equal immunity.
##
## Off, which is the rule every admin system converges on: two moderators at the
## same level
## muting each other in a loop has no correct resolution, so it is forbidden rather than
## raced.
@export var equal_immunity_may_act: bool = false

@export_group("Service")

## Publish under [constant MUTE_SERVICE] so GameSpice Voice finds this without importing it.
@export var register_mute_source: bool = true

## Publish under [constant BAN_SERVICE] so GameSpice Server enforces these bans at connect.
##
## [b]On by default, and it is the difference between a ban and a note about one.[/b]
## Nothing in this addon can refuse a connection — there is no session list here and no
## socket — so a [constant GSPunishment.Kind.BAN] recorded with nobody registered is a
## row in a file that stops nothing. A deployment keeping its bans in GameSpice Server's own
## [code]GSBanManager[/code] instead should turn this off rather than run two lists.
@export var register_ban_source: bool = true

## Where punishments are kept. A file store is created if unset.
var store: GSPunishmentStore = null

## Turns a transport peer id into the durable key a punishment is against.
##
## [b]This is the seam, and getting it wrong is silent.[/b] GameSpice Voice's router asks
## `is_voice_muted(peer)` because a peer id is all a transport knows. A punishment is
## against a durable subject, because a peer id is reused within minutes and means
## nothing after a disconnect. Something has to map one to the other and only the host
## knows how: it is GameSpice User's pseudonymous id on one deployment, an account uid on
## another, a device id for a guest on a third.
##
## Left unset, the mapping is `str(peer)`, which is [b]correct only for a single-process
## test[/b] and is wrong on a real server in a way that enforces nothing and reports
## nothing. [method describe_lines] says so out loud, and so does a warning on the first
## lookup.
var key_for_peer: Callable = Callable()

## id -> GSPunishment, everything known.
var _records: Dictionary = {}
## subject -> Array[String] of ids, so a lookup does not walk every record.
var _by_subject: Dictionary = {}
var _registered: bool = false
var _registered_bans: bool = false
var _warned_about_mapping: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if store == null:
		store = GSPunishmentStoreFile.new()

	GSRegistry.register(SERVICE, self)

	if register_mute_source:
		GSRegistry.register(MUTE_SERVICE, self)
		_registered = true

	if register_ban_source:
		GSRegistry.register(BAN_SERVICE, self)
		_registered_bans = true


func _exit_tree() -> void:
	GSRegistry.unregister_instance(SERVICE, self)
	if _registered:
		GSRegistry.unregister_instance(MUTE_SERVICE, self)
	if _registered_bans:
		GSRegistry.unregister_instance(BAN_SERVICE, self)


# --- Loading ---------------------------------------------------------------

## Reads the store. A failure keeps whatever is already in force.
func load_all() -> GSResult:
	if store == null:
		return GSResult.fail(GSError.CODE_STATE, "No punishment store.")

	var loaded: GSResult = await store.load_all()

	if not loaded.ok:
		# Kept, not cleared. Starting with an empty list on a read error readmits
		# everybody who was ever removed, silently, which is the worst of both.
		GSLog.error(CHANNEL, "could not load punishments; keeping what is in force", {
			"why": loaded.error.message, "in_force": _records.size()
		})
		return loaded

	_records.clear()
	_by_subject.clear()

	for punishment in (loaded.value as Array):
		_index(punishment as GSPunishment)

	GSLog.info(CHANNEL, "punishments loaded", {
		"records": _records.size(), "store": store.store_name()
	})

	return GSResult.success(_records.size())


func _index(punishment: GSPunishment) -> void:
	_records[punishment.id] = punishment

	if not _by_subject.has(punishment.subject):
		_by_subject[punishment.subject] = PackedStringArray()

	var ids: PackedStringArray = _by_subject[punishment.subject]
	if not ids.has(punishment.id):
		ids.append(punishment.id)
		_by_subject[punishment.subject] = ids


# --- Issuing ---------------------------------------------------------------

## Records a punishment and persists it before it takes effect here.
##
## Awaited, and the write happens first: a store that refuses must not leave a punishment
## that exists on one server and nowhere else, which is exactly the split-brain a shared
## store is bought to avoid.
func issue(
	kind: GSPunishment.Kind,
	subject: String,
	reason: String,
	issuer: String = "console",
	duration_sec: int = 0,
	issuer_immunity: int = 0,
	evidence: Dictionary = {}
) -> GSResult:
	if subject.strip_edges() == "":
		return GSResult.fail(
			GSError.CODE_INVALID, "A punishment needs somebody to be against."
		)

	if GSPunishmentSubject.is_address(subject) \
		and not GSPunishmentSubject.is_bannable_address(subject):
		# Loopback locks the operator out of their own listen server, and an address the
		# transport could not report is every client at once. Both are a mistyped
		# argument far more often than they are a decision.
		return GSResult.fail(
			GSError.CODE_INVALID,
			"That address cannot be punished.",
			GSPunishmentSubject.describe(subject)
		)

	if max_duration_sec > 0 and (duration_sec <= 0 or duration_sec > max_duration_sec):
		return GSResult.fail(
			GSError.CODE_FORBIDDEN,
			"That is longer than this server allows.",
			"asked for %s, limit is %s" % [
				"permanent" if duration_sec <= 0
					else GSPunishment.format_duration(duration_sec),
				GSPunishment.format_duration(max_duration_sec)
			]
		)

	var blocking := _immunity_blocking(subject, issuer_immunity)
	if blocking != null:
		return GSResult.fail(
			GSError.CODE_FORBIDDEN,
			"That player is protected by a higher immunity.",
			"theirs %d, yours %d" % [blocking.issuer_immunity, issuer_immunity]
		)

	var punishment := GSPunishment.create(
		kind, subject, reason, issuer, duration_sec, server_scope
	)
	punishment.issuer_immunity = issuer_immunity
	# Before the store sees it. Set afterwards, a SQL or REST store never persisted it and
	# the file store only did on the next unrelated write.
	punishment.evidence = evidence.duplicate(true)

	if store != null and store.is_writable():
		var stored: GSResult = await store.put(punishment)
		if not stored.ok:
			return stored.wrap("The punishment was not recorded, so it was not applied.")
	elif store != null:
		# A legitimate configuration: a server enforcing a centrally managed list. Said
		# plainly rather than appearing to work and vanishing on the next refresh.
		return GSResult.fail(
			GSError.CODE_FORBIDDEN,
			"This server's punishment store is read only.",
			"issued centrally; this server enforces rather than adds"
		)

	_index(punishment)
	punished.emit(punishment)

	GSLog.info(CHANNEL, "punished", {
		"kind": GSPunishment.kind_name(kind),
		"subject": subject,
		"by": issuer,
		"for": "permanent" if duration_sec <= 0
			else GSPunishment.format_duration(duration_sec),
	})

	return GSResult.success(punishment)


## Lifts a punishment early, keeping the record.
func revoke(
	id: String, by: String = "console", reason: String = "", by_immunity: int = 0
) -> GSResult:
	var punishment: Variant = _records.get(id)

	if punishment == null:
		return GSResult.fail(
			GSError.CODE_IO, "No punishment with that id.", id
		)

	var typed: GSPunishment = punishment

	if typed.revoked:
		return GSResult.fail(
			GSError.CODE_STATE, "That punishment has already been lifted."
		)

	# A junior cannot undo a senior's decision, which is the other half of what immunity
	# is for and the half that usually gets left out.
	#
	# [b]Only when the issuer actually had rank.[/b] Requiring strictly greater immunity
	# unconditionally meant a punishment issued at the default of 0 could never be lifted
	# by a caller at the default of 0, which is every ordinary `unmute` on a server that
	# has not configured immunity at all. Zero means "no immunity to respect", not "the
	# highest rank there is".
	if typed.issuer_immunity > 0 and not _may_act_on(by_immunity, typed.issuer_immunity):
		return GSResult.fail(
			GSError.CODE_FORBIDDEN,
			"That was issued by somebody with higher immunity than you.",
			"theirs %d, yours %d" % [typed.issuer_immunity, by_immunity]
		)

	typed.revoked = true
	typed.revoked_by = by
	typed.revoked_at = int(Time.get_unix_time_from_system())
	typed.revoke_reason = reason

	if store != null and store.is_writable():
		var stored: GSResult = await store.update(typed)
		if not stored.ok:
			# Rolled back, so what is in memory matches what is on disk. A revoke that
			# only happened locally comes back on the next load and looks like the
			# moderator's action was ignored.
			typed.revoked = false
			typed.revoked_by = ""
			typed.revoked_at = 0
			typed.revoke_reason = ""
			return stored.wrap("The lift was not recorded, so it was not applied.")

	revoked.emit(typed, by)

	GSLog.info(CHANNEL, "punishment lifted", {"id": id, "by": by})

	return GSResult.success(typed)


## Lifts every active punishment of a kind against a subject. What `unmute` calls.
func revoke_all(
	subject: String,
	kind: GSPunishment.Kind,
	by: String = "console",
	by_immunity: int = 0
) -> GSResult:
	var lifted := 0

	for punishment in active_for(subject):
		if punishment.kind != kind:
			continue
		var result: GSResult = await revoke(punishment.id, by, "", by_immunity)
		if result.ok:
			lifted += 1

	if lifted == 0:
		return GSResult.fail(
			GSError.CODE_STATE,
			"There is nothing of that kind to lift against them.",
			subject
		)

	return GSResult.success(lifted)


# --- Asking ----------------------------------------------------------------

## Every punishment against a subject that is in force here, expired ones removed.
func active_for(subject: String) -> Array[GSPunishment]:
	var out: Array[GSPunishment] = []
	var ids: Variant = _by_subject.get(subject)

	if ids == null:
		return out

	var now := int(Time.get_unix_time_from_system())

	for id in (ids as PackedStringArray):
		var punishment: GSPunishment = _records.get(id)
		if punishment == null:
			continue
		if not punishment.applies_to(server_scope):
			continue
		if punishment.is_active(now):
			out.append(punishment)
		elif not punishment.revoked and punishment.expires_at > 0 \
			and now >= punishment.expires_at:
			# Noticed on read rather than swept on a timer. A server that was off
			# overnight would otherwise come up enforcing yesterday's mutes until its
			# sweep fired.
			expired.emit(punishment)

	return out


## Everything ever recorded against a subject, newest first. The history is the point.
func history_for(subject: String) -> Array[GSPunishment]:
	var out: Array[GSPunishment] = []
	var ids: Variant = _by_subject.get(subject)

	if ids == null:
		return out

	for id in (ids as PackedStringArray):
		var punishment: GSPunishment = _records.get(id)
		if punishment != null:
			out.append(punishment)

	out.sort_custom(
		func(a: GSPunishment, b: GSPunishment) -> bool: return a.issued_at > b.issued_at
	)

	return out


func active_of_kind(subject: String, kind: GSPunishment.Kind) -> GSPunishment:
	for punishment in active_for(subject):
		if punishment.kind == kind:
			return punishment
	return null


func is_banned_key(subject: String) -> bool:
	return active_of_kind(subject, GSPunishment.Kind.BAN) != null


func is_voice_muted_key(subject: String) -> bool:
	return active_of_kind(subject, GSPunishment.Kind.VOICE_MUTE) != null


func is_gagged_key(subject: String) -> bool:
	return active_of_kind(subject, GSPunishment.Kind.GAG) != null


## Bans an address, with the port and any decoration stripped off it.
##
## [b]The blunt instrument, and it is here because the precise one does not always
## exist.[/b] An account ban is exact and survives a reconnect — and only works on a
## player who has an account. A guest comes back as a different guest, which is most of
## the people a server actually has to remove. An address ban catches everybody behind it,
## including a household and everybody behind one NAT, and is defeated by a router reboot.
## Neither is sufficient alone, which is why both exist.
func ban_address(
	address: String,
	reason: String,
	issuer: String = "console",
	duration_sec: int = 0,
	issuer_immunity: int = 0
) -> GSResult:
	var subject := GSPunishmentSubject.for_address(address)

	if subject == "":
		return GSResult.fail(GSError.CODE_INVALID, "No address given.")

	return await issue(
		GSPunishment.Kind.BAN, subject, reason, issuer, duration_sec, issuer_immunity
	)


## Bans a durable person id, whatever a deployment keys people on.
func ban_uid(
	uid: String,
	reason: String,
	issuer: String = "console",
	duration_sec: int = 0,
	issuer_immunity: int = 0
) -> GSResult:
	var subject := GSPunishmentSubject.for_uid(uid)

	if subject == "":
		return GSResult.fail(GSError.CODE_INVALID, "No account id given.")

	return await issue(
		GSPunishment.Kind.BAN, subject, reason, issuer, duration_sec, issuer_immunity
	)


func is_banned_address(address: String) -> bool:
	var subject := GSPunishmentSubject.for_address(address)
	return subject != "" and is_banned_key(subject)


# --- What GameSpice Voice and GameSpice Server call ------------------------------------

## Whether somebody connecting as [param uid] from [param address] may be admitted.
##
## [b]The method GameSpice Server calls on whatever is registered as
## [code]gs_ban_source[/code][/b], and the only way a ban recorded here stops anybody:
## this addon has no session list and no socket, so a ban it enforces itself is a ban
## nobody is refused by.
##
## Either argument may be empty. GameSpice Server asks twice — once on the address before a
## client has said who it is, and again with both once it has — because a ban that is only
## checked after authentication admits the connection, runs the whole handshake and then
## drops it, and an address ban exists precisely to avoid doing that work.
##
## Returns a failure carrying the player-facing message, including when a temporary ban
## lifts. A player who does not know whether they are banned for ten minutes or for ever
## keeps reconnecting, which is worse for the server than telling them.
func check_admission(uid: String, address: String) -> GSResult:
	if address != "":
		var by_address := _refusal(GSPunishmentSubject.for_address(address))
		if by_address != null:
			return _refuse(by_address)

	if uid != "":
		# Both spellings. This addon cannot know whether a deployment writes bare person
		# ids or prefixed ones — both are legal subjects and `key_for_peer` returns
		# whatever the host uses — and checking one spelling enforces nothing for the
		# other, silently, which is the shape of every expensive bug in this family.
		var prefixed := GSPunishmentSubject.for_uid(uid)

		var by_uid := _refusal(prefixed)
		if by_uid != null:
			return _refuse(by_uid)

		if prefixed != uid:
			var bare := _refusal(uid)
			if bare != null:
				return _refuse(bare)

	return GSResult.success(null)


func _refusal(subject: String) -> GSPunishment:
	if subject == "":
		return null
	return active_of_kind(subject, GSPunishment.Kind.BAN)


func _refuse(punishment: GSPunishment) -> GSResult:
	var err := GSError.make(
		GSError.CODE_FORBIDDEN,
		punishment.player_message(),
		"%s, id %s" % [GSPunishmentSubject.describe(punishment.subject), punishment.id]
	)
	# The record itself, so a caller can log or report on it without looking it up again.
	# Never sent to the player: it names the moderator, and that is how a moderator gets
	# harassed.
	err.context = punishment.to_dictionary()

	return GSResult.failure(err)




## Whether a peer may use voice. The method [GSVoiceRouter] duck-types against.
##
## Takes a peer id and maps it through [member key_for_peer], because that is what a
## transport knows and a punishment is against something durable.
func is_voice_muted(peer: int) -> bool:
	return is_voice_muted_key(_subject_for(peer))


## Whether a peer may use text chat.
func is_chat_muted(peer: int) -> bool:
	return is_gagged_key(_subject_for(peer))


## The durable subject a peer's punishments are filed under: [member key_for_peer]'s answer.
## Public for the live tools, which record against a person rather than a session id.
func subject_for_peer(peer: int) -> String:
	return _subject_for(peer)


func _subject_for(peer: int) -> String:
	if key_for_peer.is_valid():
		return str(key_for_peer.call(peer))

	# [b]Warned once, not on every frame.[/b] A voice router asks this fifty times a
	# second per speaker, so a log line per call is itself the bug. Once is enough to
	# find it and quiet enough to leave in.
	if not _warned_about_mapping:
		_warned_about_mapping = true
		GSLog.warn(
			CHANNEL,
			"no key_for_peer is set, so punishments are keyed on transport peer ids",
			{
				"why": "a peer id is reused within minutes and means nothing after a "
					+ "disconnect, so a mute keyed on one is against whoever connects "
					+ "next. Correct for a single-process test and wrong on a server."
			}
		)

	return str(peer)


# --- Immunity --------------------------------------------------------------

func _may_act_on(actor_immunity: int, target_immunity: int) -> bool:
	if actor_immunity > target_immunity:
		return true
	return equal_immunity_may_act and actor_immunity == target_immunity


## The active punishment protecting a subject, if their issuer outranks this actor.
##
## Immunity is carried on the record rather than looked up, because the moderator who set
## it may not be connected, may have been demoted, or may no longer exist. What matters
## is the rank the decision was made at.
func _immunity_blocking(subject: String, actor_immunity: int) -> GSPunishment:
	for punishment in active_for(subject):
		if punishment.issuer_immunity > 0 \
			and not _may_act_on(actor_immunity, punishment.issuer_immunity):
			return punishment
	return null


# --- Reporting -------------------------------------------------------------

func count() -> int:
	return _records.size()


func active_count() -> int:
	var now := int(Time.get_unix_time_from_system())
	var total := 0
	for key in _records.keys():
		var punishment: GSPunishment = _records[key]
		if punishment.is_active(now) and punishment.applies_to(server_scope):
			total += 1
	return total


## Records whose subject or reason contains [param query].
func search(query: String) -> Array[GSPunishment]:
	var needle := query.strip_edges().to_lower()
	var out: Array[GSPunishment] = []

	if needle == "":
		return out

	for key in _records.keys():
		var punishment: GSPunishment = _records[key]
		if punishment.subject.to_lower().contains(needle) \
			or punishment.reason.to_lower().contains(needle) \
			or punishment.id.begins_with(needle):
			out.append(punishment)

	return out


## Bans in force here, which is what makes an unregistered ban source worth warning about.
func _active_bans() -> int:
	var now := int(Time.get_unix_time_from_system())
	var total := 0

	for key in _records.keys():
		var punishment: GSPunishment = _records[key]
		if punishment.kind == GSPunishment.Kind.BAN \
			and punishment.is_active(now) and punishment.applies_to(server_scope):
			total += 1

	return total


func describe() -> Dictionary:
	return {
		"records": _records.size(),
		"active": active_count(),
		"subjects": _by_subject.size(),
		"scope": server_scope if server_scope != "" else "(all)",
		"store": store.describe() if store != null else {},
		"peer_mapping": "host" if key_for_peer.is_valid() else "peer id (NOT for a server)",
		"mute_source": _registered,
		"ban_source": _registered_bans,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("records   %d (%d in force)" % [_records.size(), active_count()])
	out.append("scope     %s" % (server_scope if server_scope != "" else "(all servers)"))
	out.append("store     %s%s" % [
		store.store_name() if store != null else "none",
		"" if store != null and store.is_writable() else " (read only)"
	])

	if not _registered_bans and _active_bans() > 0:
		# A ban here refuses nobody by itself: there is no session list in this addon and
		# no socket. Unregistered, the records are a note about a ban rather than a ban,
		# and the moderator who issued one has no way to tell the difference.
		out.append("WARNING   %d ban(s) in force and nothing is enforcing them:"
			% _active_bans())
		out.append("          register_ban_source is off, so gs-server never asks")

	if not key_for_peer.is_valid():
		# Surfaced where an operator looks, not only in a log line at boot. A mapping
		# nobody set is a moderation system enforcing nothing against the right people.
		out.append("WARNING   no key_for_peer: punishments are keyed on peer ids,")
		out.append("          which are reused and mean nothing after a disconnect")

	return out
