@tool
extends RefCounted

var store
var _base_paths: Dictionary
var _base_ids: Dictionary
var _saved_groups: Dictionary = {}

func _init(version_store):
	store = version_store

func merge(path: String, base_hash: String, host_hash: String, incoming_hash: String) -> Dictionary:
	if incoming_hash == base_hash: return {"ok": true, "hash": host_hash}
	if host_hash == base_hash or host_hash == incoming_hash: return {"ok": true, "hash": incoming_hash}
	for hash_value in [base_hash, host_hash, incoming_hash]:
		if not store.valid_hash(hash_value) or not FileAccess.file_exists(store.object_path(hash_value)):
			return {"ok": false, "reason": "Нет общей сохранённой версии"}
	if path.get_extension() in ["tscn", "scn"]:
		return _merge_scene(path, base_hash, host_hash, incoming_hash)
	if path.get_extension() in ["gd", "cs", "gdshader", "shader", "txt", "md", "cfg", "json", "csv", "ini", "toml", "yaml", "yml"]:
		return _merge_text(base_hash, host_hash, incoming_hash)
	return {"ok": false, "reason": "Одновременно изменён двоичный файл"}

func _text(hash_value: String) -> String:
	return FileAccess.get_file_as_string(store.object_path(hash_value)).replace("\r\n", "\n")

func _edit(base: PackedStringArray, other: PackedStringArray) -> Dictionary:
	var start = 0
	while start < mini(base.size(), other.size()) and base[start] == other[start]: start += 1
	var end_base = base.size()
	var end_other = other.size()
	while end_base > start and end_other > start and base[end_base - 1] == other[end_other - 1]:
		end_base -= 1
		end_other -= 1
	return {"start": start, "end": end_base, "lines": other.slice(start, end_other)}

func _merge_text(base_hash: String, host_hash: String, incoming_hash: String) -> Dictionary:
	var base = _text(base_hash).split("\n")
	var host = _text(host_hash).split("\n")
	var incoming = _text(incoming_hash).split("\n")
	var a = _edit(base, host)
	var b = _edit(base, incoming)
	if a.start == b.start and a.end == b.end and a.lines == b.lines: return {"ok": true, "hash": host_hash}
	# Conservatively merge separate ranges. Overlaps remain an explicit conflict.
	if not (a.end <= b.start or b.end <= a.start) or (a.start == b.start):
		return {"ok": false, "reason": "Один участок скрипта изменён одновременно"}
	var edits = [a, b]
	edits.sort_custom(func(left, right): return left.start > right.start)
	var result = base
	for edit in edits:
		var updated = result.slice(0, edit.start)
		updated.append_array(edit.lines)
		updated.append_array(result.slice(edit.end))
		result = updated
	var hash_value = store.capture_bytes("\n".join(result).to_utf8_buffer())
	return {"ok": hash_value != "", "hash": hash_value, "reason": "Ошибка сохранения объединённого скрипта"}

func _load_scene(path: String, hash_value: String) -> Node:
	var directory = store.state_path.path_join("merge")
	DirAccess.make_dir_recursive_absolute(directory)
	var scene_path = directory.path_join(hash_value + "." + path.get_extension())
	if not FileAccess.file_exists(scene_path):
		if DirAccess.copy_absolute(store.object_path(hash_value), scene_path) != OK: return null
	var packed = ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if not packed is PackedScene: return null
	var root = packed.instantiate()
	var groups = {}
	var state = packed.get_state()
	for index in range(state.get_node_count()): groups[str(state.get_node_path(index)).trim_prefix("./")] = state.get_node_groups(index)
	_saved_groups[root.get_instance_id()] = groups
	return root

func _relative(node: Node, root: Node) -> String:
	if node == root: return "."
	var names: Array[String] = []
	var current = node
	while current and current != root:
		names.push_front(str(current.name))
		current = current.get_parent()
	return "/".join(names)

func _depth(node: Node) -> int:
	var depth = 0
	while node:
		depth += 1
		node = node.get_parent()
	return depth

func _props(node: Node, root: Node) -> Dictionary:
	var result = {}
	for property in node.get_property_list():
		if property.usage & PROPERTY_USAGE_STORAGE and property.name != "metadata/_mc_uuid":
			result[str(property.name)] = node.get(property.name)
	var connections = []
	for signal_info in node.get_signal_list():
		for connection in node.get_signal_connection_list(signal_info.name):
			if connection.flags & CONNECT_PERSIST:
				connections.append({"signal": signal_info.name, "target": connection.callable.get_object(), "method": connection.callable.get_method(), "binds": connection.callable.get_bound_arguments(), "unbinds": connection.callable.get_unbound_arguments_count(), "flags": connection.flags})
	result["__mc_connections"] = connections
	result["__mc_groups"] = _saved_groups.get(root.get_instance_id(), {}).get(_relative(node, root), PackedStringArray())
	return result

func _stable_value(value: Variant, root: Node, seen: Dictionary) -> Variant:
	if value is Object and not is_instance_valid(value): return null
	if value is Node:
		return {"node": _key(value, root) if root == value or root.is_ancestor_of(value) else "external"}
	if value is Resource:
		if value.resource_path != "" and not value.resource_path.contains("::"):
			return {"resource": value.resource_path}
		var instance = value.get_instance_id()
		if seen.has(instance): return {"reference": seen[instance]}
		seen[instance] = seen.size()
		var properties: Array = []
		var names: Array[String] = []
		for property in value.get_property_list():
			if property.usage & PROPERTY_USAGE_STORAGE: names.append(property.name)
		names.sort()
		for name in names: properties.append([name, _stable_value(value.get(name), root, seen)])
		return {"class": value.get_class(), "properties": properties}
	if value is Array:
		var result = []
		for item in value: result.append(_stable_value(item, root, seen))
		return result
	if value is Dictionary:
		var keys = value.keys()
		keys.sort_custom(func(a, b): return var_to_str(a) < var_to_str(b))
		var result = []
		for key in keys: result.append([_stable_value(key, root, seen), _stable_value(value[key], root, seen)])
		return {"dictionary": result}
	if value is Object:
		var instance = value.get_instance_id()
		if seen.has(instance): return {"reference": seen[instance]}
		seen[instance] = seen.size()
		var properties = []
		var names = []
		for property in value.get_property_list():
			if property.usage & PROPERTY_USAGE_STORAGE: names.append(property.name)
		names.sort()
		for name in names: properties.append([name, _stable_value(value.get(name), root, seen)])
		return {"object_class": value.get_class(), "properties": properties}
	return value

func _fingerprint(value: Variant, root: Node) -> String:
	return store.hash_bytes(var_to_bytes(_stable_value(value, root, {})))

func _key(node: Node, root: Node) -> String:
	if node == root: return "."
	var path = _relative(node, root)
	var uuid = str(node.get_meta("_mc_uuid", ""))
	if uuid != "" and _base_ids.has(uuid): return _base_ids[uuid]
	if _base_paths.has(path): return _base_paths[path]
	return "id:" + uuid if uuid != "" else "path:" + path

func _tree_value(node: Node, root: Node) -> Variant:
	var children = []
	for child in node.get_children(): children.append(_tree_value(child, root))
	return [node.get_class(), str(node.name), _stable_value(_props(node, root), root, {}), children]

func _snapshot(root: Node) -> Dictionary:
	var result = {}
	_collect(root, root, result)
	return result

func _collect(node: Node, root: Node, result: Dictionary):
	if node != root and node.owner != root: return
	var key = _key(node, root)
	var opaque = node != root and node.scene_file_path != ""
	result[key] = {"node": node, "key": key, "name": str(node.name), "parent": "" if node == root else _key(node.get_parent(), root), "class": node.get_class(), "props": _props(node, root), "opaque": opaque, "order": [], "tree": _fingerprint(_tree_value(node, root), root) if opaque else ""}
	if not opaque:
		for child in node.get_children():
			if child.owner == root: result[key].order.append(_key(child, root))
	if opaque: return # Instanced addon scenes retain their native internal ownership and overrides.
	for child in node.get_children(): _collect(child, root, result)

func _same(a: Dictionary, b: Dictionary, a_root: Node, b_root: Node) -> bool:
	return a.name == b.name and a.parent == b.parent and a["class"] == b["class"] and a.tree == b.tree and a.order == b.order and _fingerprint(a.props, a_root) == _fingerprint(b.props, b_root)

func _descendant(key: String, ancestor: String, nodes: Dictionary) -> bool:
	var current = key
	while nodes.has(current) and current != ".":
		if current == ancestor: return true
		current = nodes[current].parent
	return current == ancestor

func _owners(original: Node, copy: Node, original_root: Node, new_root: Node):
	if original.owner == original_root: copy.owner = new_root
	for child in original.get_children():
		var copied = copy.get_node_or_null(NodePath(str(child.name)))
		if copied: _owners(child, copied, original_root, new_root)

func _index_base(base: Node):
	_base_paths = {}
	_base_ids = {}
	var walk = [base]
	while not walk.is_empty():
		var node = walk.pop_back()
		var relative = "." if node == base else _relative(node, base)
		var uuid = str(node.get_meta("_mc_uuid", ""))
		var key = "." if node == base else ("id:" + uuid if uuid != "" else "path:" + relative)
		_base_paths[relative] = key
		if uuid != "": _base_ids[uuid] = key
		walk.append_array(node.get_children())

func apply_to_live_scene(path: String, base_hash: String, incoming_hash: String, live: Node) -> bool:
	var base = _load_scene(path, base_hash)
	var shadow = _load_scene(path, base_hash)
	var incoming = _load_scene(path, incoming_hash)
	if not base or not shadow or not incoming:
		for root in [base, shadow, incoming]:
			if is_instance_valid(root): root.free()
		return false
	_index_base(base)
	var b = _snapshot(base)
	var r = _snapshot(incoming)
	var error = _apply_scene_merge(b, _snapshot(shadow), r, base, shadow, incoming)
	if error == "":
		_saved_groups[live.get_instance_id()] = _saved_groups.get(base.get_instance_id(), {})
		var nodes = _snapshot(live)
		error = _apply_scene_merge(b, nodes, r, base, live, incoming)
		if error == "":
			for key in r:
				if nodes.has(key) and is_instance_valid(nodes[key].node) and r[key].node.has_meta("_mc_uuid"):
					nodes[key].node.set_meta("_mc_uuid", r[key].node.get_meta("_mc_uuid"))
	_saved_groups.erase(live.get_instance_id())
	for root in [base, shadow, incoming]:
		_saved_groups.erase(root.get_instance_id())
		root.free()
	return error == ""

func _merge_scene(path: String, base_hash: String, host_hash: String, incoming_hash: String) -> Dictionary:
	var base = _load_scene(path, base_hash)
	var host = _load_scene(path, host_hash)
	var incoming = _load_scene(path, incoming_hash)
	if not base or not host or not incoming:
		for root in [base, host, incoming]:
			if is_instance_valid(root): root.free()
		return {"ok": false, "reason": "Не удалось прочитать сцену или её зависимости"}
	_index_base(base)
	var b = _snapshot(base)
	var h = _snapshot(host)
	var r = _snapshot(incoming)
	var error = _apply_scene_merge(b, h, r, base, host, incoming)
	var result = {"ok": false, "reason": error}
	if error == "":
		host.scene_file_path = path
		var packed = PackedScene.new()
		var output = store.state_path.path_join("merge/result." + path.get_extension())
		if packed.pack(host) == OK and ResourceSaver.save(packed, output) == OK:
			var hash_value = store.capture_bytes(FileAccess.get_file_as_bytes(output))
			result = {"ok": hash_value != "", "hash": hash_value, "reason": "Ошибка записи сцены"}
	_saved_groups.erase(base.get_instance_id())
	_saved_groups.erase(host.get_instance_id())
	_saved_groups.erase(incoming.get_instance_id())
	base.free()
	host.free()
	incoming.free()
	return result

func _apply_scene_merge(b: Dictionary, h: Dictionary, r: Dictionary, base: Node, host: Node, incoming: Node) -> String:
	# Replacing an opaque instance can invalidate exported references from other nodes.
	# Fall back to native reload (or an explicit conflict during a concurrent merge).
	for key in r:
		if not b.has(key) or not h.has(key) or not (r[key].opaque or h[key].opaque): continue
		if _same(r[key], b[key], incoming, base): continue
		for other in h:
			if other != key and _references_subtree(h[other].props, h[key].node, {}):
				return "Изменён экземпляр сцены со ссылками из других узлов: " + r[key].name
	# Detect delete-vs-edit conflicts before changing the detached host copy.
	for key in b:
		if key == "." or r.has(key) or not h.has(key): continue
		for child_key in h:
			if _descendant(child_key, key, h) and (not b.has(child_key) or not _same(h[child_key], b[child_key], host, base)):
				return "Удаление узла конфликтует с правками другого участника: " + b[key].name
	for key in b:
		if not h.has(key) and r.has(key) and not _same(r[key], b[key], incoming, base):
			return "Узел удалён у хоста и изменён участником: " + b[key].name
	var removals: Array = []
	for key in b:
		if key != "." and not r.has(key) and h.has(key): removals.append(key)
	removals.sort_custom(func(a, c): return _depth(h[a].node) > _depth(h[c].node))
	for key in removals:
		if is_instance_valid(h[key].node): h[key].node.free()
		h.erase(key)
	for key in r:
		if not b.has(key) and h.has(key) and not _same(h[key], r[key], host, incoming):
			return "Новый узел изменён двумя участниками: " + r[key].name
	# Create new owned nodes in parent order; native instances remain opaque subtrees.
	var additions: Array = []
	for key in r:
		if not b.has(key) and not h.has(key): additions.append(key)
	var iterations = additions.size() + 1
	while not additions.is_empty() and iterations > 0:
		iterations -= 1
		for key in additions.duplicate():
			var remote = r[key]
			if not h.has(remote.parent): continue
			var parent = h[remote.parent].node
			if parent.has_node(NodePath(remote.name)):
				return "Два новых узла имеют одинаковое имя: " + remote.name
			var copy = remote.node.duplicate()
			if not copy: return "Не удалось скопировать узел " + remote.name
			if not remote.opaque:
				for child in remote.node.get_children():
					if child.owner == incoming:
						var copied = copy.get_node_or_null(NodePath(str(child.name)))
						if copied: copied.free()
			parent.add_child(copy)
			_owners(remote.node, copy, incoming, host)
			copy.owner = host
			h[key] = remote.duplicate()
			h[key].node = copy
			additions.erase(key)
	if not additions.is_empty(): return "Родитель нового узла удалён другим участником"
	for key in r:
		if not b.has(key) or not h.has(key): continue
		var original = b[key]
		var local = h[key]
		var remote = r[key]
		if _same(remote, original, incoming, base): continue
		if remote["class"] != original["class"] or local["class"] != original["class"]:
			return "Изменён тип узла: " + remote.name
		if remote.opaque or local.opaque:
			if not _same(local, original, host, base) and not _same(local, remote, host, incoming):
				return "Один экземпляр сцены изменён одновременно: " + remote.name
			var replacement = remote.node.duplicate()
			var parent = local.node.get_parent()
			var index = local.node.get_index()
			local.node.free()
			parent.add_child(replacement)
			parent.move_child(replacement, index)
			_owners(remote.node, replacement, incoming, host)
			replacement.owner = host
			h[key].node = replacement
			continue
		for field in ["parent", "name"]:
			if remote[field] == original[field]: continue
			if local[field] != original[field] and local[field] != remote[field]: return "Разные изменения иерархии: " + remote.name
			if field == "parent":
				if not h.has(remote.parent): return "Родитель узла отсутствует"
				var parent = h[remote.parent].node
				if local.node == parent or local.node.is_ancestor_of(parent): return "Цикл в иерархии узлов"
				if parent.has_node(NodePath(str(local.node.name))) and parent.get_node(NodePath(str(local.node.name))) != local.node: return "Совпадение имён при переносе узла"
				_reparent_owned(local.node, parent, host)
			else:
				if local.node != host and local.node.get_parent().has_node(NodePath(remote.name)) and local.node.name != remote.name: return "Совпадение имён узлов"
				local.node.name = remote.name
		for property in remote.props:
			var rv = remote.props[property]
			var bv = original.props.get(property)
			var hv = local.props.get(property)
			var remote_fingerprint = _fingerprint(rv, incoming)
			if remote_fingerprint == _fingerprint(bv, base): continue
			if _fingerprint(hv, host) != _fingerprint(bv, base) and _fingerprint(hv, host) != remote_fingerprint:
				return "Одно свойство изменено одновременно: " + remote.name + "." + property
			if property == "__mc_groups":
				for group in local.props.get(property, []): local.node.remove_from_group(group)
				for group in rv: local.node.add_to_group(group, true)
			elif property == "__mc_connections":
				_apply_connections(local.node, rv, h, incoming, host)
			else:
				local.node.set(property, _remap_value(rv, h, incoming, host))
		for property in original.props:
			if property.begins_with("metadata/") and not remote.props.has(property):
				if _fingerprint(local.props.get(property), host) != _fingerprint(original.props[property], base): return "Удаление метаданных конфликтует с правками"
				local.node.remove_meta(property.trim_prefix("metadata/"))
	# Reconcile sibling order as well as object properties (important for UI/control scenes).
	for key in r:
		if not b.has(key) or not h.has(key) or r[key].opaque: continue
		var base_order = b[key].order
		var local_order = h[key].order
		var remote_order = r[key].order
		var common = base_order.filter(func(item): return item in local_order and item in remote_order)
		var local_common = local_order.filter(func(item): return item in common)
		var remote_common = remote_order.filter(func(item): return item in common)
		if local_common != common and remote_common != common and local_common != remote_common:
			return "Порядок одних узлов изменён одновременно"
		var desired = remote_order.duplicate() if remote_common != common else local_order.duplicate()
		var extra = local_order if remote_common != common else remote_order
		var previous = ""
		for item in extra:
			if item not in desired:
				var index = desired.find(previous)
				desired.insert(index + 1 if index >= 0 else desired.size(), item)
			previous = item
		var index = 0
		for item in desired:
			if h.has(item) and is_instance_valid(h[item].node) and h[item].node.get_parent() == h[key].node:
				h[key].node.move_child(h[item].node, index)
				index += 1
	# New nodes may reference existing map nodes outside their duplicated subtree.
	for key in r:
		if not b.has(key) and h.has(key):
			for property in r[key].props:
				if property == "__mc_connections": _apply_connections(h[key].node, r[key].props[property], h, incoming, host)
				elif not property.begins_with("__mc_"):
					h[key].node.set(property, _remap_value(r[key].props[property], h, incoming, host))
	return ""

func _reparent_owned(node: Node, parent: Node, root: Node):
	var owned = []
	var walk = [node]
	while not walk.is_empty():
		var child = walk.pop_back()
		if child.owner == root:
			owned.append(child)
			child.owner = null
		walk.append_array(child.get_children())
	node.reparent(parent, false)
	for child in owned: child.owner = root

func _references_subtree(value: Variant, subtree: Node, seen: Dictionary) -> bool:
	if value is Object and not is_instance_valid(value): return false
	if value is Node: return value == subtree or subtree.is_ancestor_of(value)
	if value is Array:
		for item in value:
			if _references_subtree(item, subtree, seen): return true
	if value is Dictionary:
		for key in value:
			if _references_subtree(key, subtree, seen) or _references_subtree(value[key], subtree, seen): return true
	if value is Resource:
		var id = value.get_instance_id()
		if seen.has(id): return false
		seen[id] = true
		for property in value.get_property_list():
			if property.usage & PROPERTY_USAGE_STORAGE and _references_subtree(value.get(property.name), subtree, seen): return true
	return false

func _remap_value(value: Variant, nodes: Dictionary, source: Node, target: Node) -> Variant:
	if value is Node:
		var key = _key(value, source)
		return nodes[key].node if nodes.has(key) else target.get_node_or_null(NodePath(_relative(value, source)))
	if value is Array:
		var result = value.duplicate()
		for index in range(result.size()): result[index] = _remap_value(result[index], nodes, source, target)
		return result
	if value is Dictionary:
		var result = value.duplicate()
		for key in result: result[key] = _remap_value(result[key], nodes, source, target)
		return result
	return value

func _apply_connections(node: Node, connections: Array, nodes: Dictionary, source: Node, target: Node):
	for signal_info in node.get_signal_list():
		for connection in node.get_signal_connection_list(signal_info.name):
			if connection.flags & CONNECT_PERSIST: node.disconnect(signal_info.name, connection.callable)
	for connection in connections:
		var receiver = _remap_value(connection.target, nodes, source, target)
		if not is_instance_valid(receiver): continue
		var callable = Callable(receiver, connection.method)
		if connection.unbinds > 0: callable = callable.unbind(connection.unbinds)
		if not connection.binds.is_empty(): callable = callable.bindv(connection.binds)
		if not node.is_connected(connection.signal, callable): node.connect(connection.signal, callable, connection.flags)
