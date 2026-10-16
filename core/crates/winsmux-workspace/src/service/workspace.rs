use crate::contract::ingress::{json_string, CanonicalValue, Sink};
use crate::contract::{
    Axis, ErrorCode, LayoutNode, PaneId, ProjectId, RootIdentity, RootState, RunId,
};
use crate::host::admission::{
    AllocationAuthority, AllocationError, AllocationPool, CapacityCharge, ChargedVec,
};
use crate::runtime::topology::{PaneRecord, ProjectPanes};
use crate::store::root_identity::{paths_are_windows_aliases, ObservedRoot};

pub struct WorkspaceService {
    projects: ChargedVec<ProjectRecord>,
    selected_project_id: Option<ProjectId>,
}

pub struct ProjectRecord {
    pub id: ProjectId,
    pub identity: Option<RootIdentity>,
    pub display_name: Option<String>,
    pub path: Option<String>,
    pub aliases: Vec<String>,
    pub live_run: bool,
    pub spawn_reserved: bool,
    pub panes: ProjectPanes,
    _charge: Option<CapacityCharge>,
    _alias_charges: Vec<CapacityCharge>,
}

pub enum OpenOutcome {
    Created(ProjectId),
    Existing(ProjectId),
}

pub enum OpenKind {
    Create,
    Existing(ProjectId),
}

pub enum SelectOutcome {
    Unchanged,
    Changed,
}

pub struct ListRow {
    pub project_id: ProjectId,
    pub root_state: RootState,
    pub display_name: Option<String>,
    pub path: Option<String>,
}

impl WorkspaceService {
    pub fn new(authority: &AllocationAuthority) -> Result<Self, AllocationError> {
        Ok(Self {
            projects: ChargedVec::with_capacity(authority, AllocationPool::Retained, 0, 0)?,
            selected_project_id: None,
        })
    }

    pub fn seed(
        &mut self,
        authority: &AllocationAuthority,
        ids: &[ProjectId],
    ) -> Result<(), AllocationError> {
        self.ensure_capacity(authority, ids.len())?;
        for id in ids {
            if self.contains(id) {
                continue;
            }
            let charge = authority.claim(AllocationPool::Retained, id.as_str().len())?;
            self.projects.try_push(ProjectRecord {
                id: id.clone(),
                identity: None,
                display_name: None,
                path: None,
                aliases: Vec::new(),
                live_run: false,
                spawn_reserved: false,
                panes: ProjectPanes::default(),
                _charge: Some(charge),
                _alias_charges: Vec::new(),
            })?;
        }
        Ok(())
    }

    pub fn contains(&self, id: &ProjectId) -> bool {
        self.projects.iter().any(|project| &project.id == id)
    }

    pub fn selected(&self) -> Option<&ProjectId> {
        self.selected_project_id.as_ref()
    }

    pub fn selected_pane(&self) -> Option<&PaneId> {
        self.selected_project_id
            .as_ref()
            .and_then(|id| self.get(id))
            .and_then(|project| project.panes.selected_pane_id.as_ref())
    }

    #[cfg(debug_assertions)]
    pub(crate) fn testing_alias_charge_count(&self) -> usize {
        self.projects
            .iter()
            .map(|record| record._alias_charges.len())
            .sum()
    }

    pub fn get(&self, id: &ProjectId) -> Option<&ProjectRecord> {
        self.projects.iter().find(|project| &project.id == id)
    }

    pub fn get_mut(&mut self, id: &ProjectId) -> Option<&mut ProjectRecord> {
        self.projects.iter_mut().find(|project| &project.id == id)
    }

    pub fn projects(&self) -> &[ProjectRecord] {
        &self.projects
    }

    pub fn set_fixture_occupancy(
        &mut self,
        id: &ProjectId,
        live_run: bool,
        spawn_reserved: bool,
    ) -> bool {
        if let Some(project) = self.get_mut(id) {
            project.live_run = live_run;
            project.spawn_reserved = spawn_reserved;
            true
        } else {
            false
        }
    }

    pub fn commit_open(
        &mut self,
        authority: &AllocationAuthority,
        observed: &ObservedRoot,
        expected: u64,
        current: u64,
    ) -> Result<OpenOutcome, ErrorCode> {
        if expected != current {
            return Err(ErrorCode::StaleTopology);
        }
        if let Some(existing) = self.by_identity(&observed.identity) {
            let id = existing.id.clone();
            self.add_alias(authority, &id, &observed.input_path)?;
            self.add_alias(authority, &id, &observed.actual_path)?;
            return Ok(OpenOutcome::Existing(id));
        }
        if self.alias_owned_by_other(&observed.input_path, None)
            || self.alias_owned_by_other(&observed.actual_path, None)
        {
            return Err(ErrorCode::RootChanged);
        }
        self.ensure_capacity(authority, self.projects.len() + 1)
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        let id = new_project_id(|candidate| self.contains(candidate))?;
        let display = display_name_of(&observed.actual_path);
        let charge_bytes = observed
            .actual_path
            .capacity()
            .saturating_add(observed.input_path.capacity())
            .saturating_add(display.capacity())
            .saturating_add(id.as_str().len());
        let charge = authority
            .claim(AllocationPool::Retained, charge_bytes.max(1))
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        self.projects
            .try_push(ProjectRecord {
                id: id.clone(),
                identity: Some(observed.identity.clone()),
                display_name: Some(display),
                path: Some(observed.actual_path.clone()),
                aliases: vec![observed.input_path.clone(), observed.actual_path.clone()],
                live_run: false,
                spawn_reserved: false,
                panes: ProjectPanes::default(),
                _charge: Some(charge),
                _alias_charges: Vec::new(),
            })
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        Ok(OpenOutcome::Created(id))
    }

    pub fn classify_select(
        &self,
        target: Option<&ProjectId>,
        expected: u64,
        current: u64,
    ) -> Result<SelectOutcome, ErrorCode> {
        self.classify_selection(target, None, expected, current)
    }

    pub fn classify_selection(
        &self,
        target_project: Option<&ProjectId>,
        target_pane: Option<&PaneId>,
        expected: u64,
        current: u64,
    ) -> Result<SelectOutcome, ErrorCode> {
        if expected != current {
            return Err(ErrorCode::StaleTopology);
        }
        if let Some(id) = target_project {
            let project = self.get(id).ok_or(ErrorCode::TargetNotFound)?;
            if target_pane.is_some_and(|pane| !project.panes.contains_pane(pane)) {
                return Err(ErrorCode::TargetNotFound);
            }
        } else if target_pane.is_some() {
            return Err(ErrorCode::TargetNotFound);
        }
        let same = target_project == self.selected()
            && target_pane == self.selected_pane();
        if same {
            Ok(SelectOutcome::Unchanged)
        } else {
            Ok(SelectOutcome::Changed)
        }
    }

    pub fn apply_select(&mut self, target: Option<&ProjectId>) {
        self.apply_selection(target, None);
    }

    pub fn apply_selection(&mut self, project_id: Option<&ProjectId>, pane_id: Option<&PaneId>) {
        for project in self.projects.iter_mut() {
            project.panes.selected_pane_id = None;
        }
        self.selected_project_id = project_id.cloned();
        if let (Some(project_id), Some(pane_id)) = (project_id, pane_id) {
            if let Some(project) = self.get_mut(project_id) {
                project.panes.selected_pane_id = Some(pane_id.clone());
            }
        }
    }

    pub fn commit_forget(
        &mut self,
        id: &ProjectId,
        expected: u64,
        current: u64,
    ) -> Result<ProjectId, ErrorCode> {
        if expected != current {
            return Err(ErrorCode::StaleTopology);
        }
        let Some(index) = self.projects.iter().position(|project| &project.id == id) else {
            return Err(ErrorCode::TargetNotFound);
        };
        let project = &self.projects[index];
        if project.spawn_reserved {
            return Err(ErrorCode::OperationConflict);
        }
        if self.selected_project_id.as_ref() == Some(id) {
            self.selected_project_id = None;
        }
        self.projects.remove(index);
        Ok(id.clone())
    }

    pub fn panes_mut(&mut self, id: &ProjectId) -> Option<&mut ProjectPanes> {
        self.projects
            .iter_mut()
            .find(|project| &project.id == id)
            .map(|project| &mut project.panes)
    }

    pub fn panes(&self, id: &ProjectId) -> Option<&ProjectPanes> {
        self.get(id).map(|project| &project.panes)
    }

    pub fn project_id_for_pane(&self, pane_id: &PaneId) -> Option<ProjectId> {
        self.projects.iter().find_map(|project| {
            project
                .panes
                .contains_pane(pane_id)
                .then(|| project.id.clone())
        })
    }

    pub fn project_id_for_run(&self, run_id: &RunId) -> Option<ProjectId> {
        self.projects.iter().find_map(|project| {
            project
                .panes
                .run_ids()
                .iter()
                .any(|id| id.as_str() == run_id.as_str())
                .then(|| project.id.clone())
        })
    }

    pub fn set_spawn_reserved(&mut self, id: &ProjectId, reserved: bool) -> Result<(), ErrorCode> {
        let project = self.get_mut(id).ok_or(ErrorCode::TargetNotFound)?;
        project.spawn_reserved = reserved;
        Ok(())
    }

    pub fn add_pane(
        &mut self,
        project_id: &ProjectId,
        pane_id: PaneId,
        run_id: RunId,
        split_of: Option<&PaneId>,
        axis: Axis,
        shell_profile: &str,
    ) -> Result<LayoutNode, ErrorCode> {
        let project = self.get_mut(project_id).ok_or(ErrorCode::TargetNotFound)?;
        if project.panes.contains_pane(&pane_id) {
            return Err(ErrorCode::OperationConflict);
        }
        let shell_profile_id = crate::contract::NonEmpty::new(shell_profile.to_owned())
            .map_err(|_| ErrorCode::InvalidRequest)?;
        let record = PaneRecord {
            id: pane_id.clone(),
            current_run: Some(run_id),
            previous_runs: Vec::new(),
            shell_profile_id,
            provider_profile: crate::contract::Nullable(None),
        };
        if project.panes.root.is_none() {
            project.panes.root = Some(LayoutNode::leaf(pane_id.clone()));
            project.panes.panes.push(record);
            return Ok(project.panes.root.clone().expect("leaf inserted"));
        }
        let Some(target) = split_of else {
            return Err(ErrorCode::InvalidRequest);
        };
        let current = project
            .panes
            .root
            .as_ref()
            .ok_or(ErrorCode::InvalidRequest)?;
        let next = crate::runtime::topology::split_replace_leaf(current, target, pane_id, axis)
            .ok_or(ErrorCode::TargetNotFound)?;
        project.panes.root = Some(next.clone());
        project.panes.panes.push(record);
        Ok(next)
    }

    pub fn set_pane_shell_profile(
        &mut self,
        project_id: &ProjectId,
        pane_id: &PaneId,
        shell_profile: &str,
    ) -> Result<(), ErrorCode> {
        let shell_profile_id = crate::contract::NonEmpty::new(shell_profile.to_owned())
            .map_err(|_| ErrorCode::InvalidRequest)?;
        let pane = self
            .get_mut(project_id)
            .ok_or(ErrorCode::TargetNotFound)?
            .panes
            .pane_mut(pane_id)
            .ok_or(ErrorCode::TargetNotFound)?;
        pane.shell_profile_id = shell_profile_id;
        Ok(())
    }

    pub(crate) fn snapshot(
        &self,
        generation: crate::contract::U,
        topology_revision: crate::contract::U,
    ) -> Result<crate::contract::Snapshot, ErrorCode> {
        let mut projects = Vec::new();
        let mut panes = Vec::new();
        let mut layouts = Vec::new();
        for project in self.projects.iter() {
            let identity = project
                .identity
                .clone()
                .ok_or(ErrorCode::PersistenceFailed)?;
            let path = project
                .path
                .as_deref()
                .ok_or(ErrorCode::PersistenceFailed)?;
            let path = crate::contract::NonEmpty::new(path.to_owned())
                .map_err(|_| ErrorCode::PersistenceFailed)?;
            projects.push(crate::contract::SavedProject {
                project_id: project.id.clone(),
                path,
                display_name: project.display_name.clone().unwrap_or_default(),
                root_identity: identity,
            });
            for pane in &project.panes.panes {
                panes.push(crate::contract::SavedPane {
                    pane_id: pane.id.clone(),
                    project_id: project.id.clone(),
                    shell_profile_id: pane.shell_profile_id.clone(),
                    provider_profile: pane.provider_profile.clone(),
                });
            }
            layouts.push(crate::contract::SavedLayout {
                project_id: project.id.clone(),
                root: crate::contract::Nullable(project.panes.root.clone()),
            });
        }
        let selected_project_id = crate::contract::Nullable(self.selected_project_id.clone());
        let selected_pane_id = crate::contract::Nullable(self.selected_pane().cloned());
        let snapshot = crate::contract::Snapshot {
            schema_version: crate::contract::Version::new(1)
                .map_err(|_| ErrorCode::PersistenceFailed)?,
            generation,
            topology_revision,
            projects,
            panes,
            layouts,
            selected_project_id,
            selected_pane_id,
        };
        snapshot
            .validate()
            .map_err(|_| ErrorCode::PersistenceFailed)?;
        Ok(snapshot)
    }

    /// Caller must retain `observed` handles until after this replacement is committed.
    pub(crate) fn from_snapshot(
        authority: &AllocationAuthority,
        snapshot: &crate::contract::Snapshot,
        observed: &[ObservedRoot],
    ) -> Result<Self, ErrorCode> {
        let roots: Vec<RestoreRoot<'_>> = observed
            .iter()
            .map(|root| RestoreRoot {
                identity: &root.identity,
                actual_path: &root.actual_path,
                input_path: &root.input_path,
            })
            .collect();
        Self::from_snapshot_roots(authority, snapshot, &roots)
    }

    fn from_snapshot_roots(
        authority: &AllocationAuthority,
        snapshot: &crate::contract::Snapshot,
        observed: &[RestoreRoot<'_>],
    ) -> Result<Self, ErrorCode> {
        snapshot
            .validate()
            .map_err(|_| ErrorCode::PersistenceFailed)?;
        let mut workspace = Self::new(authority).map_err(|_| ErrorCode::ResourceExhausted)?;
        workspace
            .ensure_capacity(authority, snapshot.projects.len())
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        for saved in &snapshot.projects {
            let Some(root) = observed
                .iter()
                .find(|root| *root.identity == saved.root_identity)
            else {
                return Err(ErrorCode::RootChanged);
            };
            let layout = snapshot
                .layouts
                .iter()
                .find(|layout| layout.project_id == saved.project_id)
                .ok_or(ErrorCode::PersistenceFailed)?;
            let charge_bytes = {
                use crate::contract::OwnedCapacity;
                let mut charge_bytes = saved
                    .project_id
                    .as_str()
                    .len()
                    .saturating_add(saved.display_name.len())
                    .saturating_add(root.actual_path.len())
                    .saturating_add(root.input_path.len());
                charge_bytes = charge_bytes.saturating_add(layout.root.owned_capacity());
                for pane in snapshot
                    .panes
                    .iter()
                    .filter(|pane| pane.project_id == saved.project_id)
                {
                    charge_bytes = charge_bytes
                        .saturating_add(pane.pane_id.as_str().len())
                        .saturating_add(pane.shell_profile_id.as_str().len())
                        .saturating_add(pane.provider_profile.owned_capacity());
                }
                charge_bytes.max(1)
            };
            let charge = authority
                .claim(AllocationPool::Retained, charge_bytes)
                .map_err(|_| ErrorCode::ResourceExhausted)?;
            let selected_pane_id = snapshot.selected_pane_id.0.clone().filter(|pane_id| {
                snapshot.selected_project_id.0.as_ref() == Some(&saved.project_id)
                    && snapshot.panes.iter().any(|pane| {
                        pane.project_id == saved.project_id && &pane.pane_id == pane_id
                    })
            });
            let mut panes = crate::runtime::topology::ProjectPanes {
                root: layout.root.0.clone(),
                selected_pane_id,
                panes: Vec::new(),
            };
            for pane in snapshot
                .panes
                .iter()
                .filter(|pane| pane.project_id == saved.project_id)
            {
                panes.panes.push(PaneRecord {
                    id: pane.pane_id.clone(),
                    current_run: None,
                    previous_runs: Vec::new(),
                    shell_profile_id: pane.shell_profile_id.clone(),
                    provider_profile: pane.provider_profile.clone(),
                });
            }
            workspace
                .projects
                .try_push(ProjectRecord {
                    id: saved.project_id.clone(),
                    identity: Some(root.identity.clone()),
                    display_name: Some(saved.display_name.clone()),
                    path: Some(root.actual_path.to_owned()),
                    aliases: vec![root.input_path.to_owned(), root.actual_path.to_owned()],
                    live_run: false,
                    spawn_reserved: false,
                    panes,
                    _charge: Some(charge),
                    _alias_charges: Vec::new(),
                })
                .map_err(|_| ErrorCode::ResourceExhausted)?;
        }
        workspace.selected_project_id = snapshot.selected_project_id.0.clone();
        Ok(workspace)
    }

    pub fn default_split_target(&self, project_id: &ProjectId) -> Option<PaneId> {
        let panes = self.panes(project_id)?;
        panes
            .selected_pane_id
            .clone()
            .or_else(|| panes.panes.first().map(|pane| pane.id.clone()))
    }

    pub fn replace_current_run(
        &mut self,
        project_id: &ProjectId,
        pane_id: &PaneId,
        run_id: RunId,
    ) -> Result<Option<RunId>, ErrorCode> {
        let pane = self
            .get_mut(project_id)
            .ok_or(ErrorCode::TargetNotFound)?
            .panes
            .pane_mut(pane_id)
            .ok_or(ErrorCode::TargetNotFound)?;
        let previous = pane.current_run.take();
        if let Some(previous) = previous.clone() {
            pane.previous_runs.push(previous);
        }
        pane.current_run = Some(run_id);
        Ok(previous)
    }

    pub fn close_pane_layout(
        &mut self,
        project_id: &ProjectId,
        pane_id: &PaneId,
    ) -> Result<Option<LayoutNode>, ErrorCode> {
        let project = self.get_mut(project_id).ok_or(ErrorCode::TargetNotFound)?;
        let current = project
            .panes
            .root
            .as_ref()
            .ok_or(ErrorCode::TargetNotFound)?;
        let next = crate::runtime::topology::close_leaf(current, pane_id)
            .ok_or(ErrorCode::TargetNotFound)?;
        project.panes.root = next.clone();
        project
            .panes
            .panes
            .retain(|pane| pane.id.as_str() != pane_id.as_str());
        if project
            .panes
            .selected_pane_id
            .as_ref()
            .is_some_and(|selected| selected.as_str() == pane_id.as_str())
        {
            project.panes.selected_pane_id = None;
        }
        Ok(next)
    }

    pub fn launch_occupancy_ok(
        &self,
        project_id: &ProjectId,
        pane_id: &PaneId,
        runtime: &crate::runtime::RuntimeService,
    ) -> Result<bool, ErrorCode> {
        let project = self.get(project_id).ok_or(ErrorCode::TargetNotFound)?;
        let Some(pane) = project.panes.pane(pane_id) else {
            return Err(ErrorCode::TargetNotFound);
        };
        match pane.current_run.as_ref() {
            None => Ok(true),
            Some(run) => Ok(runtime.session_clean(run)),
        }
    }

    pub fn classify_open(
        &self,
        observed: &ObservedRoot,
        expected: u64,
        current: u64,
    ) -> Result<OpenKind, ErrorCode> {
        if expected != current {
            return Err(ErrorCode::StaleTopology);
        }
        if let Some(existing) = self.by_identity(&observed.identity) {
            return Ok(OpenKind::Existing(existing.id.clone()));
        }
        if self.alias_owned_by_other(&observed.input_path, None)
            || self.alias_owned_by_other(&observed.actual_path, None)
        {
            return Err(ErrorCode::RootChanged);
        }
        Ok(OpenKind::Create)
    }

    fn by_identity(&self, identity: &RootIdentity) -> Option<&ProjectRecord> {
        self.projects.iter().find(|project| {
            project
                .identity
                .as_ref()
                .is_some_and(|stored| stored == identity)
        })
    }

    fn alias_owned_by_other(&self, path: &str, except: Option<&ProjectId>) -> bool {
        self.projects.iter().any(|project| {
            except.is_none_or(|id| &project.id != id)
                && project
                    .aliases
                    .iter()
                    .any(|alias| paths_are_windows_aliases(alias, path))
        })
    }

    fn add_alias(
        &mut self,
        authority: &AllocationAuthority,
        id: &ProjectId,
        path: &str,
    ) -> Result<(), ErrorCode> {
        if self.alias_owned_by_other(path, Some(id)) {
            return Err(ErrorCode::RootChanged);
        }
        let Some(project) = self.get_mut(id) else {
            return Err(ErrorCode::TargetNotFound);
        };
        if project
            .aliases
            .iter()
            .any(|alias| paths_are_windows_aliases(alias, path))
        {
            return Ok(());
        }
        let extra = path.len().max(1);
        let extra_charge = authority
            .claim(AllocationPool::Retained, extra)
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        project.aliases.push(path.to_owned());
        project._alias_charges.push(extra_charge);
        Ok(())
    }

    fn ensure_capacity(
        &mut self,
        authority: &AllocationAuthority,
        elements: usize,
    ) -> Result<(), AllocationError> {
        if elements <= self.projects.capacity_elements() {
            return Ok(());
        }
        let bytes = elements
            .checked_mul(std::mem::size_of::<ProjectRecord>())
            .ok_or(AllocationError::Layout)?;
        self.projects
            .try_grow_retained(authority, AllocationPool::ActiveOwner, elements, bytes)
    }
}

pub fn write_project_list(
    sink: &mut impl Sink,
    rows: &[ListRow],
    selected: Option<&ProjectId>,
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"data\":{\"projects\":[")?;
    for (index, row) in rows.iter().enumerate() {
        if index != 0 {
            sink.bytes(b",")?;
        }
        sink.bytes(b"{\"display_name\":")?;
        match &row.display_name {
            Some(name) => json_string(sink, name)?,
            None => sink.bytes(b"null")?,
        }
        sink.bytes(b",\"path\":")?;
        match &row.path {
            Some(path) => json_string(sink, path)?,
            None => sink.bytes(b"null")?,
        }
        sink.bytes(b",\"project_id\":")?;
        json_string(sink, row.project_id.as_str())?;
        sink.bytes(b",\"root_state\":")?;
        row.root_state.write_canonical(sink)?;
        sink.bytes(b"}")?;
    }
    sink.bytes(b"],\"selected_project_id\":")?;
    match selected {
        Some(id) => json_string(sink, id.as_str())?,
        None => sink.bytes(b"null")?,
    }
    sink.bytes(b"},\"operation\":\"project.list\"}")
}

pub fn write_project_open(
    sink: &mut impl Sink,
    id: &ProjectId,
    created: bool,
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"data\":{\"created\":")?;
    sink.bytes(if created { b"true" } else { b"false" })?;
    sink.bytes(b",\"project_id\":")?;
    json_string(sink, id.as_str())?;
    sink.bytes(b"},\"operation\":\"project.open\"}")
}

pub fn write_project_select(
    sink: &mut impl Sink,
    selected: Option<&ProjectId>,
) -> Result<(), AllocationError> {
    sink.bytes(b"{\"data\":{\"selected_pane_id\":null,\"selected_project_id\":")?;
    match selected {
        Some(id) => json_string(sink, id.as_str())?,
        None => sink.bytes(b"null")?,
    }
    sink.bytes(b"},\"operation\":\"project.select\"}")
}

pub fn write_project_forget(sink: &mut impl Sink, id: &ProjectId) -> Result<(), AllocationError> {
    sink.bytes(b"{\"data\":{\"project_id\":")?;
    json_string(sink, id.as_str())?;
    sink.bytes(b",\"removed\":true},\"operation\":\"project.forget\"}")
}

pub fn visible_rows(
    projects: &[ProjectRecord],
    owner: bool,
    metadata: bool,
    read_output: bool,
    granted: &[[u8; 36]],
    states: &[(ProjectId, RootState)],
) -> Vec<ListRow> {
    if !owner && !metadata {
        return Vec::new();
    }
    let mut rows = Vec::new();
    for project in projects {
        if !owner && !granted.iter().any(|key| key_of(&project.id) == *key) {
            continue;
        }
        let root_state = states
            .iter()
            .find(|(id, _)| id == &project.id)
            .map(|(_, state)| *state)
            .unwrap_or(RootState::Unknown);
        let names = owner || read_output;
        rows.push(ListRow {
            project_id: project.id.clone(),
            root_state,
            display_name: if names {
                project.display_name.clone()
            } else {
                None
            },
            path: if names { project.path.clone() } else { None },
        });
    }
    rows.sort_by(|left, right| left.project_id.as_str().cmp(right.project_id.as_str()));
    rows
}

pub fn selected_if_visible<'a>(
    selected: Option<&'a ProjectId>,
    rows: &[ListRow],
) -> Option<&'a ProjectId> {
    selected.filter(|id| rows.iter().any(|row| &row.project_id == *id))
}

pub fn key_of(id: &ProjectId) -> [u8; 36] {
    let mut key = [0u8; 36];
    key.copy_from_slice(id.as_str().as_bytes());
    key
}

fn display_name_of(path: &str) -> String {
    let trimmed = path.trim_end_matches(['\\', '/']);
    trimmed
        .rsplit(['\\', '/'])
        .next()
        .filter(|part| !part.is_empty())
        .unwrap_or(path)
        .to_owned()
}

fn new_project_id(taken: impl Fn(&ProjectId) -> bool) -> Result<ProjectId, ErrorCode> {
    for _ in 0..8 {
        let id = ProjectId::new(uuid::Uuid::new_v4().to_string())
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        if !taken(&id) {
            return Ok(id);
        }
    }
    Err(ErrorCode::ResourceExhausted)
}

struct RestoreRoot<'a> {
    identity: &'a RootIdentity,
    actual_path: &'a str,
    input_path: &'a str,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contract::{
        Axis, ErrorCode, Hex16, Hex32, LayoutNode, NonEmpty, Nullable, PaneId, ProjectId, Provider,
        ProviderProfile, Ratio, RootIdentity, RunId, SavedLayout, SavedPane, SavedProject, Snapshot,
        U, Version,
    };
    use crate::host::admission::{AllocationAuthority, AllocationPool, RETAINED_BYTES};

    fn project_id(n: u8) -> ProjectId {
        ProjectId::new(format!("00000000-0000-4000-8000-0000000000{n:02x}")).unwrap()
    }

    fn pane_id(n: u8) -> PaneId {
        PaneId::new(format!("10000000-0000-4000-8000-0000000000{n:02x}")).unwrap()
    }

    fn run_id(n: u8) -> RunId {
        RunId::new(format!("20000000-0000-4000-8000-0000000000{n:02x}")).unwrap()
    }

    fn identity(n: u8) -> RootIdentity {
        RootIdentity {
            volume_serial: Hex16::new(format!("{n:016x}")).unwrap(),
            file_id: Hex32::new(format!("{n:032x}")).unwrap(),
        }
    }

    fn generation() -> U {
        U::new(7).unwrap()
    }

    fn revision() -> U {
        U::new(11).unwrap()
    }

    fn shell(id: &str) -> NonEmpty {
        NonEmpty::new(id.to_owned()).unwrap()
    }

    struct Fixture {
        snapshot: Snapshot,
        identity_a: RootIdentity,
        identity_b: RootIdentity,
        path_a: String,
        path_b: String,
        project_a: ProjectId,
        project_b: ProjectId,
        pane_a: PaneId,
        pane_b1: PaneId,
        pane_b2: PaneId,
    }

    impl Fixture {
        fn two_project_split() -> Self {
            let project_a = project_id(1);
            let project_b = project_id(2);
            let pane_a = pane_id(1);
            let pane_b1 = pane_id(2);
            let pane_b2 = pane_id(3);
            let identity_a = identity(1);
            let identity_b = identity(2);
            let path_a = String::from("C:\\fixture\\alpha");
            let path_b = String::from("C:\\fixture\\beta");
            let root_b = LayoutNode::split(
                Axis::Vertical,
                Ratio::new(0.5).unwrap(),
                LayoutNode::leaf(pane_b1.clone()),
                LayoutNode::leaf(pane_b2.clone()),
            )
            .unwrap();
            let snapshot = Snapshot {
                schema_version: Version::new(1).unwrap(),
                generation: generation(),
                topology_revision: revision(),
                projects: vec![
                    SavedProject {
                        project_id: project_a.clone(),
                        path: NonEmpty::new(path_a.clone()).unwrap(),
                        display_name: String::from("alpha"),
                        root_identity: identity_a.clone(),
                    },
                    SavedProject {
                        project_id: project_b.clone(),
                        path: NonEmpty::new(path_b.clone()).unwrap(),
                        display_name: String::from("beta"),
                        root_identity: identity_b.clone(),
                    },
                ],
                panes: vec![
                    SavedPane {
                        pane_id: pane_a.clone(),
                        project_id: project_a.clone(),
                        shell_profile_id: shell("pwsh"),
                        provider_profile: Nullable(None),
                    },
                    SavedPane {
                        pane_id: pane_b1.clone(),
                        project_id: project_b.clone(),
                        shell_profile_id: shell("pwsh"),
                        provider_profile: Nullable(None),
                    },
                    SavedPane {
                        pane_id: pane_b2.clone(),
                        project_id: project_b.clone(),
                        shell_profile_id: shell("custom-shell"),
                        provider_profile: Nullable(Some(ProviderProfile {
                            provider: Provider::Codex,
                            model: Nullable(Some(shell("gpt"))),
                            effort: Nullable(None),
                        })),
                    },
                ],
                layouts: vec![
                    SavedLayout {
                        project_id: project_a.clone(),
                        root: Nullable(Some(LayoutNode::leaf(pane_a.clone()))),
                    },
                    SavedLayout {
                        project_id: project_b.clone(),
                        root: Nullable(Some(root_b)),
                    },
                ],
                selected_project_id: Nullable(Some(project_b.clone())),
                selected_pane_id: Nullable(Some(pane_b2.clone())),
            };
            Self {
                snapshot,
                identity_a,
                identity_b,
                path_a,
                path_b,
                project_a,
                project_b,
                pane_a,
                pane_b1,
                pane_b2,
            }
        }

        fn roots(&self) -> [RestoreRoot<'_>; 2] {
            [
                RestoreRoot {
                    identity: &self.identity_a,
                    actual_path: &self.path_a,
                    input_path: &self.path_a,
                },
                RestoreRoot {
                    identity: &self.identity_b,
                    actual_path: &self.path_b,
                    input_path: &self.path_b,
                },
            ]
        }
    }

    #[test]
    fn empty_workspace_snapshot_round_trip() {
        let authority = AllocationAuthority::host();
        let workspace = WorkspaceService::new(&authority).unwrap();
        let snapshot = workspace.snapshot(generation(), revision()).unwrap();
        assert!(snapshot.projects.is_empty());
        assert!(snapshot.panes.is_empty());
        assert!(snapshot.layouts.is_empty());
        assert!(snapshot.selected_project_id.0.is_none());
        assert!(snapshot.selected_pane_id.0.is_none());
        let restored = WorkspaceService::from_snapshot(&authority, &snapshot, &[]).unwrap();
        assert!(restored.projects().is_empty());
        assert!(restored.selected().is_none());
        let encoded = crate::contract::serialize_snapshot(&snapshot).unwrap();
        let parsed = crate::contract::parse_snapshot(&encoded).unwrap();
        assert_eq!(parsed.projects.len(), 0);
        let again = restored.snapshot(generation(), revision()).unwrap();
        assert_eq!(crate::contract::serialize_snapshot(&again).unwrap(), encoded);
    }

    #[test]
    fn incomplete_records_do_not_invent_an_empty_snapshot() {
        let authority = AllocationAuthority::host();
        let mut workspace = WorkspaceService::new(&authority).unwrap();
        let id = project_id(1);
        workspace.seed(&authority, &[id]).unwrap();
        assert_eq!(
            workspace.snapshot(generation(), revision()).unwrap_err(),
            ErrorCode::PersistenceFailed
        );
        assert_eq!(workspace.projects().len(), 1);
    }

    #[test]
    fn multi_project_split_round_trip_preserves_identities_tree_selection_and_profiles() {
        let authority = AllocationAuthority::host();
        let fixture = Fixture::two_project_split();
        let roots = fixture.roots();
        let workspace =
            WorkspaceService::from_snapshot_roots(&authority, &fixture.snapshot, &roots).unwrap();
        assert_eq!(workspace.projects().len(), 2);
        assert_eq!(workspace.selected(), Some(&fixture.project_b));
        let project_a = workspace.get(&fixture.project_a).unwrap();
        assert_eq!(project_a.identity.as_ref(), Some(&fixture.identity_a));
        assert_eq!(project_a.path.as_deref(), Some(fixture.path_a.as_str()));
        assert_eq!(project_a.display_name.as_deref(), Some("alpha"));
        assert!(!project_a.live_run);
        assert!(!project_a.spawn_reserved);
        assert_eq!(
            project_a.panes.root.as_ref(),
            Some(&LayoutNode::leaf(fixture.pane_a.clone()))
        );
        assert_eq!(
            project_a
                .panes
                .pane(&fixture.pane_a)
                .unwrap()
                .shell_profile_id
                .as_str(),
            "pwsh"
        );
        let project_b = workspace.get(&fixture.project_b).unwrap();
        assert_eq!(project_b.identity.as_ref(), Some(&fixture.identity_b));
        assert_eq!(
            project_b.panes.selected_pane_id.as_ref(),
            Some(&fixture.pane_b2)
        );
        assert_eq!(project_b.panes.leaf_count(), 2);
        let pane_b2 = project_b.panes.pane(&fixture.pane_b2).unwrap();
        assert_eq!(pane_b2.shell_profile_id.as_str(), "custom-shell");
        assert_eq!(
            pane_b2
                .provider_profile
                .0
                .as_ref()
                .map(|profile| profile.provider),
            Some(Provider::Codex)
        );
        let round_trip = workspace.snapshot(generation(), revision()).unwrap();
        assert_eq!(
            crate::contract::serialize_snapshot(&round_trip).unwrap(),
            crate::contract::serialize_snapshot(&fixture.snapshot).unwrap()
        );
    }

    #[test]
    fn selection_pair_transitions_survive_snapshot_and_clear_on_close_or_forget() {
        let authority = AllocationAuthority::host();
        let fixture = Fixture::two_project_split();
        let roots = fixture.roots();
        let mut workspace =
            WorkspaceService::from_snapshot_roots(&authority, &fixture.snapshot, &roots).unwrap();
        assert_eq!(workspace.selected(), Some(&fixture.project_b));
        assert_eq!(workspace.selected_pane(), Some(&fixture.pane_b2));

        assert!(matches!(
            workspace.classify_selection(Some(&fixture.project_a), Some(&fixture.pane_a), 7, 7),
            Ok(SelectOutcome::Changed)
        ));
        workspace.apply_selection(Some(&fixture.project_a), Some(&fixture.pane_a));
        assert_eq!(workspace.selected(), Some(&fixture.project_a));
        assert_eq!(workspace.selected_pane(), Some(&fixture.pane_a));
        assert_eq!(
            workspace.snapshot(generation(), revision()).unwrap().selected_pane_id.0,
            Some(fixture.pane_a.clone())
        );
        assert!(matches!(
            workspace.classify_selection(Some(&fixture.project_b), Some(&fixture.pane_a), 7, 7),
            Err(ErrorCode::TargetNotFound)
        ));
        assert!(matches!(
            workspace.classify_selection(Some(&fixture.project_b), Some(&fixture.pane_b1), 6, 7),
            Err(ErrorCode::StaleTopology)
        ));
        assert_eq!(workspace.selected(), Some(&fixture.project_a));
        assert_eq!(workspace.selected_pane(), Some(&fixture.pane_a));

        workspace.apply_select(Some(&fixture.project_a));
        assert_eq!(workspace.selected(), Some(&fixture.project_a));
        assert_eq!(workspace.selected_pane(), None);
        workspace.apply_selection(Some(&fixture.project_b), Some(&fixture.pane_b2));
        workspace.apply_selection(Some(&fixture.project_b), None);
        assert_eq!(workspace.selected(), Some(&fixture.project_b));
        assert_eq!(workspace.selected_pane(), None);
        workspace.apply_selection(Some(&fixture.project_b), Some(&fixture.pane_b2));
        workspace
            .close_pane_layout(&fixture.project_b, &fixture.pane_b2)
            .unwrap();
        assert_eq!(workspace.selected(), Some(&fixture.project_b));
        assert_eq!(workspace.selected_pane(), None);
        workspace.commit_forget(&fixture.project_b, 7, 7).unwrap();
        assert_eq!(workspace.selected(), None);
        assert_eq!(workspace.selected_pane(), None);
        let snapshot = workspace.snapshot(generation(), revision()).unwrap();
        assert!(snapshot.selected_project_id.0.is_none());
        assert!(snapshot.selected_pane_id.0.is_none());
    }

    #[test]
    fn restore_discards_run_history_live_and_reserved() {
        let authority = AllocationAuthority::host();
        let fixture = Fixture::two_project_split();
        let roots = fixture.roots();
        let mut workspace =
            WorkspaceService::from_snapshot_roots(&authority, &fixture.snapshot, &roots).unwrap();
        assert!(workspace.set_fixture_occupancy(&fixture.project_b, true, true));
        let previous = workspace
            .replace_current_run(&fixture.project_b, &fixture.pane_b1, run_id(1))
            .unwrap();
        assert!(previous.is_none());
        let previous = workspace
            .replace_current_run(&fixture.project_b, &fixture.pane_b1, run_id(2))
            .unwrap();
        assert_eq!(
            previous.as_ref().map(RunId::as_str),
            Some(run_id(1).as_str())
        );
        let live = workspace.get(&fixture.project_b).unwrap();
        assert!(live.live_run);
        assert!(live.spawn_reserved);
        assert!(live
            .panes
            .pane(&fixture.pane_b1)
            .unwrap()
            .current_run
            .is_some());
        assert_eq!(
            live.panes
                .pane(&fixture.pane_b1)
                .unwrap()
                .previous_runs
                .len(),
            1
        );
        let snapshot = workspace.snapshot(generation(), revision()).unwrap();
        let restored =
            WorkspaceService::from_snapshot_roots(&authority, &snapshot, &roots).unwrap();
        let project = restored.get(&fixture.project_b).unwrap();
        assert!(!project.live_run);
        assert!(!project.spawn_reserved);
        let pane = project.panes.pane(&fixture.pane_b1).unwrap();
        assert!(pane.current_run.is_none());
        assert!(pane.previous_runs.is_empty());
        assert_eq!(pane.shell_profile_id.as_str(), "pwsh");
        assert_eq!(
            restored
                .get(&fixture.project_b)
                .unwrap()
                .panes
                .pane(&fixture.pane_b2)
                .unwrap()
                .shell_profile_id
                .as_str(),
            "custom-shell"
        );
    }

    #[test]
    fn restore_rejects_cross_project_selection_and_malformed_snapshot() {
        let authority = AllocationAuthority::host();
        let fixture = Fixture::two_project_split();
        let roots = fixture.roots();
        let original =
            WorkspaceService::from_snapshot_roots(&authority, &fixture.snapshot, &roots).unwrap();
        let original_selected = original.selected().cloned();
        let mut cross = fixture.snapshot.clone();
        cross.selected_project_id = Nullable(Some(fixture.project_a.clone()));
        cross.selected_pane_id = Nullable(Some(fixture.pane_b2.clone()));
        assert_eq!(
            WorkspaceService::from_snapshot_roots(&authority, &cross, &roots)
                .err()
                .expect("cross-project restore should fail"),
            ErrorCode::PersistenceFailed
        );
        let mut malformed = fixture.snapshot.clone();
        malformed.layouts.clear();
        assert_eq!(
            WorkspaceService::from_snapshot_roots(&authority, &malformed, &roots)
                .err()
                .expect("malformed snapshot restore should fail"),
            ErrorCode::PersistenceFailed
        );
        assert_eq!(original.projects().len(), 2);
        assert_eq!(original.selected(), original_selected.as_ref());
        assert_eq!(
            original.get(&fixture.project_b).unwrap().panes.leaf_count(),
            2
        );
    }

    #[test]
    fn restore_allocation_failure_keeps_original_and_releases_charges() {
        let authority = AllocationAuthority::host();
        let fixture = Fixture::two_project_split();
        let roots = fixture.roots();
        let original =
            WorkspaceService::from_snapshot_roots(&authority, &fixture.snapshot, &roots).unwrap();
        let before = authority.snapshot().retained;
        #[cfg(debug_assertions)]
        {
            authority.fail_after_allocations(1);
            assert_eq!(
                WorkspaceService::from_snapshot_roots(&authority, &fixture.snapshot, &roots)
                    .err()
                    .expect("restore should fail after forced allocation failure"),
                ErrorCode::ResourceExhausted
            );
            assert_eq!(authority.snapshot().retained, before);
        }
        let filler = authority
            .claim(AllocationPool::Retained, RETAINED_BYTES - before)
            .unwrap();
        assert_eq!(
            WorkspaceService::from_snapshot_roots(&authority, &fixture.snapshot, &roots)
                .err()
                .expect("restore should fail when retained bytes are exhausted"),
            ErrorCode::ResourceExhausted
        );
        assert_eq!(original.projects().len(), 2);
        assert_eq!(original.selected(), Some(&fixture.project_b));
        assert_eq!(authority.snapshot().retained, RETAINED_BYTES);
        drop(filler);
        assert_eq!(authority.snapshot().retained, before);
    }

    #[test]
    fn restore_rejects_mismatched_observed_root_identity() {
        let authority = AllocationAuthority::host();
        let fixture = Fixture::two_project_split();
        let roots = fixture.roots();
        let original =
            WorkspaceService::from_snapshot_roots(&authority, &fixture.snapshot, &roots).unwrap();
        let wrong = identity(9);
        let mismatched = [
            RestoreRoot {
                identity: &wrong,
                actual_path: &fixture.path_a,
                input_path: &fixture.path_a,
            },
            RestoreRoot {
                identity: &fixture.identity_b,
                actual_path: &fixture.path_b,
                input_path: &fixture.path_b,
            },
        ];
        assert_eq!(
            WorkspaceService::from_snapshot_roots(&authority, &fixture.snapshot, &mismatched)
                .err()
                .expect("restore should fail for mismatched observed root identity"),
            ErrorCode::RootChanged
        );
        assert_eq!(original.projects().len(), 2);
        assert_eq!(
            original.get(&fixture.project_a).unwrap().identity.as_ref(),
            Some(&fixture.identity_a)
        );
    }

    #[test]
    fn pane_create_split_and_launch_keep_supplied_shell_profile() {
        let authority = AllocationAuthority::host();
        let mut workspace = WorkspaceService::new(&authority).unwrap();
        let project = project_id(1);
        workspace.seed(&authority, &[project.clone()]).unwrap();
        let first = pane_id(1);
        let second = pane_id(2);
        workspace
            .add_pane(
                &project,
                first.clone(),
                run_id(1),
                None,
                Axis::Vertical,
                "create-shell",
            )
            .unwrap();
        assert_eq!(
            workspace
                .panes(&project)
                .unwrap()
                .pane(&first)
                .unwrap()
                .shell_profile_id
                .as_str(),
            "create-shell"
        );
        assert!(workspace
            .panes(&project)
            .unwrap()
            .pane(&first)
            .unwrap()
            .provider_profile
            .0
            .is_none());
        workspace
            .add_pane(
                &project,
                second.clone(),
                run_id(2),
                Some(&first),
                Axis::Horizontal,
                "split-shell",
            )
            .unwrap();
        assert_eq!(
            workspace
                .panes(&project)
                .unwrap()
                .pane(&second)
                .unwrap()
                .shell_profile_id
                .as_str(),
            "split-shell"
        );
        workspace
            .set_pane_shell_profile(&project, &first, "first-launch")
            .unwrap();
        assert_eq!(
            workspace
                .panes(&project)
                .unwrap()
                .pane(&first)
                .unwrap()
                .shell_profile_id
                .as_str(),
            "first-launch"
        );
        workspace
            .set_pane_shell_profile(&project, &first, "second-launch")
            .unwrap();
        assert_eq!(
            workspace
                .panes(&project)
                .unwrap()
                .pane(&first)
                .unwrap()
                .shell_profile_id
                .as_str(),
            "second-launch"
        );
        assert_eq!(
            workspace
                .panes(&project)
                .unwrap()
                .pane(&second)
                .unwrap()
                .shell_profile_id
                .as_str(),
            "split-shell"
        );
    }
}
