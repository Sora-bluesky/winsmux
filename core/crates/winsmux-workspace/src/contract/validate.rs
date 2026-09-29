use super::*;
type Result = std::result::Result<(), ContractError>;
fn invariant(ok: bool) -> Result {
    if ok {
        Ok(())
    } else {
        Err(ContractError::InvariantViolation)
    }
}
fn correlated(ok: bool) -> Result {
    if ok {
        Ok(())
    } else {
        Err(ContractError::ResponseCorrelation)
    }
}
pub(crate) fn unique<T: Ord>(values: &[T]) -> Result {
    invariant(
        !values
            .iter()
            .enumerate()
            .any(|(index, value)| values[index + 1..].contains(value)),
    )
}
fn same_set<T: Ord>(a: &[T], b: &[T]) -> bool {
    a.len() == b.len() && a.iter().all(|value| b.contains(value))
}

fn unique_by<T, K: PartialEq>(values: &[T], key: impl Fn(&T) -> &K) -> bool {
    !values.iter().enumerate().any(|(index, value)| {
        values[index + 1..]
            .iter()
            .any(|other| key(value) == key(other))
    })
}

impl Request {
    pub(crate) fn validate(&self) -> Result {
        invariant(
            (self.action.operation().class() == OperationClass::T)
                == self.expected_topology_revision.0.is_some(),
        )?;
        invariant(
            self.instance_id.0.is_some()
                || matches!(
                    self.action,
                    Action::CapabilitiesGet(_) | Action::ConnectionRequest(_)
                ),
        )?;
        match &self.action {
            Action::ConnectionRequest(p) => {
                unique(&p.project_ids)?;
                unique(&p.scopes)
            }
            Action::ConnectionDecide(p) => {
                unique(&p.project_ids)?;
                unique(&p.scopes)?;
                invariant(
                    p.decision != Decision::Deny
                        || (p.project_ids.is_empty() && p.scopes.is_empty()),
                )
            }
            Action::ArtifactChoose(p) => invariant(
                p.left_artifact_id != p.right_artifact_id
                    && (p.kept_artifact_id == p.left_artifact_id
                        || p.kept_artifact_id == p.right_artifact_id),
            ),
            _ => Ok(()),
        }
    }
}
/// Closed observation relation shared by all containing wire types and schema generation.
pub(crate) fn observation_allowed(p: Process, w: Work, e: Evidence, c: Option<i32>) -> bool {
    match e {
        Evidence::Unavailable => w == Work::Unknown && c.is_none(),
        Evidence::ProviderEvent => match p {
            Process::Running => {
                c.is_none()
                    && matches!(
                        w,
                        Work::Unknown
                            | Work::Running
                            | Work::AwaitingInput
                            | Work::Succeeded
                            | Work::Failed
                    )
            }
            Process::Exited => {
                if c.is_none() || c == Some(0) {
                    matches!(
                        w,
                        Work::Unknown | Work::Succeeded | Work::Failed | Work::Interrupted
                    )
                } else {
                    matches!(w, Work::Failed | Work::Interrupted)
                }
            }
            _ => false,
        },
        Evidence::ProcessExit => {
            p == Process::Exited
                && match w {
                    Work::Unknown => c.is_none() || c == Some(0),
                    Work::Succeeded => c == Some(0),
                    Work::Failed => c.is_some_and(|n| n != 0),
                    Work::Interrupted => true,
                    _ => false,
                }
        }
    }
}
impl RunObservation {
    pub(crate) fn validate(&self) -> Result {
        invariant(observation_allowed(
            self.process,
            self.work,
            self.evidence,
            self.exit_code.0.map(ExitCode::get),
        ))
    }
}
impl PaneSummary {
    fn validate(&self) -> Result {
        match (&self.current_run_id.0, &self.observation.0) {
            (None, None) => Ok(()),
            (Some(id), Some(o)) => {
                o.validate()?;
                invariant(id == &o.run_id && self.pane_id == o.pane_id)
            }
            _ => invariant(false),
        }
    }
}
impl OperationStatus {
    pub(crate) fn validate(&self) -> Result {
        invariant(match self.phase {
            OperationPhase::Completed => match self.outcome.0 {
                Some(Outcome::Succeeded) => self.error_code.0.is_none(),
                Some(Outcome::Failed) => self.error_code.0.is_some(),
                None => false,
            },
            _ => self.outcome.0.is_none() && self.error_code.0.is_none(),
        })
    }
}
impl ArtifactRef {
    fn validate(&self) -> Result {
        invariant(self.run_id.0.is_none() == self.association.0.is_none())
    }
}
impl ArtifactChoiceData {
    fn validate(&self) -> Result {
        invariant(
            self.left_artifact_id < self.right_artifact_id
                && (self.kept_artifact_id == self.left_artifact_id
                    || self.kept_artifact_id == self.right_artifact_id),
        )
    }
}
impl ConnectionInfo {
    fn validate(&self) -> Result {
        unique(&self.requested_project_ids)?;
        unique(&self.requested_scopes)?;
        unique(&self.granted_project_ids)?;
        unique(&self.granted_scopes)?;
        invariant(
            self.granted_project_ids
                .iter()
                .all(|i| self.requested_project_ids.contains(i))
                && self
                    .granted_scopes
                    .iter()
                    .all(|s| self.requested_scopes.contains(s)),
        )?;
        let no_requests = self.requested_project_ids.is_empty() && self.requested_scopes.is_empty();
        let no_grants = self.granted_project_ids.is_empty() && self.granted_scopes.is_empty();
        invariant(match self.state {
            LiveConnectionState::Authenticating => {
                self.executable_name.0.is_none() && no_requests && no_grants
            }
            LiveConnectionState::Unpaired => {
                self.executable_name.0.is_some() && no_requests && no_grants
            }
            LiveConnectionState::Pending => self.executable_name.0.is_some() && no_grants,
            LiveConnectionState::Granted => self.executable_name.0.is_some(),
            LiveConnectionState::Closing | LiveConnectionState::Finished => no_grants,
        })
    }
}
impl WireError {
    fn validate(&self) -> Result {
        invariant(
            self.retryable == self.code.retryable()
                && self.message == self.code.message()
                && (self.target_id.0.is_none() || self.code.allows_target()),
        )
    }
}
impl MetadataEvent {
    fn validate(&self) -> Result {
        match &self.data {
            EventData::RunStateChanged { run } => run.validate(),
            EventData::OperationStateChanged { operation } => operation.validate(),
            _ => Ok(()),
        }
    }
}
fn tree<'a, I>(root: Option<&LayoutNode>, panes: I, depth: usize) -> Result
where
    I: Iterator<Item = &'a PaneId> + Clone,
{
    let pane_count = panes.clone().count();
    let duplicate = panes
        .clone()
        .enumerate()
        .any(|(index, pane)| panes.clone().skip(index + 1).any(|other| pane == other));
    invariant(!duplicate)?;
    let Some(root) = root else {
        return invariant(pane_count == 0);
    };
    let (leaf_count, _) = root.leaf_counts(depth, None)?;
    invariant(leaf_count == pane_count)?;
    for pane in panes {
        let (_, matches) = root.leaf_counts(depth, Some(pane))?;
        invariant(matches == 1)?;
    }
    Ok(())
}
impl Snapshot {
    pub(crate) fn validate(&self) -> Result {
        invariant(unique_by(&self.projects, |project| &project.project_id))?;
        invariant(unique_by(&self.panes, |pane| &pane.pane_id))?;
        invariant(unique_by(&self.layouts, |layout| &layout.project_id))?;
        invariant(
            self.projects.len() == self.layouts.len()
                && self.projects.iter().all(|project| {
                    self.layouts
                        .iter()
                        .any(|layout| layout.project_id == project.project_id)
                }),
        )?;
        invariant(self.panes.iter().all(|pane| {
            self.projects
                .iter()
                .any(|project| project.project_id == pane.project_id)
        }))?;
        for layout in &self.layouts {
            tree(
                layout.root.0.as_ref(),
                self.panes
                    .iter()
                    .filter(|p| p.project_id == layout.project_id)
                    .map(|p| &p.pane_id),
                4,
            )?;
        }
        invariant(self.selected_project_id.0.as_ref().is_none_or(|selected| {
            self.projects
                .iter()
                .any(|project| &project.project_id == selected)
        }))?;
        invariant(self.selected_pane_id.0.as_ref().is_none_or(|id| {
            self.panes.iter().any(|p| {
                &p.pane_id == id && Some(&p.project_id) == self.selected_project_id.0.as_ref()
            })
        }))
    }
}
fn file(kind: FileKind, text: &Nullable<String>, truncated: bool) -> Result {
    invariant(match kind {
        FileKind::Text => text.0.is_some(),
        FileKind::Binary => text.0.is_none() && !truncated,
    })
}
impl Success {
    fn validate(&self) -> Result {
        match self {
            Self::CapabilitiesGet(d) => {
                unique(&d.operations)?;
                invariant(d.providers.0.is_none() == d.shell_profile_ids.0.is_none())?;
                if let Some(s) = &d.shell_profile_ids.0 {
                    unique(s)?;
                }
                Ok(())
            }
            Self::ConnectionList(d) => {
                for c in &d.connections {
                    c.validate()?;
                }
                Ok(())
            }
            Self::ConnectionDecide(d) => {
                unique(&d.project_ids)?;
                unique(&d.scopes)?;
                invariant(
                    d.state != DecidedState::Revoked
                        || (d.project_ids.is_empty() && d.scopes.is_empty()),
                )
            }
            Self::ProjectList(d) => {
                invariant(unique_by(&d.projects, |project| &project.project_id))?;
                invariant(
                    d.selected_project_id.0.as_ref().is_none_or(|id| {
                        d.projects.iter().any(|project| &project.project_id == id)
                    }),
                )
            }
            Self::PaneList(d) => {
                for p in &d.panes {
                    p.validate()?;
                    invariant(p.project_id == d.project_id)?;
                }
                tree(d.root.0.as_ref(), d.panes.iter().map(|p| &p.pane_id), 4)?;
                invariant(
                    d.selected_pane_id
                        .0
                        .as_ref()
                        .is_none_or(|id| d.panes.iter().any(|p| &p.pane_id == id)),
                )
            }
            Self::PaneSelect(d) => {
                invariant(d.selected_pane_id.0.is_none() || d.selected_project_id.0.is_some())
            }
            Self::RunGet(d) => {
                d.run.validate()?;
                invariant(d.cleanup_complete != Some(true)
                    || (d.run.process == Process::Exited && d.run.evidence == Evidence::ProcessExit))
            }
            Self::OperationGet(d) => d.operation.validate(),
            Self::EventsWait(d) => {
                for e in &d.events {
                    e.validate()?;
                }
                invariant(d.events.windows(2).all(|e| e[0].event_seq < e[1].event_seq))?;
                invariant(d.events.iter().all(|e| e.event_seq <= d.next_event_seq))?;
                invariant(match d.status {
                    WaitStatus::Events => !d.events.is_empty(),
                    WaitStatus::NoChange => d.events.is_empty(),
                    WaitStatus::Gap => true,
                })
            }
            Self::ArtifactRegister(d) => d.artifact.validate(),
            Self::ArtifactList(d) => {
                unique(&d.git_candidates)?;
                for a in &d.registered {
                    a.validate()?;
                }
                Ok(())
            }
            Self::ArtifactRead(d) => file(d.kind, &d.text, d.truncated),
            Self::ArtifactDiff(d) => file(d.kind, &d.text, d.truncated),
            Self::ArtifactChoose(d) => d.validate(),
            Self::ArtifactChoiceList(d) => {
                for choice in &d.choices {
                    choice.validate()?;
                }
                invariant(d.choices.windows(2).all(|pair| {
                    (&pair[0].left_artifact_id, &pair[0].right_artifact_id)
                        < (&pair[1].left_artifact_id, &pair[1].right_artifact_id)
                }))
            }
            Self::DiagnosticsGet(d) => {
                unique(&d.capabilities)?;
                unique(&d.failure_codes)
            }
            _ => Ok(()),
        }
    }
    fn correlate(&self, request: &Request) -> Result {
        correlated(self.operation() == request.action.operation())?;
        let ok = match (&request.action, self) {
            (Action::ConnectionDecide(p), Self::ConnectionDecide(d)) => {
                p.connection_id == d.connection_id
                    && same_set(&p.project_ids, &d.project_ids)
                    && same_set(&p.scopes, &d.scopes)
                    && ((p.decision == Decision::Allow) == (d.state == DecidedState::Granted))
            }
            (Action::ConnectionRevoke(p), Self::ConnectionRevoke(d)) => {
                p.connection_id == d.connection_id
            }
            (Action::ProjectSelect(p), Self::ProjectSelect(d)) => {
                p.project_id == d.selected_project_id
            }
            (Action::ProjectForget(p), Self::ProjectForget(d)) => p.project_id == d.project_id,
            (Action::PaneList(p), Self::PaneList(d)) => p.project_id == d.project_id,
            (Action::PaneSplit(p), Self::PaneSplit(d)) => p.pane_id != d.pane_id,
            (Action::PaneSelect(p), Self::PaneSelect(d)) => p.pane_id == d.selected_pane_id,
            (Action::PaneClose(p), Self::PaneClose(d)) => {
                p.pane_id == d.pane_id && d.selected_pane_id.0.as_ref() != Some(&p.pane_id)
            }
            (Action::PaneResize(p), Self::PaneResize(d)) => p == d,
            (Action::ShellLaunch(p), Self::ShellLaunch(d)) => p.pane_id == d.pane_id,
            (Action::AgentLaunch(p), Self::AgentLaunch(d)) => p.pane_id == d.pane_id,
            (Action::InputWrite(p), Self::InputWrite(d)) => {
                p.pane_id == d.pane_id
                    && p.run_id == d.run_id
                    && p.text.len() as u64 == d.written_bytes.get()
            }
            (Action::InputKey(p), Self::InputKey(d)) => {
                p.pane_id == d.pane_id && p.run_id == d.run_id && p.key == d.key
            }
            (Action::RunGet(p), Self::RunGet(d)) => p.run_id == d.run.run_id
                && p.include_cleanup.is_some() == d.cleanup_complete.is_some(),
            (Action::RunInterrupt(p), Self::RunInterrupt(d)) => p.run_id == d.run_id,
            (Action::OperationGet(p), Self::OperationGet(d)) => {
                p.operation_id == d.operation.operation_id
            }
            (Action::OutputRead(p), Self::OutputRead(d)) => {
                p.run_id == d.run_id && d.text.len() as u64 <= p.max_bytes.get()
            }
            (Action::EventsWait(p), Self::EventsWait(d)) => {
                d.next_event_seq >= p.after_event_seq
                    && d.events.iter().all(|e| e.event_seq > p.after_event_seq)
            }
            (Action::ArtifactRegister(p), Self::ArtifactRegister(d)) => {
                p.project_id == d.artifact.project_id
                    && p.relative_path == d.artifact.relative_path
                    && p.run_id == d.artifact.run_id
            }
            (Action::ArtifactList(p), Self::ArtifactList(d)) => {
                d.registered.iter().all(|a| a.project_id == p.project_id)
            }
            (Action::ArtifactRead(p), Self::ArtifactRead(d)) => {
                p.artifact_id == d.artifact_id
                    && d.text
                        .0
                        .as_ref()
                        .is_none_or(|s| s.len() as u64 <= p.max_bytes.get())
            }
            (Action::ArtifactDiff(p), Self::ArtifactDiff(d)) => {
                p.artifact_id == d.artifact_id
                    && d.text
                        .0
                        .as_ref()
                        .is_none_or(|s| s.len() as u64 <= p.max_bytes.get())
            }
            (Action::ArtifactChoose(p), Self::ArtifactChoose(d)) => {
                let (left, right) = if p.left_artifact_id < p.right_artifact_id {
                    (&p.left_artifact_id, &p.right_artifact_id)
                } else {
                    (&p.right_artifact_id, &p.left_artifact_id)
                };
                &d.left_artifact_id == left
                    && &d.right_artifact_id == right
                    && d.kept_artifact_id == p.kept_artifact_id
            }
            (Action::ArtifactChoiceList(_), Self::ArtifactChoiceList(_)) => true,
            // These results create new IDs or return state not present in the request.
            (Action::CapabilitiesGet(_), Self::CapabilitiesGet(_))
            | (Action::ConnectionRequest(_), Self::ConnectionRequest(_))
            | (Action::ConnectionList(_), Self::ConnectionList(_))
            | (Action::HostStop(_), Self::HostStop(_))
            | (Action::ProjectList(_), Self::ProjectList(_))
            | (Action::ProjectOpen(_), Self::ProjectOpen(_))
            | (Action::PaneCreate(_), Self::PaneCreate(_))
            | (Action::LayoutSave(_), Self::LayoutSave(_))
            | (Action::LayoutRestore(_), Self::LayoutRestore(_))
            | (Action::DiagnosticsGet(_), Self::DiagnosticsGet(_)) => true,
            _ => false,
        };
        correlated(ok)
    }
}
impl Response {
    pub(crate) fn validate(&self, request: &Request) -> Result {
        request.validate()?;
        match (self.accepted, &self.result.0, &self.error.0) {
            (true, Some(s), None) => s.validate()?,
            (false, None, Some(e)) => e.validate()?,
            _ => return invariant(false),
        }
        correlated(
            self.operation_id == request.operation_id
                && request
                    .instance_id
                    .0
                    .as_ref()
                    .is_none_or(|i| i == &self.instance_id),
        )?;
        if let Some(s) = &self.result.0 {
            s.correlate(request)?;
        }
        Ok(())
    }
}
