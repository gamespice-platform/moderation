class_name GSModToolCompletion
extends RefCounted

## Console completion lists for [GSModToolCommands]; no state of its own.

## Names (and with [param selectors] the @-selectors) that start with [param partial].
static func players(server: Object, alive_fn: Callable, partial: String, selectors: bool) -> PackedStringArray:
	var out := PackedStringArray()
	var lowered := partial.to_lower()

	if selectors:
		for selector in ["@me", "@all", "@others"]:
			if selector.begins_with(lowered):
				out.append(selector)
		if alive_fn.is_valid():
			for selector in ["@alive", "@dead"]:
				if selector.begins_with(lowered):
					out.append(selector)

	var everyone: Variant = server.call("playing_sessions") if server.has_method("playing_sessions") else []

	for session: Variant in everyone:
		var shown := str((session as Object).get("display_name"))
		if lowered == "" or shown.to_lower().begins_with(lowered):
			# Quoted so a name with a space stays one argument.
			out.append("\"%s\"" % shown if shown.contains(" ") else shown)

	return out


## Entries of [param values] that start with [param partial].
static func from_list(values: Variant, partial: String) -> PackedStringArray:
	var out := PackedStringArray()
	var list: Array = []

	if values is PackedStringArray:
		list = Array(values as PackedStringArray)
	elif values is Array:
		list = values as Array

	for value: Variant in list:
		if str(value).to_lower().begins_with(partial.to_lower()):
			out.append(str(value))

	return out
