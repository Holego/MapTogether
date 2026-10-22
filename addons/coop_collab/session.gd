@tool
extends Node

signal changed
signal log_line(message: String)
signal file_received(record: Dictionary)
signal applying_file(path: String)
signal ready_changed
signal chat_message(message: Dictionary)

const PROTOCOL = 1
const CHUNK_SIZE = 65536
const MAX_FRAME = 1048576
const MergerScript = preload("res://addons/coop_collab/merge.gd")
const StoreScript = preload("res://addons/coop_collab/store.gd")
var store
var is_host = false
var connected = false
var username = "Developer"
var password = ""
var server: TCPServer
var links: Dictionary = {}
var leases: Dictionary = {}
var names: Dictionary = {}
var editor_can_apply: Callable
var editor_ready: Callable
var _wanted: Dictionary = {}
var _waiting_scenes: Dictionary = {}
var _waiting_uploads: Array = []
var _next_link = 1
var _uploads: Dictionary = {}
var _deferred_records: Dictionary = {}
var chat_history: Array = []
var _sending: Array = []
var _receiving: Dictionary = {}
var _last_heartbeat = 0
var _status = "Не подключён"

func _ready():
	if store == null: store = StoreScript.new()
	var history = store._read_json(store.state_path.path_join("chat.json"))
	chat_history = history.get("messages", [])

func log_message(message: String):
	log_line.emit(message)

func status() -> String:
	return "%s\nОжидают подтверждения: %d · Конфликты: %d" % [_status, store.pending.size(), store.conflicts.size()]

func start_host(port: int, display_name: String, room_password: String) -> Error:
	stop()
	username = display_name
	password = room_password
	server = TCPServer.new()
	var error = server.listen(port)
	if error != OK:
		_status = "Не удалось открыть порт %d (%d)" % [port, error]
		changed.emit()
		return error
	is_host = true
	connected = true
	names[store.identity] = username
	_status = "Хост · порт %d" % port
	ready_changed.emit()
	changed.emit()
	return OK

func start_client(address: String, port: int, display_name: String, room_password: String) -> Error:
	stop()
	username = display_name
	password = room_password
	var stream = StreamPeerTCP.new()
	var error = stream.connect_to_host(address, port)
	if error != OK: return error
	links[0] = _new_link(stream)
	_status = "Подключение к %s:%d" % [address, port]
	changed.emit()
	return OK

func stop():
	for id in links: links[id].stream.disconnect_from_host()
	links.clear()
	if server: server.stop()
	server = null
	for transfer in _receiving.values(): transfer.file.close()
	_receiving.clear()
	_sending.clear()
	_wanted.clear()
	_waiting_scenes.clear()
	_waiting_uploads.clear()
	_uploads.clear()
	leases.clear()
	names.clear()
	connected = false
	is_host = false
	_status = "Не подключён · очередь сохранена на диске"
	ready_changed.emit()
	changed.emit()

func _exit_tree():
	stop()

func _new_link(stream: StreamPeerTCP) -> Dictionary:
	return {"stream": stream, "buffer": PackedByteArray(), "queue": [], "offset": 0, "hello": false, "authenticated": false, "identity": "", "last_seen": Time.get_ticks_msec()}

func _process(_delta: float):
	if server and server.is_listening() and server.is_connection_available():
		links[_next_link] = _new_link(server.take_connection())
		_next_link += 1
	for id in links.keys():
		if not links.has(id): continue
		var link = links[id]
		var stream: StreamPeerTCP = link.stream
		stream.poll()
		if stream.get_status() in [StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR]:
			_drop_link(id)
			continue
		if stream.get_status() != StreamPeerTCP.STATUS_CONNECTED: continue
		if not is_host and not link.hello:
			link.hello = true
			_send(id, {"type": "hello", "protocol": PROTOCOL, "identity": store.identity, "name": username, "password": password})
		_read_link(id)
		if not links.has(id): continue
		_flush_link(id)
		if Time.get_ticks_msec() - int(link.last_seen) > 30000:
			_drop_link(id)
	_stream_chunks()
	_drain_scenes()
	_drain_uploads()
	if connected:
		_pump_outbox()
		if Time.get_ticks_msec() - _last_heartbeat > 3000:
			_last_heartbeat = Time.get_ticks_msec()
			for id in links: _send(id, {"type": "ping"})

func _read_link(id: int):
	var link = links[id]
	var stream: StreamPeerTCP = link.stream
	var count = mini(stream.get_available_bytes(), CHUNK_SIZE * 4)
	if count > 0:
		var result = stream.get_data(count)
		if result[0] != OK:
			_drop_link(id)
			return
		link.buffer.append_array(result[1])
	for _frame in range(16):
		if link.buffer.size() < 4: break
		var length = link.buffer.decode_u32(0)
		if length < 1 or length > MAX_FRAME:
			_drop_link(id)
			return
		if link.buffer.size() < length + 4: break
		var value = bytes_to_var(link.buffer.slice(4, 4 + length))
		link.buffer = link.buffer.slice(4 + length)
		if not value is Dictionary:
			_drop_link(id)
			return
		link.last_seen = Time.get_ticks_msec()
		_handle(id, value)
		if not links.has(id): return

func _send(id: int, message: Dictionary):
	if not links.has(id): return
	var body = var_to_bytes(message)
	if body.size() > MAX_FRAME:
		log_message("Сообщение слишком велико; данные остаются в очереди")
		return
	var frame = PackedByteArray()
	frame.resize(4)
	frame.encode_u32(0, body.size())
	frame.append_array(body)
	links[id].queue.append(frame)

func _flush_link(id: int):
	var link = links[id]
	for _packet in range(4):
		if link.queue.is_empty(): return
		var frame: PackedByteArray = link.queue[0]
		var result = link.stream.put_partial_data(frame.slice(link.offset))
		if result[0] == ERR_BUSY: return
		if result[0] != OK:
			_drop_link(id)
			return
		link.offset += int(result[1])
		if link.offset == frame.size():
			link.queue.pop_front()
			link.offset = 0
		else: return

func _handle(id: int, message: Dictionary):
	var type = str(message.get("type", ""))
	if is_host and not links[id].authenticated:
		if type != "hello" or int(message.get("protocol", -1)) != PROTOCOL or message.get("password", "") != password:
			_drop_link(id)
			return
		var identity = str(message.get("identity", ""))
		if identity == "" or identity == store.identity or identity in names:
			_drop_link(id)
			return
		links[id].authenticated = true
		links[id].identity = identity
		names[identity] = str(message.get("name", "Developer")).left(40)
		_send(id, {"type": "welcome", "protocol": PROTOCOL, "host": store.identity, "leases": leases, "names": names, "chat": chat_history})
		_send_manifest(id)
		_broadcast_presence()
		log_message("Подключился: " + names[identity])
		changed.emit()
		return
	if type == "ping":
		_send(id, {"type": "pong"})
		return
	if type == "pong": return
	if not is_host:
		if id != 0: return
		if type == "welcome":
			if int(message.get("protocol", -1)) != PROTOCOL:
				stop()
				return
			links[id].authenticated = true
			connected = true
			leases = message.get("leases", {})
			names = message.get("names", {})
			chat_history = message.get("chat", [])
			for entry in chat_history: chat_message.emit(entry)
			_status = "Подключён к хосту"
			ready_changed.emit()
			changed.emit()
			return
		if not connected: return
	match type:
		"presence":
			if not is_host:
				leases = message.get("leases", {})
				names = message.get("names", {})
				changed.emit()
		"scene":
			if is_host: _host_lease(links[id].identity, str(message.get("path", "")), bool(message.get("release", false)))
		"chat":
			if is_host: _host_chat(links[id].identity, str(message.get("text", "")))
			elif message.has("message"):
				chat_history.append(message.message)
				if chat_history.size() > 100: chat_history.pop_front()
				chat_message.emit(message.message)
		"manifest":
			if not is_host:
				for record in message.get("records", []):
					if _valid_record(record): _want_record(record)
		"manifest_request":
			if is_host: _send_manifest(id)
		"get":
			if is_host:
				var path = str(message.get("path", ""))
				if store.records.has(path): _send_blob(id, store.records[path], "download")
		"begin": _begin_receive(id, message)
		"chunk": _receive_chunk(id, message)
		"end": _finish_receive(id, str(message.get("transfer", "")))
		"ack":
			if not is_host and _valid_record(message.get("record", {})):
				var operation = str(message.get("operation", ""))
				if store.acknowledge(operation, message.record):
					_uploads.erase(operation)
					if not store.pending.has(message.record.path):
						_deferred_records.erase(message.record.path)
						_want_record(message.record)
					changed.emit()
		"reject":
			if not is_host:
				var operation = str(message.get("operation", ""))
				_uploads.erase(operation)
				for path in store.pending:
					if store.pending[path].operation == operation:
						store.pending[path].blocked = true
						store.pending[path].hold = "conflict"
						store.preserve_conflict(path, store.pending[path].hash, str(message.get("reason", "Хост отклонил изменение")), message.get("record", {}))
				if _valid_record(message.get("record", {})): _want_record(message.record)
				log_message(str(message.get("reason", "Изменение сохранено в очереди")))
				changed.emit()

func _valid_record(record: Variant) -> bool:
	return record is Dictionary and store.safe_path(str(record.get("path", ""))) and valid_hash(str(record.get("hash", ""))) and int(record.get("revision", -1)) >= 0 and int(record.get("size", -1)) >= 0

func valid_hash(value: String) -> bool:
	if value.length() != 64: return false
	for character in value:
		if character not in "0123456789abcdef": return false
	return true

func _priority(path: String) -> int:
	if path.get_extension() in ["gd", "cs", "gdshader", "cfg", "uid"]: return 0
	if path.get_extension() in ["tscn", "scn"]: return 2
	return 1

func _send_manifest(id: int):
	var batch: Array = []
	var records = store.records.values()
	records.sort_custom(func(a, b): return _priority(a.path) < _priority(b.path))
	for record in records:
		batch.append(record)
		if batch.size() == 128:
			_send(id, {"type": "manifest", "records": batch.duplicate()})
			batch.clear()
	if not batch.is_empty(): _send(id, {"type": "manifest", "records": batch})

func refresh_from_host():
	if connected and not is_host: _send(0, {"type": "manifest_request"})

func _want_record(record: Dictionary):
	if store.records.get(record.path, {}).get("host", "") == record.get("host", "") and int(store.records.get(record.path, {}).get("revision", -1)) > int(record.revision): return
	if store.matches_version(record.path, record.hash):
		store.capture_file(record.path)
		store.receive_record(record, false)
		changed.emit()
		return # Matching files never cause a scene reload or a redundant transfer.
	if FileAccess.file_exists(store.object_path(record.hash)):
		_apply_download(record)
	elif _wanted.get(record.path, "") != record.hash:
		_wanted[record.path] = record.hash
		_send(0, {"type": "get", "path": record.path})

func _send_blob(id: int, record: Dictionary, direction: String, operation: String = "", base: String = ""):
	var blob = store.object_path(record.hash)
	var file = FileAccess.open(blob, FileAccess.READ)
	if not file: return
	var transfer = store.identity + "-" + str(ResourceUID.create_id())
	_send(id, {"type": "begin", "transfer": transfer, "direction": direction, "record": record, "operation": operation, "base": base})
	_sending.append({"link": id, "transfer": transfer, "file": file, "offset": 0, "size": file.get_length()})

func _stream_chunks():
	var budget = 4
	for sending in _sending.duplicate():
		if not links.has(sending.link):
			sending.file.close()
			_sending.erase(sending)
			continue
		if links[sending.link].queue.size() > 8: continue
		if sending.offset == sending.size:
			_send(sending.link, {"type": "end", "transfer": sending.transfer})
			sending.file.close()
			_sending.erase(sending)
			continue
		if budget <= 0: break
		var data = sending.file.get_buffer(CHUNK_SIZE)
		_send(sending.link, {"type": "chunk", "transfer": sending.transfer, "offset": sending.offset, "data": data})
		sending.offset += data.size()
		budget -= 1

func _begin_receive(id: int, message: Dictionary):
	var record = message.get("record", {})
	if not _valid_record(record): return
	if (is_host and message.get("direction") != "upload") or (not is_host and message.get("direction") != "download"): return
	if is_host:
		var operation = str(message.get("operation", ""))
		if not operation.begins_with(links[id].identity + "-"): return
		if store.receipts.has(operation):
			_send(id, {"type": "ack", "operation": operation, "record": store.receipts[operation]})
			return
	var transfer_id = str(message.get("transfer", ""))
	if transfer_id == "" or transfer_id.length() > 100 or "/" in transfer_id or "\\" in transfer_id or ".." in transfer_id: return
	var key = str(id) + ":" + transfer_id
	if _receiving.has(key): return
	var temporary = store.state_path.path_join("transfers").path_join(str(id) + "-" + transfer_id + ".part")
	var file = FileAccess.open(temporary, FileAccess.WRITE)
	if not file: return
	_receiving[key] = {"file": file, "temporary": temporary, "record": record, "offset": 0, "operation": str(message.get("operation", "")), "base": str(message.get("base", ""))}

func _receive_chunk(id: int, message: Dictionary):
	var key = str(id) + ":" + str(message.get("transfer", ""))
	if not _receiving.has(key): return
	var receiving = _receiving[key]
	var data = message.get("data", PackedByteArray())
	if not data is PackedByteArray or int(message.get("offset", -1)) != receiving.offset or data.size() > CHUNK_SIZE or receiving.offset + data.size() > int(receiving.record.size):
		_drop_link(id)
		return
	receiving.file.store_buffer(data)
	receiving.offset += data.size()

func _finish_receive(id: int, transfer: String):
	var key = str(id) + ":" + transfer
	if not _receiving.has(key): return
	var received = _receiving[key]
	_receiving.erase(key)
	received.file.flush()
	received.file.close()
	if received.offset != int(received.record.size) or FileAccess.get_sha256(received.temporary) != received.record.hash:
		log_message("Неполная или повреждённая передача; оригинал сохранён")
		return
	var destination = store.object_path(received.record.hash)
	if DirAccess.rename_absolute(received.temporary, destination) != OK: return
	if is_host:
		if received.record.path.get_extension() in ["tscn", "scn"] and editor_ready.is_valid() and not editor_ready.call():
			_waiting_uploads.append({"link": id, "received": received})
		else: _commit_received(id, received)
	else:
		if _wanted.get(received.record.path, "") == received.record.hash: _wanted.erase(received.record.path)
		_apply_download(received.record)

func _drain_uploads():
	if editor_ready.is_valid() and not editor_ready.call(): return
	for entry in _waiting_uploads.duplicate():
		_waiting_uploads.erase(entry)
		if links.has(entry.link): _commit_received(entry.link, entry.received)

func _commit_received(id: int, received: Dictionary):
	var actor = links[id].identity
	var path = received.record.path
	if editor_can_apply.is_valid() and not editor_can_apply.call(path):
		store.preserve_conflict(path, received.record.hash, "Сцена занята или у хоста есть локальные правки", store.records.get(path, {}))
		store.conflicts[path].operation = received.operation
		store.conflicts[path].author = actor
		store.save_state()
		_send(id, {"type": "reject", "operation": received.operation, "reason": "Хост сохранил конфликт, файл не заменён", "record": store.records.get(path, {})})
		changed.emit()
		return
	var target_hash = received.record.hash
	var base_hash = received.base
	var current_hash = store.records.get(path, {}).get("hash", "")
	if base_hash != current_hash:
		var merged = MergerScript.new(store).merge(path, base_hash, current_hash, target_hash)
		if not merged.ok:
			store.preserve_conflict(path, target_hash, merged.reason, store.records.get(path, {}))
			store.conflicts[path].operation = received.operation
			store.conflicts[path].author = actor
			store.save_state()
			_send(id, {"type": "reject", "operation": received.operation, "reason": merged.reason, "record": store.records.get(path, {})})
			changed.emit()
			return
		target_hash = merged.hash
		base_hash = current_hash
	applying_file.emit(path)
	var result = store.commit(received.operation, path, base_hash, target_hash, actor, false, received.record.hash)
	if result.ok:
		file_received.emit(result.record)
		_send(id, {"type": "ack", "operation": received.operation, "record": result.record})
		_broadcast_record(result.record, id)
	else:
		if store.conflicts.has(path):
			store.conflicts[path].operation = received.operation
			store.conflicts[path].author = actor
			store.save_state()
		_send(id, {"type": "reject", "operation": received.operation, "reason": result.reason, "record": store.records.get(path, {})})
	changed.emit()

func _drain_scenes():
	if editor_ready.is_valid() and not editor_ready.call(): return
	for path in _wanted:
		if path.get_extension() not in ["tscn", "scn"]: return
	for path in _waiting_scenes.keys():
		var record = _waiting_scenes[path]
		_waiting_scenes.erase(path)
		_apply_download(record)

func _apply_download(record: Dictionary):
	if record.path.get_extension() in ["tscn", "scn"]:
		var ready = not editor_ready.is_valid() or editor_ready.call()
		for path in _wanted:
			if path.get_extension() not in ["tscn", "scn"]: ready = false
		if not ready:
			_waiting_scenes[record.path] = record
			return
	var can_apply = not editor_can_apply.is_valid() or editor_can_apply.call(record.path)
	if store.pending.has(record.path):
		_deferred_records[record.path] = record
		if store.pending[record.path].get("blocked", false) and store.conflicts.has(record.path):
			store.preserve_conflict(record.path, record.hash, store.conflicts[record.path].reason, record)
			changed.emit()
		return
	if can_apply: applying_file.emit(record.path)
	if store.receive_record(record, can_apply): file_received.emit(record)
	changed.emit()

func publish(path: String, hash_value: String, blocked: bool = false):
	if is_host:
		var operation = store.identity + "-" + str(ResourceUID.create_id())
		var result = store.commit(operation, path, store.records.get(path, {}).get("hash", ""), hash_value, store.identity, true)
		if result.ok: _broadcast_record(result.record)
		else:
			store.queue_change(path, hash_value)
			log_message(result.reason)
	else:
		store.queue_change(path, hash_value, blocked)
	changed.emit()

func _pump_outbox():
	for operation in _uploads.keys():
		if Time.get_ticks_msec() - int(_uploads[operation]) > 30000:
			_uploads.erase(operation)
	if is_host:
		for path in store.pending.keys():
			var local = store.pending[path]
			if local.get("blocked", false): continue
			var result = store.commit(local.operation, path, local.base, local.hash, store.identity, true)
			if result.ok:
				store.acknowledge(local.operation, result.record)
				_broadcast_record(result.record)
			else:
				local.blocked = true
				local.hold = "conflict"
			changed.emit()
			break
		return
	if not _uploads.is_empty(): return # Dependencies must be acknowledged before a scene upload starts.
	var paths = store.pending.keys()
	paths.sort_custom(func(a, b): return _priority(a) < _priority(b))
	for path in paths:
		var change = store.pending[path]
		if change.get("blocked", false) or _uploads.has(change.operation): continue
		var file = FileAccess.open(store.object_path(change.hash), FileAccess.READ)
		if not file: continue
		var record = {"path": path, "hash": change.hash, "revision": 0, "size": file.get_length(), "author": store.identity}
		_uploads[change.operation] = Time.get_ticks_msec()
		_send_blob(0, record, "upload", change.operation, change.base)
		break

func _broadcast_record(record: Dictionary, except_link: int = -1):
	for id in links:
		if id != except_link and links[id].authenticated:
			_send(id, {"type": "manifest", "records": [record]})

func request_lease(path: String, release: bool = false):
	if not store.safe_path(path): return
	if is_host: _host_lease(store.identity, path, release)
	elif connected: _send(0, {"type": "scene", "path": path, "release": release})

func _host_lease(actor: String, path: String, release: bool):
	if not store.safe_path(path): return
	for scene in leases.keys():
		leases[scene].erase(actor)
		if leases[scene].is_empty(): leases.erase(scene)
	if not release:
		if not leases.has(path): leases[path] = []
		if actor not in leases[path]: leases[path].append(actor)
	_broadcast_presence()
	changed.emit()

func send_chat(text: String):
	if not connected: return
	if is_host: _host_chat(store.identity, text)
	else: _send(0, {"type": "chat", "text": text.left(4000)})

func _host_chat(actor: String, text: String):
	text = text.strip_edges().left(4000)
	if text == "": return
	var message = {"author": names.get(actor, "Developer"), "text": text, "time": Time.get_time_string_from_system()}
	chat_history.append(message)
	if chat_history.size() > 100: chat_history.pop_front()
	store._atomic_bytes(store.state_path.path_join("chat.json"), JSON.stringify({"messages": chat_history}).to_utf8_buffer())
	chat_message.emit(message)
	for id in links:
		if links[id].authenticated: _send(id, {"type": "chat", "message": message})

func _broadcast_presence():
	for id in links:
		if links[id].authenticated: _send(id, {"type": "presence", "leases": leases, "names": names})

func _drop_link(id: int):
	if not links.has(id): return
	var identity = links[id].identity
	links[id].stream.disconnect_from_host()
	links.erase(id)
	for key in _receiving.keys():
		if key.begins_with(str(id) + ":"):
			_receiving[key].file.close()
			_receiving.erase(key)
	if is_host:
		names.erase(identity)
		for path in leases.keys():
			leases[path].erase(identity)
			if leases[path].is_empty(): leases.erase(path)
		_broadcast_presence()
	else:
		connected = false
		_uploads.clear()
		_status = "Связь потеряна · неподтверждённые изменения сохранены"
	ready_changed.emit()
	changed.emit()
