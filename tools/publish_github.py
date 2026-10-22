#!/usr/bin/env python3
"""Publish the prepared repository and its first prerelease with GitHub CLI."""
from pathlib import Path
import json
import subprocess
from package_addon import package

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "Holego/MapTogether"
DESCRIPTION = "Совместное редактирование карт и скриптов в Godot 4: сохранение у хоста, история версий, обработка конфликтов и чат."
TAG = "v0.1.0"


def command(*arguments, check=True):
    result = subprocess.run(arguments, cwd=ROOT, text=True, capture_output=True)
    if check and result.returncode:
        raise SystemExit(result.stderr.strip() or result.stdout.strip() or f"Command failed: {arguments[0]}")
    return result


def main():
    # No remote writes happen until authentication and the local tree are checked.
    login = command("gh", "api", "user", "--jq", ".login").stdout.strip()
    if login.lower() != "holego":
        raise SystemExit("Switch GitHub CLI to the Holego account before publishing.")
    if command("git", "status", "--porcelain").stdout.strip():
        raise SystemExit("Commit or save the repository changes before publishing.")
    if command("git", "branch", "--show-current").stdout.strip() != "main":
        raise SystemExit("Publish from the prepared main branch.")
    origin = command("git", "remote", "get-url", "origin", check=False)
    allowed_origins = [f"https://github.com/{REPOSITORY}.git", f"https://github.com/{REPOSITORY}", f"git@github.com:{REPOSITORY}.git"]
    if origin.returncode == 0 and origin.stdout.strip().lower() not in [url.lower() for url in allowed_origins]:
        raise SystemExit("Origin points to another repository; no changes were published.")
    repository = command("gh", "api", f"repos/{REPOSITORY}", check=False)
    if repository.returncode:
        if "HTTP 404" not in repository.stderr:
            raise SystemExit(repository.stderr.strip())
        command("gh", "repo", "create", REPOSITORY, "--public", "--description", DESCRIPTION, "--disable-wiki")
    elif not json.loads(repository.stdout).get("size", 0) == 0 and origin.returncode != 0:
        raise SystemExit("A non-empty repository already exists. Link and inspect its history before publishing.")
    if origin.returncode:
        command("git", "remote", "add", "origin", f"https://github.com/{REPOSITORY}.git")
    command("git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "push", "--set-upstream", "origin", "main")
    command("gh", "repo", "edit", REPOSITORY, "--description", DESCRIPTION, "--default-branch", "main", "--add-topic", "godot", "--add-topic", "godot-addon", "--add-topic", "collaborative-editing")
    head = command("git", "rev-parse", "HEAD").stdout.strip()
    tag = command("git", "rev-parse", f"{TAG}^{{commit}}", check=False)
    if tag.returncode:
        command("git", "tag", "-a", TAG, "-m", "MapTogether 0.1.0: first test release")
    elif tag.stdout.strip() != head:
        raise SystemExit("The release tag belongs to another commit; it has not been overwritten.")
    command("git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "push", "origin", f"refs/tags/{TAG}")
    artifacts = package()
    release = command("gh", "release", "view", TAG, "--repo", REPOSITORY, "--json", "url,assets", check=False)
    if release.returncode:
        command("gh", "release", "create", TAG, *(str(path) for path in artifacts), "--repo", REPOSITORY, "--verify-tag", "--title", "MapTogether 0.1.0", "--prerelease", "--notes-file", str(ROOT / "RELEASE_NOTES.md"))
    else:
        names = {asset["name"] for asset in json.loads(release.stdout)["assets"]}
        missing = [str(path) for path in artifacts if path.name not in names]
        if missing:
            command("gh", "release", "upload", TAG, *missing, "--repo", REPOSITORY)
    print(command("gh", "repo", "view", REPOSITORY, "--json", "url", "--jq", ".url").stdout.strip())
    print(command("gh", "release", "view", TAG, "--repo", REPOSITORY, "--json", "url", "--jq", ".url").stdout.strip())


if __name__ == "__main__":
    main()
