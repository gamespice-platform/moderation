class_name DotModToolsInternals
extends RefCounted

## What [DotModTools] delegates: argument rules, the landing stand-off, tracking, history filing and the report.
## Split out of the class so no file passes the size budget; it holds no state of its own.

## Why [param args] cannot be what [param action] means, or empty.
## Here, not in each game's handler: the game that forgot would let "health 0" slay.
static func validate(action: StringName, args: Dictionary) -> String:
	# Before any rule about one number: `1e999` is a valid float and is infinity, which
	# made a timer that never fires and a slap that did infinite damage past god.
	for key: Variant in args:
		var value: Variant = args[key]
		if (value is float or value is int) and not is_finite(float(value)):
			return "That is not a number anybody can use."
	if float(args.get("seconds", 0.0)) > DotModTools.MAX_SECONDS:
		return "At most %d seconds." % int(DotModTools.MAX_SECONDS)
	if float(args.get("damage", 0.0)) > DotModTools.MAX_DAMAGE:
		return "At most %d damage; use slay to kill somebody." % int(DotModTools.MAX_DAMAGE)

	match action:
		DotModTools.ACTION_HEALTH:
			var value := float(args.get("value", 0.0))
			if value <= 0.0:
				return "Health has to be above zero. Use slay to kill somebody."
		DotModTools.ACTION_SPEED, DotModTools.ACTION_GRAVITY:
			if float(args.get("scale", 0.0)) <= 0.0:
				return "A multiplier has to be above zero."
		DotModTools.ACTION_SLAP:
			if float(args.get("damage", 0.0)) < 0.0:
				return "A slap cannot heal."
		DotModTools.ACTION_GIVE:
			if str(args.get("item", "")).strip_edges() == "":
				return "Give what?"
		DotModTools.ACTION_RENAME:
			if str(args.get("name", "")).strip_edges() == "":
				return "Rename them to what?"
		DotModTools.ACTION_BURN:
			if float(args.get("seconds", 0.0)) <= 0.0:
				return "Burn for how long?"

	if DotModTools.TOGGLES.has(action) and not (args.get("on") is bool):
		return "Say whether to turn %s on or off." % String(action)

	return ""


## Moves a landing point back toward the arriving player, so nobody lands inside anybody.
static func stand_off(destination: Variant, arriving_from: Variant, standoff: float) -> Variant:
	if standoff <= 0.0:
		return destination

	if destination is Vector3:
		var to3 := destination as Vector3
		var from3 := arriving_from as Vector3 if arriving_from is Vector3 else Vector3.ZERO
		var away3 := to3 - from3
		# A zero-length direction means the two are already in the same place, which is
		# the case the stand-off exists for, so any direction beats normalising zero.
		if away3.length_squared() < 0.0001:
			away3 = Vector3.BACK
		return to3 - away3.normalized() * standoff

	if destination is Vector2:
		var to2 := destination as Vector2
		var from2 := arriving_from as Vector2 if arriving_from is Vector2 else Vector2.ZERO
		var away2 := to2 - from2
		if away2.length_squared() < 0.0001:
			away2 = Vector2.UP
		return to2 - away2.normalized() * standoff

	return destination


static func track(
	t: DotModTools, action: StringName, actor: StringName, target: StringName,
	args: Dictionary, result: DotResult
) -> void:
	if DotModTools.TOGGLES.has(action):
		var holders: Dictionary = t._toggles.get(action, {})

		if bool(args.get("on", false)):
			t._grants += 1
			holders[target] = {
				"by": actor, "at": int(Time.get_unix_time_from_system()), "serial": t._grants,
			}
		else:
			holders.erase(target)

		t._toggles[action] = holders
		t.toggled.emit(action, target, bool(args.get("on", false)), actor)
		return

	if DotModTools.MULTIPLIERS.has(action):
		var applied := float(args.get("scale", 1.0))

		if result.value is float or result.value is int:
			applied = float(result.value)

		var entries: Dictionary = t._multipliers.get(action, {})

		if is_equal_approx(applied, 1.0):
			entries.erase(target)
		else:
			entries[target] = {"value": applied, "by": actor}

		t._multipliers[action] = entries
		return

	# A slay untracks nothing: respawned() switches the handlers' modifiers off, and
	# untracking here would leave a frozen modifier the record says is free.


## Puts the action on somebody's history as a WARN: it enforces nothing and is there to be
## read when a player asks why they moved.
static func record(
	t: DotModTools, subject: StringName, action: StringName, actor: StringName, target: StringName,
	detail: Dictionary = {}
) -> void:
	if not t.record_actions or t.manager == null:
		return

	var evidence := {
		"action": String(action),
		"actor": String(actor),
		"target": String(target),
	}

	# What was done, not only that something was: "slapped for 90" and "slapped for 0" are
	# different conversations with the player who asks.
	for key: Variant in detail:
		var value: Variant = detail[key]
		if value is bool or value is int or value is float or value is String:
			evidence[str(key)] = value

	var filed_as := String(subject)
	if t.subject_fn.is_valid():
		var mapped := str(t.subject_fn.call(subject))
		if mapped != "":
			filed_as = mapped

	# The evidence goes in with the record, not onto it afterwards: a store writes what it
	# was handed, and a detail set after the write reached no store but the file one.
	var result: DotResult = await t.manager.issue(
		DotPunishment.Kind.WARN,
		filed_as,
		"%s by %s" % [String(action), String(actor)],
		String(actor),
		0,
		0,
		evidence
	)

	if not result.ok:
		DotLog.debug(DotModTools.CHANNEL, "could not record a moderator action", {
			"why": result.error.message
		})


static func describe_lines(t: DotModTools) -> PackedStringArray:
	var out := PackedStringArray()

	out.append("actions   %d taken, %d refused" % [t.actions_taken, t.actions_refused])
	out.append("wiring    %s%s" % [
		"position_fn set" if t.position_fn.is_valid() else "NO position_fn",
		", t.teleport_fn set" if t.teleport_fn.is_valid() else ", NO teleport_fn",
	])

	if not t.teleport_fn.is_valid() or not t.position_fn.is_valid():
		# Surfaced where an operator looks. Without both callables every move here
		# refuses, which is safe and is also indistinguishable from nobody using it.
		out.append("WARNING   without both callables every teleport is refused")

	out.append("returns   %d players have somewhere to go back to" % t._history.size())

	var supported := t.abilities()
	out.append("abilities %s" % (", ".join(supported) if not supported.is_empty() else "none"))

	var refused_list := PackedStringArray()
	for action in DotModTools.ABILITIES:
		if not t.supports(action):
			var why: String = str(t.unsupported_reasons.get(action, ""))
			refused_list.append(String(action) if why == "" else "%s (%s)" % [String(action), why])

	if not refused_list.is_empty():
		out.append("refused   %s" % "; ".join(refused_list))

	for action in DotModTools.TOGGLES:
		var holders: Dictionary = t._toggles.get(action, {})
		for target: Variant in holders:
			out.append("on        %s %s, by %s" % [
				String(action), str(target), str((holders[target] as Dictionary).get("by", "?"))
			])

	for action in DotModTools.MULTIPLIERS:
		var entries: Dictionary = t._multipliers.get(action, {})
		for target: Variant in entries:
			var entry: Dictionary = entries[target]
			out.append("on        %s %s x%s, by %s" % [
				String(action), str(target), str(snappedf(float(entry.get("value", 1.0)), 0.01)),
				str(entry.get("by", "?")),
			])

	return out
