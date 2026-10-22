@tool
extends EditorPlugin

const MergerScript = preload("res://addons/coop_collab/merge.gd")
const SessionScript = preload("res://addons/coop_collab/session.gd")
const DockScript = preload("res://addons/coop_collab/dock.gd")
var session: Node
var dock: Control
var _capture_clock = 0.0
var _scan_clock = 0.0
var _scan_files: Array[String] = []
var _file_hashes: Dictionary = {}
var _scene_captures: Dictionary = {}
var _saving = false
var _applying = false
var _preparing = false
var _announced_scene = ""
var auto_save = true
var _asset_scan_pending = false
var _asset_ready_at = 0
var _publishing_dependencies = false
var _apply_bases: Dictionary = {}
var _export_cleaner: EditorExportPlugin

func _enter_tree():
	session = SessionScript.new()
	session.name = "CoopCollabSession"
	add_child(session)
	session.editor_can_apply = _can_apply
	session.editor_ready = _editor_assets_ready
	session.file_received.connect(_received)
	session.applying_file.connect(_prepare_apply)
	dock = DockScript.new()
	dock.plugin = self
	dock.session = session
	add_control_to_dock(DOCK_SLOT_LEFT_UR, dock)
	session.changed.connect(dock.refresh)
	session.log_line.connect(dock.log_message)
	scene_saved.connect(_scene_saved)
	scene_changed.connect(_scene_changed)
	resource_saved.connect(_resource_saved)
	_export_cleaner = ExportCleaner.new()
	add_export_plugin(_export_cleaner)
	set_process(true)

func _exit_tree():
	set_process(false)
	if scene_saved.is_connected(_scene_saved): scene_saved.disconnect(_scene_saved)
	if scene_changed.is_connected(_scene_changed): scene_changed.disconnect(_scene_changed)
	if resource_saved.is_connected(_resource_saved): resource_saved.disconnect(_resource_saved)
	if _export_cleaner: remove_export_plugin(_export_cleaner)
	if is_instance_valid(session): session.stop()
	if is_instance_valid(dock):
		remove_control_from_docks(dock)
		dock.queue_free()
	if is_instance_valid(session): session.queue_free()

func _process(delta: float):
	if not is_instance_valid(session) or _preparing or _applying: return
	_capture_clock += delta
	_scan_clock += delta
	if session.connected and current_scene_path() != _announced_scene:
		_announced_scene = current_scene_path()
		if _announced_scene != "": session.request_lease(_announced_scene)
	if _capture_clock > 0.8:
		_capture_clock = 0.0
		if auto_save:
			_capture_active_scene()
			_capture_scripts()
	if _scan_files.is_empty() and _scan_clock > 5.0:
		_scan_clock = 0.0
		_scan_files = session.store.list_files()
	for _file in range(4):
		if _scan_files.is_empty(): break
		var path = _scan_files.pop_back()
		var hash_value = session.store.capture_file(path)
		if hash_value != "" and _file_hashes.get(path, hash_value) != hash_value:
			_publish(path, hash_value)
		elif hash_value != "" and session.connected and not session.store.pending.has(path) and not session.store.is_applied_source(path, hash_value):
			_publish(path, hash_value)
		_file_hashes[path] = hash_value

func _active_scene() -> Node:
	var editor = get_editor_interface()
	return editor.get_edited_scene_root() if not editor.get_open_scenes().is_empty() else null

func current_scene_path() -> String:
	var scene = _active_scene()
	return scene.scene_file_path if scene else ""

func host(port: int, username: String, password: String):
	if _preparing: return
	_preparing = true
	session.stop()
	_saving = true
	get_editor_interface().save_all_scenes()
	get_editor_interface().get_script_editor().save_all_scripts()
	_saving = false
	var paths = session.store.list_files()
	session.log_message("Подготовка хоста: %d файлов; предыдущие версии остаются в истории" % paths.size())
	session.store.batch_mode = true
	for i in range(paths.size()):
		var path = paths[i]
		var hash_value = session.store.capture_file(path)
		if hash_value == "": continue
		var result = {"ok": true}
		if session.store.records.get(path, {}).get("hash", "") != hash_value:
			result = session.store.commit(session.store.identity + "-bootstrap-" + str(ResourceUID.create_id()), path, session.store.records.get(path, {}).get("hash", ""), hash_value, session.store.identity, true)
		if not result.ok:
			session.log_message("Подготовка прервана: " + result.reason)
			session.store.batch_mode = false
			session.store.save_state()
			_preparing = false
			return
		_file_hashes[path] = hash_value
		session.store.applied[path] = hash_value
		if session.store.pending.has(path) and session.store.pending[path].get("next_hash", session.store.pending[path].hash) == hash_value:
			session.store.pending.erase(path)
		if i % 16 == 0: await get_tree().process_frame
	session.store.batch_mode = false
	session.store.save_state()
	_preparing = false
	if session.start_host(port, username, password) == OK:
		var path = current_scene_path()
		if path != "": session.request_lease(path)
	dock.refresh()

func join(address: String, port: int, username: String, password: String):
	_file_hashes.clear()
	for path in session.store.list_files():
		_file_hashes[path] = session.store.source_hash(path)
	session.start_client(address, port, username, password)
	dock.refresh()

func _scene_changed(scene: Node):
	if is_instance_valid(scene): _prime_scene.call_deferred(scene)

func _prime_scene(scene: Node):
	if is_instance_valid(scene) and scene.scene_file_path != "" and not _applying:
		_scene_captures[scene.scene_file_path] = _scene_hash(scene)

func _scene_hash(scene: Node) -> String:
	var packed = PackedScene.new()
	if packed.pack(scene) != OK: return ""
	var directory = session.store.state_path.path_join("captures")
	DirAccess.make_dir_recursive_absolute(directory)
	var capture = directory.path_join(scene.scene_file_path.sha256_text() + ".tscn")
	if ResourceSaver.save(packed, capture) != OK: return ""
	return session.store.hash_bytes(FileAccess.get_file_as_bytes(capture))

func _capture_active_scene():
	var scene = _active_scene()
	if not scene: return
	if scene.scene_file_path == "":
		var directory = "res://scenes/shared"
		if DirAccess.make_dir_recursive_absolute(directory) != OK: return
		var path = directory.path_join(str(scene.name).validate_filename() + "_" + str(ResourceUID.create_id()) + ".tscn")
		_saving = true
		get_editor_interface().save_scene_as(path, false)
		_saving = false
		session.log_message("Новая сцена сохранена: " + path)
		_publish(path, session.store.capture_file(path))
	if not session.store.safe_path(scene.scene_file_path): return
	var path = scene.scene_file_path
	# Inspect native persisted scene data even when an addon forgot to mark the tab dirty.
	var hash_value = _scene_hash(scene)
	if hash_value == "": return
	if not _scene_captures.has(path) and path not in get_editor_interface().get_unsaved_scenes():
		_scene_captures[path] = hash_value
		return
	if _scene_captures.get(path, "") == hash_value and path not in get_editor_interface().get_unsaved_scenes(): return
	_ensure_scene_ids(scene)
	_saving = true
	get_editor_interface().save_scene_as(path, false)
	_saving = false
	_scene_captures[path] = _scene_hash(scene)
	_publish(path, session.store.capture_file(path))

func _ensure_scene_ids(root: Node):
	var seen = {}
	var nodes = [root]
	while not nodes.is_empty():
		var node = nodes.pop_back()
		if node == root or node.owner == root:
			var uuid = str(node.get_meta("_mc_uuid", ""))
			if uuid == "" or seen.has(uuid):
				uuid = str(ResourceUID.create_id())
				node.set_meta("_mc_uuid", uuid)
			seen[uuid] = true
		nodes.append_array(node.get_children())

func _capture_scripts():
	var scripts = get_editor_interface().get_script_editor()
	if not scripts or not scripts.has_method("get_unsaved_files") or not scripts.has_method("save_all_scripts"): return
	var unsaved = scripts.get_unsaved_files()
	if unsaved.is_empty(): return
	_saving = true
	scripts.save_all_scripts()
	_saving = false
	for path in unsaved:
		if session.store.safe_path(path): _publish(path, session.store.capture_file(path))

func save_and_send():
	_saving = true
	get_editor_interface().save_all_scenes()
	get_editor_interface().get_script_editor().save_all_scripts()
	_saving = false
	for path in session.store.list_files():
		var hash_value = session.store.capture_file(path)
		if hash_value != "" and not session.store.is_applied_source(path, hash_value): _publish(path, hash_value)
	dock.refresh()

func _scene_saved(path: String):
	if _saving or _applying or _preparing: return
	_publish(path, session.store.capture_file(path))

func _resource_saved(resource: Resource):
	if _saving or _applying or _preparing: return
	if session.store.safe_path(resource.resource_path):
		_publish(resource.resource_path, session.store.capture_file(resource.resource_path))

func _publish(path: String, hash_value: String):
	if hash_value == "": return
	if path.get_extension() in ["tscn", "scn"] and not _publishing_dependencies:
		_publish_dependencies(path)
	session.publish(path, hash_value)
	_file_hashes[path] = hash_value

func _publish_dependencies(scene_path: String):
	_publishing_dependencies = true
	var paths = {}
	for dependency in ResourceLoader.get_dependencies(scene_path):
		var path = str(dependency).split("::")[-1]
		if not session.store.safe_path(path): continue
		paths[path] = true
		if path.begins_with("res://addons/"):
			var parts = path.trim_prefix("res://").split("/")
			var prefix = "res://addons/" + parts[1] + "/"
			for file in session.store.list_files():
				if file.begins_with(prefix): paths[file] = true
	for path in paths:
		var hash_value = session.store.capture_file(path)
		if hash_value != "" and not session.store.is_applied_source(path, hash_value):
			session.publish(path, hash_value)
	_publishing_dependencies = false

func _editor_assets_ready() -> bool:
	return not _asset_scan_pending and Time.get_ticks_msec() >= _asset_ready_at and not get_editor_interface().get_resource_filesystem().is_scanning()

func _schedule_asset_scan():
	if _asset_scan_pending: return
	_asset_scan_pending = true
	get_tree().create_timer(0.3).timeout.connect(_scan_assets)

func _scan_assets():
	var filesystem = get_editor_interface().get_resource_filesystem()
	if filesystem.is_scanning():
		get_tree().create_timer(0.2).timeout.connect(_scan_assets)
		return
	_asset_scan_pending = false
	_asset_ready_at = Time.get_ticks_msec() + 100
	filesystem.scan()

func _can_apply(path: String) -> bool:
	var editor = get_editor_interface()
	var active = _active_scene()
	if active and active.scene_file_path == path: _capture_active_scene()
	if path in editor.get_unsaved_scenes():
		var unsaved = editor.get_unsaved_scenes()
		_saving = true
		editor.save_all_scenes()
		_saving = false
		for scene_path in unsaved:
			if session.store.safe_path(scene_path): _publish(scene_path, session.store.capture_file(scene_path))
		if path in editor.get_unsaved_scenes(): return false
	var scripts = editor.get_script_editor()
	if scripts and scripts.has_method("get_unsaved_files"):
		if path in scripts.get_unsaved_files(): _capture_scripts()
		if path in scripts.get_unsaved_files(): return false
	return true

func _received(record: Dictionary):
	var path = record.path
	_file_hashes[path] = record.hash
	var editor = get_editor_interface()
	if path in editor.get_open_scenes():
		var live: Node
		for root in editor.get_open_scene_roots():
			if root.scene_file_path == path: live = root
		var base_hash = _apply_bases.get(path, session.store.applied.get(path, ""))
		var updated = live != null and base_hash != "" and MergerScript.new(session.store).apply_to_live_scene(path, base_hash, record.hash, live)
		if updated and current_scene_path() == path:
			_saving = true
			editor.save_scene_as(path, false)
			_saving = false
			var working_hash = session.store.capture_file(path)
			session.store.materialized[path] = {"canonical": record.hash, "working": working_hash}
			session.store.save_state()
			_file_hashes[path] = working_hash
		else:
			var previous = current_scene_path()
			editor.reload_scene_from_path(path)
			if previous != "" and previous != path: editor.open_scene_from_path(previous)
		var reloaded = _active_scene()
		if reloaded and reloaded.scene_file_path == path: _scene_captures[path] = _scene_hash(reloaded)
		_apply_bases.erase(path)
	if path.get_extension() in ["gd", "cs", "gdshader", "shader"]:
		var scripts = editor.get_script_editor()
		if scripts and scripts.has_method("reload_open_files"): scripts.reload_open_files()
	editor.get_resource_filesystem().update_file(path)
	if path.get_extension() not in ["tscn", "scn"]: _schedule_asset_scan()
	dock.refresh()

func _prepare_apply(path: String):
	_applying = true
	if path.get_extension() in ["tscn", "scn"]:
		_apply_bases[path] = session.store.capture_file(path)
	_finish_apply.call_deferred()

func _finish_apply():
	_applying = false

func request_edit(release: bool = false):
	var path = current_scene_path()
	if path != "": session.request_lease(path, release)
	dock.refresh()

func resolve_conflict(path: String, take_incoming: bool) -> bool:
	if not session.store.conflicts.has(path): return false
	var conflict = session.store.conflicts[path]
	if take_incoming:
		if not _can_apply(path): return false
		if session.store.source_hash(path) != conflict.local_hash:
			conflict.local_hash = session.store.capture_file(path)
			session.store.save_state()
			return false
		var hash_value = conflict.incoming_hash
		if not FileAccess.file_exists(session.store.object_path(hash_value)): return false
		if session.is_host:
			var operation = conflict.get("operation", session.store.identity + "-resolve-" + str(ResourceUID.create_id()))
			var author = conflict.get("author", session.store.identity)
			_prepare_apply(path)
			var result = session.store.commit(operation, path, session.store.records.get(path, {}).get("hash", ""), hash_value, author, true)
			if not result.ok: return false
			session.store.conflicts.erase(path)
			session.store.save_state()
			for id in session.links:
				if session.links[id].identity == author: session._send(id, {"type": "ack", "operation": operation, "record": result.record})
			session._broadcast_record(result.record)
			_received(result.record)
		else:
			var record = conflict.get("record", {})
			if record.is_empty(): return false
			# All local/outbox bodies remain in the content-addressed history.
			var old_pending = session.store.pending.get(path, {}).duplicate(true)
			session.store.pending.erase(path)
			session.store.applied[path] = session.store.source_hash(path)
			_prepare_apply(path)
			if not session.store.receive_record(record, true):
				if not old_pending.is_empty(): session.store.pending[path] = old_pending
				session.store.save_state()
				return false
			_received(record)
	else:
		var record = conflict.get("record", {})
		if not session.is_host and session.store.pending.has(path) and not record.is_empty():
			var pending = session.store.pending[path]
			pending.hash = pending.get("next_hash", pending.hash)
			pending.erase("next_hash")
			pending.base = record.hash
			pending.operation = session.store.identity + "-" + str(ResourceUID.create_id())
			pending.blocked = false
			pending.hold = "lease" if pending.blocked else ""
		session.store.conflicts.erase(path)
		session.store.save_state()
	dock.refresh()
	return true

func open_output():
	for output in get_tree().root.find_children("*", "EditorLog", true, false):
		if output.has_method("open") and output.has_method("make_visible"):
			output.open()
			output.make_visible()
			return

class ExportCleaner extends EditorExportPlugin:
	func _get_name() -> String: return "CoopCollabExportCleaner"
	func _export_file(path: String, _type: String, _features: PackedStringArray):
		if path.begins_with("res://addons/coop_collab/") or path.begins_with("res://.coop_collab/"): skip()
