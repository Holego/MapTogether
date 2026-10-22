extends SceneTree

const Store = preload("res://addons/coop_collab/store.gd")
const Session = preload("res://addons/coop_collab/session.gd")
const Merger = preload("res://addons/coop_collab/merge.gd")
const AddonNode = preload("res://tests/map_together_fixture.gd")
var passed = 0
var failed = 0
var _scene_serial = 0
var host
var client

func _initialize(): run.call_deferred()
func check(condition: bool, description: String):
	if condition:
		passed += 1
		print("PASS: ", description)
	else:
		failed += 1
		push_error("FAIL: " + description)

func write(path: String, bytes: PackedByteArray):
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()

func fixture(store, positions: Dictionary, addon_label: String = "original", options: Dictionary = {}) -> String:
	var scene = Node3D.new()
	scene.name = "World"
	for name in positions:
		var child = AddonNode.new()
		child.name = name
		child.position = positions[name]
		child.mesh = BoxMesh.new()
		child.addon_data = {"topology": PackedInt32Array([0, 1, 2]), "label": addon_label if name == "A" else "original"}
		child.set_meta("_mc_uuid", "fixture-" + name)
		scene.add_child(child)
		child.owner = scene
	if options.get("links", false):
		scene.get_node("B").linked_node = scene.get_node("A")
		scene.get_node("B").connect("tree_entered", Callable(scene.get_node("A"), "set_meta").bind("activated", true), CONNECT_PERSIST)
		scene.get_node("B").add_to_group("interactive", true)
	if options.get("reorder", false): scene.move_child(scene.get_node("B"), 0)
	if options.get("rename", false): scene.get_node("A").name = "RenamedA"
	if options.get("reparent", false):
		scene.get_node("A").owner = null
		scene.get_node("A").reparent(scene.get_node("B"), false)
		scene.get_node("B/A").owner = scene
	var packed = PackedScene.new()
	packed.pack(scene)
	_scene_serial += 1
	var path = store.state_path.path_join("fixture-%d.tscn" % _scene_serial)
	ResourceSaver.save(packed, path)
	var hash_value = store.capture_bytes(FileAccess.get_file_as_bytes(path))
	scene.free()
	return hash_value

func load_blob(store, hash_value: String) -> Node:
	return Merger.new(store)._load_scene("res://world.tscn", hash_value)

func make_session(store, is_host: bool):
	var value = Session.new()
	value.store = store
	root.add_child(value)
	value.set_process(false)
	value.is_host = is_host
	value.connected = is_host
	value.username = "Host" if is_host else "Guest"
	value.names[store.identity] = value.username
	return value

func connect_wire():
	host.links[1] = host._new_link(StreamPeerTCP.new())
	client.links[0] = client._new_link(StreamPeerTCP.new())
	client._send(0, {"type": "hello", "protocol": Session.PROTOCOL, "identity": client.store.identity, "name": "Guest", "password": ""})
	pump()

func deliver(source, source_id: int, target, target_id: int, drop_acks: bool = false):
	if not source.links.has(source_id): return
	var frames = source.links[source_id].queue.duplicate()
	source.links[source_id].queue.clear()
	for frame in frames:
		var size = frame.decode_u32(0)
		if size != frame.size() - 4:
			check(false, "Wire frame length")
			continue
		var message = bytes_to_var(frame.slice(4))
		if drop_acks and message.type == "ack": continue
		target._handle(target_id, message)

func pump(drop_acks: bool = false):
	for _turn in range(150):
		client._pump_outbox()
		client._stream_chunks()
		host._stream_chunks()
		client._drain_scenes()
		host._drain_uploads()
		deliver(client, 0, host, 1)
		deliver(host, 1, client, 0, drop_acks)
		if client._sending.is_empty() and host._sending.is_empty() and client.links.get(0, {}).get("queue", []).is_empty() and host.links.get(1, {}).get("queue", []).is_empty(): break

func run():
	var directory = "user://map-together-regression"
	var host_store = Store.new(directory.path_join("host"))
	var client_store = Store.new(directory.path_join("client"))
	check(not host_store.safe_path("res://../escape") and not host_store.safe_path("/tmp/escape") and not host_store.safe_path("res://.godot/cache"), "Traversal and editor internals cannot be overwritten")
	check(host_store.safe_path("res://addons/unknown_plugin/data.custombinary") and not host_store.safe_path("res://addons/coop_collab/session.gd"), "Unknown addon file types are supported; the running protocol stays local")
	var original = host_store.capture_bytes("original".to_utf8_buffer())
	var first = host_store.commit("host-first", "res://asset.data", "", original, "host", true)
	check(first.ok and host_store.source_hash("res://asset.data") == original, "Host commit writes the working file before acknowledging")
	var newer = host_store.capture_bytes("newer".to_utf8_buffer())
	var second = host_store.commit("host-second", "res://asset.data", original, newer, "host", true)
	check(second.ok and FileAccess.get_file_as_string(host_store.object_path(original)) == "original", "Replacing a file preserves its complete previous version")
	var replay = host_store.commit("host-first", "res://asset.data", "", original, "host")
	check(replay.ok and host_store.source_hash("res://asset.data") == newer, "Replaying an acknowledged operation never rolls back the host")
	var restored = Store.new(directory.path_join("host"))
	check(restored.receipts.has("host-first") and restored.records["res://asset.data"].hash == newer, "Host receipts and versions survive process restart")
	var stale = restored.commit("stale-op", "res://asset.data", original, original, "guest")
	check(not stale.ok and restored.source_hash("res://asset.data") == newer and restored.conflicts.has("res://asset.data"), "A stale write preserves both versions without replacing the host file")
	var journal_path = restored.state_path.path_join("journal.jsonl")
	var journal = FileAccess.open(journal_path, FileAccess.READ_WRITE)
	journal.seek_end()
	journal.store_string('{"torn":')
	journal.close()
	var after_crash = Store.new(directory.path_join("host"))
	var third_hash = after_crash.capture_bytes("third".to_utf8_buffer())
	check(after_crash.commit("after-torn-entry", "res://asset.data", newer, third_hash, "host", true).ok, "A torn journal tail does not prevent a later durable commit")
	var recovered = Store.new(directory.path_join("host"))
	check(recovered.records["res://asset.data"].hash == third_hash and recovered.receipts.has("after-torn-entry"), "Journal replay recovers commits written after a torn entry")
	var indexed_state = FileAccess.get_file_as_bytes(recovered.state_path.path_join("state.json"))
	var crash_hash = recovered.capture_bytes("journal before index".to_utf8_buffer())
	recovered.commit("crash-before-index", "res://asset.data", third_hash, crash_hash, "host", true)
	write(recovered.state_path.path_join("state.json"), indexed_state)
	recovered = Store.new(directory.path_join("host"))
	check(recovered.records["res://asset.data"].hash == crash_hash and recovered.receipts.has("crash-before-index"), "A flushed journal recovers a commit whose index was not saved")
	var branch = Store.new(directory.path_join("branch"))
	var branch_old = branch.capture_bytes("previous host session".to_utf8_buffer())
	branch.commit("branch-old", "res://session.txt", "", branch_old, branch.identity, true)
	var branch_remote = branch.capture_bytes("new host session".to_utf8_buffer())
	branch.receive_record({"path": "res://session.txt", "hash": branch_remote, "revision": 0, "host": "another-host", "author": "another-host", "size": 16})
	branch = Store.new(directory.path_join("branch"))
	check(branch.records["res://session.txt"].host == "another-host" and branch.source_hash("res://session.txt") == branch_remote, "An older host journal cannot roll back a later session after restart")
	var orphan = client_store.capture_bytes("offline edits".to_utf8_buffer())
	client_store.queue_change("res://offline.txt", orphan)
	var client_restart = Store.new(directory.path_join("client"))
	check(client_restart.pending.has("res://offline.txt") and FileAccess.get_file_as_string(client_restart.object_path(orphan)) == "offline edits", "Unacknowledged changes and their bodies survive restart")
	var pending_op = client_restart.pending["res://offline.txt"].operation
	check(not client_restart.acknowledge(pending_op, {"path": "res://offline.txt", "hash": original}), "An acknowledgment for different content cannot clear the outbox")
	client_restart.pending.clear()
	client_restart.save_state()
	# Independent objects of one map merge natively, including addon storage properties.
	var merger = Merger.new(host_store)
	var base = fixture(host_store, {"A": Vector3.ZERO, "B": Vector3(1, 0, 0)})
	var left = fixture(host_store, {"A": Vector3(5, 0, 0), "B": Vector3(1, 0, 0)})
	var right = fixture(host_store, {"A": Vector3.ZERO, "B": Vector3(1, 0, 9)})
	var combined = merger.merge("res://world.tscn", base, left, right)
	check(combined.ok, "Concurrent edits to different objects in the same map merge")
	if combined.ok:
		var world = load_blob(host_store, combined.hash)
		check(world.get_node("A").position == Vector3(5, 0, 0) and world.get_node("B").position == Vector3(1, 0, 9), "Merged map contains both participants' transforms")
		check(world.get_node("A").addon_data.topology == PackedInt32Array([0, 1, 2]), "Native scene merge preserves arbitrary addon storage data")
		world.free()
	var addon_change = fixture(host_store, {"A": Vector3.ZERO, "B": Vector3(1, 0, 0)}, "edited by addon")
	var addon_merge = merger.merge("res://world.tscn", base, right, addon_change)
	check(addon_merge.ok, "Custom addon data merges alongside another object's edits")
	if addon_merge.ok:
		var world = load_blob(host_store, addon_merge.hash)
		check(world.get_node("A").addon_data.label == "edited by addon" and world.get_node("B").position.z == 9, "Custom storage fields and map geometry both survive")
		world.free()
	var same_object = merger.merge("res://world.tscn", base, left, addon_change)
	check(same_object.ok, "Different properties on the same object can merge")
	for structural_change in ["rename", "reparent"]:
		var options = {structural_change: true}
		var changed_hierarchy = fixture(host_store, {"A": Vector3.ZERO, "B": Vector3(1, 0, 0)}, "original", options)
		var structural_merge = merger.merge("res://world.tscn", base, changed_hierarchy, left)
		var structural_ok = structural_merge.ok
		if structural_ok:
			var world = load_blob(host_store, structural_merge.hash)
			var expected_path = "RenamedA" if structural_change == "rename" else "B/A"
			structural_ok = world.has_node(expected_path) and is_equal_approx(world.get_node(expected_path).position.x, 5)
			world.free()
		check(structural_ok, "Stable object identity preserves a concurrent edit after " + structural_change)
	var wiring = fixture(host_store, {"A": Vector3.ZERO, "B": Vector3(1, 0, 0)}, "original", {"links": true, "reorder": true})
	var wiring_merge = merger.merge("res://world.tscn", base, left, wiring)
	check(wiring_merge.ok, "Signal, group, reference, and sibling-order changes merge with geometry edits")
	if wiring_merge.ok:
		var world = load_blob(host_store, wiring_merge.hash)
		check(world.get_node("B").linked_node == world.get_node("A") and world.get_node("B").is_in_group("interactive"), "Exported node references and persistent groups survive the merge")
		var connections = world.get_node("B").get_signal_connection_list("tree_entered")
		check(connections.size() == 1 and connections[0].callable.get_object() == world.get_node("A") and world.get_child(0).name == "B", "Signal targets point into the merged map and native sibling order is retained")
		world.free()
	var conflict = merger.merge("res://world.tscn", base, left, fixture(host_store, {"A": Vector3(-4, 0, 0), "B": Vector3(1, 0, 0)}))
	check(not conflict.ok, "Concurrent changes to the same property produce a conflict")
	var additions = merger.merge("res://world.tscn", base, fixture(host_store, {"A": Vector3.ZERO, "B": Vector3(1, 0, 0), "C": Vector3(3, 0, 0)}), fixture(host_store, {"A": Vector3.ZERO, "B": Vector3(1, 0, 0), "D": Vector3(4, 0, 0)}))
	check(additions.ok, "New nodes added by two participants merge")
	if additions.ok:
		var world = load_blob(host_store, additions.hash)
		check(world.has_node("C") and world.has_node("D") and world.get_child_count() == 4, "Neither participant's added map object disappears")
		world.free()
	var removed = fixture(host_store, {"B": Vector3(1, 0, 0)})
	check(not merger.merge("res://world.tscn", base, left, removed).ok, "Deleting an object that another participant edited is rejected safely")
	var many = {}
	for index in range(256): many["Object_%03d" % index] = Vector3(index, 0, 0)
	var large_base = fixture(host_store, many)
	many["Object_010"] = Vector3(10, 2, 0)
	var large_host = fixture(host_store, many)
	many["Object_010"] = Vector3(10, 0, 0)
	many["Object_240"] = Vector3(240, 0, 3)
	var large_remote = fixture(host_store, many)
	var large_result = merger.merge("res://large_map.tscn", large_base, large_host, large_remote)
	check(large_result.ok, "A larger map merges without a fixed node-count limit")
	if large_result.ok:
		var world = load_blob(host_store, large_result.hash)
		check(world.get_child_count() == 256 and world.get_node("Object_010").position.y == 2 and world.get_node("Object_240").position.z == 3, "Every object in the larger map remains present")
		world.free()
	var code_base = host_store.capture_bytes("extends Node\nvar speed = 1\n\nfunc run():\n\tpass\n".to_utf8_buffer())
	var code_host = host_store.capture_bytes("extends Node\nvar speed = 2\n\nfunc run():\n\tpass\n".to_utf8_buffer())
	var code_guest = host_store.capture_bytes("extends Node\nvar speed = 1\n\nfunc run():\n\tprint(42)\n".to_utf8_buffer())
	var code = merger.merge("res://movement.gd", code_base, code_host, code_guest)
	check(code.ok and "speed = 2" in FileAccess.get_file_as_string(host_store.object_path(code.hash)) and "print(42)" in FileAccess.get_file_as_string(host_store.object_path(code.hash)), "Different script sections merge without replacing either author's code")
	var conflicting_code = host_store.capture_bytes("extends Node\nvar speed = 3\n\nfunc run():\n\tpass\n".to_utf8_buffer())
	check(not merger.merge("res://movement.gd", code_base, code_host, conflicting_code).ok, "Overlapping script edits remain an explicit conflict")
	if ResourceLoader.exists("res://poi_fixture.tscn"):
		var poi = load("res://poi_fixture.tscn").instantiate()
		var meshes = []
		for child in poi.get_children():
			if child.get("pb_mesh_data") != null: meshes.append(child)
		check(meshes.size() >= 2, "The project's actual PoiBuilder scene loads with its custom data")
		if meshes.size() >= 2:
			var packed = PackedScene.new()
			packed.pack(poi)
			var saved_path = host_store.state_path.path_join("poi-test.tscn")
			ResourceSaver.save(packed, saved_path)
			var poi_base = host_store.capture_bytes(FileAccess.get_file_as_bytes(saved_path))
			var first_position = meshes[0].position
			meshes[0].position.x += 2.0
			packed = PackedScene.new()
			packed.pack(poi)
			ResourceSaver.save(packed, saved_path)
			var poi_host = host_store.capture_bytes(FileAccess.get_file_as_bytes(saved_path))
			meshes[0].position = first_position
			var points = meshes[1].pb_mesh_data.positions.duplicate()
			points[0].y += 0.125
			meshes[1].pb_mesh_data.positions = points
			meshes[1].rebuild()
			packed = PackedScene.new()
			packed.pack(poi)
			ResourceSaver.save(packed, saved_path)
			var poi_remote = host_store.capture_bytes(FileAccess.get_file_as_bytes(saved_path))
			var poi_result = merger.merge("res://poi_fixture.tscn", poi_base, poi_host, poi_remote)
			check(poi_result.ok, "PoiBuilder mesh edits merge with another map object's transform")
			if poi_result.ok:
				var result_scene = load_blob(host_store, poi_result.hash)
				check(is_equal_approx(result_scene.get_node(NodePath(str(meshes[0].name))).position.x, first_position.x + 2.0) and result_scene.get_node(NodePath(str(meshes[1].name))).pb_mesh_data.positions[0].is_equal_approx(points[0]), "Actual PoiBuilder geometry data and both participants' changes are preserved")
				result_scene.free()
		poi.free()
	# Exercise the actual encoded protocol and chunk streams without requiring local sockets.
	host = make_session(recovered, true)
	client = make_session(client_restart, false)
	connect_wire()
	check(client.connected, "Protocol handshake authenticates a separate editor identity")
	check(client.store.source_hash("res://asset.data") == host.store.source_hash("res://asset.data"), "Initial host files download through the framed protocol")
	var bytes = PackedByteArray()
	bytes.resize(260000)
	for i in range(bytes.size()): bytes[i] = i % 251
	var binary_hash = client.store.capture_bytes(bytes)
	client.publish("res://addons/unknown_plugin/geometry.custombinary", binary_hash)
	pump()
	check(host.store.source_hash("res://addons/unknown_plugin/geometry.custombinary") == binary_hash, "Large unknown-addon files arrive in multiple verified chunks")
	check(client.store.pending.is_empty(), "Client clears its outbox only after the host's durable acknowledgment")
	check(FileAccess.file_exists(host.store.state_path.path_join("journal.jsonl")), "Successful network uploads have a host journal")
	var delayed_hash = client.store.capture_bytes("ack may be lost".to_utf8_buffer())
	client.publish("res://retry.txt", delayed_hash)
	pump(true)
	check(client.store.pending.has("res://retry.txt") and host.store.source_hash("res://retry.txt") == delayed_hash, "Losing an acknowledgment retains the client's recoverable outbox")
	var sequence_before = host.store.sequence
	host.store = Store.new(directory.path_join("host"))
	client._uploads.clear()
	pump()
	check(not client.store.pending.has("res://retry.txt") and host.store.sequence == sequence_before, "Retry after host restart is idempotent and acknowledged")
	write(client.store.local_path("res://only_here.raw"), "local-only asset".to_utf8_buffer())
	host._send_manifest(1)
	pump()
	check(FileAccess.file_exists(client.store.local_path("res://only_here.raw")), "A complete host manifest never deletes local-only files")
	# Concurrent whole-scene edits traverse the actual upload, native merge, ack, and download path.
	var map_record = host.store.commit("map-initial", "res://world.tscn", "", base, host.store.identity, true)
	host._broadcast_record(map_record.record)
	pump()
	var client_map = client.store.capture_bytes(FileAccess.get_file_as_bytes(host.store.object_path(right)))
	write(client.store.local_path("res://world.tscn"), FileAccess.get_file_as_bytes(client.store.object_path(client_map)))
	client.publish("res://world.tscn", client_map)
	host.publish("res://world.tscn", left)
	pump()
	check(not client.store.pending.has("res://world.tscn"), "A merged host acknowledgment clears the matching original submission")
	var host_world = load_blob(host.store, host.store.source_hash("res://world.tscn"))
	var client_world = load_blob(client.store, client.store.source_hash("res://world.tscn"))
	check(host_world.get_node("A").position.x == 5 and host_world.get_node("B").position.z == 9 and client_world.get_node("A").position.x == 5 and client_world.get_node("B").position.z == 9, "Host and client converge to both authors' map edits")
	host_world.free()
	client_world.free()
	# Submit another edit while the first commit's acknowledgment is lost, then restart the host.
	var current_map = host.store.source_hash("res://world.tscn")
	var next_local = fixture(client.store, {"A": Vector3(5, 0, 0), "B": Vector3(1, 0, 12)})
	write(client.store.local_path("res://world.tscn"), FileAccess.get_file_as_bytes(client.store.object_path(next_local)))
	client.publish("res://world.tscn", next_local)
	client._pump_outbox()
	var latest_local = fixture(client.store, {"A": Vector3(5, 0, 0), "B": Vector3(1, 0, 15)})
	write(client.store.local_path("res://world.tscn"), FileAccess.get_file_as_bytes(client.store.object_path(latest_local)))
	client.publish("res://world.tscn", latest_local)
	var simultaneous_host = fixture(host.store, {"A": Vector3(8, 0, 0), "B": Vector3(1, 0, 9)})
	host.publish("res://world.tscn", simultaneous_host)
	pump(true)
	check(client.store.pending.has("res://world.tscn") and client.store.pending["res://world.tscn"].get("next_hash", "") == latest_local, "Editing during an in-flight upload preserves the newer queued scene")
	host.store = Store.new(directory.path_join("host"))
	client._uploads.clear()
	pump()
	var final_host = load_blob(host.store, host.store.source_hash("res://world.tscn"))
	var final_client = load_blob(client.store, client.store.source_hash("res://world.tscn"))
	check(final_host.get_node("A").position.x == 8 and final_host.get_node("B").position.z == 15 and final_client.get_node("A").position.x == 8 and final_client.get_node("B").position.z == 15, "After reconnect, newer local work is rebased without erasing concurrent host objects")
	check(not client.store.pending.has("res://world.tscn"), "All scene revisions receive durable acknowledgments after reconnect")
	final_host.free()
	final_client.free()
	# Multiple participants share a scene; presence is not an exclusive scene lock.
	host._host_lease(host.store.identity, "res://world.tscn", false)
	host._host_lease(client.store.identity, "res://world.tscn", false)
	check(host.leases["res://world.tscn"].size() == 2, "Two participants can edit the same map concurrently")
	client.send_chat("Hello map")
	pump()
	check(host.chat_history.back().author == "Guest" and client.chat_history.back().text == "Hello map", "Chat is attributed by the host and delivered to participants")
	await _player_test()
	print("MAPTOGETHER RESULT: %d passed, %d failed" % [passed, failed])
	host.free()
	client.free()
	await process_frame
	quit(1 if failed else 0)

func _player_test():
	var world = load("res://scenes/map_together_playground.tscn").instantiate()
	root.add_child(world)
	var player = world.get_node("TestPlayer")
	for i in range(60): await physics_frame
	check(player.is_on_floor(), "Test player lands on the collaboration playground")
	var start = player.position.x
	Input.action_press("ui_right")
	for i in range(20): await physics_frame
	Input.action_release("ui_right")
	check(player.position.x > start + 1.0, "Test player moves")
	Input.action_press("ui_accept")
	for i in range(10): await physics_frame
	Input.action_release("ui_accept")
	check(player.position.y > 0.3, "Test player jumps")
	world.free()
