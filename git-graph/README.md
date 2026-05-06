# git-graph

`git-graph` renders a source-control-style graph as SVG. It reads commit IDs and parent IDs, assigns lanes from the parent relationships, builds persistent lane spans, and draws short lane-to-lane bridges with cubic Bezier curves. It does not parse or replace `git log --graph` glyphs.

The renderer uses a pillar model: each active branch lane becomes one vertical span from the row where it appears to the row where it disappears, and commit circles are painted above those spans. Merges add small markers on the absorbed branch lane, while branch movement is drawn as a compact S-curve with vertical tangents so the curve connects cleanly to the lane pillars.

## Usage

Create the output directory first when writing into a new folder:

```powershell
New-Item -ItemType Directory -Force -Path output | Out-Null
cargo run -p git-graph -- --repo . --max 30 --out output/git-graph.svg
```

You can also pipe `git log --topo-order --format="%H %P"` output through stdin:

```powershell
New-Item -ItemType Directory -Force -Path output | Out-Null
git log --topo-order --format="%H %P" --max-count=30 | cargo run -p git-graph -- --from-stdin --out output/git-graph.svg
```

After installing or copying the binary, the same options are available directly:

```powershell
git-graph --max 30 --out graph.svg
git log --topo-order --format="%H %P" --max-count=30 | git-graph --from-stdin --out graph.svg
```
