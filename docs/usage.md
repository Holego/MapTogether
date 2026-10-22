# MapTogether 0.1.0

Collaborative editing for Godot 4.7 projects, including scenes, scripts, resources, and chat.

The host stores confirmed file versions and a change log. Each participant also maintains their own version history and queue of unconfirmed changes.

## Connection

1. Install the same `addons/coop_collab` folder in both copies of the project.
2. Disable **Team Create** and **CoopSync**. Enable **MapTogether** under **Project → Project Settings → Plugins**. Restart both editor instances after switching from a previous addon.
3. On the computer containing the main map, open the **MapTogether** panel and click **Create**. Wait for file preparation to finish. The default port is **TCP 25568**.
4. Other participants enter the host's IP address, the same port, and the room password, then click **Join**. Connecting over the internet requires an accessible TCP port or a shared VPN network. `127.0.0.1` only works when running two project copies on the same computer.
5. Open the desired map in both project copies. You can now edit the same scene together.

Previous Team Create/CoopSync sessions cannot be migrated to the new protocol.

Other editor plugins can remain enabled. Each participant's list of enabled plugins remains local: synchronizing `project.godot` does not automatically enable or disable plugins on other computers.

## Saving and Collaboration

- **Autosaving** checks the active scene and open modified scripts approximately every 0.8 seconds. It also works when no other participants are connected. New unnamed scenes are assigned a unique path under `res://scenes/shared/…tscn`.
- Scenes are saved using Godot's native saving system, including `STORAGE` properties from third-party addons. Addon changes are detected even when the addon does not mark the scene tab as modified.
- Changes to different objects or different properties of the same object are merged by the host against a common saved version. Renaming and reparenting use stable node IDs. Node additions, deletions, ordering, groups, signals, and exported references are taken into account during merging.
- Editing the same property, deleting an object modified by another participant, or modifying overlapping script sections results in a **conflict**. Both versions are preserved. Click **Conflicts**, select the file, and explicitly choose whether to keep your local version or accept the incoming version. Accepting the incoming version replaces the entire current file content.
- Compatible changes to the currently open scene are applied to existing nodes while preserving the current selection. If this is not possible, Godot's native scene reload mechanism is used.
- **Pending confirmations: 0** means the outgoing change queue is empty. A change is considered confirmed after the working file and journal have been written on the host. If the connection is lost, local changes remain queued. After restoring the connection, click **Join** again. Automatic reconnection is not yet supported.
- **Save and Send** immediately saves scenes and scripts. **Get Host Files** refreshes version information while preserving local differences as conflicts.
- **Output** opens Godot's standard Output panel. **Log** displays addon messages. The host stores the latest 100 chat messages.

Files outside scenes are checked incrementally, with the file list refreshed approximately every five seconds.

Scenes are transferred after their required resources and addon files.

Binary files are transferred in 64 KiB chunks with SHA-256 integrity verification.

There is no fixed limit on the number of nodes or an allowlist of supported file extensions. Performance depends on project size, scene complexity, disk speed, and network conditions.

## Version History and Recovery

A hidden `.coop_collab` directory is created in the root of each working project copy:

- `objects/<SHA256>.bin` — complete contents of every captured file version.
- `journal.jsonl` — sequential log of confirmed host operations.
- `state.json` — file versions, pending changes, conflicts, and confirmations.
- `chat.json` — chat history stored on the host.

Before replacing a file, its previous version is preserved.

New file contents are first written to a temporary file, which is then atomically renamed.

Retrying an operation after a lost confirmation does not roll back the host.

On restart, complete journal entries are read, while an incomplete final entry is ignored.

### Manual Recovery

To restore a previous version:

1. Find the required `hash` and `path` in `journal.jsonl`, or locate the hash in the conflict window.
2. **Copy** the corresponding `objects/<hash>.bin` file to a separate location, keeping the original untouched.
3. Rename the copy using the original file extension, for example `recovered_map.tscn`.
4. Open and verify the recovered file before replacing your working map.

The `.bin` file contains the original file data. The `.bin` extension is used only for version history storage.

Do not delete `.coop_collab` while you still need its history or have unconfirmed changes.

When sharing the project with a new participant, provide the project source files and addon without the `.godot`, `.team_create`, and `.coop_collab` directories. Each working copy must maintain its own history and identity.

Include the host's version history in your project backups.

The journal confirms that data has been written through the operating system, but it cannot guarantee durability in the event of storage failure or power loss.

## Limitations of the First Release

- **Nested scene instances** are merged as complete units. Simultaneous changes within the same instance may require manual version selection. References to replaced instances are checked, and unsafe merges become conflicts.
- **Script merging** supports non-overlapping line ranges. This is not a real-time character-by-character collaborative editor. Multiple separate edits may still require manual resolution.
- **Binary resources** modified simultaneously require manual version selection.
- **Project file deletions** are intentionally not synchronized automatically. A file missing from the host's file list will not cause local work to be deleted. **Scene node deletions** are supported with conflict detection.
- **Native addon data** saved by Godot is supported without requiring a separate protocol for each addon. Data not saved by the addon itself, external services, and side effects of `@tool` scripts cannot be automatically recovered from a scene.
- **MapTogether's own source code**, hidden service directories, symbolic links, and temporary files are not synchronized. Update MapTogether to the same version on every computer.
- **Direct TCP connections** are intended for trusted participants. Transport encryption is not yet implemented.

## Testing

Run the following command from the repository root:

```bash
python3 tools/test_map_together.py
```

**Requirements:** Python 3 and Godot 4.7.2, available as `godot` or specified through the `GODOT_BIN` environment variable.

Tests run in a separate temporary project.

### Automated Tests

Without external addons, the test suite performs **68 checks**:

- **50 storage and protocol checks**
- **18 native editor checks**

These cover host restarts, lost confirmations, persistent change queues, scene and script merging, transfer of a 260 KB file from an unknown addon, scenes containing 256 objects, autosaving, selection preservation, chat, the Output panel, and test character movement.

### Third-Party Addon Testing

During development, three additional checks were performed using a real PoiBuilder scene from the CoopGD project, along with editor tests with PoiBuilder enabled.

This brought the total to **71 successful checks**.

The third-party addon and original CoopGD maps are not included in this repository.

### Network Testing Limitations

The network protocol is tested by exchanging real encoded frames between two in-memory sessions.

Socket creation is restricted in the development environment.

A complete collaborative session using two graphical Godot editors on separate computers has **not yet been tested**.
