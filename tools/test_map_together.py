#!/usr/bin/env python3
"""Validate MapTogether in an isolated Godot project; never touch an active session."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="map-together-tests-") as temp:
    project = Path(temp)
    shutil.copytree(source / "addons/coop_collab", project / "addons/coop_collab")
    shutil.copytree(source / "scenes", project / "scenes")
    if (source / "addons/poibuilder").is_dir():
        shutil.copytree(source / "addons/poibuilder", project / "addons/poibuilder")
        shutil.copy2(source / "player.tscn", project / "poi_fixture.tscn")
    (project / "tests").mkdir()
    for name in ["map_together_regression.gd", "map_together_fixture.gd"]:
        shutil.copy2(source / "tests" / name, project / "tests" / name)
    (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="MapTogetherTests"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    env = dict(os.environ, XDG_CONFIG_HOME=str(project / "config"), XDG_DATA_HOME=str(project / "data"))
    command = [os.environ.get("GODOT_BIN", "godot"), "--headless", "--path", str(project)]
    smoke = project / "addons/editor_smoke"
    smoke.mkdir()
    shutil.copy2(source / "tests/map_together_editor_smoke.gd", smoke / "plugin.gd")
    (smoke / "plugin.cfg").write_text('[plugin]\nname="Smoke"\ndescription="Tests"\nauthor="Tests"\nversion="1"\nscript="plugin.gd"\n')
    (project / "tests/live_script.gd").write_text('extends Node\n')
    steps = [["--editor", "--import", "--quit"], ["--script", "res://tests/map_together_regression.gd"], ["--editor", "--quit-after", "400"]]
    for index, args in enumerate(steps):
        if index == 2:
            plugins = ['res://addons/coop_collab/plugin.cfg', 'res://addons/editor_smoke/plugin.cfg']
            if (project / 'addons/poibuilder/plugin.cfg').exists():
                plugins.append('res://addons/poibuilder/plugin.cfg')
            with (project / "project.godot").open("a") as config:
                config.write('\n[editor_plugins]\nenabled=PackedStringArray(' + ', '.join('"' + plugin + '"' for plugin in plugins) + ')\n')
        result = subprocess.run(command + args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        print(result.stdout, end="")
        if result.returncode or "SCRIPT ERROR" in result.stdout or "FAIL:" in result.stdout or "Parse Error" in result.stdout or (index == 2 and result.stdout.count("EDITOR PASS:") != 18):
            raise SystemExit(result.returncode or 1)
