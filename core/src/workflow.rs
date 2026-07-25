use std::collections::{BTreeMap, BTreeSet};
use std::io;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::workspace_recipe::{
    normalize_workspace_plan_from_value, NormalizedWorkspacePlan, SlotCapabilities,
};

const WORKFLOW_SCHEMA_VERSION: u64 = 1;
const MAX_WORKFLOW_NODES: usize = 128;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedWorkflow {
    pub schema_version: u64,
    pub workflow_id: String,
    pub run_id: String,
    pub topological_order: Vec<String>,
    pub nodes: Vec<NormalizedWorkflowNode>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedWorkflowNode {
    pub node_id: String,
    pub pane_ref: String,
    pub depends_on: Vec<String>,
    pub action: String,
    pub idempotency_key: String,
}

pub fn normalize_workspace_plan_payload(
    root: &serde_yaml::Value,
    recipe_id: &str,
    workflow_id: Option<&str>,
    run_id: Option<&str>,
    slots: &[SlotCapabilities],
) -> io::Result<Value> {
    if run_id.is_some() && workflow_id.is_none() {
        return Err(invalid_input(
            "workspace-plan --run-id requires --workflow-id.",
        ));
    }
    let plan = normalize_workspace_plan_from_value(root, recipe_id, workflow_id, slots)?;
    let mut payload = serde_json::to_value(&plan)
        .map_err(|error| invalid_data(format!("failed to serialize workspace plan: {error}")))?;
    if let Some(run_id) = run_id {
        let workflow = normalize_workflow_from_value(
            root,
            workflow_id.expect("validated workflow-id"),
            run_id,
            &plan,
        )?;
        payload["workflow"] = serde_json::to_value(workflow).map_err(|error| {
            invalid_data(format!("failed to serialize normalized workflow: {error}"))
        })?;
    }
    Ok(payload)
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct WorkflowDefinition {
    schema_version: u64,
    nodes: Vec<WorkflowNodeDefinition>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct WorkflowNodeDefinition {
    node_id: String,
    pane_ref: String,
    #[serde(default)]
    depends_on: Vec<String>,
    action: String,
}

pub fn normalize_workflow_from_value(
    root: &serde_yaml::Value,
    workflow_id: &str,
    run_id: &str,
    workspace_plan: &NormalizedWorkspacePlan,
) -> io::Result<NormalizedWorkflow> {
    require_stable_id("workflow-id", workflow_id)?;
    require_stable_id("run-id", run_id)?;

    let root = root
        .as_mapping()
        .ok_or_else(|| invalid_data(".winsmux.yaml must be a mapping."))?;
    let workflows = root
        .get(serde_yaml::Value::String("workflows".to_string()))
        .ok_or_else(|| invalid_input("workflows is not configured."))?
        .as_mapping()
        .ok_or_else(|| invalid_data("workflows must be a mapping."))?;
    let value = workflows
        .get(serde_yaml::Value::String(workflow_id.to_string()))
        .ok_or_else(|| invalid_input(format!("workflow '{workflow_id}' was not found.")))?;
    let definition: WorkflowDefinition = serde_yaml::from_value(value.clone())
        .map_err(|_| invalid_data("invalid workflow schema."))?;
    if definition.schema_version != WORKFLOW_SCHEMA_VERSION {
        return Err(invalid_data(format!(
            "unsupported workflow schema-version '{}'; supported version is {WORKFLOW_SCHEMA_VERSION}.",
            definition.schema_version
        )));
    }
    if definition.nodes.is_empty() || definition.nodes.len() > MAX_WORKFLOW_NODES {
        return Err(invalid_data(format!(
            "workflow must contain between 1 and {MAX_WORKFLOW_NODES} nodes."
        )));
    }

    let mut definitions = BTreeMap::new();
    for node in definition.nodes {
        require_stable_id("node-id", &node.node_id)?;
        require_stable_id("pane-ref", &node.pane_ref)?;
        if node.action != "operator-dispatch" {
            return Err(invalid_data("unknown workflow action."));
        }
        if !workspace_plan
            .resolved_bindings
            .contains_key(&node.pane_ref)
        {
            return Err(invalid_data(format!(
                "workflow node '{}' references unknown pane '{}'.",
                node.node_id, node.pane_ref
            )));
        }
        let mut unique_dependencies = BTreeSet::new();
        for dependency in &node.depends_on {
            require_stable_id("depends-on", dependency)?;
            if dependency == &node.node_id || !unique_dependencies.insert(dependency.clone()) {
                return Err(invalid_data(format!(
                    "workflow node '{}' has an invalid dependency set.",
                    node.node_id
                )));
            }
        }
        if definitions.insert(node.node_id.clone(), node).is_some() {
            return Err(invalid_data("duplicate workflow node-id."));
        }
    }

    for node in definitions.values() {
        for dependency in &node.depends_on {
            if !definitions.contains_key(dependency) {
                return Err(invalid_data(format!(
                    "workflow node '{}' depends on unknown node '{}'.",
                    node.node_id, dependency
                )));
            }
        }
    }

    let mut indegree: BTreeMap<String, usize> = definitions
        .iter()
        .map(|(node_id, node)| (node_id.clone(), node.depends_on.len()))
        .collect();
    let mut dependents: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for node in definitions.values() {
        for dependency in &node.depends_on {
            dependents
                .entry(dependency.clone())
                .or_default()
                .push(node.node_id.clone());
        }
    }
    for children in dependents.values_mut() {
        children.sort();
    }

    let mut ready: BTreeSet<String> = indegree
        .iter()
        .filter_map(|(node_id, degree)| (*degree == 0).then_some(node_id.clone()))
        .collect();
    let mut topological_order = Vec::with_capacity(definitions.len());
    while let Some(node_id) = ready.iter().next().cloned() {
        ready.remove(&node_id);
        topological_order.push(node_id.clone());
        if let Some(children) = dependents.get(&node_id) {
            for child in children {
                let degree = indegree
                    .get_mut(child)
                    .ok_or_else(|| invalid_data("workflow graph identity changed."))?;
                *degree = degree
                    .checked_sub(1)
                    .ok_or_else(|| invalid_data("workflow graph indegree underflow."))?;
                if *degree == 0 {
                    ready.insert(child.clone());
                }
            }
        }
    }
    if topological_order.len() != definitions.len() {
        return Err(invalid_data("workflow_cycle"));
    }

    let nodes = topological_order
        .iter()
        .map(|node_id| {
            let node = &definitions[node_id];
            let mut depends_on = node.depends_on.clone();
            depends_on.sort();
            NormalizedWorkflowNode {
                node_id: node.node_id.clone(),
                pane_ref: workspace_plan.resolved_bindings[&node.pane_ref].clone(),
                depends_on,
                action: node.action.clone(),
                idempotency_key: format!("{run_id}:{node_id}"),
            }
        })
        .collect();

    Ok(NormalizedWorkflow {
        schema_version: WORKFLOW_SCHEMA_VERSION,
        workflow_id: workflow_id.to_string(),
        run_id: run_id.to_string(),
        topological_order,
        nodes,
    })
}

fn require_stable_id(label: &str, value: &str) -> io::Result<()> {
    if value.len() > 128 || !is_stable_id(value) {
        return Err(invalid_data(format!(
            "{label} must be a non-empty stable ASCII identifier."
        )));
    }
    Ok(())
}

fn is_stable_id(value: &str) -> bool {
    let mut parts = value.split('-');
    let Some(first) = parts.next() else {
        return false;
    };
    if first.is_empty()
        || !first
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_lowercase())
        || !first
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    {
        return false;
    }
    parts.all(|part| {
        !part.is_empty()
            && part
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    })
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}
