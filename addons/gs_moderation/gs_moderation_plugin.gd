@tool
extends EditorPlugin

## Editor entry point for GameSpice Moderation. Registers inspector types only.
##
## No autoloads. A moderation manager is a tempting singleton and it is the wrong shape
## for the same reason everything else here is: a test that runs two servers in one
## process needs two, and a tool that inspects a shared store while a server uses it
## needs a second one pointed somewhere else.

const _ICON := "res://addons/gs_moderation/icon_placeholder.svg"

const _TYPES := [
	[
		"GSModerationManager",
		"Node",
		"res://addons/gs_moderation/runtime/gs_moderation_manager.gd",
	],
	[
		"GSModTools",
		"Node",
		"res://addons/gs_moderation/tools/gs_mod_tools.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
