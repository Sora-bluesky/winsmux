use crate::contract::{NonEmpty, Nullable};

pub(super) fn arguments(model: &Nullable<NonEmpty>, effort: &Nullable<NonEmpty>) -> Vec<String> {
    let mut args = Vec::new();
    if let Some(model) = &model.0 {
        args.push(format!("--model={}", model.as_str()));
    }
    if let Some(effort) = &effort.0 {
        args.push("-c".to_owned());
        args.push(format!("model_reasoning_effort={}", effort.as_str()));
    }
    args
}
