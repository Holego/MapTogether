# MapTogether

Collaborative map and script editing for Godot 4, with host-owned saves, recoverable versions, and chat.

**MapTogether** is an addon for collaborative map and script editing in Godot. Participants work in their own copies of the project, while the host saves confirmed changes and maintains version history. Version **0.1.0** is intended for testing.

## Features

- **Collaborative scene editing:** Changes to different objects and properties are merged against a shared saved version.
- **Conflict detection:** Simultaneous edits to the same property or script section preserve both versions for manual resolution.
- **Autosaving:** Automatically saves maps and open scripts, including when working alone or editing new, unnamed scenes.
- **Version history:** Full versions tracked using SHA-256, a host-side log, and a persistent queue of unconfirmed changes. Retrying submissions does not roll back the host.
- **Resource synchronization:** Transfers resources and third-party addon files without restricting file extensions. Files are transferred in chunks with integrity verification.
- **Editor integration:** Compact connection panel, scene participant presence, chat, and quick access to Godot's standard Output panel.
- **Independent networking:** Uses a separate TCP transport without interfering with the project's gameplay `MultiplayerAPI`.

## Installation

1. Download `MapTogether-0.1.0.zip` from Releases, or copy the `addons/coop_collab` folder into your project.
2. Enable **MapTogether** under **Project → Project Settings → Plugins**.
3. Make sure all participants have the same version installed.
4. If migrating from Team Create or CoopSync, disable the previous synchronization addon, save your work, and restart Godot.

The addon has been tested with **Godot 4.7.2**. Compatibility with earlier Godot versions has not been separately verified.

## Getting Started

On the computer containing the main map, open the MapTogether panel and click **Create**.

Once the files are ready, other participants can enter the host's IP address, port **TCP 25568**, and the same room password, then click **Join**.

For collaboration over the internet, use an accessible TCP port or a shared VPN network.

Open the map in both project copies and start editing together. Autosaving is enabled by default.

If the connection is lost, pending changes remain saved on disk. Click **Join** to reconnect.

The **Conflicts** button allows you to choose which version to keep, while preserving both versions in the history.

Confirmed changes are stored on the host. Until confirmation, edits remain in the participant's local queue.

The `.coop_collab` folder should be included in your backups. There is no need to share this folder with new participants.

## Demo

Open this repository as a Godot project.

Run `scenes/map_together_playground.tscn` using **F6**.

The scene includes three colored objects for testing collaborative editing and a playable test character.

**Controls:**

- **WASD / Arrow keys:** Move
- **Space:** Jump
- **Mouse click:** Capture mouse
- **Esc:** Release mouse
- **R:** Return to the platform

To test two editors on the same computer, use two separate copies of the project folder and connect through `127.0.0.1`.

## Limitations in 0.1.0

- This is the first testing release. A complete session with two graphical editors running on separate computers has not yet been verified in the development environment.
- Overlapping edits, simultaneous changes to binary files, and certain nested scene instances require manual conflict resolution.
- Scripts are merged based on non-overlapping line ranges. Real-time character-by-character collaborative editing is not yet supported.
- Project file deletions are not automatically synchronized. Scene node deletions are handled during merging with conflict detection.
- Addon data saved directly by Godot is supported. Data stored in external services and side effects of `@tool` scripts require separate verification.
- Automatic reconnection and TCP encryption are not yet implemented. Only collaborate with trusted participants over trusted networks or a VPN.
- There is no fixed limit on the number of nodes. Saving and merging performance depends on scene size, resources, disk performance, and network conditions.

## Testing and Documentation

```bash
python3 tools/test_map_together.py
```

**Requirements:** Python 3 and Godot 4.7.2.

To use a different Godot executable, set the `GODOT_BIN` environment variable.

Tests run in a separate temporary project to avoid modifying your working map.

The test suite included in this repository contains **68 checks**. During development, real PoiBuilder data from the CoopGD project was also tested, bringing that test run to **71 checks**.

[Full Usage Guide and Version Recovery](docs/usage.md) · [Version 0.1.0 Changelog](CHANGELOG.md)
