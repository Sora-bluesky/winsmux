use std::collections::BTreeSet;

use crate::commit::Commit;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lane {
    pub branch_id: u64,
    pub expecting: String,
}

#[derive(Debug, Clone)]
pub struct Row {
    pub commit: Commit,
    pub commit_lane: usize,
    pub lanes_in: Vec<Lane>,
    pub lanes_out: Vec<Lane>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Segment {
    pub branch_id: u64,
    pub kind: SegmentKind,
    pub col_in: Option<usize>,
    pub col_out: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SegmentKind {
    Straight,
    ShiftRight,
    ShiftLeft,
    Spawn,
    Absorb,
}

pub fn assign_lanes(commits: &[Commit]) -> Vec<Row> {
    let mut active: Vec<Lane> = Vec::new();
    let mut next_branch_id = 0;
    let mut rows = Vec::new();

    for commit in commits {
        let commit_lane = match active.iter().position(|lane| lane.expecting == commit.id) {
            Some(index) => index,
            None => {
                active.push(Lane {
                    branch_id: next_branch_id,
                    expecting: commit.id.clone(),
                });
                next_branch_id += 1;
                active.len() - 1
            }
        };

        assert_unique_expectations(&active);
        let lanes_in = active.clone();

        if let Some(first_parent) = commit.parents.first() {
            if active
                .iter()
                .position(|lane| {
                    lane.expecting == *first_parent
                        && lane.branch_id != active[commit_lane].branch_id
                })
                .is_some()
            {
                active.remove(commit_lane);
            } else {
                active[commit_lane].expecting = first_parent.clone();
            }
        } else {
            active.remove(commit_lane);
        }

        for parent in commit.parents.iter().skip(1) {
            if active.iter().all(|lane| lane.expecting != *parent) {
                active.push(Lane {
                    branch_id: next_branch_id,
                    expecting: parent.clone(),
                });
                next_branch_id += 1;
            }
        }

        assert_unique_expectations(&active);
        rows.push(Row {
            commit: commit.clone(),
            commit_lane,
            lanes_in,
            lanes_out: active.clone(),
        });
    }

    rows
}

pub fn build_segments(
    out: &[Lane],
    next_in: &[Lane],
    _next_commit: &Commit,
    _next_commit_lane: usize,
) -> Vec<Segment> {
    let mut ids = BTreeSet::new();
    for lane in out.iter().chain(next_in.iter()) {
        ids.insert(lane.branch_id);
    }

    ids.into_iter()
        .map(|branch_id| {
            let col_in = out.iter().position(|lane| lane.branch_id == branch_id);
            let col_out = next_in.iter().position(|lane| lane.branch_id == branch_id);
            let kind = match (col_in, col_out) {
                (Some(from), Some(to)) if from == to => SegmentKind::Straight,
                (Some(from), Some(to)) if from < to => SegmentKind::ShiftRight,
                (Some(_), Some(_)) => SegmentKind::ShiftLeft,
                (None, Some(_)) => SegmentKind::Spawn,
                (Some(_), None) => SegmentKind::Absorb,
                (None, None) => unreachable!("branch id must be present in either side"),
            };
            Segment {
                branch_id,
                kind,
                col_in,
                col_out,
            }
        })
        .collect()
}

pub fn assert_unique_expectations(lanes: &[Lane]) {
    let mut seen = BTreeSet::new();
    for lane in lanes {
        assert!(
            seen.insert(lane.expecting.as_str()),
            "duplicate expected commit in active lanes: {}",
            lane.expecting
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn commit(id: &str, parents: &[&str]) -> Commit {
        Commit {
            id: id.to_string(),
            parents: parents.iter().map(|parent| (*parent).to_string()).collect(),
            message: id.to_string(),
        }
    }

    #[test]
    fn linear_history() {
        let rows = assign_lanes(&[commit("A", &["B"]), commit("B", &["C"]), commit("C", &[])]);

        assert_eq!(rows.len(), 3);
        assert!(rows.iter().all(|row| row.commit_lane == 0));
        assert_eq!(rows[0].lanes_in.len(), 1);
        assert_eq!(rows[0].lanes_out.len(), 1);
        assert_eq!(rows[1].lanes_in.len(), 1);
        assert_eq!(rows[2].lanes_out.len(), 0);

        let segments = build_segments(
            &rows[0].lanes_out,
            &rows[1].lanes_in,
            &rows[1].commit,
            rows[1].commit_lane,
        );
        assert_eq!(segments[0].kind, SegmentKind::Straight);
    }

    #[test]
    fn simple_merge() {
        let rows = assign_lanes(&[
            commit("A", &["B", "C"]),
            commit("B", &["D"]),
            commit("C", &["D"]),
            commit("D", &[]),
        ]);

        assert_eq!(rows[0].lanes_out.len(), 2);
        assert_eq!(rows[1].lanes_in.len(), 2);
        assert_eq!(rows[1].lanes_out.len(), 2);
        assert_eq!(rows[2].lanes_out.len(), 1);
        assert_eq!(rows[3].lanes_in.len(), 1);
    }

    #[test]
    fn fast_forward_branch() {
        let rows = assign_lanes(&[
            commit("M", &["B", "F"]),
            commit("B", &["A"]),
            commit("F", &["E"]),
            commit("E", &["A"]),
            commit("A", &[]),
        ]);

        assert_eq!(rows[0].lanes_out.len(), 2);
        assert_eq!(rows[2].commit_lane, 1);
        assert_eq!(rows[3].lanes_out.len(), 1);
        assert_eq!(rows[4].lanes_in.len(), 1);
    }

    #[test]
    fn octopus_merge() {
        let rows = assign_lanes(&[
            commit("O", &["B", "C", "D"]),
            commit("B", &["A"]),
            commit("C", &["A"]),
            commit("D", &["A"]),
            commit("A", &[]),
        ]);

        assert_eq!(rows[0].lanes_out.len(), 3);
        assert_eq!(rows[1].lanes_out.len(), 3);
        assert_eq!(rows[2].lanes_out.len(), 2);
        assert_eq!(rows[3].lanes_out.len(), 1);
        assert_eq!(rows[4].lanes_in.len(), 1);
    }

    #[test]
    #[should_panic(expected = "duplicate expected commit")]
    fn duplicate_expecting_panics() {
        assert_unique_expectations(&[
            Lane {
                branch_id: 0,
                expecting: "A".to_string(),
            },
            Lane {
                branch_id: 1,
                expecting: "A".to_string(),
            },
        ]);
    }
}
