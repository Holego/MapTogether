@tool
extends RefCounted

# Content-addressed history is independent of editor nodes and third-party addons.
var root_path: String
var state_path: String
var identity: String
var records: Dictionary = {}
var applied: Dictionary = {}
var materialized: Dictionary = {}
var pending: Dictionary = {}
var conflicts: Dictionary = {}
var receipts: Dictionary = {}
var sequence: int = 0
var journal_position: int = 0
var last_error = ""
var batch_mode = false

func _init(project_root: String = "res://"):
	root_path = ProjectSettings.globalize_path(project_root).simplify_path()
	state_path = root_path.path_join(".coop_collab")
	DirAccess.make_dir_recursive_absolute(state_path.path_join("objects"))
	DirAccess.make_dir_recursive_absolute(state_path.path_join("transfers"))
	var state = _read_json(state_path.path_join("state.json"))
	identity = state.get("identity", str(ResourceUID.create_id()))
	var copied_working_root = state.get("working_root", root_path) != root_path
	if copied_working_root:
		identity = str(ResourceUID.create_id())
	records = state.get("records", {})
	applied = state.get("applied", {})
	materialized = state.get("materialized", {})
	pending = state.get("pending", {})
	if copied_working_root:
		for change in pending.values(): change.operation = identity + "-" + str(ResourceUID.create_id())
	conflicts = state.get("conflicts", {})
	receipts = state.get("receipts", {})
	sequence = int(state.get("sequence", 0))
	journal_position = int(state.get("journal_position", 0))
	for record in records.values(): sequence = maxi(sequence, int(record.get("revision", 0)))
	# Replay complete flushed journal entries after a crash between journal and index.
	var journal = FileAccess.open(state_path.path_join("journal.jsonl"), FileAccess.READ)
	if journal:
		while not journal.eof_reached():
			var parser = JSON.new()
			var line = journal.get_line()
			if line.strip_edges() == "" or parser.parse(line) != OK: continue
			var entry = parser.data
			if entry is Dictionary and entry.has("record") and entry.has("operation"):
				var record = entry.record
				if journal.get_position() > journal_position:
					records[record.path] = record
				sequence = maxi(sequence, int(record.get("revision", 0)))
				receipts[entry.operation] = record
		journal_position = journal.get_length()
	save_state()

func safe_path(path: String) -> bool:
	if not path.begins_with("res://") or "\\" in path or "%" in path or ":" in path.trim_prefix("res://"):
		return false
	var relative = path.trim_prefix("res://")
	if relative == "" or relative.ends_with("/"):
		return false
	for part in relative.split("/"):
		if part == "" or part.begins_with(".") or part in ["..", "."]:
			return false
	if path == "res://addons/coop_collab" or path.begins_with("res://addons/coop_collab/"):
		return false # Updating the running synchronization protocol is a separate operation.
	if path.ends_with(".tmp") or path.ends_with(".bak"):
		return false
	# Never follow project symlinks outside the project when receiving a file.
	var cursor = root_path
	for part in relative.split("/"):
		var directory = DirAccess.open(cursor)
		if directory and directory.is_link(part):
			return false
		cursor = cursor.path_join(part)
	return true

func local_path(path: String) -> String:
	return root_path.path_join(path.trim_prefix("res://"))

func valid_hash(value: String) -> bool:
	if value.length() != 64: return false
	for character in value:
		if character not in "0123456789abcdef": return false
	return true

func object_path(hash_value: String) -> String:
	return state_path.path_join("objects").path_join(hash_value + ".bin" if valid_hash(hash_value) else "invalid")

func hash_bytes(bytes: PackedByteArray) -> String:
	var context = HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty(): context.update(bytes)
	return context.finish().hex_encode()

func _atomic_bytes(destination: String, bytes: PackedByteArray) -> bool:
	if DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK:
		return false
	var temporary = destination + "." + str(ResourceUID.create_id()) + ".tmp"
	var file = FileAccess.open(temporary, FileAccess.WRITE)
	if not file: return false
	file.store_buffer(bytes)
	file.flush()
	var error = file.get_error()
	file.close()
	if error == OK and DirAccess.rename_absolute(temporary, destination) == OK:
		return true
	DirAccess.remove_absolute(temporary)
	return false

func capture_bytes(bytes: PackedByteArray) -> String:
	var hash_value = hash_bytes(bytes)
	var destination = object_path(hash_value)
	if FileAccess.file_exists(destination): return hash_value
	return hash_value if _atomic_bytes(destination, bytes) else ""

func capture_file(path: String) -> String:
	if not safe_path(path) or not FileAccess.file_exists(local_path(path)): return ""
	if path == "res://project.godot":
		return capture_bytes(_project_bytes(local_path(path)))
	var hash_value = FileAccess.get_sha256(local_path(path))
	if not valid_hash(hash_value): return ""
	if not FileAccess.file_exists(object_path(hash_value)):
		var temporary = object_path(hash_value) + ".tmp"
		if DirAccess.copy_absolute(local_path(path), temporary) != OK: return ""
		if FileAccess.get_sha256(temporary) != hash_value:
			DirAccess.remove_absolute(temporary)
			return "" # File changed while being captured; retry on the next scan.
		if DirAccess.rename_absolute(temporary, object_path(hash_value)) != OK: return ""
	return hash_value

func source_hash(path: String) -> String:
	if not safe_path(path) or not FileAccess.file_exists(local_path(path)): return ""
	return hash_bytes(_project_bytes(local_path(path))) if path == "res://project.godot" else FileAccess.get_sha256(local_path(path))

func is_applied_source(path: String, hash_value: String) -> bool:
	if applied.get(path, "") == hash_value: return true
	var mapping = materialized.get(path, {})
	return mapping.get("canonical", "") == applied.get(path, "") and mapping.get("working", "") == hash_value

func matches_version(path: String, hash_value: String) -> bool:
	var local = source_hash(path)
	if local == hash_value: return true
	var mapping = materialized.get(path, {})
	return mapping.get("canonical", "") == hash_value and mapping.get("working", "") == local

func _project_bytes(path: String) -> PackedByteArray:
	var config = ConfigFile.new()
	if config.load(path) != OK: return PackedByteArray()
	# Game settings travel; the editor's enabled plugin list remains local.
	if config.has_section("editor_plugins"): config.erase_section("editor_plugins")
	return config.encode_to_text().to_utf8_buffer()

func write_source(path: String, hash_value: String) -> bool:
	if not safe_path(path) or not FileAccess.file_exists(object_path(hash_value)): return false
	var current = source_hash(path)
	if current == hash_value: return true
	if current != "" and capture_file(path) == "": return false
	if path == "res://project.godot":
		var incoming = ConfigFile.new()
		if incoming.parse(FileAccess.get_file_as_string(object_path(hash_value))) != OK: return false
		var local = ConfigFile.new()
		if local.load(local_path(path)) == OK and local.has_section("editor_plugins"):
			for key in local.get_section_keys("editor_plugins"):
				incoming.set_value("editor_plugins", key, local.get_value("editor_plugins", key))
		return _atomic_bytes(local_path(path), incoming.encode_to_text().to_utf8_buffer())
	var destination = local_path(path)
	if DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK: return false
	var temporary = destination.get_base_dir().path_join("." + destination.get_file() + ".coop.tmp")
	if DirAccess.copy_absolute(object_path(hash_value), temporary) != OK: return false
	# Rename replaces atomically; the original is never removed first.
	return DirAccess.rename_absolute(temporary, destination) == OK

func queue_change(path: String, hash_value: String, blocked: bool = false) -> bool:
	if not safe_path(path) or hash_value == "": return false
	if pending.has(path):
		pending[path].next_hash = hash_value
	else:
		if is_applied_source(path, hash_value): return true
		pending[path] = {"operation": identity + "-" + str(ResourceUID.create_id()), "path": path, "base": applied.get(path, ""), "hash": hash_value, "blocked": blocked, "hold": "lease" if blocked else ""}
	return save_state()

func acknowledge(operation: String, record: Dictionary) -> bool:
	var path = str(record.get("path", ""))
	if not pending.has(path) or pending[path].operation != operation or pending[path].hash != record.get("submitted_hash", record.get("hash", "")): return false
	var next_hash = str(pending[path].get("next_hash", ""))
	records[path] = record
	var submitted_hash = record.get("submitted_hash", record.hash)
	applied[path] = submitted_hash
	pending.erase(path)
	conflicts.erase(path)
	if next_hash != "" and next_hash != submitted_hash:
		pending[path] = {"operation": identity + "-" + str(ResourceUID.create_id()), "path": path, "base": submitted_hash, "hash": next_hash, "blocked": false}
	return save_state()

func commit(operation: String, path: String, base_hash: String, hash_value: String, author: String, from_local: bool = false, submitted_hash: String = "") -> Dictionary:
	if receipts.has(operation): return {"ok": true, "record": receipts[operation]}
	if submitted_hash == "": submitted_hash = hash_value
	if not safe_path(path) or hash_value == "" or not FileAccess.file_exists(object_path(hash_value)):
		return {"ok": false, "reason": "Недопустимый путь или отсутствуют данные"}
	var current = records.get(path, {})
	if current.get("hash", "") == hash_value:
		current = current.duplicate(true)
		current.submitted_hash = submitted_hash
		if not _append_journal(operation, current): return {"ok": false, "reason": "Ошибка записи подтверждения"}
		receipts[operation] = current
		save_state()
		return {"ok": true, "record": current}
	if current.get("hash", "") != base_hash:
		preserve_conflict(path, hash_value, "Изменился файл у хоста", current)
		return {"ok": false, "reason": "Версия у хоста изменилась"}
	if not from_local and not matches_version(path, current.get("hash", "")) and source_hash(path) != hash_value:
		preserve_conflict(path, hash_value, "Локальные правки хоста", current)
		return {"ok": false, "reason": "У хоста есть локальные изменения"}
	if not write_source(path, hash_value): return {"ok": false, "reason": "Ошибка записи файла у хоста"}
	var file = FileAccess.open(object_path(hash_value), FileAccess.READ)
	var record = {"path": path, "hash": hash_value, "revision": sequence + 1, "size": file.get_length(), "author": author, "host": identity, "submitted_hash": submitted_hash}
	if not _append_journal(operation, record): return {"ok": false, "reason": "Ошибка записи журнала хоста"}
	sequence += 1
	records[path] = record
	applied[path] = hash_value
	receipts[operation] = record
	if not save_state(): return {"ok": false, "reason": "Ошибка сохранения индекса хоста"}
	return {"ok": true, "record": record}

func _append_journal(operation: String, record: Dictionary) -> bool:
	var journal_path = state_path.path_join("journal.jsonl")
	var journal = FileAccess.open(journal_path, FileAccess.READ_WRITE if FileAccess.file_exists(journal_path) else FileAccess.WRITE_READ)
	if not journal: return false
	if journal.get_length() > 0:
		journal.seek(journal.get_length() - 1)
		if journal.get_8() != 10:
			journal.seek_end()
			journal.store_8(10) # Keep a torn last entry separate from the next valid commit.
	journal.seek_end()
	journal.store_line(JSON.stringify({"operation": operation, "record": record}))
	journal.flush()
	var error = journal.get_error()
	if error == OK: journal_position = journal.get_position()
	journal.close()
	return error == OK

func receive_record(record: Dictionary, can_apply: bool = true) -> bool:
	var path = str(record.get("path", ""))
	if not safe_path(path) or not FileAccess.file_exists(object_path(str(record.get("hash", "")))): return false
	if records.get(path, {}).get("host", "") == record.get("host", "") and int(records.get(path, {}).get("revision", -1)) > int(record.get("revision", 0)): return false
	var local_hash = source_hash(path)
	if matches_version(path, record.hash):
		records[path] = record
		applied[path] = record.hash
		save_state()
		return true
	if not can_apply or pending.has(path) or (local_hash != "" and not is_applied_source(path, local_hash)):
		preserve_conflict(path, record.hash, "Сохранены локальная и входящая версии", record)
		return false
	if not write_source(path, record.hash): return false
	records[path] = record
	applied[path] = record.hash
	conflicts.erase(path)
	return save_state()

func preserve_conflict(path: String, hash_value: String, reason: String, record: Dictionary = {}):
	if not safe_path(path): return
	var local_hash = capture_file(path)
	conflicts[path] = {"path": path, "incoming_hash": hash_value, "local_hash": local_hash, "reason": reason, "record": record}
	save_state()

func save_state() -> bool:
	if batch_mode: return true
	return _atomic_bytes(state_path.path_join("state.json"), JSON.stringify({"identity": identity, "working_root": root_path, "records": records, "applied": applied, "materialized": materialized, "pending": pending, "conflicts": conflicts, "receipts": receipts, "sequence": sequence, "journal_position": journal_position}).to_utf8_buffer())

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var parser = JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK: return {}
	return parser.data if parser.data is Dictionary else {}

func list_files() -> Array[String]:
	var result: Array[String] = []
	var directories: Array[String] = ["res://"]
	while not directories.is_empty():
		var base = directories.pop_back()
		var dir = DirAccess.open(local_path(base))
		if not dir: continue
		dir.list_dir_begin()
		var name = dir.get_next()
		while name != "":
			var path = base.path_join(name)
			if not name.begins_with(".") and not dir.is_link(name):
				if dir.current_is_dir():
					if path != "res://addons/coop_collab": directories.append(path)
				elif safe_path(path): result.append(path)
			name = dir.get_next()
		dir.list_dir_end()
	return result
