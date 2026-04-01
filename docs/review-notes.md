# Review Notes

Reviewed files:

1. `README.md`
2. `README.ja.md`
3. `.psmux.conf`
4. `.references/winsmux-implementation-plan.md`

## Findings

1. Medium: `.psmux.conf:30` likely uses the wrong conditional format syntax for tmux/psmux format expansion. The current value is `#{?#{pane_title},#{pane_title},#{b:pane_current_path}}`, but the conditional form is `#{?condition,then,else}`. Using `#{pane_title}` as the condition payload is likely incorrect; this should probably be `#{?pane_title,#{pane_title},#{b:pane_current_path}}`. If left as-is, the fallback-to-path behavior may not render as intended.

2. Medium: `.references/winsmux-implementation-plan.md:66` says `v0.9.5` is the "current version", but the repo still reports `0.9.4` in `install.ps1:13` and `scripts/psmux-bridge.ps1:9`. That makes the roadmap internally inconsistent and can mislead readers about what is already shipped versus still planned.

3. Low: `.psmux.conf:25-27` describe pane labels as if they are already visible now ("Show the pane label on the top border so titles/paths are always visible"), but both `README.md:146` and `README.ja.md:146` present pane-border label support as coming in `v0.9.5`. The comment should be future-facing or explicitly scoped to patched/newer psmux builds so the files do not contradict each other.

4. Low: `README.ja.md:144` keeps the section heading as `Pane Border Labels` while surrounding section headings are localized. The body content is consistent with `README.md`, but the heading itself is not stylistically aligned with the rest of the Japanese document.

## Notes

- `README.md` and `README.ja.md` are otherwise aligned in substance: both describe `pane-border-format`, `pane-border-status`, `#{pane_title}`, and the same config example.
- For item 1, I cross-checked tmux's documented format syntax (`#{?condition,then,else}`) in the tmux manual: https://man7.org/linux/man-pages/man1/tmux.1.html
