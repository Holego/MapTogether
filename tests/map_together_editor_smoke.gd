@tool
extends EditorPlugin

var failed = false
func _enter_tree(): _run.call_deferred()
func check(value: bool, description: String):
	print("EDITOR %s: %s" % ["PASS" if value else "FAIL", description])
	failed = failed or not value

func _run():
	for i in range(35): await get_tree().process_frame
	var plugins = get_tree().root.find_children("*", "EditorPlugin", true, false)
	var plugin
	for candidate in plugins:
		if candidate.get_script() and candidate.get_script().resource_path == "res://addons/coop_collab/plugin.gd": plugin = candidate
	check(plugin != null, "MapTogether loads as a single editor addon")
	if plugin == null:
		get_tree().quit(1)
		return
	var session = plugin.session
	session.is_host = true
	session.connected = true
	session.names[session.store.identity] = "Solo editor"
	get_editor_interface().open_scene_from_path("res://scenes/map_together_playground.tscn")
	for i in range(5): await get_tree().process_frame
	var scene = get_editor_interface().get_edited_scene_root()
	check(scene != null and scene.has_node("TestPlayer"), "The test map and controllable player open in Godot")
	var box = scene.get_node("SyncBox_Red")
	box.position.x = -7.5
	get_editor_interface().mark_scene_as_unsaved()
	plugin._capture_active_scene()
	check(FileAccess.file_exists(session.store.local_path(scene.scene_file_path)) and session.store.records.has(scene.scene_file_path), "A lone map editor autosaves locally and in the host journal")
	var packed = ResourceLoader.load(scene.scene_file_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var saved = packed.instantiate()
	check(is_equal_approx(saved.get_node("SyncBox_Red").position.x, -7.5), "The autosaved scene contains the latest map geometry")
	saved.free()
	check(scene.scene_file_path not in get_editor_interface().get_unsaved_scenes(), "Native scene save clears the editor's unsaved marker")
	var original_hash = session.store.source_hash(scene.scene_file_path)
	check(session.store.records[scene.scene_file_path].hash == original_hash, "Host acknowledgment refers to exactly the saved scene")
	box.position.z = -4.5
	plugin._capture_active_scene()
	var addon_saved = ResourceLoader.load(scene.scene_file_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE).instantiate()
	check(is_equal_approx(addon_saved.get_node("SyncBox_Red").position.z, -4.5), "Addon edits are captured even without an unsaved-tab notification")
	addon_saved.free()
	var sequence = session.store.sequence
	plugin._received(session.store.records[scene.scene_file_path])
	plugin._capture_active_scene()
	check(session.store.sequence == sequence, "Applying a host scene does not create an echo save loop")
	# Exercise a real remote scene replacement through the native editor hooks.
	var path = scene.scene_file_path
	var selected_id = box.get_instance_id()
	get_editor_interface().get_selection().add_node(box)
	var incoming = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE).instantiate()
	incoming.get_node("SyncBox_Green").position.x = 8.25
	var incoming_packed = PackedScene.new()
	incoming_packed.pack(incoming)
	var incoming_path = session.store.state_path.path_join("incoming_test.tscn")
	ResourceSaver.save(incoming_packed, incoming_path)
	incoming.free()
	var incoming_hash = session.store.capture_bytes(FileAccess.get_file_as_bytes(incoming_path))
	session.applying_file.emit(path)
	var committed = session.store.commit("remote-editor-smoke", path, session.store.records[path].hash, incoming_hash, "remote-editor")
	check(committed.ok, "An incoming scene is committed on the host before editor application")
	if committed.ok: session.file_received.emit(committed.record)
	check(is_instance_valid(box) and box.get_instance_id() == selected_id and box in get_editor_interface().get_selection().get_selected_nodes(), "Applying another participant's edits preserves existing objects and selection")
	scene = get_editor_interface().get_edited_scene_root()
	check(is_equal_approx(scene.get_node("SyncBox_Green").position.x, 8.25) and is_equal_approx(scene.get_node("SyncBox_Red").position.x, -7.5), "The open native scene displays remote and local map changes together")
	sequence = session.store.sequence
	plugin._capture_active_scene()
	check(session.store.is_applied_source(path, session.store.source_hash(path)) and session.store.sequence == sequence and path not in get_editor_interface().get_unsaved_scenes(), "Native materialization clears dirty state without a repeated synchronization loop")
	var script_path = "res://tests/live_script.gd"
	var script = load(script_path)
	get_editor_interface().edit_script(script)
	for i in range(10): await get_tree().process_frame
	var scripts = get_editor_interface().get_script_editor()
	var base = scripts.get_current_editor().get_base_editor()
	base.set_caret_line(base.get_line_count() - 1)
	base.insert_text_at_caret("\n# MapTogether autosave smoke\n")
	for i in range(2): await get_tree().process_frame
	plugin._capture_scripts()
	check("MapTogether autosave smoke" in FileAccess.get_file_as_string(script_path), "Open script edits are saved through Godot's native script editor")
	check(session.store.records.has(script_path) and session.store.records[script_path].hash == session.store.source_hash(script_path), "Script autosave is journaled on the host")
	plugin.open_output()
	await get_tree().process_frame
	var output_visible = false
	for output in get_tree().root.find_children("*", "EditorLog", true, false): output_visible = output.is_visible_in_tree()
	check(output_visible, "Output opens normally during collaboration")
	session.send_chat("Editor chat smoke")
	check("Editor chat smoke" in plugin.dock.chat.text, "The dock chat displays messages")
	check(get_tree().get_multiplayer().multiplayer_peer is OfflineMultiplayerPeer, "Editor/game multiplayer remains independent of the addon transport")
	get_editor_interface().close_scene()
	var new_scene = Node3D.new()
	new_scene.name = "SoloUntitled"
	get_editor_interface().add_root_node(new_scene)
	for i in range(3): await get_tree().process_frame
	plugin._capture_active_scene()
	check(new_scene.scene_file_path != "" and FileAccess.file_exists(new_scene.scene_file_path), "A lone unnamed scene receives a unique path and is autosaved")
	get_tree().quit(1 if failed else 0)
