//! Layout helpers for pane trees. No Win32.

use crate::contract::{Axis, LayoutNode, Node, NonEmpty, Nullable, PaneId, ProviderProfile, Ratio, RunId};

#[derive(Debug, Clone)]
pub struct PaneRecord {
    pub id: PaneId,
    pub current_run: Option<RunId>,
    pub previous_runs: Vec<RunId>,
    pub shell_profile_id: NonEmpty,
    pub provider_profile: Nullable<ProviderProfile>,
}

#[derive(Debug, Default, Clone)]
pub struct ProjectPanes {
    pub root: Option<LayoutNode>,
    pub selected_pane_id: Option<PaneId>,
    pub panes: Vec<PaneRecord>,
}

impl ProjectPanes {
    pub fn pane(&self, id: &PaneId) -> Option<&PaneRecord> {
        self.panes
            .iter()
            .find(|pane| pane.id.as_str() == id.as_str())
    }

    pub fn pane_mut(&mut self, id: &PaneId) -> Option<&mut PaneRecord> {
        self.panes
            .iter_mut()
            .find(|pane| pane.id.as_str() == id.as_str())
    }

    pub fn contains_pane(&self, id: &PaneId) -> bool {
        self.pane(id).is_some()
    }

    pub fn leaf_count(&self) -> usize {
        self.root.as_ref().map(count_leaves).unwrap_or(0)
    }

    pub fn run_ids(&self) -> Vec<RunId> {
        let mut ids = Vec::new();
        for pane in &self.panes {
            if let Some(run) = pane.current_run.clone() {
                ids.push(run);
            }
            ids.extend(pane.previous_runs.iter().cloned());
        }
        ids
    }
}

fn count_leaves(node: &LayoutNode) -> usize {
    match &*node.node {
        Node::Leaf { .. } => 1,
        Node::Split { first, second, .. } => count_leaves(first) + count_leaves(second),
    }
}

pub fn default_axis() -> Axis {
    Axis::Vertical
}

pub fn default_ratio() -> Ratio {
    Ratio::new(0.5).expect("0.5 is a valid split ratio")
}

pub fn split_replace_leaf(
    root: &LayoutNode,
    target: &PaneId,
    new_pane: PaneId,
    axis: Axis,
) -> Option<LayoutNode> {
    split_node(root, target, &new_pane, axis)
}

fn split_node(
    node: &LayoutNode,
    target: &PaneId,
    new_pane: &PaneId,
    axis: Axis,
) -> Option<LayoutNode> {
    match &*node.node {
        Node::Leaf { pane_id } if pane_id.as_str() == target.as_str() => LayoutNode::split(
            axis,
            default_ratio(),
            LayoutNode::leaf(pane_id.clone()),
            LayoutNode::leaf(new_pane.clone()),
        )
        .ok(),
        Node::Leaf { .. } => None,
        Node::Split {
            axis,
            ratio,
            first,
            second,
        } => {
            if let Some(replaced) = split_node(first, target, new_pane, *axis) {
                LayoutNode::split(*axis, *ratio, replaced, clone_layout(second)).ok()
            } else if let Some(replaced) = split_node(second, target, new_pane, *axis) {
                LayoutNode::split(*axis, *ratio, clone_layout(first), replaced).ok()
            } else {
                None
            }
        }
    }
}

pub fn close_leaf(root: &LayoutNode, target: &PaneId) -> Option<Option<LayoutNode>> {
    match &*root.node {
        Node::Leaf { pane_id } if pane_id.as_str() == target.as_str() => Some(None),
        Node::Leaf { .. } => None,
        Node::Split {
            axis,
            ratio,
            first,
            second,
        } => close_split(*axis, *ratio, first, second, target),
    }
}

fn close_split(
    axis: Axis,
    ratio: Ratio,
    first: &LayoutNode,
    second: &LayoutNode,
    target: &PaneId,
) -> Option<Option<LayoutNode>> {
    if let Node::Leaf { pane_id } = &*first.node {
        if pane_id.as_str() == target.as_str() {
            return Some(Some(clone_layout(second)));
        }
    }
    if let Node::Leaf { pane_id } = &*second.node {
        if pane_id.as_str() == target.as_str() {
            return Some(Some(clone_layout(first)));
        }
    }
    if let Some(replaced) = close_leaf(first, target) {
        return Some(Some(
            LayoutNode::split(axis, ratio, replaced?, clone_layout(second)).ok()?,
        ));
    }
    if let Some(replaced) = close_leaf(second, target) {
        return Some(Some(
            LayoutNode::split(axis, ratio, clone_layout(first), replaced?).ok()?,
        ));
    }
    None
}

fn clone_layout(node: &LayoutNode) -> LayoutNode {
    match &*node.node {
        Node::Leaf { pane_id } => LayoutNode::leaf(pane_id.clone()),
        Node::Split {
            axis,
            ratio,
            first,
            second,
        } => LayoutNode::split(*axis, *ratio, clone_layout(first), clone_layout(second))
            .expect("cloned layout keeps valid depth"),
    }
}
