use crate::contract::{ArtifactChoiceData, ArtifactId, ArtifactRef, ErrorCode, OwnedCapacity, ProjectId, RootIdentity};
use crate::host::admission::{AllocationAuthority, AllocationPool, CapacityCharge, ChargedVec};
use crate::store::root_identity::{observe_project_file, ObservedFile};

pub struct ArtifactEntry {
    pub reference: ArtifactRef,
    pub root_identity: RootIdentity,
    pub file_identity: RootIdentity,
    pub epoch: u64,
    _charge: CapacityCharge,
}

pub struct ArtifactRegistry {
    entries: ChargedVec<ArtifactEntry>,
    choices: ChargedVec<ChoiceEntry>,
    epoch: u64,
}

pub struct ChoiceEntry {
    pub project_id: ProjectId,
    pub choice: ArtifactChoiceData,
    pub epoch: u64,
    _charge: CapacityCharge,
}

impl ArtifactRegistry {
    pub fn new(authority: &AllocationAuthority) -> Self {
        Self {
            entries: ChargedVec::empty(authority, AllocationPool::Retained),
            choices: ChargedVec::empty(authority, AllocationPool::Retained),
            epoch: 0,
        }
    }

    pub fn epoch(&self) -> u64 { self.epoch }

    pub fn get(&self, id: &ArtifactId) -> Option<&ArtifactEntry> {
        self.entries.iter().find(|entry| entry.epoch == self.epoch && &entry.reference.artifact_id == id)
    }

    pub fn project_entries<'a>(&'a self, id: &'a ProjectId) -> impl Iterator<Item = &'a ArtifactEntry> + 'a {
        self.entries.iter().filter(move |entry| entry.epoch == self.epoch && &entry.reference.project_id == id)
    }

    pub fn project_choices<'a>(&'a self, id: &'a ProjectId) -> impl Iterator<Item = &'a ChoiceEntry> + 'a {
        self.choices.iter().filter(move |entry| entry.epoch == self.epoch && &entry.project_id == id)
    }

    pub fn choice(&self, project_id: &ProjectId, left: &ArtifactId, right: &ArtifactId) -> Option<&ChoiceEntry> {
        self.choices.iter().find(|entry| {
            entry.epoch == self.epoch && &entry.project_id == project_id
                && &entry.choice.left_artifact_id == left && &entry.choice.right_artifact_id == right
        })
    }

    pub fn reserve_choice(
        &mut self,
        authority: &AllocationAuthority,
        pool: AllocationPool,
        project_id: &ProjectId,
        choice: &ArtifactChoiceData,
    ) -> Result<Option<CapacityCharge>, ErrorCode> {
        if self.choice(project_id, &choice.left_artifact_id, &choice.right_artifact_id).is_some() {
            return Ok(None);
        }
        let charge = authority.claim(
            AllocationPool::Retained,
            project_id.owned_capacity().saturating_add(choice.owned_capacity()).max(1),
        ).map_err(|_| ErrorCode::ResourceExhausted)?;
        let needed = self.choices.len().checked_add(1).ok_or(ErrorCode::ResourceExhausted)?;
        if needed > self.choices.capacity_elements() {
            let bytes = needed.checked_mul(std::mem::size_of::<ChoiceEntry>())
                .ok_or(ErrorCode::ResourceExhausted)?;
            self.choices.try_grow_retained(authority, pool, needed, bytes)
                .map_err(|_| ErrorCode::ResourceExhausted)?;
        }
        Ok(Some(charge))
    }

    pub fn publish_choice(
        &mut self,
        project_id: ProjectId,
        choice: ArtifactChoiceData,
        charge: Option<CapacityCharge>,
    ) -> Result<(), ErrorCode> {
        if let Some(existing) = self.choices.iter_mut().find(|entry| {
            entry.epoch == self.epoch && entry.project_id == project_id
                && entry.choice.left_artifact_id == choice.left_artifact_id
                && entry.choice.right_artifact_id == choice.right_artifact_id
        }) {
            existing.choice = choice;
            return Ok(());
        }
        let charge = charge.ok_or(ErrorCode::ResourceExhausted)?;
        self.choices.try_push(ChoiceEntry {
            project_id,
            choice,
            epoch: self.epoch,
            _charge: charge,
        }).map_err(|_| ErrorCode::ResourceExhausted)
    }

    pub fn reserve_entry(
        &mut self,
        authority: &AllocationAuthority,
        pool: AllocationPool,
        reference: &ArtifactRef,
    ) -> Result<CapacityCharge, ErrorCode> {
        use crate::contract::OwnedCapacity;
        // Root and leaf identities each own 16 + 32 hexadecimal bytes.
        let charge = authority
            .claim(AllocationPool::Retained, reference.owned_capacity().saturating_add(96).max(1))
            .map_err(|_| ErrorCode::ResourceExhausted)?;
        let needed = self.entries.len().checked_add(1).ok_or(ErrorCode::ResourceExhausted)?;
        if needed > self.entries.capacity_elements() {
            let bytes = needed.checked_mul(std::mem::size_of::<ArtifactEntry>())
                .ok_or(ErrorCode::ResourceExhausted)?;
            self.entries.try_grow_retained(authority, pool, needed, bytes)
                .map_err(|_| ErrorCode::ResourceExhausted)?;
        }
        Ok(charge)
    }

    pub fn publish(
        &mut self,
        reference: ArtifactRef,
        root_identity: RootIdentity,
        file_identity: RootIdentity,
        charge: CapacityCharge,
    ) -> Result<(), ErrorCode> {
        self.entries.try_push(ArtifactEntry {
            reference,
            root_identity,
            file_identity,
            epoch: self.epoch,
            _charge: charge,
        }).map_err(|_| ErrorCode::ResourceExhausted)
    }

    pub fn forget(&mut self, id: &ProjectId) {
        let mut index = 0;
        while index < self.entries.len() {
            if &self.entries[index].reference.project_id == id {
                self.entries.remove(index);
            } else {
                index += 1;
            }
        }
        let mut index = 0;
        while index < self.choices.len() {
            if &self.choices[index].project_id == id {
                self.choices.remove(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn invalidate_all(&mut self) {
        self.epoch = self.epoch.wrapping_add(1);
        self.entries.clear();
        self.choices.clear();
    }
}

pub fn open(
    project_path: &str,
    root_identity: &RootIdentity,
    relative_path: &str,
    authority: &AllocationAuthority,
    pool: AllocationPool,
) -> Result<ObservedFile, ErrorCode> {
    observe_project_file(project_path, root_identity, relative_path, authority, pool)
}
