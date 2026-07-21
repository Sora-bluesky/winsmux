use std::io;

use serde_json::{json, Value};

use super::{find_provider_capability, ProviderCapabilityRegistry};

pub(super) fn builtin_provider_capability(provider_id: &str) -> Option<Value> {
    // Explicit mirror of
    // winsmux-core/scripts/settings.ps1:Get-BridgeBuiltinProviderCapability.
    // Keep only fields consumed by the Rust resolver/preview contract; the
    // PowerShell function remains the runtime source of truth.
    match provider_id.trim().to_ascii_lowercase().as_str() {
        "openrouter" => Some(json!({
            "adapter": "openai-compatible",
            "command": "openrouter",
            "model_options": [
                {"id": "provider-default", "label": "Provider default", "source": "provider-default"},
                {"id": "sakana/fugu-ultra", "label": "Sakana: Fugu Ultra", "source": "provider-api", "availability": "OpenRouter Models API"},
                {"id": "z-ai/glm-5.2", "label": "Z.ai: GLM 5.2", "source": "provider-api", "availability": "OpenRouter Models API"},
                {"id": "moonshotai/kimi-k2.7-code", "label": "MoonshotAI: Kimi K2.7 Code", "source": "provider-api", "availability": "OpenRouter Models API"}
            ],
            "model_sources": ["provider-default", "provider-api", "operator-override"],
            "reasoning_efforts": ["provider-default"],
            "local_access_note": "Hosted OpenRouter Models API via the local api_llm pane worker.",
            "harness_availability": "official-api",
            "credential_requirements": "OPENROUTER_API_KEY environment variable",
            "execution_backend": "openai-compatible-chat-completions",
            "runtime_requirements": "Set OPENROUTER_API_KEY in the process environment before starting the worker.",
            "analysis_posture": "hosted-api-worker",
            "prompt_transports": ["file", "stdin"],
            "auth_modes": ["api-key-env"],
            "supports_parallel_runs": true,
            "supports_interrupt": false,
            "supports_structured_result": true,
            "supports_file_edit": false,
            "supports_subagents": false,
            "supports_verification": true,
            "supports_consultation": true,
            "supports_context_reset": true
        })),
        "antigravity" => Some(json!({
            "adapter": "antigravity",
            "command": "agy",
            "model_options": [
                {"id": "provider-default", "label": "Provider default", "source": "provider-default"},
                {"id": "Gemini 3.5 Flash (High)", "label": "Gemini 3.5 Flash (High)", "source": "cli-discovery", "availability": "Antigravity CLI model picker"},
                {"id": "Gemini 3.5 Flash (Medium)", "label": "Gemini 3.5 Flash (Medium)", "source": "cli-discovery", "availability": "Antigravity CLI model picker"},
                {"id": "Gemini 3.5 Flash (Low)", "label": "Gemini 3.5 Flash (Low)", "source": "cli-discovery", "availability": "Antigravity CLI model picker"},
                {"id": "Gemini 3.1 Pro (High)", "label": "Gemini 3.1 Pro (High)", "source": "cli-discovery", "availability": "Antigravity CLI model picker"},
                {"id": "Gemini 3.1 Pro (Low)", "label": "Gemini 3.1 Pro (Low)", "source": "cli-discovery", "availability": "Antigravity CLI model picker"},
                {"id": "Claude Sonnet 4.6 (Thinking)", "label": "Claude Sonnet 4.6 (Thinking)", "source": "cli-discovery", "availability": "Antigravity CLI model picker"},
                {"id": "Claude Opus 4.6 (Thinking)", "label": "Claude Opus 4.6 (Thinking)", "source": "cli-discovery", "availability": "Antigravity CLI model picker"},
                {"id": "GPT-OSS 120B (Medium)", "label": "GPT-OSS 120B (Medium)", "source": "cli-discovery", "availability": "Antigravity CLI model picker"}
            ],
            "model_sources": ["provider-default", "cli-discovery", "operator-override"],
            "reasoning_efforts": ["provider-default"],
            "local_access_note": "Local Antigravity CLI account and model picker access.",
            "harness_availability": "official-cli",
            "credential_requirements": "local-cli-owned",
            "execution_backend": "antigravity-cli-print",
            "runtime_requirements": "Antigravity CLI agy installed in the pane environment.",
            "analysis_posture": "read-write-worker",
            "prompt_transports": ["argv", "file"],
            "auth_modes": ["antigravity-official-cli"],
            "local_interactive_oauth_modes": ["antigravity-official-cli"],
            "supports_parallel_runs": true,
            "supports_interrupt": false,
            "supports_structured_result": true,
            "supports_file_edit": false,
            "supports_subagents": false,
            "supports_verification": true,
            "supports_consultation": true,
            "supports_context_reset": true
        })),
        "grok-build" => Some(json!({
            "adapter": "grok-build",
            "command": "grok",
            "model_options": [
                {"id": "provider-default", "label": "Provider default", "source": "provider-default"},
                {"id": "grok-build", "label": "Grok 4.3", "source": "cli-discovery", "availability": "Grok Build models"},
                {"id": "grok-composer-2.5-fast", "label": "Composer 2.5 Fast", "source": "cli-discovery", "availability": "Grok Build models"}
            ],
            "model_sources": ["provider-default", "cli-discovery", "operator-override"],
            "reasoning_efforts": ["provider-default"],
            "local_access_note": "Local Grok Build account and model picker access.",
            "harness_availability": "official-cli",
            "credential_requirements": "local-cli-owned",
            "execution_backend": "agent-cli",
            "runtime_requirements": "Grok Build CLI grok installed in the pane environment.",
            "analysis_posture": "read-write-worker",
            "prompt_transports": ["argv", "file"],
            "auth_modes": ["grok-build-local"],
            "local_interactive_oauth_modes": ["grok-build-local"],
            "supports_parallel_runs": true,
            "supports_interrupt": false,
            "supports_structured_result": true,
            "supports_file_edit": true,
            "supports_subagents": false,
            "supports_verification": true,
            "supports_consultation": true,
            "supports_context_reset": true
        })),
        _ => None,
    }
}

pub(super) fn resolve_provider_capability_in_registry(
    registry: &ProviderCapabilityRegistry,
    provider_id: &str,
) -> io::Result<Option<Value>> {
    if let Some(capability) = find_provider_capability(registry, provider_id) {
        return Ok(Some(capability.clone()));
    }
    if let Some(capability) = builtin_provider_capability(provider_id) {
        return Ok(Some(capability));
    }
    if registry.providers.is_empty() {
        return Ok(None);
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("Provider capability '{provider_id}' was not found."),
    ))
}
