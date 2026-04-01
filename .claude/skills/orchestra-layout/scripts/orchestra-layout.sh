#!/usr/bin/env bash
# orchestra-layout.sh — Deterministic psmux grid layout for Orchestra
#
# Usage: bash orchestra-layout.sh [PRESET]
#   PRESET format: NbNrNv (e.g., 4b1r1v = 4 builders, 1 researcher, 1 reviewer)
#   Default: 4b1r1v
#
# Workaround: Uses split-window -p (percentage) to avoid psmux bugs:
#   - resize-pane -x/-y silently fails (psmux/psmux#171)
#   - split-window -l is aliased as percentage
#   - split-window -t is silently ignored
set -euo pipefail

PRESET="${1:-4b1r1v}"

# --- Parse preset (NbNrNv) ---
parse_preset() {
    local p="$1"
    BUILDERS=0; RESEARCHERS=0; REVIEWERS=0
    while [[ -n "$p" ]]; do
        if [[ "$p" =~ ^([0-9]+)([brv]) ]]; then
            local num="${BASH_REMATCH[1]}"
            local role="${BASH_REMATCH[2]}"
            case "$role" in
                b) BUILDERS=$num ;;
                r) RESEARCHERS=$num ;;
                v) REVIEWERS=$num ;;
            esac
            p="${p:${#BASH_REMATCH[0]}}"
        else
            echo "Error: Invalid preset: $1 (expected format: NbNrNv, e.g. 4b1r1v)" >&2
            exit 1
        fi
    done
    TOTAL=$((BUILDERS + RESEARCHERS + REVIEWERS))
    if (( TOTAL < 1 || TOTAL > 12 )); then
        echo "Error: Total panes must be 1-12 (got $TOTAL)" >&2
        exit 1
    fi
}

# --- Grid dimensions for N panes ---
calc_grid() {
    local n=$1
    case $n in
        1)     ROWS=1; COLS=1 ;;
        2)     ROWS=1; COLS=2 ;;
        3)     ROWS=1; COLS=3 ;;
        4)     ROWS=2; COLS=2 ;;
        5|6)   ROWS=2; COLS=3 ;;
        7|8)   ROWS=2; COLS=4 ;;
        9)     ROWS=3; COLS=3 ;;
        10|12) ROWS=3; COLS=4 ;;
        11)    ROWS=3; COLS=4 ;;
    esac
}

# --- Helpers ---
get_pane_ids() {
    psmux list-panes 2>/dev/null | grep -o '%[0-9]*'
}

# Split active pane into N equal parts.
# Uses chained percentage splits: pct[i] = 100*(N-1-i)/(N-i)
# Each split creates a new pane (right/bottom) which becomes active.
split_equal() {
    local n=$1 dir=$2
    for (( i=0; i<n-1; i++ )); do
        local remaining=$((n - i))
        local pct=$(( 100 * (remaining - 1) / remaining ))
        psmux split-window "$dir" -p "$pct"
    done
}

# --- Main ---
parse_preset "$PRESET"
calc_grid "$TOTAL"

echo "=== Orchestra Layout: ${BUILDERS}b${RESEARCHERS}r${REVIEWERS}v → ${ROWS}x${COLS} grid ==="

# Ensure psmux is running, then create a clean window
if ! psmux list-sessions &>/dev/null; then
    psmux new-session -d
    sleep 0.5
fi

# Kill all existing panes in current window, start fresh in a new window
psmux new-window

# Step 1: Create rows (vertical splits on the initial pane)
if (( ROWS > 1 )); then
    split_equal "$ROWS" -v
fi

# Capture row pane IDs (ordered top-to-bottom by list-panes)
mapfile -t ROW_IDS < <(get_pane_ids)

# Step 2: For each row, select it and split into columns
if (( COLS > 1 )); then
    for (( r=0; r<ROWS; r++ )); do
        psmux select-pane -t "${ROW_IDS[$r]}"
        split_equal "$COLS" -h
    done
fi

sleep 0.3

# Step 3: Collect all pane IDs in screen order
mapfile -t ALL_IDS < <(get_pane_ids)

# Step 4: Build role labels
LABELS=()
for (( i=1; i<=BUILDERS; i++ ));    do LABELS+=("Builder-$i");    done
for (( i=1; i<=RESEARCHERS; i++ )); do LABELS+=("Researcher-$i"); done
for (( i=1; i<=REVIEWERS; i++ ));   do LABELS+=("Reviewer-$i");   done

# Step 5: Label panes via select-pane -T
for (( i=0; i<${#ALL_IDS[@]} && i<TOTAL; i++ )); do
    psmux select-pane -t "${ALL_IDS[$i]}" -T "${LABELS[$i]}"
done

# Select first pane
psmux select-pane -t "${ALL_IDS[0]}"

# Report
echo "Panes:"
for (( i=0; i<${#ALL_IDS[@]} && i<TOTAL; i++ )); do
    echo "  ${ALL_IDS[$i]} → ${LABELS[$i]}"
done
echo "Done."
