"""Fill the draft release asset ids into a workflow's TASK879_ASSETS manifest.

Usage:
  python -I fill-draft-asset-ids.py --workflow <path.yml> --release-id <id>
      [--release-json <file>] [--commit]

The manifest rows carry DRAFT_ASSET_ID until the unpublished draft release exists.
The release is read with `gh api repos/Sora-bluesky/winsmux/releases/<id>` (GET only)
unless --release-json supplies the same document. Every row must match one asset of
the draft by name, byte size and GitHub sha256 digest, and the release must be an
unpublished draft whose tag and target are the ones the workflow comment names.
--commit stages only the workflow file and commits it in the file's own worktree.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

REPO = "Sora-bluesky/winsmux"
PLACEHOLDER = "DRAFT_ASSET_ID"
ROW = re.compile(
    r"^(?P<indent> +)(?P<id>[0-9]+|"
    + PLACEHOLDER
    + r") (?P<bytes>[0-9]+) (?P<sha>[0-9a-f]{64}) (?P<name>[A-Za-z0-9._-]+)$"
)
DRAFT_LINE = re.compile(
    r"^ *# Unpublished draft release (?P<id>[0-9]+|"
    + PLACEHOLDER.replace("ASSET", "RELEASE")
    + r") \((?P<tag>[A-Za-z0-9._-]+), target (?P<target>[0-9a-f]{40})\)"
)


def fail(message):
    sys.exit("FAIL: " + message)


def load_release(release_id, release_json):
    if release_json:
        return json.loads(pathlib.Path(release_json).read_bytes())
    result = subprocess.run(
        ["gh", "api", f"repos/{REPO}/releases/{release_id}"], capture_output=True
    )
    if result.returncode != 0:
        fail("gh api GET failed: " + result.stderr.decode("utf-8", "replace").strip())
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--release-id", required=True, type=int)
    parser.add_argument("--release-json")
    parser.add_argument("--commit", action="store_true")
    args = parser.parse_args()

    workflow = pathlib.Path(args.workflow).resolve()
    raw = workflow.read_bytes()
    if b"\r" in raw or raw.startswith(b"\xef\xbb\xbf"):
        fail("workflow must be LF without BOM")
    lines = raw.decode("utf-8").split("\n")

    draft = [
        (i, DRAFT_LINE.match(line))
        for i, line in enumerate(lines)
        if DRAFT_LINE.match(line)
    ]
    if len(draft) != 1:
        fail('expected exactly one "# Unpublished draft release" comment line')
    draft_index, draft_match = draft[0]
    tag, target = draft_match["tag"], draft_match["target"]

    rows = [(i, ROW.match(line)) for i, line in enumerate(lines) if ROW.match(line)]
    if len(rows) != 5 or any(m["id"] != PLACEHOLDER for _, m in rows):
        fail("expected five manifest rows that all still carry " + PLACEHOLDER)

    release = load_release(args.release_id, args.release_json)
    if release.get("id") != args.release_id or release.get("draft") is not True:
        fail("release is not the named unpublished draft")
    if release.get("tag_name") != tag or release.get("target_commitish") != target:
        fail(
            f"release tag/target {release.get('tag_name')}/{release.get('target_commitish')} differ from {tag}/{target}"
        )
    assets = release.get("assets") or []
    if len(assets) != 5 or len({a.get("name") for a in assets}) != 5:
        fail("draft must hold exactly five distinct assets")
    by_name = {a["name"]: a for a in assets}

    report = []
    for index, match in rows:
        asset = by_name.get(match["name"])
        if asset is None:
            fail("draft has no asset named " + match["name"])
        if (
            asset.get("state") != "uploaded"
            or asset.get("size") != int(match["bytes"])
            or asset.get("digest") != "sha256:" + match["sha"]
        ):
            fail(
                f"asset identity differs for {match['name']}: size {asset.get('size')} digest {asset.get('digest')}"
            )
        if not isinstance(asset.get("id"), int) or asset["id"] <= 0:
            fail("asset id is malformed for " + match["name"])
        lines[index] = (
            f"{match['indent']}{asset['id']} {match['bytes']} {match['sha']} {match['name']}"
        )
        report.append({"name": match["name"], "id": asset["id"]})
    lines[draft_index] = lines[draft_index].replace(
        draft_match["id"], str(args.release_id), 1
    )

    text = "\n".join(lines).encode("utf-8")
    workflow.write_bytes(text)
    if any(
        PLACEHOLDER in line or "DRAFT_RELEASE_ID" in line
        for line in text.decode("utf-8").split("\n")
    ):
        fail("a placeholder remained after filling")
    print(
        json.dumps(
            {
                "workflow": str(workflow),
                "release_id": args.release_id,
                "tag": tag,
                "target": target,
                "assets": report,
            },
            indent=1,
        )
    )

    if args.commit:
        root = (
            subprocess.run(
                ["git", "-C", str(workflow.parent), "rev-parse", "--show-toplevel"],
                capture_output=True,
                check=True,
            )
            .stdout.decode()
            .strip()
        )
        relative = workflow.relative_to(pathlib.Path(root).resolve()).as_posix()
        subprocess.run(["git", "-C", root, "add", "--", relative], check=True)
        message = (
            f"ci(evidence): pin draft release {args.release_id} asset ids\n\n"
            f"Filled from a GET of the unpublished draft {tag} (target {target}).\n"
            "Each id is bound to the recorded name, size and sha256 digest.\n\n"
            "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n"
        )
        subprocess.run(
            ["git", "-C", root, "commit", "-m", message, "--", relative], check=True
        )


if __name__ == "__main__":
    main()
