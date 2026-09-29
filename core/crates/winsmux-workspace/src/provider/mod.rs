pub(crate) mod claude;
pub(crate) mod codex;
pub(crate) mod lifecycle;

use crate::contract::{ErrorCode, NonEmpty, Nullable, Provider};

pub(crate) fn launch_arguments(
    provider: Provider,
    model: &Nullable<NonEmpty>,
    effort: &Nullable<NonEmpty>,
) -> Result<Vec<String>, ErrorCode> {
    let validate = |value: &NonEmpty| {
        let text = value.as_str();
        !text.trim().is_empty() && !text.chars().any(char::is_control)
    };
    if model.0.as_ref().is_some_and(|value| !validate(value))
        || effort.0.as_ref().is_some_and(|value| !validate(value))
    {
        return Err(ErrorCode::InvalidRequest);
    }
    match provider {
        Provider::Codex => Ok(codex::arguments(model, effort)),
        Provider::Claude => Ok(claude::arguments(model, effort)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chosen(value: &str) -> Nullable<NonEmpty> {
        Nullable(Some(
            NonEmpty::new(value.to_owned()).expect("nonempty test value"),
        ))
    }

    #[test]
    fn cli_values_are_single_arguments_and_controls_are_rejected() {
        let model = chosen("model with space\\\"quote");
        let effort = chosen("unrecognized-but-explicit");
        assert_eq!(
            launch_arguments(Provider::Codex, &model, &effort),
            Ok(vec![
                "--model=model with space\\\"quote".to_owned(),
                "-c".to_owned(),
                "model_reasoning_effort=unrecognized-but-explicit".to_owned(),
            ])
        );
        assert_eq!(
            launch_arguments(Provider::Claude, &model, &effort),
            Ok(vec![
                "--model=model with space\\\"quote".to_owned(),
                "--effort=unrecognized-but-explicit".to_owned(),
            ])
        );
        assert_eq!(
            launch_arguments(Provider::Codex, &chosen("--help"), &chosen("--version")),
            Ok(vec![
                "--model=--help".to_owned(),
                "-c".to_owned(),
                "model_reasoning_effort=--version".to_owned(),
            ])
        );
        assert_eq!(
            launch_arguments(Provider::Claude, &chosen("--help"), &chosen("--version")),
            Ok(vec![
                "--model=--help".to_owned(),
                "--effort=--version".to_owned(),
            ])
        );
        assert_eq!(
            launch_arguments(Provider::Codex, &chosen("  "), &Nullable(None)),
            Err(ErrorCode::InvalidRequest)
        );
        assert_eq!(
            launch_arguments(Provider::Claude, &Nullable(None), &chosen("bad\nvalue")),
            Err(ErrorCode::InvalidRequest)
        );
    }
}
