use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommonContractPackage {
    pub version: String,
    pub surfaces: Vec<String>,
    pub vocabularies: CommonContractVocabularies,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommonContractVocabularies {
    pub runtime_provider_ids: CommonContractVocabulary,
    pub model_sources: CommonContractVocabulary,
    pub reasoning_efforts: CommonContractVocabulary,
    pub backend_capabilities: CommonContractVocabulary,
    pub prompt_transports: CommonContractVocabulary,
    pub model_readiness: CommonContractVocabulary,
    pub runtime_worker_readiness: CommonContractVocabulary,
    pub worker_pane_readiness: CommonContractVocabulary,
    pub agent_vault_command_providers: CommonContractVocabulary,
    pub benchmark_families: CommonContractVocabulary,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommonContractVocabulary {
    pub owner: String,
    pub values: Vec<String>,
    #[serde(default)]
    pub note: String,
}

impl CommonContractPackage {
    pub fn from_json(content: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(content)
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.version != "0.36.28" {
            return Err(format!(
                "unsupported common contract version: {}",
                self.version
            ));
        }

        assert_exact_values(
            "surfaces",
            &self.surfaces,
            &[
                "provider",
                "readiness",
                "manifest",
                "route",
                "capsule",
                "mailbox",
                "settings",
            ],
        )?;

        self.vocabularies.validate()?;
        assert_exact_values(
            "backend capabilities",
            &self.vocabularies.backend_capabilities.values,
            &["any", "agent-cli", "antigravity", "api_llm"],
        )?;

        let model_readiness = &self.vocabularies.model_readiness.values;
        let runtime_worker = &self.vocabularies.runtime_worker_readiness.values;
        let worker_pane = &self.vocabularies.worker_pane_readiness.values;

        for state in runtime_worker {
            if !model_readiness.contains(state) {
                return Err(format!(
                    "runtime worker readiness {} is not in model readiness",
                    state
                ));
            }
        }

        if model_readiness == worker_pane {
            return Err("model readiness and worker pane readiness must stay separate".to_string());
        }
        if model_readiness.iter().any(|value| value == "ready") {
            return Err("model readiness must not contain pane state ready".to_string());
        }
        if worker_pane.iter().any(|value| value == "selectable") {
            return Err(
                "worker pane readiness must not contain model state selectable".to_string(),
            );
        }
        assert_exact_values(
            "model readiness",
            model_readiness,
            &[
                "selectable",
                "candidate",
                "setup-required",
                "runnable",
                "blocked",
                "reference-only",
                "unavailable",
            ],
        )?;
        assert_exact_values(
            "runtime worker readiness",
            runtime_worker,
            &["runnable", "setup-required", "blocked"],
        )?;
        assert_exact_values(
            "worker pane readiness",
            worker_pane,
            &["ready", "blocked", "pending"],
        )?;

        assert_order(
            "reasoning efforts",
            &self.vocabularies.reasoning_efforts.values,
            "max",
            "xhigh",
        )?;

        Ok(())
    }
}

impl CommonContractVocabularies {
    fn validate(&self) -> Result<(), String> {
        for (name, vocabulary) in self.entries() {
            vocabulary.validate(name)?;
        }
        Ok(())
    }

    fn entries(&self) -> [(&'static str, &CommonContractVocabulary); 10] {
        [
            ("runtimeProviderIds", &self.runtime_provider_ids),
            ("modelSources", &self.model_sources),
            ("reasoningEfforts", &self.reasoning_efforts),
            ("backendCapabilities", &self.backend_capabilities),
            ("promptTransports", &self.prompt_transports),
            ("modelReadiness", &self.model_readiness),
            ("runtimeWorkerReadiness", &self.runtime_worker_readiness),
            ("workerPaneReadiness", &self.worker_pane_readiness),
            (
                "agentVaultCommandProviders",
                &self.agent_vault_command_providers,
            ),
            ("benchmarkFamilies", &self.benchmark_families),
        ]
    }
}

impl CommonContractVocabulary {
    fn validate(&self, name: &str) -> Result<(), String> {
        if self.owner.trim().is_empty() {
            return Err(format!("{} owner must be non-empty", name));
        }
        if self.values.is_empty() {
            return Err(format!("{} values must be non-empty", name));
        }
        for value in &self.values {
            if value.trim().is_empty() {
                return Err(format!("{} contains an empty value", name));
            }
        }
        if self.note.contains('\0') {
            return Err(format!("{} note must not contain NUL", name));
        }
        Ok(())
    }
}

fn assert_exact_values(name: &str, actual: &[String], expected: &[&str]) -> Result<(), String> {
    let expected = expected
        .iter()
        .map(|value| value.to_string())
        .collect::<Vec<_>>();
    if actual != expected {
        return Err(format!(
            "{} diverged: actual={:?} expected={:?}",
            name, actual, expected
        ));
    }
    Ok(())
}

fn assert_order(
    values_name: &str,
    values: &[String],
    before: &str,
    after: &str,
) -> Result<(), String> {
    let before_index = values
        .iter()
        .position(|value| value == before)
        .ok_or_else(|| format!("{} missing {}", values_name, before))?;
    let after_index = values
        .iter()
        .position(|value| value == after)
        .ok_or_else(|| format!("{} missing {}", values_name, after))?;
    if before_index > after_index {
        return Err(format!(
            "{} must keep {} before {}",
            values_name, before, after
        ));
    }
    Ok(())
}
