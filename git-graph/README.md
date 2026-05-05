# git-graph

`git-graph` renders a VS Code-style source control graph as SVG. It reads commit IDs and parent IDs, assigns lanes from the parent relationships, and draws lane shifts with cubic Bezier curves. It does not parse or replace `git log --graph` glyphs.

## Usage

```powershell
cargo run -p git-graph -- --repo . --max 30 --out output/git-graph.svg
```

You can also pipe `git log --format="%H %P"` output through stdin:

```powershell
git log --format="%H %P" --max-count=30 | cargo run -p git-graph -- --from-stdin --out output/git-graph.svg
```

After installing or copying the binary, the same options are available directly:

```powershell
git-graph --max 30 --out graph.svg
git log --format="%H %P" --max-count=30 | git-graph --from-stdin --out graph.svg
```
