use std::collections::{BTreeMap, BTreeSet};

use crate::lane::Row;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaneSpan {
    pub branch_id: u64,
    pub col: usize,
    pub start_row: usize,
    pub end_row: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MergeMarker {
    pub row: usize,
    pub from_col: usize,
    pub to_col: usize,
    pub color_idx: u64,
}

#[derive(Debug, Clone)]
pub struct GraphLayout {
    pub rows: Vec<Row>,
    pub lane_spans: Vec<LaneSpan>,
    pub merge_markers: Vec<MergeMarker>,
}

pub fn build_layout(rows: Vec<Row>) -> GraphLayout {
    let lane_spans = build_lane_spans(&rows);
    let merge_markers = build_merge_markers(&rows);

    GraphLayout {
        rows,
        lane_spans,
        merge_markers,
    }
}

pub fn build_lane_spans(rows: &[Row]) -> Vec<LaneSpan> {
    let mut active: BTreeMap<u64, (usize, usize)> = BTreeMap::new();
    let mut spans = Vec::new();

    for (row_idx, row) in rows.iter().enumerate() {
        for (col, lane) in row.lanes_in.iter().enumerate() {
            active.entry(lane.branch_id).or_insert((row_idx, col));
        }

        let out_ids: BTreeSet<u64> = row.lanes_out.iter().map(|lane| lane.branch_id).collect();

        for (col, lane) in row.lanes_out.iter().enumerate() {
            match active.get(&lane.branch_id).copied() {
                Some((start_row, active_col)) if active_col != col => {
                    push_lane_span(&mut spans, lane.branch_id, active_col, start_row, row_idx);
                    active.insert(lane.branch_id, (row_idx + 1, col));
                }
                Some(_) => {}
                None => {
                    active.insert(lane.branch_id, (row_idx + 1, col));
                }
            }
        }

        let dead_ids: Vec<u64> = active
            .keys()
            .copied()
            .filter(|branch_id| !out_ids.contains(branch_id))
            .collect();
        for branch_id in dead_ids {
            if let Some((start_row, col)) = active.remove(&branch_id) {
                push_lane_span(&mut spans, branch_id, col, start_row, row_idx);
            }
        }
    }

    let end_row = rows.len();
    for (branch_id, (start_row, col)) in active {
        push_lane_span(&mut spans, branch_id, col, start_row, end_row);
    }

    spans.sort_by_key(|span| (span.start_row, span.col, span.branch_id, span.end_row));
    spans
}

fn push_lane_span(
    spans: &mut Vec<LaneSpan>,
    branch_id: u64,
    col: usize,
    start_row: usize,
    end_row: usize,
) {
    if start_row == end_row {
        return;
    }

    spans.push(LaneSpan {
        branch_id,
        col,
        start_row,
        end_row,
    });
}

pub fn build_merge_markers(rows: &[Row]) -> Vec<MergeMarker> {
    let mut markers = Vec::new();

    for (row_idx, row) in rows.iter().enumerate() {
        if row.commit.parents.len() < 2 {
            continue;
        }

        let to_col = row.commit_lane;
        for parent in row.commit.parents.iter().skip(1) {
            let Some((from_col, lane)) = row
                .lanes_out
                .iter()
                .enumerate()
                .find(|(_, lane)| lane.expecting == *parent)
            else {
                continue;
            };

            if from_col != to_col {
                markers.push(MergeMarker {
                    row: row_idx,
                    from_col,
                    to_col,
                    color_idx: lane.branch_id,
                });
            }
        }
    }

    markers
}

#[cfg(test)]
mod tests {
    use crate::commit::Commit;
    use crate::lane::assign_lanes;

    use super::*;

    fn commit(id: &str, parents: &[&str]) -> Commit {
        Commit {
            id: id.to_string(),
            parents: parents.iter().map(|parent| (*parent).to_string()).collect(),
            message: id.to_string(),
        }
    }

    #[test]
    fn lane_spans_persist_through_inactive_rows() {
        let rows = assign_lanes(&[
            commit("M", &["B", "F"]),
            commit("B", &["A"]),
            commit("X", &["Y"]),
            commit("F", &["E"]),
            commit("E", &["A"]),
            commit("A", &[]),
        ]);
        let branch_id = rows[0].lanes_out[1].branch_id;
        let spans = build_lane_spans(&rows);
        let feature_span = spans
            .iter()
            .find(|span| span.branch_id == branch_id && span.col == 1)
            .expect("feature lane should have a persistent span");

        assert_eq!(feature_span.start_row, 1);
        assert_eq!(feature_span.end_row, 4);
    }

    #[test]
    fn merge_markers_at_absorbed_branch() {
        let rows = assign_lanes(&[
            commit("A", &["B", "C"]),
            commit("B", &["D"]),
            commit("C", &["D"]),
            commit("D", &[]),
        ]);
        let markers = build_merge_markers(&rows);

        assert_eq!(
            markers,
            vec![MergeMarker {
                row: 0,
                from_col: 1,
                to_col: 0,
                color_idx: rows[0].lanes_out[1].branch_id,
            }]
        );
    }

    #[test]
    fn octopus_merge_markers_use_each_absorbed_branch() {
        let rows = assign_lanes(&[
            commit("O", &["B", "C", "D"]),
            commit("B", &["A"]),
            commit("C", &["A"]),
            commit("D", &["A"]),
            commit("A", &[]),
        ]);
        let markers = build_merge_markers(&rows);

        assert_eq!(markers.len(), 2);
        assert_eq!(markers[0].from_col, 1);
        assert_eq!(markers[1].from_col, 2);
        assert_ne!(markers[0].color_idx, markers[1].color_idx);
    }

    #[test]
    fn build_layout_keeps_rows_and_derived_shapes() {
        let rows = assign_lanes(&[
            commit("A", &["B", "C"]),
            commit("B", &["D"]),
            commit("C", &["D"]),
            commit("D", &[]),
        ]);
        let layout = build_layout(rows);

        assert_eq!(layout.rows.len(), 4);
        assert!(!layout.lane_spans.is_empty());
        assert_eq!(layout.merge_markers.len(), 1);
    }
}
