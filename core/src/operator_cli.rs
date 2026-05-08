use std::{
    collections::{BTreeMap, HashMap},
    env, fs,
    io::{self, Write},
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicU32, Ordering},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

use crate::event_contract::{parse_event_jsonl, EventRecord};
use crate::ledger::{
    attach_evidence_chain_to_event, public_changed_files, LedgerBoardPayload, LedgerDigestItem,
    LedgerDigestPayload, LedgerExplainPayload, LedgerInboxPayload, LedgerRunsPayload,
    LedgerSnapshot, LedgerStatusPayload,
};
use crate::machine_contract::machine_contract_catalog;
use crate::types::VERSION;

static REVIEW_REQUEST_COUNTER: AtomicU32 = AtomicU32::new(0);
static ATOMIC_WRITE_COUNTER: AtomicU32 = AtomicU32::new(0);

const FILE_LOCK_TIMEOUT: Duration = Duration::from_millis(120_000);
const FILE_LOCK_STALE_AFTER: Duration = Duration::from_secs(60);
const FILE_LOCK_RETRY_DELAY: Duration = Duration::from_millis(50);

pub fn is_operator_status_invocation(args: &[&String]) -> bool {
    args.iter()
        .any(|arg| matches!(arg.as_str(), "--json" | "-h" | "--help"))
}

pub fn run_status_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux status --json [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("status", args, 0)?;
    require_json("status", &options)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    let payload = LedgerStatusPayload::from_snapshot(
        generated_at(),
        project_dir_string(&options.project_dir),
        &snapshot,
    );
    write_json(&payload)
}

pub fn run_board_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux board [--json] [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("board", args, 0)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    let payload = LedgerBoardPayload::from_projection(
        generated_at(),
        project_dir_string(&options.project_dir),
        snapshot.board_projection(),
    );
    if options.json {
        return write_json(&payload);
    }
    let payload = payload_to_value(&payload)?;
    print_board_table(&payload)
}

pub fn run_inbox_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux inbox [--json] [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("inbox", args, 0)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    let payload = LedgerInboxPayload::from_projection(
        generated_at(),
        project_dir_string(&options.project_dir),
        snapshot.inbox_projection(),
    );
    if options.json {
        write_json(&payload)
    } else {
        let payload = payload_to_value(&payload)?;
        print_inbox_table(&payload)
    }
}

pub fn run_digest_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux digest [--json] [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("digest", args, 0)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    let payload = LedgerDigestPayload::from_projection(
        generated_at(),
        project_dir_string(&options.project_dir),
        snapshot.digest_projection(),
    );
    if options.json {
        write_json(&payload)
    } else {
        let payload = payload_to_value(&payload)?;
        print_digest_text(&payload)
    }
}

pub fn run_desktop_summary_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux desktop-summary [--json] [--stream] [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_desktop_summary_options(args)?;

    if options.stream {
        return stream_desktop_summary(&options);
    }

    let snapshot = load_snapshot(&options.project_dir)?;
    let payload = desktop_summary_payload(&snapshot, &options.project_dir)?;
    if options.json {
        return write_json(&payload);
    }

    let board_count = payload["board"]["summary"]["pane_count"]
        .as_u64()
        .unwrap_or(0);
    let inbox_count = payload["inbox"]["summary"]["item_count"]
        .as_u64()
        .unwrap_or(0);
    let digest_count = payload["digest"]["summary"]["item_count"]
        .as_u64()
        .unwrap_or(0);
    let projection_count = payload["run_projections"]
        .as_array()
        .map(Vec::len)
        .unwrap_or(0);
    println!(
        "Desktop summary: {board_count} panes, {inbox_count} inbox items, {digest_count} digest items, {projection_count} projections"
    );
    Ok(())
}

pub fn run_meta_plan_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("meta-plan"));
        return Ok(());
    }

    let options = parse_meta_plan_options(args)?;
    let run = build_meta_plan_run(&options)?;
    if options.json {
        return write_json(&run.payload);
    }

    println!("Meta-planning run: {}", run.run_id);
    println!("Roles: {}", run.role_count);
    println!("Review rounds: {}", run.review_rounds);
    println!("Integrated plan: {}", run.integrated_plan_ref);
    println!("Audit log: {}", run.audit_log_ref);
    Ok(())
}

pub fn run_provider_capabilities_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux provider-capabilities [provider] [--json] [--project-dir <path>]");
        return Ok(());
    }

    let options = parse_provider_capabilities_options(args)?;
    let registry_path = provider_capability_registry_path(&options.project_dir);
    let registry = read_provider_capability_registry(&registry_path)?;

    if let Some(provider_id) = options.provider_id.as_deref() {
        let Some(capabilities) = find_provider_capability(&registry, provider_id) else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("provider capability '{provider_id}' was not found."),
            ));
        };
        let payload = json!({
            "provider_id": provider_id,
            "capabilities": capabilities,
            "registry_path": registry_path.display().to_string(),
        });
        if options.json {
            return write_json(&payload);
        }

        println!("provider capability {provider_id}");
        if let Some(entries) = capabilities.as_object() {
            for (key, value) in entries {
                println!("  {key}: {}", provider_capability_value_text(value));
            }
        }
        return Ok(());
    }

    let payload = json!({
        "version": registry.version,
        "registry_path": registry_path.display().to_string(),
        "providers": registry.providers,
    });
    if options.json {
        return write_json(&payload);
    }

    if registry.providers.is_empty() {
        println!("provider capabilities: none");
        return Ok(());
    }

    println!("provider capabilities");
    for provider_id in registry.providers.keys() {
        println!("  {provider_id}");
    }
    Ok(())
}

pub fn run_operator_jobs_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("operator-jobs"));
        return Ok(());
    }

    let options = parse_operator_jobs_options(args)?;
    let payload = match options.action.as_str() {
        "catalog" => operator_jobs_catalog_payload(),
        "list" => operator_jobs_list_payload(&options.project_dir)?,
        "create" => operator_jobs_create(&options)?,
        "run" => operator_jobs_start_run(&options)?,
        "pause" => operator_jobs_pause(&options)?,
        "update" => operator_jobs_update(&options)?,
        "delete" => operator_jobs_delete(&options)?,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                usage_for("operator-jobs"),
            ))
        }
    };

    if options.json {
        return write_json(&payload);
    }

    println!(
        "operator-jobs {}: {}",
        options.action,
        payload["summary"]["message"].as_str().unwrap_or("ok")
    );
    Ok(())
}

pub fn run_skills_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("skills"));
        return Ok(());
    }
    let json = parse_json_only_options("skills", args)?;
    let payload = progressive_skills_catalog();
    if json {
        return write_json(&payload);
    }

    println!("Progressive skills catalog");
    if let Some(packs) = payload["workflow_pack_registry"]["packs"].as_array() {
        println!("Workflow packs");
        for pack in packs {
            println!(
                "- {}: {}",
                pack["id"].as_str().unwrap_or_default(),
                pack["metadata"]["purpose"].as_str().unwrap_or_default()
            );
        }
    }
    println!("Skill contracts");
    for skill in payload["skills"].as_array().into_iter().flatten() {
        println!(
            "- {}: {}",
            skill["id"].as_str().unwrap_or_default(),
            skill["purpose"].as_str().unwrap_or_default()
        );
        if let Some(commands) = skill["commands"].as_array() {
            let command_text = commands
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(", ");
            if !command_text.trim().is_empty() {
                println!("  commands: {command_text}");
            }
        }
    }
    Ok(())
}

fn progressive_skills_catalog() -> Value {
    json!({
        "contract_version": 1,
        "packet_type": "progressive_skills_catalog",
        "command": "skills",
        "generated_at": generated_at(),
        "private_skill_bodies_allowed": false,
        "freeform_body_stored": false,
        "private_guidance_stored": false,
        "local_reference_paths_stored": false,
        "operator_judgement_boundary": "operator keeps final task split, merge, release, and human-escalation decisions",
        "workflow_pack_registry": {
            "contract_version": 1,
            "public_contract_only": true,
            "private_skill_bodies_allowed": false,
            "local_absolute_paths_allowed": false,
            "discovery": {
                "contract_version": 1,
                "supported_levels": ["builtin", "user", "repository"],
                "sources": [
                    {
                        "level": "builtin",
                        "source_ref": "winsmux:operator-contract",
                        "selection_reason": "built in public workflow packs are always available",
                        "public_contract_only": true,
                        "private_skill_bodies_allowed": false,
                        "local_absolute_paths_allowed": false
                    },
                    {
                        "level": "user",
                        "source_ref": "user-workflow-packs",
                        "selection_reason": "user-level workflow packs may extend public contracts without exposing local paths or private bodies",
                        "public_contract_only": true,
                        "private_skill_bodies_allowed": false,
                        "local_absolute_paths_allowed": false
                    },
                    {
                        "level": "repository",
                        "source_ref": "repository-workflow-packs",
                        "selection_reason": "repository-level workflow packs may describe task-local contracts from tracked contributor or public docs",
                        "public_contract_only": true,
                        "private_skill_bodies_allowed": false,
                        "local_absolute_paths_allowed": false
                    }
                ],
                "selection_policy": [
                    "prefer repository packs when the task references repository contracts or tracked docs",
                    "fall back to user packs when no repository pack matches",
                    "fall back to builtin packs when no user or repository pack matches",
                    "derive selected_pack_id, selected_level, and selection_reason only after an explicit operator or workflow request"
                ],
                "privacy_guards": [
                    "do not publish private skill bodies",
                    "do not publish user home paths or repository absolute paths",
                    "publish only stable source_ref values and tracked relative supporting files"
                ]
            },
            "packs": [
                {
                    "id": "run-read-models",
                    "metadata": {
                        "display_name": "Run read models",
                        "purpose": "inspect current runs before assigning follow-up work",
                        "status": "available",
                        "review_role": "operator"
                    },
                    "scope": [
                        "read run summaries",
                        "inspect run evidence",
                        "prepare follow-up context"
                    ],
                    "commands": ["runs --json", "explain <run_id> --json"],
                    "supporting_files": ["README.md", "docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux public operator contract",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false
                    },
                    "evidence_requirements": ["context_contract", "knowledge_layer", "run_insights"],
                    "operator_judgement_boundary": "use read models as evidence, not as automatic merge permission"
                },
                {
                    "id": "compare-and-promote",
                    "metadata": {
                        "display_name": "Compare and promote",
                        "purpose": "compare runs and export a reusable follow-up input",
                        "status": "available",
                        "review_role": "reviewer"
                    },
                    "scope": [
                        "compare run outputs",
                        "surface winner evidence",
                        "prepare follow-up candidate contracts"
                    ],
                    "commands": ["compare runs <left_run_id> <right_run_id> --json", "compare promote <run_id> --json"],
                    "supporting_files": ["docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux compare coordination contract",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false
                    },
                    "evidence_requirements": ["comparison_evidence", "playbook_template_contract", "security_verdict"],
                    "operator_judgement_boundary": "operator chooses whether the exported candidate should become work"
                },
                {
                    "id": "guarded-release",
                    "metadata": {
                        "display_name": "Guarded release",
                        "purpose": "check release gates before tag or merge automation",
                        "status": "available",
                        "review_role": "tester"
                    },
                    "scope": [
                        "collect release gate evidence",
                        "check public surface safety",
                        "report publish blockers"
                    ],
                    "commands": ["guard --json", "manual-checklist --json", "legacy-compat-gate --json"],
                    "supporting_files": ["docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux release gate contract",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false
                    },
                    "evidence_requirements": ["git_guard", "public_surface_audit", "manual_validation"],
                    "operator_judgement_boundary": "operator resolves failed gates before publishing"
                },
                {
                    "id": "scheduled-operator-jobs",
                    "metadata": {
                        "display_name": "Scheduled operator jobs",
                        "purpose": "record one-time or recurring maintenance jobs with evidence and approval gates",
                        "status": "available",
                        "review_role": "operator"
                    },
                    "scope": [
                        "record maintenance job contracts",
                        "start fresh run records",
                        "keep destructive changes pending approval"
                    ],
                    "commands": ["operator-jobs catalog --json", "operator-jobs create <job_id> --kind <kind> --json", "operator-jobs run <job_id> --json"],
                    "supporting_files": ["docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux scheduled operator job contract",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false
                    },
                    "evidence_requirements": ["fresh_run_record", "evidence_records", "approval_gate"],
                    "operator_judgement_boundary": "destructive maintenance changes remain pending until explicit operator approval"
                },
                {
                    "id": "provider-routing",
                    "metadata": {
                        "display_name": "Provider routing",
                        "purpose": "inspect provider capability and dry-run assignment decisions",
                        "status": "available",
                        "review_role": "operator"
                    },
                    "scope": [
                        "read provider capability",
                        "check task routing policy",
                        "explain assignment constraints"
                    ],
                    "commands": ["provider-capabilities --json", "assign --task <TASK-ID> --json"],
                    "supporting_files": ["docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux provider capability contract",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false
                    },
                    "evidence_requirements": ["provider_capability", "task_policy", "approval_policy"],
                    "operator_judgement_boundary": "operator may override routing when task risk or budget requires it"
                },
                {
                    "id": "repository-skill-discovery",
                    "metadata": {
                        "display_name": "Repository skill discovery",
                        "purpose": "discover user-level and repository-level workflow packs without exposing private material",
                        "status": "available",
                        "review_role": "operator"
                    },
                    "scope": [
                        "discover workflow pack source levels",
                        "select the narrowest matching public contract",
                        "prepare scoped supporting-file load plans"
                    ],
                    "commands": ["skills --json"],
                    "supporting_files": ["docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux workflow pack discovery contract",
                        "source_level": "repository",
                        "source_ref": "repository-workflow-packs",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false,
                        "local_absolute_path_stored": false
                    },
                    "discovery": {
                        "available_source_levels": ["user", "repository"],
                        "selected_level": "repository",
                        "selection_reason": "repository contracts take precedence when tracked docs define the workflow pack boundary"
                    },
                    "loading_plan": {
                        "minimum_supporting_files": ["docs/operator-model.md"],
                        "excluded": ["private skill bodies", "local absolute paths", "generated runtime artifacts"],
                        "public_contract_only": true
                    },
                    "evidence_requirements": ["workflow_pack_registry", "discovery_source_metadata", "scoped_loading_plan"],
                    "operator_judgement_boundary": "operator decides whether discovered packs are sufficient for the current task"
                },
                {
                    "id": "documentation-refresh",
                    "metadata": {
                        "display_name": "Documentation refresh",
                        "purpose": "refresh public documentation from observed product behavior",
                        "status": "template",
                        "review_role": "writer"
                    },
                    "scope": [
                        "identify public documentation surfaces",
                        "compare documented behavior with current commands",
                        "report wording or coverage gaps"
                    ],
                    "commands": ["skills --json", "guard --json"],
                    "supporting_files": ["README.md", "docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux workflow pack registry contract",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false
                    },
                    "evidence_requirements": ["doc_surface_list", "behavior_evidence", "public_safety_review"],
                    "required_evidence_fields": ["changed_docs", "source_commands", "public_safety_notes", "open_questions"],
                    "expected_result_fields": ["workflow_pack_id", "status", "evidence", "doc_update_summary", "operator_decision"],
                    "operator_judgement_boundary": "operator decides whether documentation gaps block release or become follow-up work"
                },
                {
                    "id": "ci-diagnosis",
                    "metadata": {
                        "display_name": "CI diagnosis",
                        "purpose": "diagnose failing automation without treating reruns as proof",
                        "status": "template",
                        "review_role": "tester"
                    },
                    "scope": [
                        "collect failing job evidence",
                        "separate environment failures from code failures",
                        "recommend the next verification command"
                    ],
                    "commands": ["runs --json", "explain <run_id> --json", "guard --json"],
                    "supporting_files": ["docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux workflow pack registry contract",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false
                    },
                    "evidence_requirements": ["failing_check", "log_excerpt", "reproduction_command", "rerun_evidence"],
                    "required_evidence_fields": ["check_name", "failure_summary", "first_bad_signal", "local_reproduction", "next_verification"],
                    "expected_result_fields": ["workflow_pack_id", "status", "evidence", "diagnosis", "operator_decision"],
                    "operator_judgement_boundary": "operator decides whether the diagnosis is enough to merge, retry, or escalate"
                },
                {
                    "id": "issue-dedupe",
                    "metadata": {
                        "display_name": "Issue dedupe",
                        "purpose": "compare a new problem report with existing tracked work",
                        "status": "template",
                        "review_role": "triager"
                    },
                    "scope": [
                        "summarize the observed problem",
                        "compare symptoms and root-cause evidence",
                        "recommend reuse or new tracking"
                    ],
                    "commands": ["skills --json", "runs --json", "explain <run_id> --json"],
                    "supporting_files": ["docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux workflow pack registry contract",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false
                    },
                    "evidence_requirements": ["problem_statement", "candidate_issue_refs", "matching_symptoms", "difference_summary"],
                    "required_evidence_fields": ["new_symptom", "candidate_refs", "match_reason", "non_match_reason", "recommended_tracking"],
                    "expected_result_fields": ["workflow_pack_id", "status", "evidence", "dedupe_recommendation", "operator_decision"],
                    "operator_judgement_boundary": "operator decides whether to reuse existing tracking or create a new issue"
                },
                {
                    "id": "web-quality-check",
                    "metadata": {
                        "display_name": "Web quality check",
                        "purpose": "check web accessibility and performance evidence before accepting UI work",
                        "status": "template",
                        "review_role": "tester"
                    },
                    "scope": [
                        "collect accessibility findings",
                        "collect responsive viewport evidence",
                        "collect performance budget evidence"
                    ],
                    "commands": ["skills --json", "guard --json"],
                    "supporting_files": ["docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux workflow pack registry contract",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false
                    },
                    "evidence_requirements": ["accessibility_report", "viewport_evidence", "performance_budget", "interaction_risk"],
                    "required_evidence_fields": ["tested_routes", "viewport_matrix", "accessibility_findings", "performance_findings", "blocking_risks"],
                    "expected_result_fields": ["workflow_pack_id", "status", "evidence", "quality_verdict", "operator_decision"],
                    "operator_judgement_boundary": "operator decides whether remaining web quality risks block acceptance"
                },
                {
                    "id": "mcp-tool-builder",
                    "metadata": {
                        "display_name": "MCP tool builder",
                        "purpose": "define and validate a Model Context Protocol tool contract",
                        "status": "template",
                        "review_role": "builder"
                    },
                    "scope": [
                        "define tool input and output schema",
                        "document side effects and safety boundaries",
                        "collect smoke-test evidence"
                    ],
                    "commands": ["provider-capabilities --json", "skills --json", "guard --json"],
                    "supporting_files": ["docs/operator-model.md"],
                    "provenance": {
                        "source": "winsmux workflow pack registry contract",
                        "public_contract_only": true,
                        "private_skill_body_stored": false,
                        "private_material_referenced": false
                    },
                    "evidence_requirements": ["tool_schema", "transport_contract", "safety_boundary", "smoke_test"],
                    "required_evidence_fields": ["tool_name", "input_schema", "output_schema", "side_effects", "smoke_result"],
                    "expected_result_fields": ["workflow_pack_id", "status", "evidence", "tool_contract_summary", "operator_decision"],
                    "operator_judgement_boundary": "operator decides whether the tool contract is safe enough to enable"
                }
            ]
        },
        "workflow_execution_contract": {
            "contract_version": 1,
            "entrypoint": "winsmux skills --json",
            "execution_model": "operator-mediated workflow pack execution",
            "private_skill_bodies_allowed": false,
            "local_absolute_paths_allowed": false,
            "required_request_fields": ["workflow_pack_id", "task_summary", "evidence_references"],
            "required_result_fields": ["workflow_pack_id", "status", "evidence", "operator_decision"],
            "execution_steps": [
                "select a workflow pack by public id",
                "collect required evidence from public commands or repository docs",
                "return a result contract without private bodies or local absolute paths",
                "leave task split, merge, release, and escalation decisions to the operator"
            ],
            "selection_result_fields": ["selected_pack_id", "selected_level", "selection_reason", "source_ref"],
            "scoped_loading_plan_fields": ["selected_pack_id", "minimum_supporting_files", "load_order", "excluded"],
            "operator_judgement_boundaries": [
                "operator keeps final task split decisions",
                "operator keeps final merge and release decisions",
                "operator keeps human escalation decisions"
            ],
            "forbidden_payloads": [
                "private skill bodies",
                "local absolute paths",
                "freeform private guidance"
            ]
        },
        "skills": [
            {
                "id": "run-read-models",
                "purpose": "inspect current runs before assigning follow-up work",
                "commands": ["runs --json", "explain <run_id> --json"],
                "required_evidence": ["context_contract", "knowledge_layer", "run_insights"],
                "review_role": "operator",
                "operator_judgement_boundary": "use read models as evidence, not as automatic merge permission",
                "public_contract_only": true,
                "private_skill_body_stored": false
            },
            {
                "id": "compare-and-promote",
                "purpose": "compare two runs and export a reusable follow-up input",
                "commands": ["compare runs <left_run_id> <right_run_id> --json", "compare promote <run_id> --json"],
                "required_evidence": ["comparison_evidence", "playbook_template_contract", "security_verdict"],
                "review_role": "reviewer",
                "operator_judgement_boundary": "operator chooses whether the exported candidate should become work",
                "public_contract_only": true,
                "private_skill_body_stored": false
            },
            {
                "id": "guarded-release",
                "purpose": "check release gates before tag or merge automation",
                "commands": ["guard --json", "manual-checklist --json", "legacy-compat-gate --json"],
                "required_evidence": ["git_guard", "public_surface_audit", "manual_validation"],
                "review_role": "tester",
                "operator_judgement_boundary": "operator resolves failed gates before publishing",
                "public_contract_only": true,
                "private_skill_body_stored": false
            },
            {
                "id": "scheduled-operator-jobs",
                "purpose": "record scheduled maintenance job contracts, fresh runs, evidence, and approval gates",
                "commands": ["operator-jobs catalog --json", "operator-jobs list --json", "operator-jobs run <job_id> --json"],
                "required_evidence": ["fresh_run_record", "evidence_records", "approval_gate"],
                "review_role": "operator",
                "operator_judgement_boundary": "destructive maintenance changes remain pending until explicit operator approval",
                "public_contract_only": true,
                "private_skill_body_stored": false
            },
            {
                "id": "provider-routing",
                "purpose": "inspect provider capability and dry-run assignment decisions",
                "commands": ["provider-capabilities --json", "assign --task <TASK-ID> --json"],
                "required_evidence": ["provider_capability", "task_policy", "approval_policy"],
                "review_role": "operator",
                "operator_judgement_boundary": "operator may override routing when task risk or budget requires it",
                "public_contract_only": true,
                "private_skill_body_stored": false
            },
            {
                "id": "repository-skill-discovery",
                "purpose": "discover user-level and repository-level workflow packs without exposing private material",
                "commands": ["skills --json"],
                "required_evidence": ["workflow_pack_registry", "discovery_source_metadata", "scoped_loading_plan"],
                "review_role": "operator",
                "operator_judgement_boundary": "operator decides whether discovered packs are sufficient for the current task",
                "public_contract_only": true,
                "private_skill_body_stored": false
            },
            {
                "id": "documentation-refresh",
                "purpose": "refresh public documentation from observed product behavior",
                "commands": ["skills --json", "guard --json"],
                "required_evidence": ["doc_surface_list", "behavior_evidence", "public_safety_review"],
                "required_evidence_fields": ["changed_docs", "source_commands", "public_safety_notes", "open_questions"],
                "review_role": "writer",
                "operator_judgement_boundary": "operator decides whether documentation gaps block release or become follow-up work",
                "public_contract_only": true,
                "private_skill_body_stored": false
            },
            {
                "id": "ci-diagnosis",
                "purpose": "diagnose failing automation without treating reruns as proof",
                "commands": ["runs --json", "explain <run_id> --json", "guard --json"],
                "required_evidence": ["failing_check", "log_excerpt", "reproduction_command", "rerun_evidence"],
                "required_evidence_fields": ["check_name", "failure_summary", "first_bad_signal", "local_reproduction", "next_verification"],
                "review_role": "tester",
                "operator_judgement_boundary": "operator decides whether the diagnosis is enough to merge, retry, or escalate",
                "public_contract_only": true,
                "private_skill_body_stored": false
            },
            {
                "id": "issue-dedupe",
                "purpose": "compare a new problem report with existing tracked work",
                "commands": ["skills --json", "runs --json", "explain <run_id> --json"],
                "required_evidence": ["problem_statement", "candidate_issue_refs", "matching_symptoms", "difference_summary"],
                "required_evidence_fields": ["new_symptom", "candidate_refs", "match_reason", "non_match_reason", "recommended_tracking"],
                "review_role": "triager",
                "operator_judgement_boundary": "operator decides whether to reuse existing tracking or create a new issue",
                "public_contract_only": true,
                "private_skill_body_stored": false
            },
            {
                "id": "web-quality-check",
                "purpose": "check web accessibility and performance evidence before accepting UI work",
                "commands": ["skills --json", "guard --json"],
                "required_evidence": ["accessibility_report", "viewport_evidence", "performance_budget", "interaction_risk"],
                "required_evidence_fields": ["tested_routes", "viewport_matrix", "accessibility_findings", "performance_findings", "blocking_risks"],
                "review_role": "tester",
                "operator_judgement_boundary": "operator decides whether remaining web quality risks block acceptance",
                "public_contract_only": true,
                "private_skill_body_stored": false
            },
            {
                "id": "mcp-tool-builder",
                "purpose": "define and validate a Model Context Protocol tool contract",
                "commands": ["provider-capabilities --json", "skills --json", "guard --json"],
                "required_evidence": ["tool_schema", "transport_contract", "safety_boundary", "smoke_test"],
                "required_evidence_fields": ["tool_name", "input_schema", "output_schema", "side_effects", "smoke_result"],
                "review_role": "builder",
                "operator_judgement_boundary": "operator decides whether the tool contract is safe enough to enable",
                "public_contract_only": true,
                "private_skill_body_stored": false
            }
        ]
    })
}

pub fn run_machine_contract_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("machine-contract"));
        return Ok(());
    }

    let json = parse_machine_contract_options(args)?;
    if !json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "winsmux machine-contract currently supports only --json in the Rust CLI.",
        ));
    }
    write_json(&machine_contract_catalog())
}

pub fn run_rust_canary_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("rust-canary"));
        return Ok(());
    }

    let options = parse_options("rust-canary", args, 0)?;
    let backend = rust_canary_backend()?;
    let backend_name = backend.backend;
    let backend_source = backend.source;
    let tauri_backend_candidate = backend_name == "tauri";
    let payload = json!({
        "contract_version": 1,
        "task_id": "TASK-283",
        "target_version": "v0.24.5",
        "generated_at": generated_at(),
        "project_dir": project_dir_string(&options.project_dir),
        "product_version": VERSION,
        "phase": "default-on-canary",
        "runtime": {
            "rust_cli_available": true,
            "backend_env": "WINSMUX_BACKEND",
            "backend": backend_name,
            "backend_source": backend_source,
            "tauri_backend_candidate": tauri_backend_candidate,
        },
        "required_gates": [
            "local_rust_cli_tests",
            "tauri_backend_smoke",
            "shadow_cutover_gate",
            "versioned_manual_checklist",
            "public_surface_audit",
            "release_ci"
        ],
        "blocking_conditions": [
            "invalid_WINSMUX_BACKEND",
            "shadow_cutover_difference",
            "tauri_backend_smoke_failure",
            "release_ci_failure",
            "public_surface_drift"
        ],
        "depends_on": ["TASK-270", "TASK-272", "TASK-273", "TASK-274", "TASK-296"],
        "next_action": "Run canary validation with WINSMUX_BACKEND=tauri before v0.24.5 release.",
    });

    if options.json {
        return write_json(&payload);
    }

    println!(
        "Rust canary: {} backend for v0.24.5 (version {})",
        payload["runtime"]["backend"].as_str().unwrap_or("unknown"),
        VERSION
    );
    println!("{}", payload["next_action"].as_str().unwrap_or(""));
    Ok(())
}

pub fn run_manual_checklist_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("manual-checklist"));
        return Ok(());
    }

    let options = parse_options("manual-checklist", args, 0)?;
    let payload = json!({
        "contract_version": 1,
        "task_id": "TASK-316",
        "target_version": "v0.24.5",
        "generated_at": generated_at(),
        "project_dir": project_dir_string(&options.project_dir),
        "product_version": VERSION,
        "document": {
            "path": "docs/internal/winsmux-manual-checklist-by-version.md",
            "source": "winsmux-core/scripts/sync-internal-docs.ps1",
            "tracked": false,
        },
        "required_result_values": ["未", "合格", "不合格", "保留"],
        "release_gates": [
            "version_by_version_results_recorded",
            "no_critical_unchecked_items",
            "pre_v1_fixups_taskified",
            "reusable_screen_recording_candidates_recorded",
            "task_220_can_reference_results"
        ],
        "v0_24_5_focus": [
            "legacy_alias_sunset",
            "rust_default_on_canary",
            "windows_install_guidance",
            "release_ci",
            "public_surface_gate"
        ],
        "blocking_conditions": [
            "missing_manual_checklist_document",
            "unchecked_critical_item",
            "failed_result_without_followup_task",
            "blocked_result_without_owner",
            "public_surface_drift"
        ],
        "next_action": "Record v0.24.5 manual validation results before the v0.24.5 release and feed any failed or blocked item back into backlog."
    });

    if options.json {
        return write_json(&payload);
    }

    println!(
        "Manual checklist: {} for {}",
        payload["document"]["path"].as_str().unwrap_or("unknown"),
        payload["target_version"].as_str().unwrap_or("unknown")
    );
    println!("{}", payload["next_action"].as_str().unwrap_or(""));
    Ok(())
}

pub fn run_legacy_compat_gate_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("legacy-compat-gate"));
        return Ok(());
    }

    let options = parse_options("legacy-compat-gate", args, 0)?;
    let report = legacy_compat_gate_report(&options.project_dir)?;
    let passed = report["summary"]["passed"].as_bool().unwrap_or(false);
    if options.json {
        if !passed {
            write_json(&report)?;
            return Err(io::Error::new(
                io::ErrorKind::Other,
                "legacy compatibility gate failed",
            ));
        }
        return write_json(&report);
    }

    println!(
        "Legacy compatibility gate: {} files covered; {} removal candidates; {} unclassified.",
        report["summary"]["matched_file_count"]
            .as_u64()
            .unwrap_or(0),
        report["summary"]["removal_candidate_files"]
            .as_u64()
            .unwrap_or(0),
        report["summary"]["unclassified_count"]
            .as_u64()
            .unwrap_or(0)
    );
    println!("{}", report["next_action"].as_str().unwrap_or(""));
    if !passed {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "legacy compatibility gate failed",
        ));
    }
    Ok(())
}

pub fn run_guard_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("guard"));
        return Ok(());
    }

    let options = parse_options("guard", args, 0)?;
    let payload = guard_report_payload(&options.project_dir);
    if options.json {
        return write_json(&payload);
    }

    println!(
        "Guard baseline: {} checks for {}",
        payload["summary"]["required_check_count"]
            .as_u64()
            .unwrap_or(0),
        payload["target_version"].as_str().unwrap_or("release")
    );
    println!(
        "{}",
        payload["summary"]["next_action"].as_str().unwrap_or("")
    );
    Ok(())
}

fn legacy_compat_gate_report(project_dir: &Path) -> io::Result<Value> {
    let inventory_relative_path = "docs/project/legacy-compat-surface-inventory.json";
    let inventory_path = project_dir.join(inventory_relative_path);
    let inventory_raw = fs::read_to_string(&inventory_path).map_err(|err| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "failed to read legacy compatibility inventory at {}: {err}",
                inventory_path.display()
            ),
        )
    })?;
    let inventory: Value = serde_json::from_str(&inventory_raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to parse legacy compatibility inventory: {err}"),
        )
    })?;

    let task = inventory
        .get("task")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if task != "TASK-408" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "legacy compatibility inventory task must be TASK-408",
        ));
    }

    let terms = inventory
        .get("terms")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|term| term.to_ascii_lowercase())
        .filter(|term| !term.trim().is_empty())
        .collect::<Vec<_>>();
    if terms.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "legacy compatibility inventory must include terms",
        ));
    }

    let allowed_classes = inventory
        .get("allowed_classes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_string)
        .collect::<Vec<_>>();
    if allowed_classes.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "legacy compatibility inventory must include allowed_classes",
        ));
    }

    let tracked_files = git_repository_files(project_dir)?;
    let mut coverage: HashMap<String, String> = HashMap::new();
    let mut inventory_entry_count = 0usize;
    let entries = inventory
        .get("entries")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "legacy compatibility inventory must include entries",
            )
        })?;

    for entry in entries {
        inventory_entry_count += 1;
        let class = entry
            .get("class")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !allowed_classes.iter().any(|allowed| allowed == class) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unknown legacy compatibility class: {class}"),
            ));
        }
        for required in ["owner", "surface", "reason", "target"] {
            if entry
                .get(required)
                .and_then(Value::as_str)
                .map(str::trim)
                .unwrap_or_default()
                .is_empty()
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("legacy compatibility inventory entry is missing {required}"),
                ));
            }
        }

        for path in entry
            .get("paths")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            let normalized = normalize_repo_path(path);
            if !tracked_files.iter().any(|file| file == &normalized) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("legacy compatibility inventory path is not a repository file: {normalized}"),
                ));
            }
            coverage.insert(normalized, class.to_string());
        }

        for glob in entry
            .get("globs")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            let normalized = normalize_repo_path(glob);
            let pattern = glob::Pattern::new(&normalized).map_err(|err| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("invalid legacy compatibility inventory glob {normalized}: {err}"),
                )
            })?;
            let matches = tracked_files
                .iter()
                .filter(|file| pattern.matches(file))
                .cloned()
                .collect::<Vec<_>>();
            if matches.is_empty() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("legacy compatibility inventory glob matched no files: {normalized}"),
                ));
            }
            for matched in matches {
                coverage.insert(matched, class.to_string());
            }
        }
    }

    let matched_files = compatibility_surface_files(project_dir, &tracked_files, &terms);
    let private_reference_files = legacy_compat_private_reference_files(
        project_dir,
        &[
            inventory_relative_path,
            "docs/project/legacy-compat-surface-inventory.md",
        ],
    );
    let mut class_counts: BTreeMap<String, usize> = BTreeMap::new();
    for class in &allowed_classes {
        class_counts.insert(class.clone(), 0);
    }
    let mut unclassified = Vec::new();
    for file in &matched_files {
        if let Some(class) = coverage.get(file) {
            *class_counts.entry(class.clone()).or_insert(0) += 1;
        } else {
            unclassified.push(file.clone());
        }
    }

    let passed = unclassified.is_empty() && private_reference_files.is_empty();
    Ok(json!({
        "contract_version": 1,
        "task_id": "TASK-408",
        "target_version": inventory.get("target_version").cloned().unwrap_or_else(|| json!("v1.0.0")),
        "generated_at": generated_at(),
        "project_dir": project_dir_string(project_dir),
        "product_version": VERSION,
        "inventory": {
            "path": inventory_relative_path,
            "terms": terms,
            "entry_count": inventory_entry_count,
        },
        "summary": {
            "passed": passed,
            "matched_file_count": matched_files.len(),
            "intentional_shim_files": class_counts.get("intentional-shim").copied().unwrap_or(0),
            "removal_candidate_files": class_counts.get("removal-candidate").copied().unwrap_or(0),
            "unclassified_count": unclassified.len(),
            "private_reference_count": private_reference_files.len(),
        },
        "class_counts": class_counts,
        "unclassified_files": unclassified,
        "private_reference_files": private_reference_files,
        "blocking_conditions": [
            "unclassified_legacy_compat_surface",
            "unknown_inventory_class",
            "missing_inventory_owner_or_target",
            "inventory_path_or_glob_without_file",
            "private_local_reference_in_inventory"
        ],
        "next_action": "Before v1.0.0, remove or replace removal-candidate alias surfaces while keeping intentional tmux-compatible product behavior covered."
    }))
}

fn git_repository_files(project_dir: &Path) -> io::Result<Vec<String>> {
    let output = Command::new("git")
        .arg("-C")
        .arg(project_dir)
        .args(["ls-files", "--cached", "--others", "--exclude-standard"])
        .output()?;
    if !output.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!(
                "failed to list repository files: {}",
                String::from_utf8_lossy(&output.stderr)
            ),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(normalize_repo_path)
        .filter(|line| !line.trim().is_empty())
        .collect())
}

fn compatibility_surface_files(
    project_dir: &Path,
    files: &[String],
    terms: &[String],
) -> Vec<String> {
    let mut matched = Vec::new();
    for file in files {
        let path = project_dir.join(file);
        let Ok(content) = fs::read_to_string(path) else {
            continue;
        };
        let lowered = content.to_ascii_lowercase();
        if terms.iter().any(|term| lowered.contains(term)) {
            matched.push(file.clone());
        }
    }
    matched.sort();
    matched.dedup();
    matched
}

fn legacy_compat_private_reference_files(project_dir: &Path, files: &[&str]) -> Vec<String> {
    const FORBIDDEN_PATTERNS: &[&str] = &[
        "C:\\Users\\",
        "C:\\\\Users\\\\",
        "/Users/",
        ".claude/local",
        "WINSMUX_PRIVATE_SKILLS_ROOT",
        "private-skills-root",
    ];

    let mut matched = Vec::new();
    for file in files {
        let path = project_dir.join(file);
        let Ok(content) = fs::read_to_string(path) else {
            continue;
        };
        if FORBIDDEN_PATTERNS
            .iter()
            .any(|pattern| content.contains(pattern))
        {
            matched.push((*file).to_string());
        }
    }
    matched.sort();
    matched.dedup();
    matched
}

fn normalize_repo_path(path: impl AsRef<str>) -> String {
    path.as_ref().replace('\\', "/")
}

struct RustCanaryBackend {
    backend: String,
    source: String,
}

fn rust_canary_backend() -> io::Result<RustCanaryBackend> {
    let Ok(raw_backend) = env::var("WINSMUX_BACKEND") else {
        return Ok(RustCanaryBackend {
            backend: "cli".to_string(),
            source: "default".to_string(),
        });
    };

    let normalized = raw_backend.trim().to_lowercase();
    match normalized.as_str() {
        "" => Ok(RustCanaryBackend {
            backend: "cli".to_string(),
            source: "default".to_string(),
        }),
        "cli" | "winsmux" => Ok(RustCanaryBackend {
            backend: "cli".to_string(),
            source: "WINSMUX_BACKEND".to_string(),
        }),
        "tauri" | "desktop" => Ok(RustCanaryBackend {
            backend: "tauri".to_string(),
            source: "WINSMUX_BACKEND".to_string(),
        }),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("WINSMUX_BACKEND must be cli or tauri, got '{raw_backend}'"),
        )),
    }
}

fn parse_machine_contract_options(args: &[&String]) -> io::Result<bool> {
    parse_json_only_options("machine-contract", args)
}

fn parse_json_only_options(command: &str, args: &[&String]) -> io::Result<bool> {
    let mut json = false;
    for arg in args {
        match arg.as_str() {
            "--json" => json = true,
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux {command}: {value}"),
                ));
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    usage_for(command).to_string(),
                ));
            }
        }
    }
    Ok(json)
}

pub fn run_provider_switch_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("provider-switch"));
        return Ok(());
    }

    let options = parse_provider_switch_options(args)?;
    let settings = read_bridge_settings(&options.project_dir)?;
    if !settings.has_slot(&options.slot_id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "provider-switch target slot '{}' is not present in agent_slots.",
                options.slot_id
            ),
        ));
    }
    if options.clear
        && (options.agent.is_some()
            || options.model.is_some()
            || options.model_source.is_some()
            || options.reasoning_effort.is_some()
            || options.prompt_transport.is_some()
            || options.auth_mode.is_some())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "provider-switch --clear cannot be combined with --agent, --model, --model-source, --reasoning-effort, --prompt-transport, or --auth-mode.",
        ));
    }

    let restart_pane_id = if options.restart {
        Some(validate_provider_switch_restart_target(
            &options.project_dir,
            &options.slot_id,
        )?)
    } else {
        None
    };

    let registry_path = provider_registry_path(&options.project_dir);
    let candidate_entry = if options.clear {
        None
    } else {
        Some(ProviderRegistryEntry::new(&options)?)
    };
    if options.clear {
        validate_provider_switch_clear_candidate(
            &options.project_dir,
            &settings,
            &options.slot_id,
        )?;
    } else if let Some(entry) = candidate_entry.as_ref() {
        validate_provider_switch_candidate(&options.project_dir, &settings, &options, entry)?;
    }

    let restart_plan = if let Some(pane_id) = restart_pane_id.as_deref() {
        Some(build_provider_switch_restart_plan(
            &options.project_dir,
            &settings,
            &options.slot_id,
            pane_id,
            candidate_entry.as_ref(),
        )?)
    } else {
        None
    };
    let (updated_at_utc, reason, cleared) = if options.clear {
        let result = remove_provider_registry_entry(&registry_path, &options.slot_id)?;
        (result.updated_at_utc, String::new(), result.removed)
    } else {
        let entry = candidate_entry.expect("provider switch candidate entry should exist");
        let updated_at_utc = entry.updated_at_utc.clone();
        let reason = entry.reason.clone().unwrap_or_default();
        write_provider_registry_entry(&registry_path, &options.slot_id, entry)?;
        (updated_at_utc, reason, false)
    };

    let effective = resolve_slot_agent_config(&options.project_dir, &settings, &options.slot_id)?;
    let mut restarted = false;
    let mut restart_pane_id_output = String::new();
    if let Some(plan) = restart_plan {
        invoke_restart_plan(&plan)?;
        let _ = update_restart_manifest_metadata(&options.project_dir, &plan);
        restarted = true;
        restart_pane_id_output = plan.pane_id;
    }

    let payload = json!({
        "slot_id": options.slot_id,
        "agent": effective.agent,
        "model": effective.model,
        "model_source": effective.model_source,
        "reasoning_effort": effective.reasoning_effort,
        "prompt_transport": effective.prompt_transport,
        "auth_mode": effective.auth_mode,
        "auth_policy": effective.auth_policy,
        "local_access_note": effective.local_access_note,
        "source": effective.source,
        "capability_adapter": effective.capability_adapter,
        "capability_command": effective.capability_command,
        "supports_parallel_runs": effective.supports_parallel_runs,
        "supports_interrupt": effective.supports_interrupt,
        "supports_structured_result": effective.supports_structured_result,
        "supports_file_edit": effective.supports_file_edit,
        "supports_subagents": effective.supports_subagents,
        "supports_verification": effective.supports_verification,
        "supports_consultation": effective.supports_consultation,
        "supports_context_reset": effective.supports_context_reset,
        "registry_path": registry_path.display().to_string(),
        "updated_at_utc": updated_at_utc,
        "reason": reason,
        "clear_requested": options.clear,
        "cleared": cleared,
        "restart_requested": options.restart,
        "restarted": restarted,
        "restart_pane_id": restart_pane_id_output,
    });

    if options.json {
        return write_json(&payload);
    }

    let action = if options.clear {
        "provider switch cleared"
    } else {
        "provider switched"
    };
    println!(
        "{action} for {}: {} / {} ({}, {})",
        payload["slot_id"].as_str().unwrap_or_default(),
        payload["agent"].as_str().unwrap_or_default(),
        payload["model"].as_str().unwrap_or_default(),
        payload["prompt_transport"].as_str().unwrap_or_default(),
        payload["auth_policy"].as_str().unwrap_or_default()
    );
    Ok(())
}

pub fn run_signal_command(args: &[&String]) -> io::Result<()> {
    if args.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("signal"),
        ));
    }

    let channel = args[0].trim();
    if channel.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("signal"),
        ));
    }

    let signal_dir = signal_dir_path();
    fs::create_dir_all(&signal_dir)?;
    let signal_file = signal_file_path(channel);
    fs::write(signal_file, generated_at())?;
    println!("sent signal: {channel}");
    Ok(())
}

pub fn run_wait_command(args: &[&String]) -> io::Result<()> {
    if args.is_empty() || args.len() > 2 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("wait"),
        ));
    }

    let channel = args[0].trim();
    if channel.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("wait"),
        ));
    }

    let timeout_secs = match args.get(1) {
        Some(raw) => raw
            .parse::<u64>()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, usage_for("wait")))?,
        None => 120,
    };
    let signal_dir = signal_dir_path();
    fs::create_dir_all(&signal_dir)?;
    let signal_file = signal_file_path(channel);
    if signal_file.exists() {
        fs::remove_file(&signal_file)?;
        println!("received signal: {channel}");
        return Ok(());
    }

    let deadline = Instant::now() + Duration::from_secs(timeout_secs);
    while Instant::now() < deadline {
        thread::sleep(Duration::from_millis(100));
        if signal_file.exists() {
            fs::remove_file(&signal_file)?;
            println!("received signal: {channel}");
            return Ok(());
        }
    }

    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("timeout waiting for signal: {channel} ({timeout_secs}s)"),
    ))
}

fn signal_dir_path() -> PathBuf {
    env::var_os("TEMP")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir)
        .join("winsmux")
        .join("signals")
}

fn signal_file_path(channel: &str) -> PathBuf {
    signal_dir_path().join(format!("{channel}.signal"))
}

#[derive(Debug)]
struct ProviderCapabilitiesOptions {
    project_dir: PathBuf,
    provider_id: Option<String>,
    json: bool,
}

#[derive(Debug)]
struct OperatorJobsOptions {
    project_dir: PathBuf,
    action: String,
    job_id: Option<String>,
    kind: Option<String>,
    title: Option<String>,
    schedule_type: Option<String>,
    every: Option<String>,
    evidence: Vec<String>,
    destructive: bool,
    reason: Option<String>,
    json: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct OperatorJobsState {
    contract_version: u8,
    packet_type: String,
    updated_at: String,
    jobs: Vec<OperatorJobRecord>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct OperatorJobRecord {
    job_id: String,
    kind: String,
    title: String,
    status: String,
    schedule: OperatorJobSchedule,
    evidence_requirements: Vec<String>,
    command_plan: OperatorJobCommandPlan,
    approval_policy: OperatorJobApprovalPolicy,
    created_at: String,
    updated_at: String,
    pending_update: Option<Value>,
    runs: Vec<OperatorJobRunRecord>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct OperatorJobSchedule {
    schedule_type: String,
    every: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct OperatorJobCommandPlan {
    workflow_kind: String,
    execution_backend: String,
    destructive_change_possible: bool,
    side_effect_policy: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct OperatorJobApprovalPolicy {
    destructive_changes_require_explicit_approval: bool,
    auto_execute_destructive_changes: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct OperatorJobRunRecord {
    run_id: String,
    run_number: u32,
    status: String,
    started_at: String,
    fresh_record: bool,
    evidence: Vec<OperatorJobEvidenceRecord>,
    approval_gate: OperatorJobApprovalGate,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct OperatorJobEvidenceRecord {
    evidence_id: String,
    kind: String,
    summary: String,
    reference: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct OperatorJobApprovalGate {
    required: bool,
    state: String,
    destructive_change: bool,
    approved_by: Option<String>,
    approved_at: Option<String>,
    reason: String,
}

#[derive(Debug)]
struct ProviderCapabilityRegistry {
    version: u64,
    providers: Map<String, Value>,
}

#[derive(Debug)]
struct ProviderSwitchOptions {
    project_dir: PathBuf,
    slot_id: String,
    agent: Option<String>,
    model: Option<String>,
    model_source: Option<String>,
    reasoning_effort: Option<String>,
    prompt_transport: Option<String>,
    auth_mode: Option<String>,
    reason: Option<String>,
    restart: bool,
    clear: bool,
    json: bool,
}

#[derive(Clone, Debug)]
struct BridgeSettings {
    agent: String,
    model: String,
    model_source: String,
    reasoning_effort: String,
    prompt_transport: String,
    auth_mode: String,
    agent_explicit: bool,
    model_explicit: bool,
    worker_role: ProviderRoleConfig,
    agent_slots: Vec<ProviderSlotConfig>,
}

#[derive(Clone, Debug, Default)]
struct ProviderRoleConfig {
    agent: Option<String>,
    model: Option<String>,
    model_source: Option<String>,
    reasoning_effort: Option<String>,
    prompt_transport: Option<String>,
    auth_mode: Option<String>,
}

#[derive(Clone, Debug)]
struct ProviderSlotConfig {
    slot_id: String,
    agent: Option<String>,
    model: Option<String>,
    model_source: Option<String>,
    reasoning_effort: Option<String>,
    prompt_transport: Option<String>,
    auth_mode: Option<String>,
}

#[derive(Clone, Debug, Default)]
struct ProviderRegistryEntry {
    agent: Option<String>,
    model: Option<String>,
    model_source: Option<String>,
    reasoning_effort: Option<String>,
    prompt_transport: Option<String>,
    auth_mode: Option<String>,
    updated_at_utc: String,
    reason: Option<String>,
}

#[derive(Clone, Debug)]
struct SlotAgentConfig {
    agent: String,
    model: String,
    model_source: String,
    reasoning_effort: String,
    prompt_transport: String,
    auth_mode: String,
    auth_policy: String,
    source: String,
    capability_adapter: String,
    capability_command: String,
    model_options: Value,
    model_sources: Value,
    reasoning_efforts: Value,
    local_access_note: String,
    supports_parallel_runs: bool,
    supports_interrupt: bool,
    supports_structured_result: bool,
    supports_file_edit: bool,
    supports_subagents: bool,
    supports_verification: bool,
    supports_consultation: bool,
    supports_context_reset: bool,
}

#[derive(Debug)]
struct ProviderRegistryRemoveResult {
    removed: bool,
    updated_at_utc: String,
}

fn parse_provider_capabilities_options(
    args: &[&String],
) -> io::Result<ProviderCapabilitiesOptions> {
    let mut project_dir = env::current_dir()?;
    let mut provider_id: Option<String> = None;
    let mut json = false;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        usage_for("provider-capabilities"),
                    ));
                };
                project_dir = PathBuf::from(value.as_str());
                index += 2;
            }
            value => {
                if provider_id.is_none() {
                    provider_id = Some(value.to_string());
                    index += 1;
                    continue;
                }
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    usage_for("provider-capabilities"),
                ));
            }
        }
    }

    Ok(ProviderCapabilitiesOptions {
        project_dir,
        provider_id,
        json,
    })
}

fn parse_operator_jobs_options(args: &[&String]) -> io::Result<OperatorJobsOptions> {
    let mut project_dir = env::current_dir()?;
    let mut action: Option<String> = None;
    let mut job_id = None;
    let mut kind = None;
    let mut title = None;
    let mut schedule_type = None;
    let mut every = None;
    let mut evidence = Vec::new();
    let mut destructive = false;
    let mut reason = None;
    let mut json = false;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                project_dir = PathBuf::from(required_option_value(args, index, "--project-dir")?);
                index += 2;
            }
            "--job-id" => {
                job_id = Some(required_operator_job_id(&required_option_value(
                    args, index, "--job-id",
                )?)?);
                index += 2;
            }
            "--kind" => {
                kind = Some(validate_operator_job_kind(&required_option_value(
                    args, index, "--kind",
                )?)?);
                index += 2;
            }
            "--title" => {
                title = trim_text(required_option_value(args, index, "--title")?);
                index += 2;
            }
            "--schedule" => {
                schedule_type = Some(validate_operator_job_schedule_type(
                    &required_option_value(args, index, "--schedule")?,
                )?);
                index += 2;
            }
            "--every" => {
                every = trim_text(required_option_value(args, index, "--every")?);
                index += 2;
            }
            "--evidence" => {
                evidence.push(required_option_value(args, index, "--evidence")?);
                index += 2;
            }
            "--destructive" => {
                destructive = true;
                index += 1;
            }
            "--reason" => {
                reason = trim_text(required_option_value(args, index, "--reason")?);
                index += 2;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux operator-jobs: {value}"),
                ));
            }
            value => {
                if action.is_none() {
                    action = Some(value.to_string());
                } else if job_id.is_none() {
                    job_id = Some(required_operator_job_id(value)?);
                } else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        usage_for("operator-jobs"),
                    ));
                }
                index += 1;
            }
        }
    }

    let action = action.unwrap_or_else(|| "list".to_string());
    if !matches!(
        action.as_str(),
        "catalog" | "list" | "create" | "run" | "pause" | "update" | "delete"
    ) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("operator-jobs"),
        ));
    }

    Ok(OperatorJobsOptions {
        project_dir,
        action,
        job_id,
        kind,
        title,
        schedule_type,
        every,
        evidence,
        destructive,
        reason,
        json,
    })
}

fn parse_provider_switch_options(args: &[&String]) -> io::Result<ProviderSwitchOptions> {
    if args.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("provider-switch"),
        ));
    }

    let mut project_dir = env::current_dir()?;
    let mut slot_id: Option<String> = None;
    let mut agent = None;
    let mut model = None;
    let mut model_source = None;
    let mut reasoning_effort = None;
    let mut prompt_transport = None;
    let mut auth_mode = None;
    let mut reason = None;
    let mut restart = false;
    let mut clear = false;
    let mut json = false;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--agent" => {
                agent = Some(required_option_value(args, index, "--agent")?);
                index += 2;
            }
            "--model" => {
                model = Some(required_option_value(args, index, "--model")?);
                index += 2;
            }
            "--model-source" => {
                let value = required_option_value(args, index, "--model-source")?;
                validate_model_source(&value)?;
                model_source = Some(value);
                index += 2;
            }
            "--reasoning-effort" => {
                let value = required_option_value(args, index, "--reasoning-effort")?;
                validate_reasoning_effort(&value)?;
                reasoning_effort = Some(value.trim().to_ascii_lowercase());
                index += 2;
            }
            "--prompt-transport" => {
                let value = required_option_value(args, index, "--prompt-transport")?;
                let normalized = value.trim().to_ascii_lowercase();
                if !matches!(normalized.as_str(), "argv" | "file" | "stdin") {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("Invalid provider registry prompt_transport '{value}'."),
                    ));
                }
                prompt_transport = Some(normalized);
                index += 2;
            }
            "--auth-mode" => {
                auth_mode = Some(required_option_value(args, index, "--auth-mode")?);
                index += 2;
            }
            "--reason" => {
                reason = Some(required_option_value(args, index, "--reason")?);
                index += 2;
            }
            "--project-dir" => {
                project_dir = PathBuf::from(required_option_value(args, index, "--project-dir")?);
                index += 2;
            }
            "--restart" => {
                restart = true;
                index += 1;
            }
            "--clear" => {
                clear = true;
                index += 1;
            }
            "--json" => {
                json = true;
                index += 1;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    usage_for("provider-switch"),
                ));
            }
            value => {
                if slot_id.is_some() || value.trim().is_empty() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        usage_for("provider-switch"),
                    ));
                }
                slot_id = Some(value.to_string());
                index += 1;
            }
        }
    }

    let Some(slot_id) = slot_id else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("provider-switch"),
        ));
    };

    Ok(ProviderSwitchOptions {
        project_dir,
        slot_id,
        agent: trim_optional(agent),
        model: trim_optional(model),
        model_source: trim_optional(model_source),
        reasoning_effort: trim_optional(reasoning_effort),
        prompt_transport,
        auth_mode: trim_optional(auth_mode),
        reason: trim_optional(reason),
        restart,
        clear,
        json,
    })
}

fn required_option_value(args: &[&String], index: usize, flag: &str) -> io::Result<String> {
    let Some(value) = args.get(index + 1) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{flag} requires a value"),
        ));
    };
    Ok(value.to_string())
}

fn trim_optional(value: Option<String>) -> Option<String> {
    value
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
}

fn trim_text(value: String) -> Option<String> {
    let trimmed = value.trim().to_string();
    (!trimmed.is_empty()).then_some(trimmed)
}

fn required_operator_job_id(value: &str) -> io::Result<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > 80
        || !trimmed
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.'))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "operator job id must use only ASCII letters, digits, dash, underscore, or dot",
        ));
    }
    Ok(trimmed.to_string())
}

fn validate_operator_job_kind(value: &str) -> io::Result<String> {
    let normalized = value.trim().to_ascii_lowercase();
    if matches!(
        normalized.as_str(),
        "dependency-check" | "issue-triage" | "documentation-refresh" | "repository-hygiene"
    ) {
        Ok(normalized)
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "operator job kind must be dependency-check, issue-triage, documentation-refresh, or repository-hygiene",
        ))
    }
}

fn validate_operator_job_schedule_type(value: &str) -> io::Result<String> {
    let normalized = value.trim().to_ascii_lowercase();
    if matches!(normalized.as_str(), "one-time" | "recurring") {
        Ok(normalized)
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "operator job schedule must be one-time or recurring",
        ))
    }
}

fn operator_jobs_catalog_payload() -> Value {
    json!({
        "contract_version": 1,
        "packet_type": "operator_job_catalog",
        "command": "operator-jobs",
        "public_state_ref": ".winsmux/operator-jobs.json",
        "supported_jobs": [
            {
                "kind": "dependency-check",
                "purpose": "collect dependency status and update recommendations",
                "default_evidence": ["dependency_report", "risk_summary", "proposed_change_summary"]
            },
            {
                "kind": "issue-triage",
                "purpose": "collect issue status, labels, duplicates, and planning links",
                "default_evidence": ["issue_query", "triage_summary", "planning_mapping"]
            },
            {
                "kind": "documentation-refresh",
                "purpose": "collect stale public documentation signals and proposed edits",
                "default_evidence": ["doc_inventory", "staleness_reason", "validation_plan"]
            },
            {
                "kind": "repository-hygiene",
                "purpose": "collect public-surface, guard, and cleanup evidence",
                "default_evidence": ["git_guard", "public_surface_audit", "cleanup_candidate"]
            }
        ],
        "schedule_contract": {
            "supported_types": ["one-time", "recurring"],
            "recurring_every_values": ["daily", "weekly", "monthly"],
            "daemon_included": false,
            "run_model": "operator starts a fresh run record when invoking operator-jobs run"
        },
        "approval_contract": {
            "destructive_changes_require_explicit_approval": true,
            "delete_is_soft_pending_approval": true,
            "auto_execute_destructive_changes": false
        },
        "summary": {
            "message": "catalog lists public-safe scheduled operator job contracts"
        }
    })
}

fn operator_jobs_list_payload(project_dir: &Path) -> io::Result<Value> {
    let state = read_operator_jobs_state(project_dir)?;
    Ok(json!({
        "contract_version": 1,
        "packet_type": "operator_job_registry_view",
        "command": "operator-jobs list",
        "public_state_ref": operator_jobs_state_ref(),
        "updated_at": state.updated_at,
        "jobs": state.jobs,
        "summary": {
            "message": "listed operator jobs",
            "job_count": state.jobs.len()
        }
    }))
}

fn operator_jobs_create(options: &OperatorJobsOptions) -> io::Result<Value> {
    let job_id = required_option(options.job_id.as_deref(), "create requires <job_id>")?;
    let kind = options
        .kind
        .clone()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "create requires --kind"))?;
    let schedule_type = options
        .schedule_type
        .clone()
        .unwrap_or_else(|| "one-time".to_string());
    if schedule_type == "recurring" {
        let every = options.every.as_deref().unwrap_or_default();
        if !matches!(every, "daily" | "weekly" | "monthly") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "recurring operator jobs require --every daily, weekly, or monthly",
            ));
        }
    }

    let (job, total_jobs) = mutate_operator_jobs_state(&options.project_dir, |state| {
        if state.jobs.iter().any(|job| job.job_id == job_id) {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("operator job already exists: {job_id}"),
            ));
        }

        let now = generated_at();
        let evidence_requirements = operator_job_evidence_requirements(&kind, &options.evidence);
        let job = OperatorJobRecord {
            job_id: job_id.to_string(),
            kind: kind.clone(),
            title: options
                .title
                .clone()
                .unwrap_or_else(|| operator_job_default_title(&kind).to_string()),
            status: "scheduled".to_string(),
            schedule: OperatorJobSchedule {
                schedule_type,
                every: options.every.clone(),
            },
            evidence_requirements,
            command_plan: OperatorJobCommandPlan {
                workflow_kind: kind,
                execution_backend: "operator_managed".to_string(),
                destructive_change_possible: options.destructive,
                side_effect_policy: if options.destructive {
                    "record_pending_approval_only".to_string()
                } else {
                    "evidence_only".to_string()
                },
            },
            approval_policy: OperatorJobApprovalPolicy {
                destructive_changes_require_explicit_approval: true,
                auto_execute_destructive_changes: false,
            },
            created_at: now.clone(),
            updated_at: now,
            pending_update: None,
            runs: Vec::new(),
        };
        state.jobs.push(job.clone());
        Ok((job, state.jobs.len()))
    })?;

    Ok(operator_jobs_result_payload(
        "create",
        format!("created operator job {job_id}"),
        Some(job),
        None,
        total_jobs,
    ))
}

fn operator_jobs_start_run(options: &OperatorJobsOptions) -> io::Result<Value> {
    let job_id = required_option(options.job_id.as_deref(), "run requires <job_id>")?;
    let (job, run, total_jobs) = mutate_operator_jobs_state(&options.project_dir, |state| {
        let job = find_operator_job_mut(state, job_id)?;
        if job.status == "paused" || job.status == "delete_pending_approval" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("operator job {job_id} is not runnable while status is {}", job.status),
            ));
        }
        let run_number = job.runs.len() as u32 + 1;
        let run_id = format!("operator-job:{job_id}:{run_number}");
        let destructive = job.command_plan.destructive_change_possible || options.destructive;
        let evidence = operator_job_run_evidence(job, &options.evidence);
        let run = OperatorJobRunRecord {
            run_id,
            run_number,
            status: if destructive {
                "approval_pending".to_string()
            } else {
                "evidence_recorded".to_string()
            },
            started_at: generated_at(),
            fresh_record: true,
            evidence,
            approval_gate: OperatorJobApprovalGate {
                required: destructive,
                state: if destructive {
                    "pending_operator_approval".to_string()
                } else {
                    "not_required".to_string()
                },
                destructive_change: destructive,
                approved_by: None,
                approved_at: None,
                reason: options.reason.clone().unwrap_or_else(|| {
                    "destructive changes are represented only as pending approval".to_string()
                }),
            },
        };
        job.updated_at = generated_at();
        job.runs.push(run.clone());
        Ok((job.clone(), run, state.jobs.len()))
    })?;

    Ok(operator_jobs_result_payload(
        "run",
        format!("started fresh run record for {job_id}"),
        Some(job),
        Some(run),
        total_jobs,
    ))
}

fn operator_jobs_pause(options: &OperatorJobsOptions) -> io::Result<Value> {
    let job_id = required_option(options.job_id.as_deref(), "pause requires <job_id>")?;
    let (job, total_jobs) = mutate_operator_jobs_state(&options.project_dir, |state| {
        let job = find_operator_job_mut(state, job_id)?;
        job.status = "paused".to_string();
        job.updated_at = generated_at();
        Ok((job.clone(), state.jobs.len()))
    })?;
    Ok(operator_jobs_result_payload(
        "pause",
        format!("paused operator job {job_id}"),
        Some(job),
        None,
        total_jobs,
    ))
}

fn operator_jobs_update(options: &OperatorJobsOptions) -> io::Result<Value> {
    let job_id = required_option(options.job_id.as_deref(), "update requires <job_id>")?;
    let mut update = Map::new();
    if let Some(title) = options.title.as_deref() {
        update.insert("title".to_string(), json!(title));
    }
    if let Some(schedule_type) = options.schedule_type.as_deref() {
        update.insert("schedule_type".to_string(), json!(schedule_type));
    }
    if let Some(every) = options.every.as_deref() {
        update.insert("every".to_string(), json!(every));
    }
    if update.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "update requires --title, --schedule, or --every",
        ));
    }

    let (job, total_jobs) = mutate_operator_jobs_state(&options.project_dir, |state| {
        let job = find_operator_job_mut(state, job_id)?;
        if options.destructive {
            job.status = "update_pending_approval".to_string();
            job.pending_update = Some(json!({
                "requested_at": generated_at(),
                "changes": update,
                "approval_gate": {
                    "required": true,
                    "state": "pending_operator_approval",
                    "destructive_change": true,
                    "approved_by": null,
                    "approved_at": null,
                    "reason": options.reason.clone().unwrap_or_else(|| "destructive job update requires explicit approval".to_string())
                }
            }));
        } else {
            apply_operator_job_update(job, &update)?;
        }
        job.updated_at = generated_at();
        Ok((job.clone(), state.jobs.len()))
    })?;
    Ok(operator_jobs_result_payload(
        "update",
        format!("updated operator job {job_id}"),
        Some(job),
        None,
        total_jobs,
    ))
}

fn operator_jobs_delete(options: &OperatorJobsOptions) -> io::Result<Value> {
    let job_id = required_option(options.job_id.as_deref(), "delete requires <job_id>")?;
    let (job, total_jobs) = mutate_operator_jobs_state(&options.project_dir, |state| {
        let job = find_operator_job_mut(state, job_id)?;
        job.status = "delete_pending_approval".to_string();
        job.pending_update = Some(json!({
            "requested_at": generated_at(),
            "delete_requested": true,
            "approval_gate": {
                "required": true,
                "state": "pending_operator_approval",
                "destructive_change": true,
                "approved_by": null,
                "approved_at": null,
                "reason": options.reason.clone().unwrap_or_else(|| "operator job delete is soft pending approval".to_string())
            }
        }));
        job.updated_at = generated_at();
        Ok((job.clone(), state.jobs.len()))
    })?;
    Ok(operator_jobs_result_payload(
        "delete",
        format!("recorded delete approval request for {job_id}"),
        Some(job),
        None,
        total_jobs,
    ))
}

fn read_operator_jobs_state(project_dir: &Path) -> io::Result<OperatorJobsState> {
    let path = operator_jobs_state_path(project_dir);
    read_operator_jobs_state_from_path(&path)
}

fn read_operator_jobs_state_from_path(path: &Path) -> io::Result<OperatorJobsState> {
    if !path.exists() {
        return Ok(default_operator_jobs_state());
    }
    let raw = fs::read_to_string(&path)?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(default_operator_jobs_state());
    }
    let state = serde_json::from_str::<OperatorJobsState>(trimmed).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid operator jobs state: {}: {err}", path.display()),
        )
    })?;
    if state.contract_version != 1 || state.packet_type != "operator_job_registry" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "operator jobs state must be contract_version 1 operator_job_registry",
        ));
    }
    Ok(state)
}

fn mutate_operator_jobs_state<T>(
    project_dir: &Path,
    action: impl FnOnce(&mut OperatorJobsState) -> io::Result<T>,
) -> io::Result<T> {
    let path = operator_jobs_state_path(project_dir);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    with_file_lock(&path, || {
        let mut state = read_operator_jobs_state_from_path(&path)?;
        let result = action(&mut state)?;
        write_operator_jobs_state_locked(&path, &mut state)?;
        Ok(result)
    })
}

fn write_operator_jobs_state_locked(path: &Path, state: &mut OperatorJobsState) -> io::Result<()> {
    state.updated_at = generated_at();
    let content = serde_json::to_string_pretty(state).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize operator jobs state: {err}"),
        )
    })?;
    write_text_file_locked(path, &format!("{content}\n"))
}

fn default_operator_jobs_state() -> OperatorJobsState {
    OperatorJobsState {
        contract_version: 1,
        packet_type: "operator_job_registry".to_string(),
        updated_at: generated_at(),
        jobs: Vec::new(),
    }
}

fn operator_jobs_state_path(project_dir: &Path) -> PathBuf {
    project_dir.join(".winsmux").join("operator-jobs.json")
}

fn operator_jobs_state_ref() -> &'static str {
    ".winsmux/operator-jobs.json"
}

fn operator_jobs_result_payload(
    action: &str,
    message: String,
    job: Option<OperatorJobRecord>,
    run: Option<OperatorJobRunRecord>,
    job_count: usize,
) -> Value {
    json!({
        "contract_version": 1,
        "packet_type": "operator_job_result",
        "command": format!("operator-jobs {action}"),
        "public_state_ref": operator_jobs_state_ref(),
        "job": job,
        "run": run,
        "summary": {
            "message": message,
            "job_count": job_count
        }
    })
}

fn required_option<'a>(value: Option<&'a str>, message: &str) -> io::Result<&'a str> {
    value
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, message))
}

fn find_operator_job_mut<'a>(
    state: &'a mut OperatorJobsState,
    job_id: &str,
) -> io::Result<&'a mut OperatorJobRecord> {
    state
        .jobs
        .iter_mut()
        .find(|job| job.job_id == job_id)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("operator job not found: {job_id}")))
}

fn operator_job_evidence_requirements(kind: &str, explicit: &[String]) -> Vec<String> {
    if !explicit.is_empty() {
        return explicit
            .iter()
            .map(|item| item.trim().to_string())
            .filter(|item| !item.is_empty())
            .collect();
    }
    match kind {
        "dependency-check" => vec!["dependency_report", "risk_summary", "proposed_change_summary"],
        "issue-triage" => vec!["issue_query", "triage_summary", "planning_mapping"],
        "documentation-refresh" => vec!["doc_inventory", "staleness_reason", "validation_plan"],
        "repository-hygiene" => vec!["git_guard", "public_surface_audit", "cleanup_candidate"],
        _ => vec!["operator_evidence"],
    }
    .into_iter()
    .map(str::to_string)
    .collect()
}

fn operator_job_run_evidence(
    job: &OperatorJobRecord,
    explicit: &[String],
) -> Vec<OperatorJobEvidenceRecord> {
    let source = if explicit.is_empty() {
        job.evidence_requirements.clone()
    } else {
        explicit
            .iter()
            .map(|item| item.trim().to_string())
            .filter(|item| !item.is_empty())
            .collect()
    };
    source
        .into_iter()
        .enumerate()
        .map(|(index, summary)| OperatorJobEvidenceRecord {
            evidence_id: format!("evidence-{}", index + 1),
            kind: summary.clone(),
            summary,
            reference: operator_jobs_state_ref().to_string(),
        })
        .collect()
}

fn operator_job_default_title(kind: &str) -> &'static str {
    match kind {
        "dependency-check" => "Dependency check",
        "issue-triage" => "Issue triage",
        "documentation-refresh" => "Documentation refresh",
        "repository-hygiene" => "Repository hygiene",
        _ => "Operator job",
    }
}

fn apply_operator_job_update(job: &mut OperatorJobRecord, update: &Map<String, Value>) -> io::Result<()> {
    if let Some(title) = update.get("title").and_then(Value::as_str) {
        job.title = title.to_string();
    }
    if let Some(schedule_type) = update.get("schedule_type").and_then(Value::as_str) {
        let schedule_type = validate_operator_job_schedule_type(schedule_type)?;
        job.schedule.schedule_type = schedule_type;
    }
    if let Some(every) = update.get("every").and_then(Value::as_str) {
        job.schedule.every = Some(every.to_string());
    }
    job.pending_update = None;
    Ok(())
}

fn validate_model_source(value: &str) -> io::Result<()> {
    let normalized = value.trim();
    if matches!(
        normalized,
        "provider-default" | "cli-discovery" | "official-doc" | "operator-override"
    ) {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Invalid provider registry model_source '{value}'."),
        ))
    }
}

fn validate_reasoning_effort(value: &str) -> io::Result<()> {
    let normalized = value.trim().to_ascii_lowercase();
    if matches!(
        normalized.as_str(),
        "provider-default" | "low" | "medium" | "high" | "xhigh" | "max"
    ) {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Invalid provider registry reasoning_effort '{value}'."),
        ))
    }
}

fn provider_capability_registry_path(project_dir: &Path) -> PathBuf {
    project_dir
        .join(".winsmux")
        .join("provider-capabilities.json")
}

fn read_provider_capability_registry(path: &Path) -> io::Result<ProviderCapabilityRegistry> {
    if !path.exists() {
        return Ok(ProviderCapabilityRegistry {
            version: 1,
            providers: Map::new(),
        });
    }

    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(ProviderCapabilityRegistry {
            version: 1,
            providers: Map::new(),
        });
    }

    let parsed: Value = serde_json::from_str(&raw).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Invalid provider capability registry JSON at '{}'.",
                path.display()
            ),
        )
    })?;
    let Some(root) = parsed.as_object() else {
        return Err(invalid_provider_capability_registry(path));
    };

    let version = match root.get("version") {
        Some(Value::Number(number)) => number.as_u64().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "Invalid provider capability registry version at '{}'.",
                    path.display()
                ),
            )
        })?,
        Some(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "Invalid provider capability registry version at '{}'.",
                    path.display()
                ),
            ))
        }
        None => 1,
    };
    if version != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Unsupported provider capability registry version '{version}'. Supported versions: 1."
            ),
        ));
    }

    let raw_providers = match root.get("providers") {
        Some(Value::Object(providers)) => providers.clone(),
        Some(Value::Null) | None => Map::new(),
        Some(_) => return Err(invalid_provider_capability_registry(path)),
    };

    let mut providers = Map::new();
    for (provider_id, capabilities) in &raw_providers {
        if provider_id.trim().is_empty() {
            return Err(invalid_provider_capability_registry(path));
        }
        providers.insert(
            provider_id.clone(),
            normalize_provider_capability_entry(path, provider_id, capabilities)?,
        );
    }

    Ok(ProviderCapabilityRegistry { version, providers })
}

fn normalize_provider_capability_entry(
    path: &Path,
    provider_id: &str,
    value: &Value,
) -> io::Result<Value> {
    let Some(entry) = value.as_object() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Invalid provider capability entry '{provider_id}' at '{}'.",
                path.display()
            ),
        ));
    };
    if entry.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Invalid provider capability entry '{provider_id}' at '{}'.",
                path.display()
            ),
        ));
    }

    let mut normalized = Map::new();
    let string_fields = [
        "adapter",
        "display_name",
        "command",
        "model_catalog_source",
        "local_access_note",
    ];
    let transport_fields = ["prompt_transports"];
    let string_array_fields = [
        "auth_modes",
        "local_interactive_oauth_modes",
        "model_sources",
        "reasoning_efforts",
    ];
    let raw_string_array_fields = ["read_only_launch_args"];
    let model_option_fields = ["model_options"];
    let bool_fields = [
        "supports_parallel_runs",
        "supports_interrupt",
        "supports_structured_result",
        "supports_file_edit",
        "supports_subagents",
        "supports_verification",
        "supports_consultation",
        "supports_context_reset",
    ];

    for (field, field_value) in entry {
        let name = field.as_str();
        if !string_fields.contains(&name)
            && !transport_fields.contains(&name)
            && !string_array_fields.contains(&name)
            && !raw_string_array_fields.contains(&name)
            && !model_option_fields.contains(&name)
            && !bool_fields.contains(&name)
        {
            return Err(invalid_provider_capability_field(name));
        }

        if string_fields.contains(&name) {
            let Some(text) = field_value.as_str() else {
                return Err(invalid_provider_capability_field(name));
            };
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                normalized.insert(field.clone(), Value::String(trimmed.to_string()));
            }
            continue;
        }

        if transport_fields.contains(&name) {
            let Some(items) = field_value.as_array() else {
                return Err(invalid_provider_capability_field(name));
            };
            if items.is_empty() {
                return Err(invalid_provider_capability_field(name));
            }
            let mut normalized_items = Vec::new();
            for item in items {
                let Some(transport) = item.as_str() else {
                    return Err(invalid_provider_capability_field(name));
                };
                let normalized_transport = transport.trim().to_ascii_lowercase();
                if normalized_transport.is_empty()
                    || !matches!(normalized_transport.as_str(), "argv" | "file" | "stdin")
                {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("Invalid provider capability prompt transport '{transport}'."),
                    ));
                }
                normalized_items.push(Value::String(normalized_transport));
            }
            normalized.insert(field.clone(), Value::Array(normalized_items));
            continue;
        }

        if string_array_fields.contains(&name) {
            let Some(items) = field_value.as_array() else {
                return Err(invalid_provider_capability_field(name));
            };
            let mut normalized_items = Vec::new();
            for item in items {
                let Some(text) = item.as_str() else {
                    return Err(invalid_provider_capability_field(name));
                };
                let normalized_text = text.trim().to_ascii_lowercase();
                if normalized_text.is_empty() {
                    return Err(invalid_provider_capability_field(name));
                }
                if name == "model_sources" && !valid_model_source(&normalized_text) {
                    return Err(invalid_provider_capability_field(name));
                }
                if name == "reasoning_efforts" && !valid_reasoning_effort(&normalized_text) {
                    return Err(invalid_provider_capability_field(name));
                }
                normalized_items.push(Value::String(normalized_text));
            }
            normalized.insert(field.clone(), Value::Array(normalized_items));
            continue;
        }

        if raw_string_array_fields.contains(&name) {
            let Some(items) = field_value.as_array() else {
                return Err(invalid_provider_capability_field(name));
            };
            if items.is_empty() {
                return Err(invalid_provider_capability_field(name));
            }
            let mut normalized_items = Vec::new();
            for item in items {
                let Some(text) = item.as_str() else {
                    return Err(invalid_provider_capability_field(name));
                };
                let trimmed_text = text.trim();
                if trimmed_text.is_empty() {
                    return Err(invalid_provider_capability_field(name));
                }
                normalized_items.push(Value::String(trimmed_text.to_string()));
            }
            normalized.insert(field.clone(), Value::Array(normalized_items));
            continue;
        }

        if model_option_fields.contains(&name) {
            let Some(items) = field_value.as_array() else {
                return Err(invalid_provider_capability_field(name));
            };
            if items.is_empty() {
                return Err(invalid_provider_capability_field(name));
            }
            let mut normalized_items = Vec::new();
            for item in items {
                normalized_items.push(normalize_provider_model_option(item)?);
            }
            normalized.insert(field.clone(), Value::Array(normalized_items));
            continue;
        }

        if bool_fields.contains(&name) {
            if !field_value.is_boolean() {
                return Err(invalid_provider_capability_field(name));
            }
            normalized.insert(field.clone(), field_value.clone());
        }
    }

    for required in ["adapter", "command", "prompt_transports"] {
        if !normalized.contains_key(required) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Missing provider capability field '{required}'."),
            ));
        }
    }

    Ok(Value::Object(normalized))
}

fn normalize_provider_model_option(value: &Value) -> io::Result<Value> {
    let Some(entry) = value.as_object() else {
        return Err(invalid_provider_capability_field("model_options"));
    };
    let mut normalized = Map::new();
    for (field, field_value) in entry {
        if !matches!(
            field.as_str(),
            "id" | "label" | "source" | "availability" | "notes"
        ) {
            return Err(invalid_provider_capability_field("model_options"));
        }
        let Some(text) = field_value.as_str() else {
            return Err(invalid_provider_capability_field("model_options"));
        };
        let trimmed = text.trim();
        if trimmed.is_empty() {
            if matches!(field.as_str(), "id" | "source") {
                return Err(invalid_provider_capability_field("model_options"));
            }
            continue;
        }
        let value = if field == "source" {
            let normalized_source = trimmed.to_ascii_lowercase();
            if !valid_model_source(&normalized_source) {
                return Err(invalid_provider_capability_field("model_options"));
            }
            normalized_source
        } else {
            trimmed.to_string()
        };
        normalized.insert(field.clone(), Value::String(value));
    }
    if !normalized.contains_key("id") || !normalized.contains_key("source") {
        return Err(invalid_provider_capability_field("model_options"));
    }
    Ok(Value::Object(normalized))
}

fn valid_model_source(value: &str) -> bool {
    matches!(
        value,
        "provider-default" | "cli-discovery" | "official-doc" | "operator-override"
    )
}

fn valid_reasoning_effort(value: &str) -> bool {
    matches!(
        value,
        "provider-default" | "low" | "medium" | "high" | "xhigh" | "max"
    )
}

fn default_provider_model_source() -> String {
    "provider-default".to_string()
}

fn default_provider_reasoning_effort() -> String {
    "provider-default".to_string()
}

fn inferred_model_source_for_model(model: &str) -> String {
    if provider_default_model(model) {
        default_provider_model_source()
    } else {
        "operator-override".to_string()
    }
}

fn provider_default_model(model: &str) -> bool {
    model.trim().is_empty() || model.trim().eq_ignore_ascii_case("provider-default")
}

fn provider_default_model_source(model_source: &str) -> bool {
    !model_source.trim().is_empty() && model_source.trim().eq_ignore_ascii_case("provider-default")
}

fn provider_model_override(model: &str, model_source: &str) -> bool {
    !provider_default_model(model) && !provider_default_model_source(model_source)
}

fn provider_default_reasoning_effort(reasoning_effort: &str) -> bool {
    reasoning_effort.trim().is_empty()
        || reasoning_effort
            .trim()
            .eq_ignore_ascii_case("provider-default")
}

fn invalid_provider_capability_field(field: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("Invalid provider capability field '{field}'."),
    )
}

fn invalid_provider_capability_registry(path: &Path) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!(
            "Invalid provider capability registry JSON at '{}'.",
            path.display()
        ),
    )
}

fn find_provider_capability<'a>(
    registry: &'a ProviderCapabilityRegistry,
    provider_id: &str,
) -> Option<&'a Value> {
    registry
        .providers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(provider_id))
        .map(|(_, value)| value)
}

fn provider_capability_value_text(value: &Value) -> String {
    match value {
        Value::Array(items) => items
            .iter()
            .map(provider_capability_value_text)
            .collect::<Vec<_>>()
            .join(","),
        Value::String(text) => text.clone(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(number) => number.to_string(),
        Value::Null => String::new(),
        Value::Object(_) => value.to_string(),
    }
}

impl BridgeSettings {
    fn has_slot(&self, slot_id: &str) -> bool {
        self.agent_slots
            .iter()
            .any(|slot| slot.slot_id.eq_ignore_ascii_case(slot_id))
    }

    fn slot(&self, slot_id: &str) -> Option<&ProviderSlotConfig> {
        self.agent_slots
            .iter()
            .find(|slot| slot.slot_id.eq_ignore_ascii_case(slot_id))
    }
}

impl ProviderRegistryEntry {
    fn new(options: &ProviderSwitchOptions) -> io::Result<Self> {
        if options.agent.is_none()
            && options.model.is_none()
            && options.model_source.is_none()
            && options.reasoning_effort.is_none()
            && options.prompt_transport.is_none()
            && options.auth_mode.is_none()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Provider registry entry requires agent, model, model_source, reasoning_effort, prompt_transport, or auth_mode.",
            ));
        }
        let model_source = options.model_source.clone().or_else(|| {
            options
                .model
                .as_deref()
                .map(inferred_model_source_for_model)
        });
        Ok(Self {
            agent: options.agent.clone(),
            model: options.model.clone(),
            model_source,
            reasoning_effort: options.reasoning_effort.clone(),
            prompt_transport: options.prompt_transport.clone(),
            auth_mode: options.auth_mode.clone(),
            updated_at_utc: generated_at(),
            reason: options.reason.clone(),
        })
    }

    fn from_value(slot_id: &str, value: &Value, path: &Path) -> io::Result<Self> {
        let Some(map) = value.as_object() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "Invalid provider registry slot '{slot_id}' at '{}'.",
                    path.display()
                ),
            ));
        };
        let agent = provider_registry_optional_string(map, "agent")?;
        let model = provider_registry_optional_string(map, "model")?;
        let mut model_source = provider_registry_optional_string(map, "model_source")?;
        let reasoning_effort = provider_registry_optional_string(map, "reasoning_effort")?;
        let prompt_transport = provider_registry_optional_string(map, "prompt_transport")?;
        let auth_mode = provider_registry_optional_string(map, "auth_mode")?;
        let updated_at_utc =
            provider_registry_optional_string(map, "updated_at_utc")?.unwrap_or_default();
        let reason = provider_registry_optional_string(map, "reason")?;
        if let Some(transport) = prompt_transport.as_deref() {
            if !matches!(transport, "argv" | "file" | "stdin") {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("Invalid provider registry prompt_transport '{transport}'."),
                ));
            }
        }
        if let Some(value) = model_source.as_deref() {
            validate_model_source(value)?;
        } else if let Some(value) = model.as_deref() {
            model_source = Some(inferred_model_source_for_model(value));
        }
        if let Some(value) = reasoning_effort.as_deref() {
            validate_reasoning_effort(value)?;
        }
        if agent.is_none()
            && model.is_none()
            && model_source.is_none()
            && reasoning_effort.is_none()
            && prompt_transport.is_none()
            && auth_mode.is_none()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "Invalid provider registry slot '{slot_id}' at '{}'.",
                    path.display()
                ),
            ));
        }
        Ok(Self {
            agent,
            model,
            model_source,
            reasoning_effort,
            prompt_transport,
            auth_mode,
            updated_at_utc,
            reason,
        })
    }

    fn to_value(&self) -> Value {
        let mut map = Map::new();
        if let Some(value) = self.agent.as_deref() {
            map.insert("agent".to_string(), Value::String(value.to_string()));
        }
        if let Some(value) = self.model.as_deref() {
            map.insert("model".to_string(), Value::String(value.to_string()));
        }
        if let Some(value) = self.model_source.as_deref() {
            map.insert("model_source".to_string(), Value::String(value.to_string()));
        }
        if let Some(value) = self.reasoning_effort.as_deref() {
            map.insert(
                "reasoning_effort".to_string(),
                Value::String(value.to_string()),
            );
        }
        if let Some(value) = self.prompt_transport.as_deref() {
            map.insert(
                "prompt_transport".to_string(),
                Value::String(value.to_string()),
            );
        }
        if let Some(value) = self.auth_mode.as_deref() {
            map.insert("auth_mode".to_string(), Value::String(value.to_string()));
        }
        map.insert(
            "updated_at_utc".to_string(),
            Value::String(self.updated_at_utc.clone()),
        );
        if let Some(value) = self.reason.as_deref() {
            map.insert("reason".to_string(), Value::String(value.to_string()));
        }
        Value::Object(map)
    }
}

fn read_bridge_settings(project_dir: &Path) -> io::Result<BridgeSettings> {
    let path = project_dir.join(".winsmux.yaml");
    let mut settings = BridgeSettings {
        agent: "codex".to_string(),
        model: String::new(),
        model_source: "provider-default".to_string(),
        reasoning_effort: "provider-default".to_string(),
        prompt_transport: "argv".to_string(),
        auth_mode: String::new(),
        agent_explicit: false,
        model_explicit: false,
        worker_role: ProviderRoleConfig::default(),
        agent_slots: Vec::new(),
    };
    if !path.exists() {
        if let Some(runtime_worker_role) = runtime_role_config(project_dir, "worker")? {
            settings.worker_role = merge_role_config(settings.worker_role, runtime_worker_role);
        }
        return Ok(settings);
    }

    let raw = fs::read_to_string(&path)?;
    if raw.trim().is_empty() {
        if let Some(runtime_worker_role) = runtime_role_config(project_dir, "worker")? {
            settings.worker_role = merge_role_config(settings.worker_role, runtime_worker_role);
        }
        return Ok(settings);
    }
    let root = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid settings: {}: {err}", path.display()),
        )
    })?;

    if let Some(value) = yaml_string(&root, "agent") {
        settings.agent = value;
        settings.agent_explicit = true;
    }
    if let Some(value) = yaml_string(&root, "model") {
        settings.model = value;
        settings.model_explicit = true;
    }
    if let Some(value) =
        yaml_string(&root, "model_source").or_else(|| yaml_string(&root, "model-source"))
    {
        settings.model_source = value;
    } else if settings.model_explicit {
        settings.model_source = inferred_model_source_for_model(&settings.model);
    }
    if let Some(value) =
        yaml_string(&root, "reasoning_effort").or_else(|| yaml_string(&root, "reasoning-effort"))
    {
        settings.reasoning_effort = value.to_ascii_lowercase();
    }
    settings.prompt_transport = yaml_string(&root, "prompt_transport")
        .or_else(|| yaml_string(&root, "prompt-transport"))
        .unwrap_or(settings.prompt_transport);
    settings.auth_mode = yaml_string(&root, "auth_mode")
        .or_else(|| yaml_string(&root, "auth-mode"))
        .unwrap_or_default();
    settings.worker_role = yaml_role_config(&root, "Worker")
        .or_else(|| yaml_role_config(&root, "worker"))
        .unwrap_or_default();
    if let Some(runtime_worker_role) = runtime_role_config(project_dir, "worker")? {
        settings.worker_role = merge_role_config(settings.worker_role, runtime_worker_role);
    }
    settings.agent_slots = yaml_agent_slots(&root)?;
    let external_operator = yaml_bool(&root, "external_operator")
        .or_else(|| yaml_bool(&root, "external-operator"))
        .unwrap_or(true);
    let legacy_role_layout = yaml_bool(&root, "legacy_role_layout")
        .or_else(|| yaml_bool(&root, "legacy-role-layout"))
        .unwrap_or(false);
    let worker_count = yaml_u64(&root, "worker_count")
        .or_else(|| yaml_u64(&root, "worker-count"))
        .unwrap_or(6);
    if settings.agent_slots.is_empty() && external_operator && !legacy_role_layout {
        for index in 1..=worker_count {
            settings.agent_slots.push(ProviderSlotConfig {
                slot_id: format!("worker-{index}"),
                agent: settings.agent_explicit.then(|| settings.agent.clone()),
                model: settings.model_explicit.then(|| settings.model.clone()),
                model_source: Some(settings.model_source.clone()),
                reasoning_effort: Some(settings.reasoning_effort.clone()),
                prompt_transport: Some(settings.prompt_transport.clone()),
                auth_mode: (!settings.auth_mode.trim().is_empty())
                    .then(|| settings.auth_mode.clone()),
            });
        }
    }
    Ok(settings)
}

fn merge_role_config(
    mut base: ProviderRoleConfig,
    overlay: ProviderRoleConfig,
) -> ProviderRoleConfig {
    if overlay.agent.is_some() {
        base.agent = overlay.agent;
    }
    if overlay.model.is_some() {
        base.model = overlay.model;
    }
    if overlay.model_source.is_some() {
        base.model_source = overlay.model_source;
    }
    if overlay.reasoning_effort.is_some() {
        base.reasoning_effort = overlay.reasoning_effort;
    }
    if overlay.prompt_transport.is_some() {
        base.prompt_transport = overlay.prompt_transport;
    }
    if overlay.auth_mode.is_some() {
        base.auth_mode = overlay.auth_mode;
    }
    base
}

fn runtime_role_config(project_dir: &Path, role: &str) -> io::Result<Option<ProviderRoleConfig>> {
    let path = project_dir
        .join(".winsmux")
        .join("runtime-role-preferences.json");
    if !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(&path)?;
    if raw.trim().is_empty() {
        return Ok(None);
    }
    let root = serde_json::from_str::<Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "invalid runtime role preferences: {}: {err}",
                path.display()
            ),
        )
    })?;
    let version = root.get("version").and_then(Value::as_u64).unwrap_or(1);
    if version != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Unsupported runtime role preferences version '{version}'. Supported versions: 1."
            ),
        ));
    }
    let roles = root.get("roles").unwrap_or(&root);
    runtime_role_config_from_roles(roles, role)
}

fn runtime_role_config_from_roles(
    roles: &Value,
    role: &str,
) -> io::Result<Option<ProviderRoleConfig>> {
    if let Some(map) = roles.as_object() {
        for (key, value) in map {
            if key.eq_ignore_ascii_case(role) {
                return Ok(Some(runtime_role_config_from_value(value)?));
            }
        }
        return Ok(None);
    }
    if let Some(items) = roles.as_array() {
        for item in items {
            let role_id =
                json_string_any(item, &["role_id", "roleId", "runtime_role", "runtimeRole"])
                    .unwrap_or_default();
            if role_id.eq_ignore_ascii_case(role) {
                return Ok(Some(runtime_role_config_from_value(item)?));
            }
        }
    }
    Ok(None)
}

fn runtime_role_config_from_value(value: &Value) -> io::Result<ProviderRoleConfig> {
    let model = json_string_any(value, &["model"]);
    let model_source = json_string_any(value, &["model_source", "model-source", "modelSource"])
        .or_else(|| model.as_deref().map(inferred_model_source_for_model));
    let config = ProviderRoleConfig {
        agent: json_string_any(value, &["agent", "provider"])
            .filter(|value| !value.eq_ignore_ascii_case("provider-default")),
        model,
        model_source,
        reasoning_effort: json_string_any(
            value,
            &["reasoning_effort", "reasoning-effort", "reasoningEffort"],
        )
        .map(|value| value.to_ascii_lowercase()),
        prompt_transport: json_string_any(value, &["prompt_transport", "prompt-transport"]),
        auth_mode: json_string_any(value, &["auth_mode", "auth-mode"]),
    };
    if let Some(source) = config.model_source.as_deref() {
        validate_model_source(source)?;
    }
    if let Some(effort) = config.reasoning_effort.as_deref() {
        validate_reasoning_effort(effort)?;
    }
    Ok(config)
}

fn json_string_any(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_string)
    })
}

fn yaml_agent_slots(root: &serde_yaml::Value) -> io::Result<Vec<ProviderSlotConfig>> {
    let Some(slots) = yaml_get(root, "agent_slots").or_else(|| yaml_get(root, "agent-slots"))
    else {
        return Ok(Vec::new());
    };
    let Some(items) = slots.as_sequence() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid agent_slots configuration: every slot entry must include at least slot_id.",
        ));
    };
    let mut result = Vec::new();
    for item in items {
        let slot_id = yaml_string(item, "slot_id")
            .or_else(|| yaml_string(item, "slot-id"))
            .unwrap_or_default();
        if slot_id.trim().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid agent_slots configuration: every slot entry must include at least slot_id.",
            ));
        }
        let model = yaml_string(item, "model");
        let model_source = yaml_string(item, "model_source")
            .or_else(|| yaml_string(item, "model-source"))
            .or_else(|| model.as_deref().map(inferred_model_source_for_model));
        result.push(ProviderSlotConfig {
            slot_id,
            agent: yaml_string(item, "agent"),
            model,
            model_source,
            reasoning_effort: yaml_string(item, "reasoning_effort")
                .or_else(|| yaml_string(item, "reasoning-effort"))
                .map(|value| value.to_ascii_lowercase()),
            prompt_transport: yaml_string(item, "prompt_transport")
                .or_else(|| yaml_string(item, "prompt-transport")),
            auth_mode: yaml_string(item, "auth_mode").or_else(|| yaml_string(item, "auth-mode")),
        });
    }
    Ok(result)
}

fn yaml_role_config(root: &serde_yaml::Value, role: &str) -> Option<ProviderRoleConfig> {
    let roles = yaml_get(root, "roles")?;
    let role_value = yaml_get(roles, role)?;
    let model = yaml_string(role_value, "model");
    let model_source = yaml_string(role_value, "model_source")
        .or_else(|| yaml_string(role_value, "model-source"))
        .or_else(|| model.as_deref().map(inferred_model_source_for_model));
    Some(ProviderRoleConfig {
        agent: yaml_string(role_value, "agent"),
        model,
        model_source,
        reasoning_effort: yaml_string(role_value, "reasoning_effort")
            .or_else(|| yaml_string(role_value, "reasoning-effort"))
            .map(|value| value.to_ascii_lowercase()),
        prompt_transport: yaml_string(role_value, "prompt_transport")
            .or_else(|| yaml_string(role_value, "prompt-transport")),
        auth_mode: yaml_string(role_value, "auth_mode")
            .or_else(|| yaml_string(role_value, "auth-mode")),
    })
}

fn yaml_get<'a>(value: &'a serde_yaml::Value, key: &str) -> Option<&'a serde_yaml::Value> {
    let map = value.as_mapping()?;
    let yaml_key = serde_yaml::Value::String(key.to_string());
    map.get(&yaml_key)
}

fn yaml_string(value: &serde_yaml::Value, key: &str) -> Option<String> {
    yaml_get(value, key)
        .and_then(serde_yaml::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn yaml_bool(value: &serde_yaml::Value, key: &str) -> Option<bool> {
    yaml_get(value, key).and_then(|item| {
        item.as_bool().or_else(|| {
            item.as_str()
                .map(str::trim)
                .and_then(|text| match text.to_ascii_lowercase().as_str() {
                    "true" => Some(true),
                    "false" => Some(false),
                    _ => None,
                })
        })
    })
}

fn yaml_u64(value: &serde_yaml::Value, key: &str) -> Option<u64> {
    yaml_get(value, key).and_then(|item| {
        item.as_u64().or_else(|| {
            item.as_str()
                .map(str::trim)
                .and_then(|text| text.parse::<u64>().ok())
        })
    })
}

fn resolve_slot_agent_config(
    project_dir: &Path,
    settings: &BridgeSettings,
    slot_id: &str,
) -> io::Result<SlotAgentConfig> {
    resolve_slot_agent_config_inner(project_dir, settings, slot_id, true)
}

fn resolve_slot_agent_config_without_registry(
    project_dir: &Path,
    settings: &BridgeSettings,
    slot_id: &str,
) -> io::Result<SlotAgentConfig> {
    resolve_slot_agent_config_inner(project_dir, settings, slot_id, false)
}

fn resolve_slot_agent_config_inner(
    project_dir: &Path,
    settings: &BridgeSettings,
    slot_id: &str,
    include_registry: bool,
) -> io::Result<SlotAgentConfig> {
    let mut agent = settings.agent.clone();
    let mut model = settings.model.clone();
    let mut model_source = settings.model_source.clone();
    let mut reasoning_effort = settings.reasoning_effort.clone();
    let mut prompt_transport = settings.prompt_transport.clone();
    let mut auth_mode = settings.auth_mode.clone();
    let mut source = "role".to_string();

    apply_role_config(
        &mut agent,
        &mut model,
        &mut model_source,
        &mut reasoning_effort,
        &mut prompt_transport,
        &mut auth_mode,
        &settings.worker_role,
        &mut source,
    );
    if let Some(slot) = settings.slot(slot_id) {
        if let Some(value) = slot.agent.as_deref() {
            agent = value.to_string();
            source = "slot".to_string();
        }
        if let Some(value) = slot.model.as_deref() {
            model = value.to_string();
            source = "slot".to_string();
        }
        if let Some(value) = slot.model_source.as_deref() {
            model_source = value.to_string();
            source = "slot".to_string();
        }
        if let Some(value) = slot.reasoning_effort.as_deref() {
            reasoning_effort = value.to_string();
            source = "slot".to_string();
        }
        if let Some(value) = slot.prompt_transport.as_deref() {
            prompt_transport = value.to_string();
            source = "slot".to_string();
        }
        if let Some(value) = slot.auth_mode.as_deref() {
            auth_mode = value.to_string();
            source = "slot".to_string();
        }
    }

    if include_registry {
        if let Some(entry) = provider_registry_entry_full(project_dir, slot_id)? {
            if let Some(value) = entry.agent {
                agent = value;
            }
            if let Some(value) = entry.model {
                model = value;
            }
            if let Some(value) = entry.model_source {
                model_source = value;
            }
            if let Some(value) = entry.reasoning_effort {
                reasoning_effort = value;
            }
            if let Some(value) = entry.prompt_transport {
                prompt_transport = value;
            }
            if let Some(value) = entry.auth_mode {
                auth_mode = value;
            }
            source = "registry".to_string();
        }
    }

    finalize_slot_agent_config(
        project_dir,
        agent,
        model,
        model_source,
        reasoning_effort,
        prompt_transport,
        auth_mode,
        source,
    )
}

fn resolve_slot_agent_config_with_registry_replacement(
    project_dir: &Path,
    settings: &BridgeSettings,
    slot_id: &str,
    registry_entry: Option<&ProviderRegistryEntry>,
) -> io::Result<SlotAgentConfig> {
    let mut agent = settings.agent.clone();
    let mut model = settings.model.clone();
    let mut model_source = settings.model_source.clone();
    let mut reasoning_effort = settings.reasoning_effort.clone();
    let mut prompt_transport = settings.prompt_transport.clone();
    let mut auth_mode = settings.auth_mode.clone();
    let mut source = "role".to_string();

    apply_role_config(
        &mut agent,
        &mut model,
        &mut model_source,
        &mut reasoning_effort,
        &mut prompt_transport,
        &mut auth_mode,
        &settings.worker_role,
        &mut source,
    );
    if let Some(slot) = settings.slot(slot_id) {
        if let Some(value) = slot.agent.as_deref() {
            agent = value.to_string();
            source = "slot".to_string();
        }
        if let Some(value) = slot.model.as_deref() {
            model = value.to_string();
            source = "slot".to_string();
        }
        if let Some(value) = slot.model_source.as_deref() {
            model_source = value.to_string();
            source = "slot".to_string();
        }
        if let Some(value) = slot.reasoning_effort.as_deref() {
            reasoning_effort = value.to_string();
            source = "slot".to_string();
        }
        if let Some(value) = slot.prompt_transport.as_deref() {
            prompt_transport = value.to_string();
            source = "slot".to_string();
        }
        if let Some(value) = slot.auth_mode.as_deref() {
            auth_mode = value.to_string();
            source = "slot".to_string();
        }
    }

    if let Some(entry) = registry_entry {
        if let Some(value) = entry.agent.as_deref() {
            agent = value.to_string();
        }
        if let Some(value) = entry.model.as_deref() {
            model = value.to_string();
        }
        if let Some(value) = entry.model_source.as_deref() {
            model_source = value.to_string();
        }
        if let Some(value) = entry.reasoning_effort.as_deref() {
            reasoning_effort = value.to_string();
        }
        if let Some(value) = entry.prompt_transport.as_deref() {
            prompt_transport = value.to_string();
        }
        if let Some(value) = entry.auth_mode.as_deref() {
            auth_mode = value.to_string();
        }
        source = "registry".to_string();
    }

    finalize_slot_agent_config(
        project_dir,
        agent,
        model,
        model_source,
        reasoning_effort,
        prompt_transport,
        auth_mode,
        source,
    )
}

fn finalize_slot_agent_config(
    project_dir: &Path,
    agent: String,
    model: String,
    model_source: String,
    reasoning_effort: String,
    prompt_transport: String,
    auth_mode: String,
    source: String,
) -> io::Result<SlotAgentConfig> {
    assert_provider_prompt_transport(project_dir, &agent, &prompt_transport)?;
    assert_provider_auth_mode(project_dir, &agent, &auth_mode)?;
    validate_model_source(&model_source)?;
    validate_reasoning_effort(&reasoning_effort)?;
    let capability = resolve_provider_capability(project_dir, &agent)?;
    assert_provider_capability_selection(
        capability.as_ref(),
        &agent,
        "model_sources",
        "model_source",
        &model_source,
    )?;
    assert_provider_capability_selection(
        capability.as_ref(),
        &agent,
        "reasoning_efforts",
        "reasoning_effort",
        &reasoning_effort,
    )?;
    Ok(SlotAgentConfig {
        auth_policy: provider_auth_policy(capability.as_ref(), &auth_mode),
        capability_adapter: capability_string(capability.as_ref(), "adapter"),
        capability_command: capability_string(capability.as_ref(), "command"),
        model_options: capability
            .as_ref()
            .and_then(|value| value.get("model_options"))
            .cloned()
            .unwrap_or_else(|| Value::Array(Vec::new())),
        model_sources: capability
            .as_ref()
            .and_then(|value| value.get("model_sources"))
            .cloned()
            .unwrap_or_else(|| Value::Array(Vec::new())),
        reasoning_efforts: capability
            .as_ref()
            .and_then(|value| value.get("reasoning_efforts"))
            .cloned()
            .unwrap_or_else(|| Value::Array(Vec::new())),
        local_access_note: capability_string(capability.as_ref(), "local_access_note"),
        supports_parallel_runs: capability_bool(capability.as_ref(), "supports_parallel_runs"),
        supports_interrupt: capability_bool(capability.as_ref(), "supports_interrupt"),
        supports_structured_result: capability_bool(
            capability.as_ref(),
            "supports_structured_result",
        ),
        supports_file_edit: capability_bool(capability.as_ref(), "supports_file_edit"),
        supports_subagents: capability_bool(capability.as_ref(), "supports_subagents"),
        supports_verification: capability_bool(capability.as_ref(), "supports_verification"),
        supports_consultation: capability_bool(capability.as_ref(), "supports_consultation"),
        supports_context_reset: capability_bool(capability.as_ref(), "supports_context_reset"),
        agent,
        model,
        model_source,
        reasoning_effort,
        prompt_transport,
        auth_mode,
        source,
    })
}

fn apply_role_config(
    agent: &mut String,
    model: &mut String,
    model_source: &mut String,
    reasoning_effort: &mut String,
    prompt_transport: &mut String,
    auth_mode: &mut String,
    config: &ProviderRoleConfig,
    source: &mut String,
) {
    if let Some(value) = config.agent.as_deref() {
        *agent = value.to_string();
        *source = "role".to_string();
    }
    if let Some(value) = config.model.as_deref() {
        *model = value.to_string();
        *source = "role".to_string();
    }
    if let Some(value) = config.model_source.as_deref() {
        *model_source = value.to_string();
        *source = "role".to_string();
    }
    if let Some(value) = config.reasoning_effort.as_deref() {
        *reasoning_effort = value.to_string();
        *source = "role".to_string();
    }
    if let Some(value) = config.prompt_transport.as_deref() {
        *prompt_transport = value.to_string();
        *source = "role".to_string();
    }
    if let Some(value) = config.auth_mode.as_deref() {
        *auth_mode = value.to_string();
        *source = "role".to_string();
    }
}

fn validate_provider_switch_candidate(
    project_dir: &Path,
    settings: &BridgeSettings,
    options: &ProviderSwitchOptions,
    candidate_entry: &ProviderRegistryEntry,
) -> io::Result<()> {
    let _ = resolve_slot_agent_config_with_registry_replacement(
        project_dir,
        settings,
        &options.slot_id,
        Some(candidate_entry),
    )?;
    Ok(())
}

fn validate_provider_switch_clear_candidate(
    project_dir: &Path,
    settings: &BridgeSettings,
    slot_id: &str,
) -> io::Result<()> {
    let _ = resolve_slot_agent_config_without_registry(project_dir, settings, slot_id)?;
    Ok(())
}

fn provider_registry_path(project_dir: &Path) -> PathBuf {
    project_dir.join(".winsmux").join("provider-registry.json")
}

fn read_provider_registry(path: &Path) -> io::Result<Map<String, Value>> {
    if !path.exists() {
        let mut root = Map::new();
        root.insert("version".to_string(), Value::from(1));
        root.insert("slots".to_string(), Value::Object(Map::new()));
        return Ok(root);
    }
    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        let mut root = Map::new();
        root.insert("version".to_string(), Value::from(1));
        root.insert("slots".to_string(), Value::Object(Map::new()));
        return Ok(root);
    }
    let parsed: Value = serde_json::from_str(&raw).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Invalid provider registry JSON at '{}'.", path.display()),
        )
    })?;
    let Some(root) = parsed.as_object() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Invalid provider registry JSON at '{}'.", path.display()),
        ));
    };
    match root.get("version") {
        Some(Value::Number(number)) if number.as_u64() == Some(1) => {}
        Some(_) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Unsupported provider registry version. Supported versions: 1.",
            ))
        }
        None => {}
    }
    Ok(root.clone())
}

fn provider_registry_entry_full(
    project_dir: &Path,
    slot_id: &str,
) -> io::Result<Option<ProviderRegistryEntry>> {
    let path = provider_registry_path(project_dir);
    let root = read_provider_registry(&path)?;
    let Some(slots) = root.get("slots").and_then(Value::as_object) else {
        return Ok(None);
    };
    for (candidate, value) in slots {
        if candidate.eq_ignore_ascii_case(slot_id) {
            return Ok(Some(ProviderRegistryEntry::from_value(
                candidate, value, &path,
            )?));
        }
    }
    Ok(None)
}

fn write_provider_registry_entry(
    path: &Path,
    slot_id: &str,
    entry: ProviderRegistryEntry,
) -> io::Result<()> {
    let mut root = read_provider_registry(path)?;
    let slots = ensure_provider_registry_slots(&mut root)?;
    let matched: Vec<String> = slots
        .keys()
        .filter(|candidate| candidate.eq_ignore_ascii_case(slot_id))
        .cloned()
        .collect();
    for key in matched {
        slots.remove(&key);
    }
    slots.insert(slot_id.to_string(), entry.to_value());
    write_provider_registry(path, root)
}

fn remove_provider_registry_entry(
    path: &Path,
    slot_id: &str,
) -> io::Result<ProviderRegistryRemoveResult> {
    let mut root = read_provider_registry(path)?;
    let slots = ensure_provider_registry_slots(&mut root)?;
    let matched = slots
        .keys()
        .find(|candidate| candidate.eq_ignore_ascii_case(slot_id))
        .cloned();
    let removed = if let Some(key) = matched {
        slots.remove(&key).is_some()
    } else {
        false
    };
    let updated_at_utc = generated_at();
    write_provider_registry(path, root)?;
    Ok(ProviderRegistryRemoveResult {
        removed,
        updated_at_utc,
    })
}

fn ensure_provider_registry_slots(
    root: &mut Map<String, Value>,
) -> io::Result<&mut Map<String, Value>> {
    if !root.contains_key("version") {
        root.insert("version".to_string(), Value::from(1));
    }
    if !root.contains_key("slots") {
        root.insert("slots".to_string(), Value::Object(Map::new()));
    }
    root.get_mut("slots")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid provider registry slots.",
            )
        })
}

fn write_provider_registry(path: &Path, root: Map<String, Value>) -> io::Result<()> {
    let content = serde_json::to_string_pretty(&Value::Object(root)).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize provider registry: {err}"),
        )
    })?;
    write_text_file_with_lock(path, &(content + "\n"))
}

fn provider_registry_optional_string(
    map: &Map<String, Value>,
    key: &str,
) -> io::Result<Option<String>> {
    let Some(value) = map.get(key) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    let Some(text) = value.as_str() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Invalid provider registry field '{key}'."),
        ));
    };
    let trimmed = text.trim();
    if trimmed.is_empty() {
        if matches!(
            key,
            "agent"
                | "model"
                | "model_source"
                | "reasoning_effort"
                | "prompt_transport"
                | "auth_mode"
        ) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Invalid provider registry field '{key}'."),
            ));
        }
        return Ok(None);
    }
    let normalized = if key == "prompt_transport" {
        trimmed.to_ascii_lowercase()
    } else {
        trimmed.to_string()
    };
    Ok(Some(normalized))
}

fn resolve_provider_capability(project_dir: &Path, provider_id: &str) -> io::Result<Option<Value>> {
    let path = provider_capability_registry_path(project_dir);
    let registry = read_provider_capability_registry(&path)?;
    if registry.providers.is_empty() {
        return Ok(None);
    }
    find_provider_capability(&registry, provider_id)
        .cloned()
        .map(Some)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("Provider capability '{provider_id}' was not found."),
            )
        })
}

fn assert_provider_prompt_transport(
    project_dir: &Path,
    provider_id: &str,
    prompt_transport: &str,
) -> io::Result<()> {
    if provider_id.trim().is_empty() || prompt_transport.trim().is_empty() {
        return Ok(());
    }
    let Some(capability) = resolve_provider_capability(project_dir, provider_id)? else {
        return Ok(());
    };
    let Some(transports) = capability
        .get("prompt_transports")
        .and_then(Value::as_array)
    else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Provider capability '{provider_id}' does not declare prompt_transports."),
        ));
    };
    let requested = prompt_transport.trim().to_ascii_lowercase();
    let supported: Vec<String> = transports
        .iter()
        .filter_map(Value::as_str)
        .map(|value| value.trim().to_ascii_lowercase())
        .collect();
    if !supported.iter().any(|value| value == &requested) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "Provider capability '{provider_id}' does not support prompt_transport '{requested}'. Supported values: {}.",
                supported.join(", ")
            ),
        ));
    }
    Ok(())
}

fn assert_provider_auth_mode(
    project_dir: &Path,
    provider_id: &str,
    auth_mode: &str,
) -> io::Result<()> {
    if auth_mode.trim().is_empty() {
        return Ok(());
    }
    let requested = auth_mode.trim().to_ascii_lowercase();
    if blocked_provider_auth_mode(&requested) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Provider auth_mode '{requested}' is not allowed. winsmux must not broker OAuth, receive callback URLs, extract provider tokens, or share provider tokens across panes."),
        ));
    }
    let Some(capability) = resolve_provider_capability(project_dir, provider_id)? else {
        return Ok(());
    };
    let Some(auth_modes) = capability.get("auth_modes").and_then(Value::as_array) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Provider capability '{provider_id}' does not declare auth_modes."),
        ));
    };
    let supported: Vec<String> = auth_modes
        .iter()
        .filter_map(Value::as_str)
        .map(|value| value.trim().to_ascii_lowercase())
        .collect();
    if !supported.iter().any(|value| value == &requested) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "Provider capability '{provider_id}' does not support auth_mode '{requested}'. Supported values: {}.",
                supported.join(", ")
            ),
        ));
    }
    Ok(())
}

fn assert_provider_capability_selection(
    capability: Option<&Value>,
    provider_id: &str,
    capability_field: &str,
    selector_name: &str,
    value: &str,
) -> io::Result<()> {
    if value.trim().is_empty() {
        return Ok(());
    }
    let Some(capability) = capability else {
        return Ok(());
    };
    let Some(raw_values) = capability.get(capability_field) else {
        return Ok(());
    };
    let Some(values) = raw_values.as_array() else {
        return Err(invalid_provider_capability_field(capability_field));
    };

    let requested = value.trim().to_ascii_lowercase();
    let supported: Vec<String> = values
        .iter()
        .filter_map(Value::as_str)
        .map(|item| item.trim().to_ascii_lowercase())
        .filter(|item| !item.is_empty())
        .collect();
    if !supported.iter().any(|item| item == &requested) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "Provider capability '{provider_id}' does not support {selector_name} '{requested}'. Supported values: {}.",
                supported.join(", ")
            ),
        ));
    }
    Ok(())
}

fn blocked_provider_auth_mode(auth_mode: &str) -> bool {
    matches!(
        auth_mode.trim().to_ascii_lowercase().as_str(),
        "oauth-broker"
            | "token-broker"
            | "callback-url"
            | "callback-url-receiver"
            | "shared-token"
            | "provider-api-proxy"
    )
}

fn provider_auth_policy(capability: Option<&Value>, auth_mode: &str) -> String {
    if auth_mode.trim().is_empty() {
        return "unspecified".to_string();
    }
    let normalized = auth_mode.trim().to_ascii_lowercase();
    let local_modes: Vec<String> = capability
        .and_then(|item| item.get("local_interactive_oauth_modes"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(|value| value.trim().to_ascii_lowercase())
                .collect()
        })
        .unwrap_or_default();
    if local_modes.iter().any(|mode| mode == &normalized)
        || normalized.ends_with("oauth")
        || normalized.ends_with("chatgpt-local")
    {
        "local_interactive_only".to_string()
    } else {
        "standard".to_string()
    }
}

fn capability_string(capability: Option<&Value>, key: &str) -> String {
    capability
        .and_then(|value| value.get(key))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn capability_string_array(capability: Option<&Value>, key: &str) -> Vec<String> {
    capability
        .and_then(|value| value.get(key))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(ToString::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn capability_bool(capability: Option<&Value>, key: &str) -> bool {
    capability
        .and_then(|value| value.get(key))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn validate_provider_switch_restart_target(
    project_dir: &Path,
    slot_id: &str,
) -> io::Result<String> {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;
    let session_name = manifest_session_name(&manifest)?;
    let project_root = manifest_project_dir(&manifest).unwrap_or_else(|| project_dir.to_path_buf());
    let session_git_worktree_dir = manifest_session_git_worktree_dir(&manifest);
    let context = resolve_restart_manifest_context(
        &manifest,
        slot_id,
        &manifest_path,
        &project_root,
        session_git_worktree_dir.as_deref(),
    )
    .map_err(|_| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("provider-switch --restart target slot '{slot_id}' is not present in the orchestra manifest."),
        )
    })?;
    ensure_live_pane_target(&session_name, &context.pane_id)?;
    Ok(context.pane_id)
}

pub fn run_runs_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux runs [--json] [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("runs", args, 0)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    let payload = LedgerRunsPayload::from_snapshot(
        generated_at(),
        project_dir_string(&options.project_dir),
        &snapshot,
    );
    if options.json {
        write_json(&payload)
    } else {
        let payload = payload_to_value(&payload)?;
        print_runs_table(&payload)
    }
}

pub fn run_explain_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("explain"));
        return Ok(());
    }
    let options = parse_explain_options(args)?;

    let run_id = options.positionals[0].clone();
    let snapshot = load_snapshot(&options.project_dir)?;
    let projection = snapshot.explain_projection(&run_id).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, format!("run not found: {run_id}"))
    })?;
    let observation_pack = read_artifact_json(
        &projection.run.experiment_packet.observation_pack_ref,
        &options.project_dir,
        &[".winsmux", "observation-packs"],
        &run_id,
    );
    let consultation_packet = read_artifact_json(
        &projection.run.experiment_packet.consultation_ref,
        &options.project_dir,
        &[".winsmux", "consultations"],
        &run_id,
    );
    let payload = LedgerExplainPayload::from_projection(
        generated_at(),
        project_dir_string(&options.project_dir),
        projection,
        observation_pack,
        consultation_packet,
        Value::Null,
    );
    if options.follow {
        if options.json {
            write_json(&payload)?;
        } else {
            let payload_value = payload_to_value(&payload)?;
            print_explain_follow_header(&payload_value)?;
        }
        let payload = payload_to_value(&payload)?;
        return stream_explain_follow(&options.project_dir, payload, options.json);
    }
    if options.json {
        write_json(&payload)
    } else {
        let payload = payload_to_value(&payload)?;
        print_explain_text(&payload)
    }
}

pub fn run_conflict_preflight_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("conflict-preflight"));
        return Ok(());
    }

    run_conflict_preflight(args, false)
}

pub fn run_compare_preflight_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("compare-preflight"));
        return Ok(());
    }

    run_conflict_preflight(args, true)
}

fn run_conflict_preflight(args: &[&String], compare_alias: bool) -> io::Result<()> {
    let usage_key = if compare_alias {
        "compare-preflight"
    } else {
        "conflict-preflight"
    };
    let options = parse_conflict_preflight_options(args, usage_key)?;
    let mut payload =
        conflict_preflight_payload(&env::current_dir()?, &options.left_ref, &options.right_ref)?;
    if compare_alias {
        payload.command = "compare preflight".to_string();
        payload.next_action = payload
            .next_action
            .replace("winsmux conflict-preflight", "winsmux compare preflight");
    }
    if options.json {
        return write_json(&payload);
    }

    let label = if compare_alias {
        "compare preflight"
    } else {
        "conflict preflight"
    };
    println!("{label}: {}", payload.status);
    println!(
        "left: {} ({})",
        payload.left_ref,
        short_head_sha(&payload.left_sha)
    );
    println!(
        "right: {} ({})",
        payload.right_ref,
        short_head_sha(&payload.right_sha)
    );
    if !payload.merge_base.trim().is_empty() {
        println!("merge-base: {}", short_head_sha(&payload.merge_base));
    }
    println!("overlap paths: {}", payload.overlap_paths.len());
    for path in &payload.overlap_paths {
        println!("- {path}");
    }
    println!("next: {}", payload.next_action);
    Ok(())
}

pub fn run_compare_runs_command(args: &[&String]) -> io::Result<()> {
    run_compare_runs_with_usage("compare-runs", args)
}

pub fn run_compare_runs_public_command(args: &[&String]) -> io::Result<()> {
    run_compare_runs_with_usage("compare runs", args)
}

fn run_compare_runs_with_usage(command_name: &str, args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for(command_name));
        return Ok(());
    }
    let options = parse_options(command_name, args, 2)?;

    let snapshot = load_snapshot(&options.project_dir)?;
    let left_id = options.positionals[0].clone();
    let right_id = options.positionals[1].clone();
    let left = snapshot.explain_projection(&left_id).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, format!("run not found: {left_id}"))
    })?;
    let right = snapshot.explain_projection(&right_id).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("run not found: {right_id}"),
        )
    })?;
    let payload = compare_runs_payload(&left, &right);
    if options.json {
        return write_json(&payload);
    }

    println!(
        "Compare: {} vs {}",
        payload["left"]["run_id"].as_str().unwrap_or_default(),
        payload["right"]["run_id"].as_str().unwrap_or_default()
    );
    println!(
        "Shared changed files: {}",
        payload["shared_changed_files"]
            .as_array()
            .map(|items| items.len())
            .unwrap_or(0)
    );
    if !payload["confidence_delta"].is_null() {
        println!("Confidence delta: {}", payload["confidence_delta"]);
    }
    if let Some(winner) = payload["recommend"]["winning_run_id"].as_str() {
        if !winner.is_empty() {
            println!("Winning run: {winner}");
        }
    }
    println!(
        "Next action: {}",
        payload["recommend"]["next_action"]
            .as_str()
            .unwrap_or_default()
    );
    let differences = payload["differences"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    if differences.is_empty() {
        println!("Differences: (none)");
    } else {
        println!("Differences:");
        for difference in differences {
            println!(
                "- {}: left={} right={}",
                difference["field"].as_str().unwrap_or_default(),
                compare_display_value(&difference["left"]),
                compare_display_value(&difference["right"])
            );
        }
    }
    Ok(())
}

pub fn run_promote_tactic_command(args: &[&String]) -> io::Result<()> {
    run_promote_tactic_with_usage("promote-tactic", args)
}

pub fn run_compare_promote_command(args: &[&String]) -> io::Result<()> {
    run_promote_tactic_with_usage("compare promote", args)
}

fn run_promote_tactic_with_usage(command_name: &'static str, args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for(command_name));
        return Ok(());
    }
    let options = parse_promote_tactic_options(command_name, args)?;
    let run_id = options.positionals[0].clone();
    if !matches!(
        options.kind.as_str(),
        "playbook" | "prewarm" | "verification"
    ) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Unsupported promote kind: {}", options.kind),
        ));
    }

    let snapshot = load_snapshot(&options.project_dir)?;
    let projection = snapshot.explain_projection(&run_id).ok_or_else(|| {
        io::Error::new(io::ErrorKind::NotFound, format!("run not found: {run_id}"))
    })?;
    if !run_recommendable(&projection.run) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("run is not promotable: {run_id}"),
        ));
    }

    let consultation_packet = read_artifact_json(
        &projection.run.experiment_packet.consultation_ref,
        &options.project_dir,
        &[".winsmux", "consultations"],
        &run_id,
    );
    let candidate = promote_tactic_candidate(&projection, &consultation_packet, &options);
    let artifact = write_playbook_candidate(&options.project_dir, &candidate)?;
    let result = json!({
        "generated_at": generated_at(),
        "run_id": run_id,
        "candidate_ref": artifact.reference,
        "candidate_path": artifact.path,
        "candidate": candidate,
    });

    if options.json {
        return write_json(&result);
    }
    println!(
        "promoted tactic from {} -> {}",
        result["run_id"].as_str().unwrap_or_default(),
        result["candidate_ref"].as_str().unwrap_or_default()
    );
    Ok(())
}

pub fn run_consult_result_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("consult-result"));
        return Ok(());
    }
    let options = parse_consult_result_options(args)?;
    assert_consult_role_permission("consult-result")?;

    let timestamp = generated_at();
    let context = consultation_command_context(&options.project_dir, &options.run_id)?;
    let packet = consultation_result_packet(&context, &options, &timestamp);
    let artifact = write_consultation_packet(&options.project_dir, "consult-result", &packet)?;
    let event = consultation_result_event(&context, &options, &artifact.reference, &timestamp);
    append_event_record(&options.project_dir, &event)?;
    let _ = mark_current_review_pane_last_event(&options.project_dir, "consult.result", &timestamp);

    if options.json {
        return write_json(&json!({
            "run_id": context.run_id,
            "task_id": context.task_id,
            "pane_id": context.pane_id,
            "slot": context.slot,
            "kind": "consult_result",
            "mode": options.mode,
            "target_slot": options.target_slot,
            "recommendation": options.message,
            "confidence": options.confidence,
            "next_test": options.next_test,
            "risks": options.risks,
            "consultation_ref": artifact.reference,
            "cost_unit_refs": consultation_governance_cost_unit_refs(
                &context,
                &options.mode,
                &options.target_slot,
            ),
            "generated_at": timestamp,
        }));
    }

    println!("consult result recorded for {}", context.run_id);
    Ok(())
}

pub fn run_consult_request_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("consult-request"));
        return Ok(());
    }
    let options = parse_consult_request_options(args)?;
    assert_consult_role_permission("consult-request")?;

    let timestamp = generated_at();
    let context = consultation_command_context(&options.project_dir, "")?;
    let packet = consultation_request_packet(&context, &options, &timestamp);
    let artifact = write_consultation_packet(&options.project_dir, "consult-request", &packet)?;
    let event = consultation_request_event(&context, &options, &artifact.reference, &timestamp);
    append_event_record(&options.project_dir, &event)?;
    let _ =
        mark_current_review_pane_last_event(&options.project_dir, "consult.request", &timestamp);

    println!("consult request recorded for {}", context.run_id);
    Ok(())
}

pub fn run_consult_error_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("consult-error"));
        return Ok(());
    }
    let options = parse_consult_error_options(args)?;
    assert_consult_role_permission("consult-error")?;

    let timestamp = generated_at();
    let context = consultation_command_context(&options.project_dir, "")?;
    let packet = consultation_error_packet(&context, &options, &timestamp);
    let artifact = write_consultation_packet(&options.project_dir, "consult-error", &packet)?;
    let event = consultation_error_event(&context, &options, &artifact.reference, &timestamp);
    append_event_record(&options.project_dir, &event)?;
    let _ = mark_current_review_pane_last_event(&options.project_dir, "consult.error", &timestamp);

    println!("consult error recorded for {}", context.run_id);
    Ok(())
}

pub fn run_poll_events_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("poll-events"));
        return Ok(());
    }
    let options = parse_poll_events_options(args)?;
    if options.json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("poll-events"),
        ));
    }

    let mut cursor = 0usize;
    if let Some(raw_cursor) = options.positionals.first() {
        let parsed = raw_cursor
            .parse::<i32>()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, usage_for("poll-events")))?;
        if parsed > 0 {
            cursor = parsed as usize;
        }
    }

    let events_path = options.project_dir.join(".winsmux").join("events.jsonl");
    let mut response = json!({
        "cursor": 0,
        "events": [],
    });
    if !events_path.is_file() {
        return write_json(&response);
    }

    let raw = fs::read_to_string(&events_path)
        .map_err(|err| io::Error::new(err.kind(), format!("failed to read event log: {}", err)))?;
    let lines: Vec<&str> = raw.lines().filter(|line| !line.trim().is_empty()).collect();
    if cursor > lines.len() {
        cursor = lines.len();
    }

    let mut events = Vec::new();
    for (index, line) in lines.iter().enumerate().skip(cursor) {
        let event = serde_json::from_str::<Value>(line).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("failed to parse event log line {}: {}", index + 1, err),
            )
        })?;
        events.push(event);
    }

    response["cursor"] = json!(lines.len());
    response["events"] = Value::Array(events);
    write_json(&response)
}

pub fn run_review_reset_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux review-reset [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("review-reset", args, 0)?;
    if options.json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("review-reset"),
        ));
    }

    let branch = current_git_branch(&options.project_dir)?;
    clear_review_state_record(&options.project_dir, &branch)?;
    let _ = clear_current_pane_review_manifest_state(&options.project_dir);
    println!("review PASS cleared for {branch}");
    Ok(())
}

pub fn run_review_request_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("usage: winsmux review-request [--project-dir <path>]");
        return Ok(());
    }
    let options = parse_options("review-request", args, 0)?;
    if options.json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("review-request"),
        ));
    }
    assert_review_role_permission("review-request")?;

    let branch = current_git_branch(&options.project_dir)?;
    let head_sha = current_git_head(&options.project_dir)?;
    let context = current_review_pane_context(&options.project_dir)?;
    let timestamp = generated_at();
    let request = review_request_record(&branch, &head_sha, &context, &timestamp);
    let reviewer = json!({
        "pane_id": context.pane_id,
        "label": context.label,
        "role": context.role,
        "agent_name": env::var("WINSMUX_AGENT_NAME").unwrap_or_default(),
    });

    let mut state = load_review_state(&options.project_dir)?;
    state.insert(
        branch.clone(),
        json!({
            "status": "PENDING",
            "branch": branch,
            "head_sha": head_sha,
            "request": request,
            "reviewer": reviewer,
            "updatedAt": timestamp,
        }),
    );
    save_review_state(&options.project_dir, state)?;
    let _ = mark_current_pane_review_requested(&options.project_dir, &context, &branch, &head_sha);
    println!("review request recorded for {branch}");
    Ok(())
}

pub fn run_dispatch_review_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("dispatch-review"));
        return Ok(());
    }
    if !args.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("dispatch-review"),
        ));
    }
    assert_dispatch_review_role_permission("dispatch-review")?;

    let project_dir = env::current_dir()?;
    let branch = current_git_branch(&project_dir)?;
    let head_sha = current_git_head(&project_dir)?;
    let context = preferred_review_pane_context(&project_dir)?;
    let short_head = short_head_sha(&head_sha);
    println!(
        "Dispatching review to {} [{}] for branch {} ({})",
        context.label, context.pane_id, branch, short_head
    );

    send_review_request_to_pane(&context.pane_id)?;
    println!(
        "review-request sent to {}. Waiting for PENDING state...",
        context.label
    );

    if !wait_for_pending_review_state(&project_dir, &branch, &head_sha)? {
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            format!(
                "review-request was not recorded after {} attempts. Check review pane {}.",
                dispatch_review_poll_attempts(),
                context.pane_id
            ),
        ));
    }

    println!(
        "PENDING confirmed. {} pane will run review-approve or review-fail. Monitor review-state.json for result.",
        context.role
    );
    Ok(())
}

pub fn run_review_approve_command(args: &[&String]) -> io::Result<()> {
    record_review_result(
        args,
        "review-approve",
        "PASS",
        "approved_at",
        "approved_via",
        "pass",
    )
}

pub fn run_review_fail_command(args: &[&String]) -> io::Result<()> {
    record_review_result(
        args,
        "review-fail",
        "FAIL",
        "failed_at",
        "failed_via",
        "fail",
    )
}

pub fn run_restart_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("restart"));
        return Ok(());
    }
    let options = parse_options("restart", args, 1)?;
    if options.json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("restart"),
        ));
    }

    let target = options.positionals[0].clone();
    let plan = build_restart_plan(&options.project_dir, &target)?;
    invoke_restart_plan(&plan)?;
    let _ = update_restart_manifest_metadata(&options.project_dir, &plan);
    println!("restarted {} ({})", plan.pane_id, plan.label);
    Ok(())
}

pub fn run_rebind_worktree_command(args: &[&String]) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for("rebind-worktree"));
        return Ok(());
    }
    let options = parse_rebind_worktree_options(args)?;
    let target = options.positionals[0].clone();
    let new_worktree_path = options.positionals[1..].join(" ").trim().to_string();
    if new_worktree_path.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "new worktree path must not be empty",
        ));
    }

    let requested_path = PathBuf::from(&new_worktree_path);
    if !requested_path.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("worktree path not found: {new_worktree_path}"),
        ));
    }

    let resolved_worktree_path = resolved_display_path(&requested_path)?;
    let manifest_path = options.project_dir.join(".winsmux").join("manifest.yaml");
    let context =
        update_rebind_manifest_with_lock(&manifest_path, &target, &resolved_worktree_path)?;
    println!(
        "rebound {} ({}) to {}",
        context.pane_id, context.label, resolved_worktree_path
    );
    Ok(())
}

struct ParsedOptions {
    json: bool,
    project_dir: PathBuf,
    positionals: Vec<String>,
}

struct DesktopSummaryOptions {
    json: bool,
    stream: bool,
    project_dir: PathBuf,
}

struct MetaPlanOptions {
    json: bool,
    project_dir: PathBuf,
    task: String,
    session_name: String,
    role_file: Option<PathBuf>,
    review_rounds: Option<u8>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct MetaPlanRole {
    #[serde(alias = "role-id")]
    role_id: String,
    label: String,
    provider: String,
    model: String,
    #[serde(default = "default_provider_model_source", alias = "model-source")]
    model_source: String,
    #[serde(
        default = "default_provider_reasoning_effort",
        alias = "reasoning-effort"
    )]
    reasoning_effort: String,
    #[serde(alias = "plan-mode")]
    plan_mode: String,
    #[serde(alias = "read-only")]
    read_only: bool,
    #[serde(default, alias = "review-rounds")]
    review_rounds: u8,
    #[serde(default)]
    capabilities: Vec<String>,
    #[serde(default)]
    prompt: String,
}

#[derive(Debug, Deserialize)]
struct MetaPlanRoleFile {
    version: u32,
    roles: Vec<MetaPlanRole>,
}

struct MetaPlanRun {
    run_id: String,
    role_count: usize,
    review_rounds: u8,
    integrated_plan_ref: String,
    audit_log_ref: String,
    payload: Value,
}

struct ExplainOptions {
    json: bool,
    follow: bool,
    project_dir: PathBuf,
    positionals: Vec<String>,
}

struct PromoteTacticOptions {
    json: bool,
    project_dir: PathBuf,
    positionals: Vec<String>,
    title: String,
    kind: String,
}

struct ConflictPreflightOptions {
    json: bool,
    left_ref: String,
    right_ref: String,
}

#[derive(Debug, Serialize)]
struct ConflictPreflightPayload {
    command: String,
    status: String,
    reason: String,
    project_dir: String,
    left_ref: String,
    right_ref: String,
    left_sha: String,
    right_sha: String,
    merge_base: String,
    merge_tree_exit_code: Option<i32>,
    conflict_detected: bool,
    overlap_paths: Vec<String>,
    left_only_paths: Vec<String>,
    right_only_paths: Vec<String>,
    next_action: String,
}

struct GitProbeResult {
    exit_code: i32,
    output: String,
}

struct ConsultResultOptions {
    json: bool,
    project_dir: PathBuf,
    mode: String,
    message: String,
    target_slot: String,
    confidence: Option<f64>,
    run_id: String,
    next_test: String,
    risks: Vec<String>,
}

struct ConsultRequestOptions {
    project_dir: PathBuf,
    mode: String,
    message: String,
    target_slot: String,
}

fn parse_options(
    command: &str,
    args: &[&String],
    expected_positionals: usize,
) -> io::Result<ParsedOptions> {
    let mut json = false;
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "missing value after --project-dir",
                    ));
                };
                project_dir = Some(PathBuf::from(value.to_string()));
                index += 2;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux {command}: {value}"),
                ));
            }
            value => {
                positionals.push(value.to_string());
                index += 1;
            }
        }
    }

    if positionals.len() != expected_positionals {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for(command).to_string(),
        ));
    }

    Ok(ParsedOptions {
        json,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        positionals,
    })
}

fn parse_meta_plan_options(args: &[&String]) -> io::Result<MetaPlanOptions> {
    let mut json = false;
    let mut project_dir = None;
    let mut task = String::new();
    let mut session_name = "winsmux-orchestra".to_string();
    let mut role_file = None;
    let mut review_rounds = None;
    let mut trailing_task_parts = Vec::new();
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                project_dir = Some(PathBuf::from(required_option_value(
                    args,
                    index,
                    "--project-dir",
                )?));
                index += 2;
            }
            "--task" => {
                task = required_option_value(args, index, "--task")?;
                index += 2;
            }
            "--session" => {
                session_name = required_option_value(args, index, "--session")?;
                index += 2;
            }
            "--roles" => {
                role_file = Some(PathBuf::from(required_option_value(
                    args, index, "--roles",
                )?));
                index += 2;
            }
            "--review-rounds" => {
                let value = required_option_value(args, index, "--review-rounds")?;
                let parsed = value.parse::<u8>().map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--review-rounds must be 1 or 2",
                    )
                })?;
                if !matches!(parsed, 1 | 2) {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--review-rounds must be 1 or 2",
                    ));
                }
                review_rounds = Some(parsed);
                index += 2;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux meta-plan: {value}"),
                ));
            }
            value => {
                trailing_task_parts.push(value.to_string());
                index += 1;
            }
        }
    }

    if task.trim().is_empty() && !trailing_task_parts.is_empty() {
        task = trailing_task_parts.join(" ");
    }
    if task.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("meta-plan"),
        ));
    }
    if session_name.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "--session must not be empty",
        ));
    }

    Ok(MetaPlanOptions {
        json,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        task: task.trim().to_string(),
        session_name: session_name.trim().to_string(),
        role_file,
        review_rounds,
    })
}

fn build_meta_plan_run(options: &MetaPlanOptions) -> io::Result<MetaPlanRun> {
    let (roles, role_source) = resolve_meta_plan_roles(options)?;
    let role_provider_adapters = roles
        .iter()
        .map(|role| meta_plan_provider_adapter(&options.project_dir, role))
        .collect::<io::Result<Vec<_>>>()?;
    let role_provider_commands = roles
        .iter()
        .map(|role| meta_plan_provider_command(&options.project_dir, role))
        .collect::<io::Result<Vec<_>>>()?;
    let review_rounds = effective_meta_plan_review_rounds(options.review_rounds, &roles);
    let run_id = format!("meta-{}", unique_artifact_id());
    let run_dir = options
        .project_dir
        .join(".winsmux")
        .join("meta-plans")
        .join(&run_id);
    fs::create_dir_all(&run_dir)?;

    let task_hash = sha256_hex(options.task.as_bytes());
    let task_preview = preview_text(&options.task, 160);
    let role_ids: Vec<String> = roles.iter().map(|role| role.role_id.clone()).collect();
    let audit_log_path = meta_plan_audit_log_path(&options.project_dir, &options.session_name);
    let audit_log_ref = artifact_reference(&options.project_dir, &audit_log_path);

    append_meta_plan_audit_record(
        &options.project_dir,
        &options.session_name,
        "meta_plan_init",
        "Meta-planning run started.",
        "operator",
        json!({
            "run_id": run_id.clone(),
            "task_hash": task_hash.clone(),
            "task_preview": task_preview.clone(),
            "selected_roles": role_ids,
            "operator_pane": env::var("WINSMUX_PANE_ID").unwrap_or_default(),
            "read_only_principle": true,
            "role_source": role_source.clone(),
            "review_rounds": review_rounds,
            "shield_harness": {
                "role_definition_policy": "read_only_required",
                "provider_selection": "capability_registry_or_builtin_adapter",
                "selected_providers": roles.iter().map(|role| role.provider.clone()).collect::<Vec<_>>(),
                "private_prompt_bodies_in_audit": false,
                "private_prompt_bodies_in_artifacts": false,
            },
        }),
    )?;

    let mut draft_refs = Vec::new();
    let mut role_payloads = Vec::new();
    for ((role, provider_adapter), provider_command) in roles
        .iter()
        .zip(role_provider_adapters.iter())
        .zip(role_provider_commands.iter())
    {
        let prompt_hash = sha256_hex(role.prompt.as_bytes());
        let launch_contract = meta_plan_launch_contract(
            &options.project_dir,
            role,
            provider_adapter,
            provider_command,
        )?;
        append_meta_plan_audit_record(
            &options.project_dir,
            &options.session_name,
            "role_assigned",
            "Planning role assigned.",
            &role.role_id,
            json!({
                "run_id": run_id.clone(),
                "role_id": role.role_id.clone(),
                "label": role.label.clone(),
                "provider": role.provider.clone(),
                "provider_adapter": provider_adapter.clone(),
                "model": role.model.clone(),
                "model_source": role.model_source.clone(),
                "reasoning_effort": role.reasoning_effort.clone(),
                "plan_mode": role.plan_mode.clone(),
                "read_only": role.read_only,
                "review_rounds": role.review_rounds,
                "prompt_hash": prompt_hash.clone(),
                "launch_contract": launch_contract.clone(),
            }),
        )?;

        let draft_path = run_dir.join(format!("{}-draft.md", role.role_id));
        write_text_file_with_lock(
            &draft_path,
            &render_meta_plan_role_draft(&run_id, &task_hash, role, &prompt_hash),
        )?;
        let draft_ref = artifact_reference(&options.project_dir, &draft_path);
        draft_refs.push(draft_ref.clone());
        append_meta_plan_audit_record(
            &options.project_dir,
            &options.session_name,
            "plan_drafted",
            "Planning draft artifact recorded.",
            &role.role_id,
            json!({
                "run_id": run_id.clone(),
                "role_id": role.role_id.clone(),
                "draft_ref": draft_ref.clone(),
                "confidence": "scaffold",
                "open_questions": [],
            }),
        )?;

        role_payloads.push(json!({
            "role_id": role.role_id.clone(),
            "label": role.label.clone(),
            "provider": role.provider.clone(),
            "provider_adapter": provider_adapter.clone(),
            "model": role.model.clone(),
            "model_source": role.model_source.clone(),
            "reasoning_effort": role.reasoning_effort.clone(),
            "plan_mode": role.plan_mode.clone(),
            "read_only": role.read_only,
            "review_rounds": role.review_rounds,
            "capabilities": role.capabilities.clone(),
            "prompt_hash": prompt_hash.clone(),
            "draft_ref": draft_ref.clone(),
            "launch_contract": launch_contract.clone(),
        }));
    }

    let mut review_refs = Vec::new();
    let mut review_payloads = Vec::new();
    for round in 1..=review_rounds {
        for reviewer in &roles {
            for target in &roles {
                if reviewer.role_id == target.role_id {
                    continue;
                }
                let review_path = run_dir.join(format!(
                    "{}-reviews-{}-round-{}.md",
                    reviewer.role_id, target.role_id, round
                ));
                write_text_file_with_lock(
                    &review_path,
                    &render_meta_plan_cross_review(&run_id, reviewer, target, round),
                )?;
                let review_ref = artifact_reference(&options.project_dir, &review_path);
                review_refs.push(review_ref.clone());
                review_payloads.push(json!({
                    "round": round,
                    "reviewer_role_id": reviewer.role_id.clone(),
                    "target_role_id": target.role_id.clone(),
                    "review_ref": review_ref.clone(),
                    "blocking": false,
                }));
                append_meta_plan_audit_record(
                    &options.project_dir,
                    &options.session_name,
                    "cross_review",
                    "Cross-planning review artifact recorded.",
                    &reviewer.role_id,
                    json!({
                        "run_id": run_id.clone(),
                        "round": round,
                        "reviewer_role_id": reviewer.role_id.clone(),
                        "target_role_id": target.role_id.clone(),
                        "review_ref": review_ref.clone(),
                        "blocking": false,
                    }),
                )?;
            }
        }
    }

    let integrated_plan_path = run_dir.join("integrated-plan.md");
    write_text_file_with_lock(
        &integrated_plan_path,
        &render_meta_plan_integrated_plan(&run_id, &task_hash, &roles, &draft_refs, &review_refs),
    )?;
    let integrated_plan_ref = artifact_reference(&options.project_dir, &integrated_plan_path);

    append_meta_plan_audit_record(
        &options.project_dir,
        &options.session_name,
        "plan_merged",
        "Integrated plan artifact recorded.",
        "operator",
        json!({
            "run_id": run_id.clone(),
            "integrated_plan_ref": integrated_plan_ref.clone(),
            "source_draft_refs": draft_refs.clone(),
            "cross_review_refs": review_refs.clone(),
            "unresolved_items": [],
        }),
    )?;
    append_meta_plan_audit_record(
        &options.project_dir,
        &options.session_name,
        "exit_plan_mode",
        "Operator owns the single approval gate for the integrated plan.",
        "operator",
        json!({
            "run_id": run_id.clone(),
            "integrated_plan_ref": integrated_plan_ref.clone(),
            "final_gate_state": "operator_approval_required",
            "worker_plan_mode_exited": false,
        }),
    )?;

    let payload = json!({
        "command": "meta-plan",
        "contract_version": 1,
        "run_id": run_id.clone(),
        "generated_at": generated_at(),
        "project_dir": project_dir_string(&options.project_dir),
        "task_hash": task_hash,
        "task_preview": task_preview,
        "roles": role_payloads,
        "role_source": role_source,
        "review_rounds": review_rounds,
        "cross_reviews": review_payloads,
        "integrated_plan_ref": integrated_plan_ref.clone(),
        "audit_log_ref": audit_log_ref.clone(),
        "audit_events": ["meta_plan_init", "role_assigned", "plan_drafted", "cross_review", "plan_merged", "exit_plan_mode"],
        "approval_gate": {
            "owner": "operator",
            "single_user_approval": true,
            "worker_execution_allowed": false
        }
    });

    Ok(MetaPlanRun {
        run_id,
        role_count: roles.len(),
        review_rounds,
        integrated_plan_ref,
        audit_log_ref,
        payload,
    })
}

fn default_meta_plan_roles() -> Vec<MetaPlanRole> {
    vec![
        MetaPlanRole {
            role_id: "investigator".to_string(),
            label: "Investigator".to_string(),
            provider: "claude".to_string(),
            model: "provider-default".to_string(),
            model_source: default_provider_model_source(),
            reasoning_effort: default_provider_reasoning_effort(),
            plan_mode: "required".to_string(),
            read_only: true,
            review_rounds: 1,
            capabilities: vec!["facts".to_string(), "constraints".to_string()],
            prompt: "Gather facts, constraints, and unknowns. Do not edit files.".to_string(),
        },
        MetaPlanRole {
            role_id: "verifier".to_string(),
            label: "Verifier".to_string(),
            provider: "codex".to_string(),
            model: "provider-default".to_string(),
            model_source: default_provider_model_source(),
            reasoning_effort: default_provider_reasoning_effort(),
            plan_mode: "read_only_equivalent".to_string(),
            read_only: true,
            review_rounds: 1,
            capabilities: vec!["risk".to_string(), "tests".to_string()],
            prompt: "Find risks, missing tests, and failure modes. Do not edit files.".to_string(),
        },
    ]
}

fn resolve_meta_plan_roles(options: &MetaPlanOptions) -> io::Result<(Vec<MetaPlanRole>, String)> {
    let Some(role_file) = options.role_file.as_ref() else {
        return Ok((
            default_meta_plan_roles(),
            "default_capability_seed".to_string(),
        ));
    };

    let raw = fs::read_to_string(role_file)?;
    let parsed: MetaPlanRoleFile = serde_yaml::from_str(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "invalid meta-plan role YAML at '{}': {err}",
                role_file.display()
            ),
        )
    })?;
    if parsed.version != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "meta-plan role YAML version must be 1",
        ));
    }
    if parsed.roles.len() < 3 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "--roles must define at least three planning roles",
        ));
    }

    for role in &parsed.roles {
        validate_meta_plan_role(&options.project_dir, role)?;
    }

    Ok((parsed.roles, meta_plan_role_source(role_file, &raw)))
}

fn validate_meta_plan_role(project_dir: &Path, role: &MetaPlanRole) -> io::Result<()> {
    if role.role_id.trim().is_empty()
        || !role
            .role_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-'))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "meta-plan role_id must be non-empty ASCII alphanumeric, '-' or '_'",
        ));
    }
    if role.label.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("meta-plan role '{}' label must not be empty", role.role_id),
        ));
    }
    if role.model.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("meta-plan role '{}' model must not be empty", role.role_id),
        ));
    }
    validate_model_source(&role.model_source)?;
    validate_reasoning_effort(&role.reasoning_effort)?;
    if !role.read_only {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("meta-plan role '{}' must set read_only: true", role.role_id),
        ));
    }
    if !matches!(role.plan_mode.as_str(), "required" | "read_only_equivalent") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "meta-plan role '{}' plan_mode must be required or read_only_equivalent",
                role.role_id
            ),
        ));
    }
    let provider_adapter = meta_plan_provider_adapter(project_dir, role)?;
    if provider_adapter == "claude" && role.plan_mode != "required" {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("meta-plan role '{}' must use plan_mode: required for Claude Code compatible providers", role.role_id)));
    }
    if provider_adapter != "claude" && role.plan_mode != "read_only_equivalent" {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("meta-plan role '{}' must use plan_mode: read_only_equivalent for non-Claude providers", role.role_id)));
    }
    if !matches!(provider_adapter.as_str(), "claude" | "codex" | "gemini") {
        let _ = meta_plan_provider_read_only_launch_args(project_dir, role, &provider_adapter)?;
    }
    if !matches!(role.review_rounds, 0 | 1 | 2) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "meta-plan role '{}' review_rounds must be omitted, 1, or 2",
                role.role_id
            ),
        ));
    }
    if role
        .capabilities
        .iter()
        .all(|value| value.trim().is_empty())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "meta-plan role '{}' must declare at least one capability",
                role.role_id
            ),
        ));
    }
    Ok(())
}

fn effective_meta_plan_review_rounds(requested: Option<u8>, roles: &[MetaPlanRole]) -> u8 {
    requested.unwrap_or_else(|| {
        roles
            .iter()
            .map(|role| role.review_rounds)
            .max()
            .filter(|value| matches!(value, 1 | 2))
            .unwrap_or(1)
    })
}

fn meta_plan_role_source(path: &Path, raw: &str) -> String {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("roles.yaml");
    format!("yaml:{name}:sha256:{}", sha256_hex(raw.as_bytes()))
}

fn missing_meta_plan_provider_capability(role: &MetaPlanRole) -> io::Error {
    io::Error::new(
        io::ErrorKind::NotFound,
        format!(
            "meta-plan role '{}' provider '{}' must be declared in .winsmux/provider-capabilities.json",
            role.role_id, role.provider
        ),
    )
}

fn meta_plan_provider_capability(
    project_dir: &Path,
    role: &MetaPlanRole,
) -> io::Result<Option<Value>> {
    let path = provider_capability_registry_path(project_dir);
    let registry = read_provider_capability_registry(&path)?;
    if let Some(capability) = find_provider_capability(&registry, &role.provider) {
        return Ok(Some(capability.clone()));
    }

    if matches!(role.provider.as_str(), "claude" | "codex") {
        return Ok(None);
    }

    Err(missing_meta_plan_provider_capability(role))
}

fn meta_plan_provider_adapter(project_dir: &Path, role: &MetaPlanRole) -> io::Result<String> {
    let Some(capability) = meta_plan_provider_capability(project_dir, role)? else {
        return Ok(provider_adapter_from_agent(&role.provider));
    };

    let adapter = capability_string(Some(&capability), "adapter");
    if adapter.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "meta-plan role '{}' provider '{}' is missing capability adapter",
                role.role_id, role.provider
            ),
        ));
    }
    Ok(adapter)
}

fn meta_plan_provider_command(project_dir: &Path, role: &MetaPlanRole) -> io::Result<String> {
    let Some(capability) = meta_plan_provider_capability(project_dir, role)? else {
        return Ok(role.provider.clone());
    };

    let command = capability_string(Some(&capability), "command");
    if command.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "meta-plan role '{}' provider '{}' is missing capability command",
                role.role_id, role.provider
            ),
        ));
    }
    Ok(command)
}

fn meta_plan_provider_read_only_launch_args(
    project_dir: &Path,
    role: &MetaPlanRole,
    provider_adapter: &str,
) -> io::Result<Vec<String>> {
    if matches!(provider_adapter, "claude" | "codex" | "gemini") {
        return Ok(Vec::new());
    }

    let Some(capability) = meta_plan_provider_capability(project_dir, role)? else {
        return Ok(Vec::new());
    };

    let args = capability_string_array(Some(&capability), "read_only_launch_args");
    if args.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "meta-plan role '{}' provider '{}' with adapter '{}' must declare read_only_launch_args in .winsmux/provider-capabilities.json",
                role.role_id, role.provider, provider_adapter
            ),
        ));
    }

    Ok(args)
}

fn meta_plan_launch_contract(
    project_dir: &Path,
    role: &MetaPlanRole,
    provider_adapter: &str,
    provider_command: &str,
) -> io::Result<Value> {
    let model_override = provider_model_override(&role.model, &role.model_source);
    let mut args = Vec::new();
    let launch_contract = match provider_adapter {
        "claude" => {
            if model_override {
                args.push("--model".to_string());
                args.push(role.model.clone());
            }
            if !provider_default_reasoning_effort(&role.reasoning_effort) {
                args.push("--effort".to_string());
                args.push(role.reasoning_effort.trim().to_ascii_lowercase());
            }
            args.push("--permission-mode".to_string());
            args.push("plan".to_string());
            json!({
                "provider": role.provider.clone(),
                "provider_adapter": provider_adapter,
                "command": provider_command,
                "model": role.model.clone(),
                "model_source": role.model_source.clone(),
                "reasoning_effort": role.reasoning_effort.clone(),
                "model_override": model_override,
                "args": args,
                "plan_mode_enforced": true,
                "read_only": role.read_only,
            })
        }
        "codex" => {
            args.push("exec".to_string());
            if model_override {
                args.push("-c".to_string());
                args.push(format!("model={}", role.model));
            }
            if !provider_default_reasoning_effort(&role.reasoning_effort) {
                args.push("-c".to_string());
                args.push(format!(
                    "model_reasoning_effort={}",
                    role.reasoning_effort.trim().to_ascii_lowercase()
                ));
            }
            args.push("--sandbox".to_string());
            args.push("read-only".to_string());
            json!({
                "provider": role.provider.clone(),
                "provider_adapter": provider_adapter,
                "command": provider_command,
                "model": role.model.clone(),
                "model_source": role.model_source.clone(),
                "reasoning_effort": role.reasoning_effort.clone(),
                "model_override": model_override,
                "args": args,
                "plan_mode_enforced": false,
                "read_only_equivalent": true,
                "read_only": role.read_only,
            })
        }
        "gemini" => {
            if model_override {
                args.push("--model".to_string());
                args.push(role.model.clone());
            }
            args.push("--approval-mode=plan".to_string());
            json!({
                "provider": role.provider.clone(),
                "provider_adapter": provider_adapter,
                "command": provider_command,
                "model": role.model.clone(),
                "model_source": role.model_source.clone(),
                "reasoning_effort": role.reasoning_effort.clone(),
                "model_override": model_override,
                "args": args,
                "plan_mode_enforced": false,
                "read_only_equivalent": true,
                "read_only": role.read_only,
            })
        }
        _ => {
            args = meta_plan_provider_read_only_launch_args(project_dir, role, provider_adapter)?;
            json!({
                "provider": role.provider.clone(),
                "provider_adapter": provider_adapter,
                "command": provider_command,
                "model": role.model.clone(),
                "model_source": role.model_source.clone(),
                "reasoning_effort": role.reasoning_effort.clone(),
                "model_override": model_override,
                "args": args,
                "plan_mode_enforced": false,
                "read_only_equivalent": true,
                "read_only": role.read_only,
            })
        }
    };
    Ok(launch_contract)
}

fn render_meta_plan_role_draft(
    run_id: &str,
    task_hash: &str,
    role: &MetaPlanRole,
    prompt_hash: &str,
) -> String {
    format!("# Meta-Planning Draft: {label}\n\nRun: `{run_id}`\nRole: `{role_id}`\nProvider: `{provider}`\nModel: `{model}`\nModel source: `{model_source}`\nReasoning effort: `{reasoning_effort}`\nPlan mode: `{plan_mode}`\nRead-only: `{read_only}`\nTask hash: `{task_hash}`\nRole prompt hash: `{prompt_hash}`\n\n## Task\n\nThe task body is not stored in this artifact. Use the task hash and audit event references to correlate the operator-owned request.\n\n## Responsibility\n\nThe role prompt body is not stored in this artifact by default. Use the prompt hash and role definition source to correlate the role contract.\n\n## Draft Plan\n\n- Confirm facts and constraints for this role.\n- Identify assumptions that must be carried into the integrated plan.\n- Keep all recommendations side-effect-free until operator approval.\n\n## Evidence To Collect\n\n- Existing repository contracts and tests relevant to this role.\n- Gaps, risks, or open questions for the operator to merge.\n", label = &role.label, role_id = &role.role_id, provider = &role.provider, model = &role.model, model_source = &role.model_source, reasoning_effort = &role.reasoning_effort, plan_mode = &role.plan_mode, read_only = role.read_only)
}

fn render_meta_plan_cross_review(
    run_id: &str,
    reviewer: &MetaPlanRole,
    target: &MetaPlanRole,
    round: u8,
) -> String {
    format!("# Cross-Planning Review\n\nRun: `{run_id}`\nReviewer: `{reviewer}`\nTarget: `{target}`\nRound: `{round}`\n\n## Review Checklist\n\n- Check whether the target plan stays read-only.\n- Check whether missing tests or approval gates are visible.\n- Check whether unresolved questions need operator attention.\n\n## Findings\n\nNo blocking finding is recorded in the scaffold. A live worker review can replace this artifact before operator approval.\n", reviewer = &reviewer.role_id, target = &target.role_id)
}

fn render_meta_plan_integrated_plan(
    run_id: &str,
    task_hash: &str,
    roles: &[MetaPlanRole],
    draft_refs: &[String],
    review_refs: &[String],
) -> String {
    let role_lines = roles
        .iter()
        .map(|role| {
            format!(
                "- `{}`: {} via `{}`",
                role.role_id, role.label, role.provider
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let draft_lines = draft_refs
        .iter()
        .map(|reference| format!("- `{reference}`"))
        .collect::<Vec<_>>()
        .join("\n");
    let review_lines = review_refs
        .iter()
        .map(|reference| format!("- `{reference}`"))
        .collect::<Vec<_>>()
        .join("\n");
    format!("# Integrated Meta-Plan\n\nRun: `{run_id}`\nTask hash: `{task_hash}`\n\n## Summary\n\nThe operator-owned task body is not stored in this scaffold artifact by default. The operator keeps the full request in the interactive approval flow.\n\n## Key Changes\n\n- Run a capability-driven planning pass before execution.\n- Keep worker output as evidence and keep operator approval as the only approval point.\n\n## Interfaces And Data Flow\n\n{role_lines}\n\nDraft artifacts:\n\n{draft_lines}\n\nCross-review artifacts:\n\n{review_lines}\n\n## Safety And Approval Gates\n\n- Workers remain read-only and do not own execution approval.\n- The operator reviews this integrated plan and triggers the single user approval point.\n- JSONL audit events are written before execution.\n- Private task and role prompt bodies are not retained in generated scaffold artifacts.\n\n## Test Plan\n\n- Validate `winsmux meta-plan --json` output.\n- Validate required audit events and artifact references.\n- Validate that generated role contracts remain read-only.\n- Validate that scaffold artifacts retain hashes instead of private prompt bodies.\n\n## Open Questions\n\n- Replace scaffold draft artifacts with live worker responses when panes are available.\n")
}

fn meta_plan_audit_log_path(project_dir: &Path, session_name: &str) -> PathBuf {
    let safe_session = if session_name.trim().is_empty() {
        "winsmux-orchestra".to_string()
    } else {
        session_name
            .chars()
            .map(|ch| {
                if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                    ch
                } else {
                    '_'
                }
            })
            .collect::<String>()
    };
    project_dir
        .join(".winsmux")
        .join("logs")
        .join(format!("{safe_session}.jsonl"))
}

fn append_meta_plan_audit_record(
    project_dir: &Path,
    session_name: &str,
    event: &str,
    message: &str,
    role: &str,
    data: Value,
) -> io::Result<()> {
    let path = meta_plan_audit_log_path(project_dir, session_name);
    let record = json!({
        "timestamp": generated_at(),
        "session": session_name,
        "event": event,
        "level": "info",
        "message": message,
        "role": role,
        "pane_id": env::var("WINSMUX_PANE_ID").unwrap_or_default(),
        "target": "",
        "data": data,
    });
    append_jsonl_record_with_lock(&path, &record)
}

fn append_jsonl_record_with_lock(path: &Path, value: &Value) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    with_file_lock(path, || {
        let mut content = if path.exists() {
            fs::read_to_string(path)?
        } else {
            String::new()
        };
        if !content.is_empty() && !content.ends_with('\n') {
            content.push('\n');
        }
        let line = serde_json::to_string(value).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("failed to serialize JSONL record: {err}"),
            )
        })?;
        content.push_str(&line);
        content.push('\n');
        write_text_file_locked(path, &content)
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn preview_text(text: &str, max_chars: usize) -> String {
    let mut preview = text.chars().take(max_chars).collect::<String>();
    if text.chars().count() > max_chars {
        preview.push_str("...");
    }
    preview
}

fn parse_explain_options(args: &[&String]) -> io::Result<ExplainOptions> {
    let mut json = false;
    let mut follow = false;
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--json" => {
                json = true;
                index += 1;
            }
            "--follow" => {
                follow = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "missing value after --project-dir",
                    ));
                };
                project_dir = Some(PathBuf::from(value.to_string()));
                index += 2;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux explain: {value}"),
                ));
            }
            value => {
                positionals.push(value.to_string());
                index += 1;
            }
        }
    }

    if positionals.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("explain").to_string(),
        ));
    }

    Ok(ExplainOptions {
        json,
        follow,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        positionals,
    })
}

fn parse_desktop_summary_options(args: &[&String]) -> io::Result<DesktopSummaryOptions> {
    let mut json = false;
    let mut stream = false;
    let mut project_dir = None;
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--json" => {
                json = true;
                index += 1;
            }
            "--stream" => {
                stream = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "missing value after --project-dir",
                    ));
                };
                project_dir = Some(PathBuf::from(value.to_string()));
                index += 2;
            }
            value => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux desktop-summary: {value}"),
                ));
            }
        }
    }

    Ok(DesktopSummaryOptions {
        json,
        stream,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
    })
}

fn parse_poll_events_options(args: &[&String]) -> io::Result<ParsedOptions> {
    let mut json = false;
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "missing value after --project-dir",
                    ));
                };
                project_dir = Some(PathBuf::from(value.to_string()));
                index += 2;
            }
            value => {
                positionals.push(value.to_string());
                index += 1;
            }
        }
    }

    if positionals.len() > 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("poll-events"),
        ));
    }

    Ok(ParsedOptions {
        json,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        positionals,
    })
}

fn parse_promote_tactic_options(
    command_name: &'static str,
    args: &[&String],
) -> io::Result<PromoteTacticOptions> {
    let mut json = false;
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut title = String::new();
    let mut kind = "playbook".to_string();
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "missing value after --project-dir",
                    ));
                };
                project_dir = Some(PathBuf::from(value.to_string()));
                index += 2;
            }
            "--title" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--title requires a value",
                    ));
                };
                title = value.to_string();
                index += 2;
            }
            "--kind" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--kind requires a value",
                    ));
                };
                kind = value.to_string();
                index += 2;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux {command_name}: {value}"),
                ));
            }
            value => {
                positionals.push(value.to_string());
                index += 1;
            }
        }
    }

    if positionals.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for(command_name).to_string(),
        ));
    }

    Ok(PromoteTacticOptions {
        json,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        positionals,
        title,
        kind,
    })
}

fn parse_conflict_preflight_options(
    args: &[&String],
    usage_key: &'static str,
) -> io::Result<ConflictPreflightOptions> {
    let mut json = false;
    let mut refs = Vec::new();
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--json" => {
                json = true;
                index += 1;
            }
            value if !value.trim().is_empty() => {
                refs.push(value.to_string());
                index += 1;
            }
            _ => {
                index += 1;
            }
        }
    }

    if refs.len() != 2 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for(usage_key).to_string(),
        ));
    }

    Ok(ConflictPreflightOptions {
        json,
        left_ref: refs[0].clone(),
        right_ref: refs[1].clone(),
    })
}

fn parse_consult_result_options(args: &[&String]) -> io::Result<ConsultResultOptions> {
    let mut json = false;
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut message = String::new();
    let mut message_parts = Vec::new();
    let mut target_slot = String::new();
    let mut confidence = None;
    let mut run_id = String::new();
    let mut next_test = String::new();
    let mut risks = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--json" => {
                json = true;
                index += 1;
            }
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "missing value after --project-dir",
                    ));
                };
                project_dir = Some(PathBuf::from(value.to_string()));
                index += 2;
            }
            "--message" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--message requires a value",
                    ));
                };
                message = value.to_string();
                index += 2;
            }
            "--target-slot" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--target-slot requires a value",
                    ));
                };
                target_slot = value.to_string();
                index += 2;
            }
            "--confidence" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--confidence requires a value",
                    ));
                };
                confidence = Some(value.parse::<f64>().map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("Invalid confidence value: {value}"),
                    )
                })?);
                index += 2;
            }
            "--run-id" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--run-id requires a value",
                    ));
                };
                run_id = value.to_string();
                index += 2;
            }
            "--next-test" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--next-test requires a value",
                    ));
                };
                next_test = value.to_string();
                index += 2;
            }
            "--risk" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--risk requires a value",
                    ));
                };
                if !value.trim().is_empty() {
                    risks.push(value.to_string());
                }
                index += 2;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux consult-result: {value}"),
                ));
            }
            value => {
                if positionals.is_empty() {
                    positionals.push(value.to_string());
                } else if !value.trim().is_empty() {
                    message_parts.push(value.to_string());
                }
                index += 1;
            }
        }
    }

    if positionals.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("consult-result"),
        ));
    }

    let mode = positionals[0].trim().to_ascii_lowercase();
    if !matches!(mode.as_str(), "early" | "stuck" | "reconcile" | "final") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Unsupported consult mode: {}", positionals[0]),
        ));
    }

    if message.trim().is_empty() && !message_parts.is_empty() {
        message = message_parts.join(" ");
    }
    if message.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "consult message is required",
        ));
    }

    Ok(ConsultResultOptions {
        json,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        mode,
        message,
        target_slot,
        confidence,
        run_id,
        next_test,
        risks,
    })
}

fn parse_consult_request_options(args: &[&String]) -> io::Result<ConsultRequestOptions> {
    parse_consult_simple_options("consult-request", args)
}

fn parse_consult_error_options(args: &[&String]) -> io::Result<ConsultRequestOptions> {
    parse_consult_simple_options("consult-error", args)
}

fn parse_consult_simple_options(
    command: &str,
    args: &[&String],
) -> io::Result<ConsultRequestOptions> {
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut message = String::new();
    let mut message_parts = Vec::new();
    let mut target_slot = String::new();
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "missing value after --project-dir",
                    ));
                };
                project_dir = Some(PathBuf::from(value.to_string()));
                index += 2;
            }
            "--message" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--message requires a value",
                    ));
                };
                message = value.to_string();
                index += 2;
            }
            "--target-slot" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--target-slot requires a value",
                    ));
                };
                target_slot = value.to_string();
                index += 2;
            }
            "--run-id" => {
                let Some(_) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--run-id requires a value",
                    ));
                };
                index += 2;
            }
            "--confidence" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--confidence requires a value",
                    ));
                };
                value.parse::<f64>().map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("Invalid confidence value: {value}"),
                    )
                })?;
                index += 2;
            }
            "--next-test" => {
                let Some(_) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--next-test requires a value",
                    ));
                };
                index += 2;
            }
            "--risk" => {
                let Some(_) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "--risk requires a value",
                    ));
                };
                index += 2;
            }
            "--json" => {
                index += 1;
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux {command}: {value}"),
                ));
            }
            value => {
                if positionals.is_empty() {
                    positionals.push(value.to_string());
                } else if !value.trim().is_empty() {
                    message_parts.push(value.to_string());
                }
                index += 1;
            }
        }
    }

    if positionals.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for(command),
        ));
    }

    let mode = positionals[0].trim().to_ascii_lowercase();
    if !matches!(mode.as_str(), "early" | "stuck" | "reconcile" | "final") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Unsupported consult mode: {}", positionals[0]),
        ));
    }

    if message.trim().is_empty() && !message_parts.is_empty() {
        message = message_parts.join(" ");
    }
    if message.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "consult message is required",
        ));
    }

    Ok(ConsultRequestOptions {
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        mode,
        message,
        target_slot,
    })
}

fn parse_rebind_worktree_options(args: &[&String]) -> io::Result<ParsedOptions> {
    let mut project_dir = None;
    let mut positionals = Vec::new();
    let mut index = 0;

    while index < args.len() {
        let arg = args[index].as_str();
        match arg {
            "--project-dir" => {
                let Some(value) = args.get(index + 1) else {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "missing value after --project-dir",
                    ));
                };
                project_dir = Some(PathBuf::from(value.to_string()));
                index += 2;
            }
            "--json" => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    usage_for("rebind-worktree"),
                ));
            }
            value if value.starts_with('-') => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument for winsmux rebind-worktree: {value}"),
                ));
            }
            value => {
                positionals.push(value.to_string());
                index += 1;
            }
        }
    }

    if positionals.len() < 2 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for("rebind-worktree"),
        ));
    }

    Ok(ParsedOptions {
        json: false,
        project_dir: project_dir.unwrap_or(env::current_dir()?),
        positionals,
    })
}

fn should_print_help(args: &[&String]) -> bool {
    args.iter().any(|arg| *arg == "-h" || *arg == "--help")
}

fn require_json(command: &str, options: &ParsedOptions) -> io::Result<()> {
    if options.json {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("winsmux {command} currently supports only --json in the Rust CLI"),
    ))
}

fn usage_for(command: &str) -> &'static str {
    match command {
        "status" => "usage: winsmux status --json [--project-dir <path>]",
        "board" => "usage: winsmux board [--json] [--project-dir <path>]",
        "inbox" => "usage: winsmux inbox [--json] [--project-dir <path>]",
        "digest" => "usage: winsmux digest [--json] [--project-dir <path>]",
        "desktop-summary" => "usage: winsmux desktop-summary [--json] [--stream] [--project-dir <path>]",
        "meta-plan" => {
            "usage: winsmux meta-plan --task <text> [--roles <path>] [--review-rounds <1|2>] [--json] [--project-dir <path>] [--session <name>]"
        }
        "provider-capabilities" => {
            "usage: winsmux provider-capabilities [provider] [--json] [--project-dir <path>]"
        }
        "skills" => "usage: winsmux skills [--json]",
        "operator-jobs" => {
            "usage: winsmux operator-jobs <catalog|list|create|run|pause|update|delete> [job_id] [--kind <dependency-check|issue-triage|documentation-refresh|repository-hygiene>] [--schedule <one-time|recurring>] [--every <daily|weekly|monthly>] [--title <text>] [--evidence <text>] [--destructive] [--reason <text>] [--json] [--project-dir <path>]"
        },
        "machine-contract" => "usage: winsmux machine-contract --json",
        "rust-canary" => "usage: winsmux rust-canary [--json] [--project-dir <path>]",
        "manual-checklist" => {
            "usage: winsmux manual-checklist [--json] [--project-dir <path>]"
        }
        "legacy-compat-gate" => {
            "usage: winsmux legacy-compat-gate [--json] [--project-dir <path>]"
        }
        "guard" => "usage: winsmux guard [--json] [--project-dir <path>]",
        "provider-switch" => {
            "usage: winsmux provider-switch <slot> [--agent <name>] [--model <name>] [--model-source <source>] [--reasoning-effort <level>] [--prompt-transport <argv|file|stdin>] [--auth-mode <mode>] [--reason <text>] [--restart] [--clear] [--json] [--project-dir <path>]"
        }
        "signal" => "usage: winsmux signal <channel>",
        "wait" => "usage: winsmux wait <channel> [timeout_seconds]",
        "runs" => "usage: winsmux runs [--json] [--project-dir <path>]",
        "explain" => "usage: winsmux explain <run_id> [--json] [--follow] [--project-dir <path>]",
        "compare-runs" => {
            "usage: winsmux compare-runs <left_run_id> <right_run_id> [--json] [--project-dir <path>]"
        }
        "compare runs" => {
            "usage: winsmux compare runs <left_run_id> <right_run_id> [--json] [--project-dir <path>]"
        }
        "conflict-preflight" => {
            "usage: winsmux conflict-preflight <left_ref> <right_ref> [--json]"
        }
        "compare-preflight" => {
            "usage: winsmux compare preflight <left_ref> <right_ref> [--json]"
        }
        "compare promote" => {
            "usage: winsmux compare promote <run_id> [--title <text>] [--kind <playbook|prewarm|verification>] [--json] [--project-dir <path>]"
        }
        "promote-tactic" => {
            "usage: winsmux promote-tactic <run_id> [--title <text>] [--kind <playbook|prewarm|verification>] [--json] [--project-dir <path>]"
        }
        "consult-request" => {
            "usage: winsmux consult-request <early|stuck|reconcile|final> [--message <text>] [--target-slot <slot>] [--project-dir <path>]"
        }
        "consult-result" => {
            "usage: winsmux consult-result <early|stuck|reconcile|final> [--message <text>] [--target-slot <slot>] [--confidence <0..1>] [--next-test <text>] [--risk <text>] [--run-id <run_id>] [--json] [--project-dir <path>]"
        }
        "consult-error" => {
            "usage: winsmux consult-error <early|stuck|reconcile|final> [--message <text>] [--target-slot <slot>] [--project-dir <path>]"
        }
        "poll-events" => "usage: winsmux poll-events [cursor] [--project-dir <path>]",
        "dispatch-review" => "usage: winsmux dispatch-review",
        "review-reset" => "usage: winsmux review-reset [--project-dir <path>]",
        "review-request" => "usage: winsmux review-request [--project-dir <path>]",
        "review-approve" => "usage: winsmux review-approve [--project-dir <path>]",
        "review-fail" => "usage: winsmux review-fail [--project-dir <path>]",
        "restart" => "usage: winsmux restart <target> [--project-dir <path>]",
        "rebind-worktree" => {
            "usage: winsmux rebind-worktree <target> <new-worktree-path> [--project-dir <path>]"
        }
        _ => "usage: winsmux <command> --json [--project-dir <path>]",
    }
}

fn current_git_branch(project_dir: &Path) -> io::Result<String> {
    if let Some(branch) = git_output_line(project_dir, &["rev-parse", "--abbrev-ref", "HEAD"])? {
        if branch != "HEAD" {
            return Ok(branch);
        }
    }

    if let Some(branch) = git_output_line(project_dir, &["symbolic-ref", "--short", "HEAD"])? {
        return Ok(branch);
    }

    Err(io::Error::new(
        io::ErrorKind::Other,
        format!(
            "unable to determine current git branch in {}",
            project_dir.display()
        ),
    ))
}

fn git_output_line(project_dir: &Path, args: &[&str]) -> io::Result<Option<String>> {
    let output = Command::new("git")
        .arg("-C")
        .arg(project_dir)
        .args(args)
        .output()
        .map_err(|err| {
            io::Error::new(
                io::ErrorKind::Other,
                format!(
                    "unable to determine current git branch in {}: {err}",
                    project_dir.display()
                ),
            )
        })?;

    if !output.status.success() {
        return Ok(None);
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    Ok((!value.is_empty()).then_some(value))
}

fn current_git_head(project_dir: &Path) -> io::Result<String> {
    if let Some(head) = git_output_line(project_dir, &["rev-parse", "HEAD"])? {
        return Ok(head);
    }

    Err(io::Error::new(
        io::ErrorKind::Other,
        format!(
            "unable to determine current git HEAD in {}",
            project_dir.display()
        ),
    ))
}

fn clear_review_state_record(project_dir: &Path, branch: &str) -> io::Result<()> {
    let path = review_state_path(project_dir);
    if !path.exists() {
        return Ok(());
    }

    let mut state = load_review_state(project_dir)?;
    state.remove(branch);
    save_review_state(project_dir, state)
}

fn review_state_path(project_dir: &Path) -> PathBuf {
    project_dir.join(".winsmux").join("review-state.json")
}

fn load_review_state(project_dir: &Path) -> io::Result<Map<String, Value>> {
    let path = review_state_path(project_dir);
    if !path.exists() {
        return Ok(Map::new());
    }

    let raw = fs::read_to_string(&path)?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(Map::new());
    }

    serde_json::from_str::<Map<String, Value>>(trimmed).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid review state: {}", path.display()),
        )
    })
}

fn save_review_state(project_dir: &Path, state: Map<String, Value>) -> io::Result<()> {
    let path = review_state_path(project_dir);
    if state.is_empty() {
        if path.exists() {
            fs::remove_file(&path)?;
        }
        return Ok(());
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let content = serde_json::to_string_pretty(&state).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize review state: {err}"),
        )
    })?;
    fs::write(path, format!("{content}\n"))
}

fn assert_review_role_permission(command_name: &str) -> io::Result<()> {
    let role = current_canonical_role()?;
    if !matches!(role.as_str(), "Reviewer" | "Worker") {
        return Err(review_permission_error(command_name));
    }

    let role_map = role_map_from_env()?;
    if role_map.is_empty() {
        return Ok(());
    }

    let pane_id = env::var("WINSMUX_PANE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_PANE_ID not set"))?;
    let Some(mapped_role) = role_map
        .get(&pane_id)
        .and_then(serde_json::Value::as_str)
        .map(str::to_string)
    else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("WINSMUX_ROLE_MAP missing entry for pane {pane_id}"),
        ));
    };
    if mapped_role != role {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("WINSMUX_ROLE mismatch for pane {pane_id}: expected {mapped_role}, got {role}"),
        ));
    }
    Ok(())
}

fn assert_consult_role_permission(command_name: &str) -> io::Result<()> {
    let role = current_canonical_role()?;
    if !matches!(
        role.as_str(),
        "Operator" | "Builder" | "Worker" | "Researcher" | "Reviewer"
    ) {
        return Err(review_permission_error(command_name));
    }

    let role_map = role_map_from_env()?;
    if role_map.is_empty() {
        return Ok(());
    }

    let pane_id = env::var("WINSMUX_PANE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_PANE_ID not set"))?;
    let Some(mapped_role) = role_map
        .get(&pane_id)
        .and_then(serde_json::Value::as_str)
        .map(str::to_string)
    else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("WINSMUX_ROLE_MAP missing entry for pane {pane_id}"),
        ));
    };
    if mapped_role != role {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("WINSMUX_ROLE mismatch for pane {pane_id}: expected {mapped_role}, got {role}"),
        ));
    }
    Ok(())
}

fn assert_dispatch_review_role_permission(command_name: &str) -> io::Result<()> {
    let role = current_canonical_role()?;
    if role != "Operator" {
        return Err(review_permission_error(command_name));
    }

    let role_map = role_map_from_env()?;
    if role_map.is_empty() {
        return Ok(());
    }

    let pane_id = env::var("WINSMUX_PANE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_PANE_ID not set"))?;
    let Some(mapped_role) = role_map
        .get(&pane_id)
        .and_then(serde_json::Value::as_str)
        .map(str::to_string)
    else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("WINSMUX_ROLE_MAP missing entry for pane {pane_id}"),
        ));
    };
    if mapped_role != role {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("WINSMUX_ROLE mismatch for pane {pane_id}: expected {mapped_role}, got {role}"),
        ));
    }
    Ok(())
}

fn current_canonical_role() -> io::Result<String> {
    let raw = env::var("WINSMUX_ROLE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_ROLE not set"))?;
    canonical_role(&raw).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Invalid WINSMUX_ROLE: {raw}"),
        )
    })
}

fn role_map_from_env() -> io::Result<Map<String, Value>> {
    let raw = env::var("WINSMUX_ROLE_MAP").unwrap_or_default();
    if raw.trim().is_empty() {
        return Ok(Map::new());
    }
    let parsed = serde_json::from_str::<Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Invalid WINSMUX_ROLE_MAP JSON: {err}"),
        )
    })?;
    let Some(raw_map) = parsed.as_object() else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid WINSMUX_ROLE_MAP JSON: expected object",
        ));
    };

    let mut role_map = Map::new();
    for (pane_id, role) in raw_map {
        let Some(role_name) = role.as_str() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("Invalid WINSMUX_ROLE_MAP role for pane {pane_id}: {role}"),
            ));
        };
        let Some(canonical) = canonical_role(role_name) else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("Invalid WINSMUX_ROLE_MAP role for pane {pane_id}: {role_name}"),
            ));
        };
        role_map.insert(pane_id.clone(), Value::String(canonical));
    }
    Ok(role_map)
}

fn canonical_role(role: &str) -> Option<String> {
    match role.trim().to_ascii_lowercase().as_str() {
        "operator" => Some("Operator".to_string()),
        "worker" => Some("Worker".to_string()),
        "builder" => Some("Builder".to_string()),
        "researcher" => Some("Researcher".to_string()),
        "reviewer" => Some("Reviewer".to_string()),
        _ => None,
    }
}

fn review_permission_error(command_name: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        format!("{command_name} is not permitted for the current role"),
    )
}

#[derive(Clone)]
struct ReviewPaneContext {
    label: String,
    pane_id: String,
    role: String,
}

#[derive(Clone)]
struct ConsultationContext {
    session_name: String,
    label: String,
    pane_id: String,
    role: String,
    task_id: String,
    branch: String,
    head_sha: String,
    run_id: String,
    slot: String,
    worktree: String,
}

#[derive(Clone)]
struct RebindManifestContext {
    label: String,
    pane_id: String,
    role: String,
}

#[derive(Clone)]
struct RestartPlan {
    label: String,
    pane_id: String,
    role: String,
    session_name: String,
    launch_dir: String,
    git_worktree_dir: String,
    agent: String,
    model: String,
    model_source: String,
    reasoning_effort: String,
    capability_adapter: String,
    launch_command: String,
}

fn current_review_pane_context(project_dir: &Path) -> io::Result<ReviewPaneContext> {
    let pane_id = env::var("WINSMUX_PANE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_PANE_ID not set"))?;
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;
    let Some(context) = find_review_pane_context(&manifest, &pane_id) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "pane {pane_id} is not registered as a review-capable pane in .winsmux/manifest.yaml"
            ),
        ));
    };
    Ok(context)
}

fn preferred_review_pane_context(project_dir: &Path) -> io::Result<ReviewPaneContext> {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = load_manifest_yaml(&manifest_path)?;
    find_preferred_review_pane_context(&manifest).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "No review-capable pane found in manifest.",
        )
    })
}

fn consultation_command_context(
    project_dir: &Path,
    run_id_override: &str,
) -> io::Result<ConsultationContext> {
    if !run_id_override.trim().is_empty() {
        let snapshot = load_snapshot(project_dir)?;
        let projection = snapshot
            .explain_projection(run_id_override)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("run not found: {run_id_override}"),
                )
            })?;
        let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
        let manifest = load_manifest_yaml(&manifest_path)?;
        let session_name = manifest_session_name(&manifest).unwrap_or_default();
        return Ok(ConsultationContext {
            session_name,
            label: projection.run.primary_label.clone(),
            pane_id: projection.run.primary_pane_id.clone(),
            role: projection.run.primary_role.clone(),
            task_id: projection.run.task_id.clone(),
            branch: projection.run.branch.clone(),
            head_sha: projection.run.head_sha.clone(),
            run_id: projection.run.run_id.clone(),
            slot: projection.run.primary_label.clone(),
            worktree: projection.run.worktree.clone(),
        });
    }

    let pane_id = env::var("WINSMUX_PANE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_PANE_ID not set"))?;
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let manifest = load_manifest_yaml(&manifest_path)?;
    let Some(context) = find_consultation_context(&manifest, &pane_id, project_dir) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("pane {pane_id} is not registered in .winsmux/manifest.yaml"),
        ));
    };
    Ok(context)
}

fn load_manifest_yaml(manifest_path: &Path) -> io::Result<serde_yaml::Value> {
    let raw = fs::read_to_string(manifest_path)?;
    serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })
}

fn find_consultation_context(
    manifest: &serde_yaml::Value,
    pane_id: &str,
    project_dir: &Path,
) -> Option<ConsultationContext> {
    let panes = manifest.get("panes")?;
    match panes {
        serde_yaml::Value::Mapping(map) => map.iter().find_map(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            consultation_context_from_value(manifest, label, pane_id, pane, project_dir)
        }),
        serde_yaml::Value::Sequence(items) => items.iter().find_map(|pane| {
            consultation_context_from_value(manifest, "", pane_id, pane, project_dir)
        }),
        _ => None,
    }
}

fn consultation_context_from_value(
    manifest: &serde_yaml::Value,
    fallback_label: &str,
    pane_id: &str,
    pane: &serde_yaml::Value,
    project_dir: &Path,
) -> Option<ConsultationContext> {
    let map = pane.as_mapping()?;
    let actual = manifest_string(map, "pane_id");
    if actual != pane_id {
        return None;
    }
    let label = first_non_empty(&manifest_string(map, "label"), fallback_label);
    let role = canonical_manifest_role(&manifest_string(map, "role"), &label).unwrap_or_default();
    let task_id = manifest_string(map, "task_id");
    let mut run_id = manifest_string(map, "parent_run_id");
    if run_id.trim().is_empty() && !task_id.trim().is_empty() {
        run_id = format!("task:{task_id}");
    }
    if run_id.trim().is_empty() && task_id.trim().is_empty() {
        return None;
    }

    let branch = {
        let manifest_branch = manifest_string(map, "branch");
        if manifest_branch.trim().is_empty() {
            current_git_branch(project_dir).unwrap_or_default()
        } else {
            manifest_branch
        }
    };
    let head_sha = {
        let manifest_head = manifest_string(map, "head_sha");
        if manifest_head.trim().is_empty() {
            current_git_head(project_dir).unwrap_or_default()
        } else {
            manifest_head
        }
    };
    let worktree_path = first_non_empty(
        &first_non_empty(
            &first_non_empty(
                &manifest_string(map, "worktree_git_dir"),
                &manifest_string(map, "git_worktree_dir"),
            ),
            &manifest_string(map, "builder_worktree_path"),
        ),
        &manifest_string(map, "launch_dir"),
    );
    let worktree = if worktree_path.trim().is_empty() {
        String::new()
    } else {
        artifact_reference(project_dir, Path::new(&worktree_path))
    };

    Some(ConsultationContext {
        session_name: manifest_session_name(manifest).unwrap_or_default(),
        label: label.clone(),
        pane_id: actual,
        role,
        task_id,
        branch,
        head_sha,
        run_id,
        slot: label,
        worktree,
    })
}

fn find_review_pane_context(
    manifest: &serde_yaml::Value,
    pane_id: &str,
) -> Option<ReviewPaneContext> {
    let panes = manifest.get("panes")?;
    match panes {
        serde_yaml::Value::Mapping(map) => map.iter().find_map(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            review_pane_context_from_value(label, pane_id, pane)
        }),
        serde_yaml::Value::Sequence(items) => items
            .iter()
            .filter_map(|pane| review_pane_context_from_value("", pane_id, pane))
            .next(),
        _ => None,
    }
}

fn find_preferred_review_pane_context(manifest: &serde_yaml::Value) -> Option<ReviewPaneContext> {
    let contexts = review_pane_contexts(manifest);
    for preferred_role in ["Reviewer", "Worker"] {
        if let Some(context) = contexts
            .iter()
            .find(|context| context.role == preferred_role)
            .cloned()
        {
            return Some(context);
        }
    }
    None
}

fn review_pane_contexts(manifest: &serde_yaml::Value) -> Vec<ReviewPaneContext> {
    let Some(panes) = manifest.get("panes") else {
        return Vec::new();
    };
    match panes {
        serde_yaml::Value::Mapping(map) => map
            .iter()
            .filter_map(|(key, pane)| {
                let label = key.as_str().unwrap_or_default();
                review_pane_context_from_value(label, "", pane)
            })
            .collect(),
        serde_yaml::Value::Sequence(items) => items
            .iter()
            .filter_map(|pane| review_pane_context_from_value("", "", pane))
            .collect(),
        _ => Vec::new(),
    }
}

fn review_pane_context_from_value(
    fallback_label: &str,
    pane_id: &str,
    pane: &serde_yaml::Value,
) -> Option<ReviewPaneContext> {
    let map = pane.as_mapping()?;
    let actual = manifest_string(map, "pane_id");
    if actual.trim().is_empty() {
        return None;
    }
    if !pane_id.is_empty() && actual != pane_id {
        return None;
    }
    let role = manifest_string(map, "role");
    let canonical_role = canonical_manifest_role(&role, fallback_label);
    if !matches!(canonical_role.as_deref(), Some("Reviewer" | "Worker")) {
        return None;
    }
    let label = first_non_empty(&manifest_string(map, "label"), fallback_label);
    Some(ReviewPaneContext {
        label,
        pane_id: actual,
        role: canonical_role.unwrap_or_default(),
    })
}

fn send_review_request_to_pane(pane_id: &str) -> io::Result<()> {
    let command_text = "winsmux review-request";
    let pre_send_text = capture_pane_tail(pane_id)?;
    run_winsmux_command(&["send-keys", "-t", pane_id, "-l", "--", command_text])?;
    thread::sleep(Duration::from_millis(300));
    let typed_text = capture_pane_tail(pane_id)?;
    if typed_text == pre_send_text {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("pane buffer did not change after typing review request into {pane_id}"),
        ));
    }
    if !typed_text.contains(command_text) {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("typed review request was not observed in {pane_id}"),
        ));
    }
    run_winsmux_command(&["send-keys", "-t", pane_id, "Enter"])
}

fn wait_for_pending_review_state(
    project_dir: &Path,
    branch: &str,
    head_sha: &str,
) -> io::Result<bool> {
    let attempts = dispatch_review_poll_attempts();
    for attempt in 0..=attempts {
        let state = load_review_state(project_dir)?;
        if review_state_is_pending_for_head(&state, branch, head_sha) {
            return Ok(true);
        }
        if attempt < attempts {
            thread::sleep(dispatch_review_poll_delay());
        }
    }
    Ok(false)
}

fn dispatch_review_poll_attempts() -> usize {
    env::var("WINSMUX_DISPATCH_REVIEW_POLL_ATTEMPTS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(10)
}

fn dispatch_review_poll_delay() -> Duration {
    env::var("WINSMUX_DISPATCH_REVIEW_POLL_INTERVAL_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .map(Duration::from_millis)
        .unwrap_or_else(|| Duration::from_secs(3))
}

fn review_state_is_pending_for_head(
    state: &Map<String, Value>,
    branch: &str,
    head_sha: &str,
) -> bool {
    let Some(record) = state.get(branch) else {
        return false;
    };
    let status_matches = record
        .get("status")
        .and_then(Value::as_str)
        .map(|status| status == "PENDING")
        .unwrap_or(false);
    if !status_matches {
        return false;
    }
    let record_head = record
        .get("head_sha")
        .and_then(Value::as_str)
        .or_else(|| {
            record
                .get("request")
                .and_then(|request| request.get("head_sha"))
                .and_then(Value::as_str)
        })
        .unwrap_or_default();
    record_head == head_sha
}

fn canonical_manifest_role(role: &str, label: &str) -> Option<String> {
    let candidate = if role.trim().is_empty() {
        label.trim()
    } else {
        role.trim()
    };
    let lowered = candidate.to_ascii_lowercase();
    for (prefix, canonical) in [
        ("worker", "Worker"),
        ("builder", "Builder"),
        ("researcher", "Researcher"),
        ("reviewer", "Reviewer"),
        ("operator", "Operator"),
    ] {
        if lowered == prefix
            || lowered.starts_with(&format!("{prefix}-"))
            || lowered.starts_with(&format!("{prefix}_"))
            || lowered.starts_with(&format!("{prefix}:"))
            || lowered.starts_with(&format!("{prefix}/"))
            || lowered.starts_with(&format!("{prefix} "))
        {
            return Some(canonical.to_string());
        }
    }
    Some("Operator".to_string())
}

fn manifest_string(map: &serde_yaml::Mapping, key: &str) -> String {
    map.get(serde_yaml::Value::String(key.to_string()))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn first_non_empty(first: &str, second: &str) -> String {
    if first.trim().is_empty() {
        second.to_string()
    } else {
        first.to_string()
    }
}

fn resolve_rebind_manifest_context(
    manifest: &serde_yaml::Value,
    target: &str,
    manifest_path: &Path,
) -> io::Result<RebindManifestContext> {
    let Some(context) = find_rebind_manifest_context(manifest, target) else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "Pane {target} was not found in manifest: {}",
                manifest_path.display()
            ),
        ));
    };
    Ok(context)
}

fn update_rebind_manifest_with_lock(
    manifest_path: &Path,
    target: &str,
    resolved_worktree_path: &str,
) -> io::Result<RebindManifestContext> {
    with_file_lock(manifest_path, || {
        let raw = fs::read_to_string(manifest_path)?;
        let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid manifest: {}: {err}", manifest_path.display()),
            )
        })?;
        let session_name = manifest_session_name(&manifest)?;
        let context = resolve_rebind_manifest_context(&manifest, target, manifest_path)?;
        if !matches!(context.role.as_str(), "Builder" | "Worker") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "rebind-worktree is only supported for Builder/Worker panes: {} ({})",
                    context.pane_id, context.label
                ),
            ));
        }
        ensure_live_pane_target(&session_name, &context.pane_id)?;

        if !update_manifest_pane_paths(
            &mut manifest,
            &context.pane_id,
            resolved_worktree_path,
            resolved_worktree_path,
        ) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!(
                    "Pane {} was not found in manifest: {}",
                    context.pane_id,
                    manifest_path.display()
                ),
            ));
        }

        let content = serde_yaml::to_string(&manifest).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("failed to serialize manifest: {err}"),
            )
        })?;
        write_text_file_locked(manifest_path, &content)?;
        Ok(context)
    })
}

fn find_rebind_manifest_context(
    manifest: &serde_yaml::Value,
    target: &str,
) -> Option<RebindManifestContext> {
    let panes = manifest.get("panes")?;
    match panes {
        serde_yaml::Value::Mapping(map) => map.iter().find_map(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            rebind_context_from_value(label, target, pane)
        }),
        serde_yaml::Value::Sequence(items) => items
            .iter()
            .filter_map(|pane| rebind_context_from_value("", target, pane))
            .next(),
        _ => None,
    }
}

fn rebind_context_from_value(
    fallback_label: &str,
    target: &str,
    pane: &serde_yaml::Value,
) -> Option<RebindManifestContext> {
    let map = pane.as_mapping()?;
    let pane_id = manifest_string(map, "pane_id");
    let label = first_non_empty(&manifest_string(map, "label"), fallback_label);
    if pane_id != target && label != target {
        return None;
    }
    let role = manifest_string(map, "role");
    Some(RebindManifestContext {
        label,
        pane_id,
        role: canonical_manifest_role(&role, fallback_label).unwrap_or_default(),
    })
}

fn resolved_display_path(path: &Path) -> io::Result<String> {
    let resolved = fs::canonicalize(path)?;
    let display = resolved.to_string_lossy().to_string();
    Ok(strip_windows_extended_path_prefix(&display))
}

fn manifest_session_name(manifest: &serde_yaml::Value) -> io::Result<String> {
    let session_name = manifest
        .get("session")
        .and_then(|session| session.get("name"))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    if session_name.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "manifest session.name must not be empty",
        ));
    }
    Ok(session_name)
}

fn build_restart_plan(project_dir: &Path, target: &str) -> io::Result<RestartPlan> {
    build_restart_plan_with_provider(project_dir, target, None)
}

fn build_restart_plan_with_provider(
    project_dir: &Path,
    target: &str,
    provider_override: Option<(String, String, String, String, String)>,
) -> io::Result<RestartPlan> {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;
    let session_name = manifest_session_name(&manifest)?;
    let project_root = manifest_project_dir(&manifest).unwrap_or_else(|| project_dir.to_path_buf());
    let session_git_worktree_dir = manifest_session_git_worktree_dir(&manifest);
    let context = resolve_restart_manifest_context(
        &manifest,
        target,
        &manifest_path,
        &project_root,
        session_git_worktree_dir.as_deref(),
    )?;
    ensure_live_pane_target(&session_name, &context.pane_id)?;

    let (agent, model, model_source, reasoning_effort, capability_adapter) =
        if let Some(provider) = provider_override {
            provider
        } else {
            resolve_restart_provider(project_dir, &context)?
        };
    let launch_command = build_provider_launch_command(
        &agent,
        &model,
        &model_source,
        &reasoning_effort,
        &capability_adapter,
        &context.launch_dir,
        &context.git_worktree_dir,
    )?;
    Ok(RestartPlan {
        label: context.label,
        pane_id: context.pane_id,
        role: context.role,
        session_name,
        launch_dir: context.launch_dir,
        git_worktree_dir: context.git_worktree_dir,
        agent,
        model,
        model_source,
        reasoning_effort,
        capability_adapter,
        launch_command,
    })
}

fn build_provider_switch_restart_plan(
    project_dir: &Path,
    settings: &BridgeSettings,
    slot_id: &str,
    pane_id: &str,
    registry_entry: Option<&ProviderRegistryEntry>,
) -> io::Result<RestartPlan> {
    if !slot_has_explicit_provider_metadata_after_registry_replacement(
        settings,
        slot_id,
        registry_entry,
    ) {
        return Err(restart_provider_metadata_missing(slot_id, pane_id));
    }

    let effective = resolve_slot_agent_config_with_registry_replacement(
        project_dir,
        settings,
        slot_id,
        registry_entry,
    )?;
    let adapter = if effective.capability_adapter.trim().is_empty() {
        provider_adapter_from_agent(&effective.agent)
    } else {
        effective.capability_adapter.clone()
    };
    build_restart_plan_with_provider(
        project_dir,
        pane_id,
        Some((
            effective.agent,
            effective.model,
            effective.model_source,
            effective.reasoning_effort,
            adapter,
        )),
    )
}

fn manifest_project_dir(manifest: &serde_yaml::Value) -> Option<PathBuf> {
    manifest
        .get("session")
        .and_then(|session| session.get("project_dir"))
        .and_then(serde_yaml::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from)
}

fn manifest_session_git_worktree_dir(manifest: &serde_yaml::Value) -> Option<String> {
    manifest
        .get("session")
        .and_then(|session| session.get("git_worktree_dir"))
        .and_then(serde_yaml::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
}

fn resolve_restart_manifest_context(
    manifest: &serde_yaml::Value,
    target: &str,
    manifest_path: &Path,
    project_root: &Path,
    session_git_worktree_dir: Option<&str>,
) -> io::Result<RestartPlan> {
    let Some(context) =
        find_restart_manifest_context(manifest, target, project_root, session_git_worktree_dir)
    else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "Pane {target} was not found in manifest: {}",
                manifest_path.display()
            ),
        ));
    };
    Ok(context)
}

fn find_restart_manifest_context(
    manifest: &serde_yaml::Value,
    target: &str,
    project_root: &Path,
    session_git_worktree_dir: Option<&str>,
) -> Option<RestartPlan> {
    let panes = manifest.get("panes")?;
    match panes {
        serde_yaml::Value::Mapping(map) => map.iter().find_map(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            restart_context_from_value(label, target, pane, project_root, session_git_worktree_dir)
        }),
        serde_yaml::Value::Sequence(items) => items.iter().find_map(|pane| {
            restart_context_from_value("", target, pane, project_root, session_git_worktree_dir)
        }),
        _ => None,
    }
}

fn restart_context_from_value(
    fallback_label: &str,
    target: &str,
    pane: &serde_yaml::Value,
    project_root: &Path,
    session_git_worktree_dir: Option<&str>,
) -> Option<RestartPlan> {
    let map = pane.as_mapping()?;
    let pane_id = manifest_string(map, "pane_id");
    let label = first_non_empty(&manifest_string(map, "label"), fallback_label);
    if pane_id != target && label != target {
        return None;
    }
    let role = canonical_manifest_role(&manifest_string(map, "role"), &label)?;
    let uses_worktree = matches!(role.as_str(), "Builder" | "Worker");
    let builder_worktree_path = if uses_worktree {
        manifest_string(map, "builder_worktree_path")
    } else {
        String::new()
    };
    let mut launch_dir = manifest_string(map, "launch_dir");
    if launch_dir.trim().is_empty() && !builder_worktree_path.trim().is_empty() {
        launch_dir = builder_worktree_path;
    }
    if launch_dir.trim().is_empty() {
        launch_dir = project_root.to_string_lossy().to_string();
    }

    let mut git_worktree_dir = if uses_worktree {
        manifest_string(map, "worktree_git_dir")
    } else {
        String::new()
    };
    if git_worktree_dir.trim().is_empty() {
        git_worktree_dir = session_git_worktree_dir.unwrap_or_default().to_string();
    }
    if uses_worktree || git_worktree_dir.trim().is_empty() {
        git_worktree_dir = pane_git_worktree_dir(Path::new(&launch_dir));
    }

    Some(RestartPlan {
        label,
        pane_id,
        role,
        session_name: String::new(),
        launch_dir,
        git_worktree_dir,
        agent: String::new(),
        model: String::new(),
        model_source: default_provider_model_source(),
        capability_adapter: String::new(),
        reasoning_effort: default_provider_reasoning_effort(),
        launch_command: String::new(),
    })
}

fn pane_git_worktree_dir(project_dir: &Path) -> String {
    let dot_git = project_dir.join(".git");
    if dot_git.is_file() {
        if let Ok(raw) = fs::read_to_string(&dot_git) {
            if let Some(rest) = raw.trim().strip_prefix("gitdir:") {
                let value = rest.trim();
                let path = PathBuf::from(value);
                return if path.is_absolute() {
                    path.to_string_lossy().to_string()
                } else {
                    project_dir.join(path).to_string_lossy().to_string()
                };
            }
        }
    }
    if dot_git.is_dir() {
        return dot_git.to_string_lossy().to_string();
    }
    project_dir.to_string_lossy().to_string()
}

fn resolve_restart_provider(
    project_dir: &Path,
    context: &RestartPlan,
) -> io::Result<(String, String, String, String, String)> {
    let manifest_provider_target = manifest_provider_target(project_dir, &context.pane_id);
    let manifest_capability_adapter =
        manifest_capability_adapter(project_dir, &context.pane_id).unwrap_or_default();
    let (agent, model) = split_provider_target(&manifest_provider_target);
    if let Ok(settings) = read_bridge_settings(project_dir) {
        if settings.has_slot(&context.label)
            && restart_slot_has_explicit_provider_metadata(project_dir, &settings, &context.label)?
        {
            if let Ok(effective) = resolve_slot_agent_config(project_dir, &settings, &context.label)
            {
                let adapter = if effective.capability_adapter.trim().is_empty() {
                    provider_adapter_from_agent(&effective.agent)
                } else {
                    effective.capability_adapter
                };
                return Ok((
                    effective.agent,
                    effective.model,
                    effective.model_source,
                    effective.reasoning_effort,
                    adapter,
                ));
            }
        }
    }

    if !agent.trim().is_empty() {
        let adapter = if !manifest_capability_adapter.trim().is_empty() {
            manifest_capability_adapter
        } else {
            match resolve_provider_capability(project_dir, &agent) {
                Ok(capability) => capability
                    .as_ref()
                    .and_then(|capability| capability.get("adapter"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .filter(|value| !value.trim().is_empty())
                    .unwrap_or_else(|| provider_adapter_from_agent(&agent)),
                Err(err) if err.kind() == io::ErrorKind::NotFound => {
                    provider_adapter_from_agent(&agent)
                }
                Err(err) => return Err(err),
            }
        };
        return Ok((
            agent,
            model.clone(),
            inferred_model_source_for_model(&model),
            default_provider_reasoning_effort(),
            adapter,
        ));
    }

    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        format!(
            "restart provider metadata missing for pane '{}' ({}). Set manifest provider_target or an explicit slot provider before restart.",
            context.pane_id, context.label
        ),
    ))
}

fn restart_slot_has_explicit_provider_metadata(
    project_dir: &Path,
    settings: &BridgeSettings,
    slot_id: &str,
) -> io::Result<bool> {
    let registry_entry = provider_registry_entry_full(project_dir, slot_id)?;
    Ok(
        slot_has_explicit_provider_metadata_after_registry_replacement(
            settings,
            slot_id,
            registry_entry.as_ref(),
        ),
    )
}

fn slot_has_explicit_provider_metadata_after_registry_replacement(
    settings: &BridgeSettings,
    slot_id: &str,
    registry_entry: Option<&ProviderRegistryEntry>,
) -> bool {
    if registry_entry
        .and_then(|entry| entry.agent.as_ref())
        .is_some()
    {
        return true;
    }
    if let Some(slot) = settings.slot(slot_id) {
        if slot.agent.is_some() {
            return true;
        }
    }

    settings.worker_role.agent.is_some() || settings.agent_explicit
}

fn restart_provider_metadata_missing(slot_id: &str, pane_id: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!(
            "restart provider metadata missing for pane '{pane_id}' ({slot_id}). Set an explicit slot provider before restart.",
        ),
    )
}

fn manifest_provider_target(project_dir: &Path, pane_id: &str) -> String {
    manifest_pane_field(project_dir, pane_id, "provider_target").unwrap_or_default()
}

fn manifest_capability_adapter(project_dir: &Path, pane_id: &str) -> Option<String> {
    manifest_pane_field(project_dir, pane_id, "capability_adapter")
}

fn manifest_pane_field(project_dir: &Path, pane_id: &str, field: &str) -> Option<String> {
    let path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(path).ok()?;
    let manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).ok()?;
    let panes = manifest.get("panes")?;
    match panes {
        serde_yaml::Value::Mapping(map) => map.values().find_map(|pane| {
            let map = pane.as_mapping()?;
            (manifest_string(map, "pane_id") == pane_id)
                .then(|| manifest_string(map, field))
                .filter(|value| !value.trim().is_empty())
        }),
        serde_yaml::Value::Sequence(items) => items.iter().find_map(|pane| {
            let map = pane.as_mapping()?;
            (manifest_string(map, "pane_id") == pane_id)
                .then(|| manifest_string(map, field))
                .filter(|value| !value.trim().is_empty())
        }),
        _ => None,
    }
}

fn split_provider_target(provider_target: &str) -> (String, String) {
    let trimmed = provider_target.trim();
    if let Some((agent, model)) = trimmed.split_once(':') {
        return (agent.trim().to_string(), model.trim().to_string());
    }
    (trimmed.to_string(), String::new())
}

fn provider_adapter_from_agent(agent: &str) -> String {
    let lowered = agent.trim().to_ascii_lowercase();
    if lowered.starts_with("codex") {
        "codex".to_string()
    } else if lowered.starts_with("claude") {
        "claude".to_string()
    } else if lowered.starts_with("gemini") {
        "gemini".to_string()
    } else {
        lowered
    }
}

fn build_provider_launch_command(
    agent: &str,
    model: &str,
    model_source: &str,
    reasoning_effort: &str,
    capability_adapter: &str,
    launch_dir: &str,
    git_worktree_dir: &str,
) -> io::Result<String> {
    let model_override = provider_model_override(model, model_source);
    let effort_override = !provider_default_reasoning_effort(reasoning_effort);
    match capability_adapter.trim().to_ascii_lowercase().as_str() {
        "codex" => {
            let mut parts = vec![shell_literal(agent)];
            if model_override {
                parts.push("-c".to_string());
                parts.push(shell_literal(&format!("model={model}")));
            }
            if effort_override {
                parts.push("-c".to_string());
                parts.push(shell_literal(&format!(
                    "model_reasoning_effort={}",
                    reasoning_effort.trim().to_ascii_lowercase()
                )));
            }
            parts.push("--sandbox".to_string());
            parts.push("danger-full-access".to_string());
            parts.push("-C".to_string());
            parts.push(shell_literal(launch_dir));
            parts.push("--add-dir".to_string());
            parts.push(shell_literal(git_worktree_dir));
            Ok(parts.join(" "))
        }
        "claude" => {
            let mut parts = vec![shell_literal(agent)];
            if model_override {
                parts.push("--model".to_string());
                parts.push(shell_literal(model));
            }
            if effort_override {
                parts.push("--effort".to_string());
                parts.push(reasoning_effort.trim().to_ascii_lowercase());
            }
            parts.push("--permission-mode".to_string());
            parts.push("bypassPermissions".to_string());
            Ok(parts.join(" "))
        }
        "gemini" => {
            let mut parts = vec![shell_literal(agent)];
            if model_override {
                parts.push("--model".to_string());
                parts.push(shell_literal(model));
            }
            parts.push("--approval-mode=default".to_string());
            Ok(parts.join(" "))
        }
        adapter => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("Unsupported provider adapter '{adapter}' for restart"),
        )),
    }
}

fn shell_literal(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | ':' | '/' | '\\'))
    {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', "''"))
}

fn provider_target_with_model(agent: &str, model: &str, model_source: &str) -> String {
    if !provider_model_override(model, model_source) {
        agent.to_string()
    } else {
        format!("{}:{}", agent.trim(), model.trim())
    }
}

fn invoke_restart_plan(plan: &RestartPlan) -> io::Result<()> {
    let readiness_agent = restart_readiness_agent(plan);
    if readiness_agent.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "restart readiness adapter missing for pane '{}' ({}). Set provider capability metadata before restart.",
                plan.pane_id, plan.label
            ),
        ));
    }

    run_winsmux_command(&[
        "respawn-pane",
        "-k",
        "-t",
        &plan.pane_id,
        "-c",
        &plan.launch_dir,
    ])?;
    wait_for_shell_prompt(&plan.pane_id)?;
    run_winsmux_command(&[
        "send-keys",
        "-t",
        &plan.pane_id,
        "-l",
        "--",
        &plan.launch_command,
    ])?;
    run_winsmux_command(&["send-keys", "-t", &plan.pane_id, "Enter"])?;
    wait_for_agent_prompt(&plan.pane_id, &readiness_agent)?;
    Ok(())
}

fn restart_readiness_agent(plan: &RestartPlan) -> String {
    let adapter = readiness_agent_name(&plan.capability_adapter);
    if !adapter.is_empty() {
        return adapter;
    }
    let agent = readiness_agent_name(&plan.agent);
    agent
}

fn readiness_agent_name(value: &str) -> String {
    let lowered = value.trim().to_ascii_lowercase();
    for name in ["codex", "claude", "gemini"] {
        if lowered == name
            || lowered.starts_with(&format!("{name}:"))
            || lowered.starts_with(&format!("{name}-"))
            || lowered.starts_with(&format!("{name}_"))
            || lowered.starts_with(&format!("{name}/"))
        {
            return name.to_string();
        }
    }
    String::new()
}

fn wait_for_shell_prompt(pane_id: &str) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        let text = capture_pane_tail(pane_id)?;
        if text.lines().any(|line| line.trim().starts_with("PS ")) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(500));
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("timed out waiting for shell prompt in {pane_id}"),
    ))
}

fn wait_for_agent_prompt(pane_id: &str, agent: &str) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(60);
    while Instant::now() < deadline {
        let text = capture_pane_tail(pane_id)?;
        if agent_ready_prompt(&text, agent) {
            return Ok(());
        }
        thread::sleep(Duration::from_secs(2));
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        format!("timed out waiting for {agent} prompt after restart in {pane_id}"),
    ))
}

fn capture_pane_tail(pane_id: &str) -> io::Result<String> {
    let output = winsmux_command_output(&["capture-pane", "-t", pane_id, "-p", "-J", "-S", "-50"])?;
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_string())
}

fn agent_ready_prompt(text: &str, agent: &str) -> bool {
    let recent: Vec<&str> = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .rev()
        .take(8)
        .collect();
    recent.into_iter().any(|line| {
        let line = line.trim();
        match agent {
            "claude" => {
                line.eq_ignore_ascii_case("Welcome to Claude Code!")
                    || line.eq_ignore_ascii_case("Welcome to Claude Code")
                    || line.starts_with("/help for help, /status for your current setup")
                    || line.starts_with("?  for shortcuts")
            }
            "gemini" => {
                line.to_ascii_lowercase().starts_with("type your message")
                    || line.to_ascii_lowercase().starts_with("using:")
                    || line.to_ascii_lowercase().starts_with("gemini-")
            }
            _ => line == ">" || line == "›" || line == "▌" || line == "❯" || line.starts_with('>'),
        }
    })
}

fn run_winsmux_command(args: &[&str]) -> io::Result<()> {
    let output = winsmux_command_output(args)?;
    if !output.status.success() {
        return Err(winsmux_command_error(args, &output));
    }
    Ok(())
}

fn winsmux_command_output(args: &[&str]) -> io::Result<std::process::Output> {
    let winsmux_bin = winsmux_bin_path();
    Command::new(&winsmux_bin)
        .args(args)
        .output()
        .map_err(|err| {
            io::Error::new(
                io::ErrorKind::Other,
                format!("failed to run {}: {err}", winsmux_bin.display()),
            )
        })
}

fn winsmux_command_error(args: &[&str], output: &std::process::Output) -> io::Error {
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let detail = if !stderr.is_empty() {
        stderr
    } else if !stdout.is_empty() {
        stdout
    } else {
        output.status.to_string()
    };
    io::Error::new(
        io::ErrorKind::Other,
        format!("winsmux {} failed: {detail}", args.join(" ")),
    )
}

fn winsmux_bin_path() -> PathBuf {
    env::var_os("WINSMUX_BIN")
        .map(PathBuf::from)
        .or_else(|| env::current_exe().ok())
        .unwrap_or_else(|| PathBuf::from("winsmux"))
}

fn update_restart_manifest_metadata(project_dir: &Path, plan: &RestartPlan) -> io::Result<bool> {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    with_file_lock(&manifest_path, || {
        let raw = fs::read_to_string(&manifest_path)?;
        let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid manifest: {}: {err}", manifest_path.display()),
            )
        })?;
        let provider_target =
            provider_target_with_model(&plan.agent, &plan.model, &plan.model_source);
        let updated = update_manifest_pane_restart_fields(
            &mut manifest,
            &plan.pane_id,
            &[
                ("provider_target", provider_target.as_str()),
                ("capability_adapter", plan.capability_adapter.as_str()),
            ],
        );
        if !updated {
            return Ok(false);
        }
        let content = serde_yaml::to_string(&manifest).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("failed to serialize manifest: {err}"),
            )
        })?;
        write_text_file_locked(&manifest_path, &content)?;
        Ok(true)
    })
}

fn ensure_live_pane_target(session_name: &str, pane_id: &str) -> io::Result<()> {
    let winsmux_bin = winsmux_bin_path();
    let output = Command::new(&winsmux_bin)
        .args(["-t", session_name, "list-panes", "-a", "-F", "#{pane_id}"])
        .output()
        .map_err(|err| {
            io::Error::new(
                io::ErrorKind::Other,
                format!(
                    "failed to validate live panes with {}: {err}",
                    winsmux_bin.display()
                ),
            )
        })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let detail = if stderr.is_empty() {
            output.status.to_string()
        } else {
            stderr
        };
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("failed to validate live panes: {detail}"),
        ));
    }
    let found = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .any(|line| line == pane_id);
    if !found {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid target: {pane_id}"),
        ));
    }
    Ok(())
}

struct FileLock {
    path: PathBuf,
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn write_text_file_with_lock(path: &Path, content: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    with_file_lock(path, || write_text_file_locked(path, content))
}

fn with_file_lock<T>(path: &Path, action: impl FnOnce() -> io::Result<T>) -> io::Result<T> {
    let _lock = acquire_file_lock(path)?;
    action()
}

fn write_text_file_locked(path: &Path, content: &str) -> io::Result<()> {
    let tmp_path = temp_write_path(path);
    fs::write(&tmp_path, content)?;
    match replace_file_with_temp(&tmp_path, path) {
        Ok(()) => Ok(()),
        Err(err) => {
            let _ = fs::remove_file(&tmp_path);
            Err(err)
        }
    }
}

#[cfg(windows)]
fn replace_file_with_temp(tmp_path: &Path, path: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    fn wide(value: &Path) -> Vec<u16> {
        value
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    let tmp = wide(tmp_path);
    let target = wide(path);
    let result = unsafe {
        MoveFileExW(
            tmp.as_ptr(),
            target.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(windows))]
fn replace_file_with_temp(tmp_path: &Path, path: &Path) -> io::Result<()> {
    fs::rename(tmp_path, path)
}

fn acquire_file_lock(path: &Path) -> io::Result<FileLock> {
    let lock_path = lock_path_for(path);
    let start = Instant::now();
    loop {
        match fs::create_dir(&lock_path) {
            Ok(()) => {
                let owner = json!({
                    "pid": std::process::id(),
                    "started_at": generated_at(),
                    "path": path.display().to_string(),
                });
                let mut owner = owner;
                if let Some(process_started_at) = current_process_started_at() {
                    owner["process_started_at"] = json!(process_started_at);
                }
                let owner_json = serde_json::to_string_pretty(&owner).unwrap_or_default();
                let _ = fs::write(lock_path.join("owner.json"), owner_json);
                return Ok(FileLock { path: lock_path });
            }
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => {
                remove_stale_lock(&lock_path);
                if start.elapsed() >= FILE_LOCK_TIMEOUT {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        format!("timed out waiting for file lock: {}", lock_path.display()),
                    ));
                }
                thread::sleep(FILE_LOCK_RETRY_DELAY);
            }
            Err(err) => return Err(err),
        }
    }
}

#[cfg(windows)]
fn current_process_started_at() -> Option<String> {
    use windows_sys::Win32::System::Threading::GetCurrentProcess;

    let handle = unsafe { GetCurrentProcess() };
    process_started_at_for_handle(handle)
}

#[cfg(not(windows))]
fn current_process_started_at() -> Option<String> {
    None
}

#[cfg(windows)]
fn process_started_at_for_pid(pid: u32) -> Option<String> {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};

    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if handle.is_null() {
        return None;
    }
    let started_at = process_started_at_for_handle(handle);
    unsafe {
        let _ = CloseHandle(handle);
    }
    started_at
}

#[cfg(windows)]
fn process_started_at_for_handle(handle: windows_sys::Win32::Foundation::HANDLE) -> Option<String> {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::GetProcessTimes;

    let mut created = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let mut exited = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let mut kernel = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let mut user = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let ok = unsafe { GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) };
    if ok == 0 {
        return None;
    }
    filetime_to_rfc3339(created)
}

#[cfg(windows)]
fn filetime_to_rfc3339(value: windows_sys::Win32::Foundation::FILETIME) -> Option<String> {
    let ticks = ((value.dwHighDateTime as u64) << 32) | (value.dwLowDateTime as u64);
    let unix_ticks = ticks.checked_sub(116_444_736_000_000_000)?;
    let secs = (unix_ticks / 10_000_000) as i64;
    let nanos = ((unix_ticks % 10_000_000) * 100) as u32;
    DateTime::<Utc>::from_timestamp(secs, nanos)
        .map(|timestamp| timestamp.to_rfc3339_opts(SecondsFormat::Secs, true))
}

fn remove_stale_lock(lock_path: &Path) {
    let owner_path = lock_path.join("owner.json");
    if owner_path.is_file() {
        match fs::read_to_string(&owner_path)
            .ok()
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        {
            Some(owner) => {
                if let Some(pid) = owner.get("pid").and_then(Value::as_u64) {
                    let expected = owner
                        .get("process_started_at")
                        .and_then(Value::as_str)
                        .filter(|value| !value.trim().is_empty());
                    if process_lock_is_stale(pid as u32, expected) {
                        let _ = fs::remove_dir_all(lock_path);
                    }
                    return;
                }
                if owner.get("started_at").and_then(Value::as_str).is_some() {
                    return;
                }
                let _ = fs::remove_dir_all(lock_path);
                return;
            }
            None => {}
        }
    }

    let Ok(metadata) = fs::metadata(lock_path) else {
        return;
    };
    let Ok(modified) = metadata.modified() else {
        return;
    };
    let Ok(age) = modified.elapsed() else {
        return;
    };
    if age >= FILE_LOCK_STALE_AFTER {
        let _ = fs::remove_dir_all(lock_path);
    }
}

#[cfg(windows)]
fn process_lock_is_stale(pid: u32, expected_started_at: Option<&str>) -> bool {
    let Some(actual_started_at) = process_started_at_for_pid(pid) else {
        return true;
    };
    let Some(expected_started_at) = expected_started_at else {
        return false;
    };
    let Ok(expected) = DateTime::parse_from_rfc3339(expected_started_at) else {
        return true;
    };
    let Ok(actual) = DateTime::parse_from_rfc3339(&actual_started_at) else {
        return true;
    };
    (actual - expected).num_seconds().abs() > 1
}

#[cfg(not(windows))]
fn process_lock_is_stale(_pid: u32, _expected_started_at: Option<&str>) -> bool {
    false
}

fn lock_path_for(path: &Path) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(".lock");
    PathBuf::from(value)
}

fn temp_write_path(path: &Path) -> PathBuf {
    let counter = ATOMIC_WRITE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let mut value = path.as_os_str().to_os_string();
    value.push(format!(".tmp-{}-{counter}", std::process::id()));
    PathBuf::from(value)
}

fn strip_windows_extended_path_prefix(path: &str) -> String {
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        return format!(r"\\{rest}");
    }
    if let Some(rest) = path.strip_prefix(r"\\?\") {
        return rest.to_string();
    }
    path.to_string()
}

fn review_request_record(
    branch: &str,
    head_sha: &str,
    context: &ReviewPaneContext,
    timestamp: &str,
) -> Value {
    json!({
        "id": review_request_id(),
        "branch": branch,
        "head_sha": head_sha,
        "target_review_pane_id": context.pane_id,
        "target_review_label": context.label,
        "target_review_role": context.role,
        "target_reviewer_pane_id": context.pane_id,
        "target_reviewer_label": context.label,
        "target_reviewer_role": context.role,
        "review_contract": review_contract_record(),
        "dispatched_at": timestamp,
    })
}

fn review_request_id() -> String {
    let now = Utc::now();
    format!(
        "review-{}-{}",
        now.format("%Y%m%d%H%M%S"),
        review_request_suffix(now)
    )
}

fn review_request_suffix(now: chrono::DateTime<Utc>) -> String {
    let nanos = now.timestamp_nanos_opt().unwrap_or_default() as u64;
    let counter = REVIEW_REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed) as u64;
    let mixed = nanos ^ ((std::process::id() as u64) << 16) ^ counter;
    format!("{:08x}", mixed & 0xffff_ffff)
}

fn review_contract_record() -> Value {
    json!({
        "version": 1,
        "source_task": "TASK-210",
        "issue_ref": "#315",
        "style": "utility_first",
        "required_scope": [
            "design_impact",
            "replacement_coverage",
            "orphaned_artifacts",
            "pathspec_completeness"
        ],
        "checklist_labels": [
            "design impact",
            "replacement coverage",
            "orphaned artifacts",
            "pathspec completeness"
        ],
        "pathspec_policy": {
            "source_task": "TASK-395",
            "issue_ref": "#593",
            "include_definition_hosts": true,
            "incomplete_scope_is_review_gap": true
        },
        "rationale": "Review requests must audit downstream design impact, replacement coverage, orphaned artifacts, and pathspec completeness as part of the runtime contract."
    })
}

fn record_review_result(
    args: &[&String],
    command_name: &str,
    status: &str,
    timestamp_key: &str,
    via_key: &str,
    manifest_state: &str,
) -> io::Result<()> {
    if should_print_help(args) {
        println!("{}", usage_for(command_name));
        return Ok(());
    }
    let options = parse_options(command_name, args, 0)?;
    if options.json {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            usage_for(command_name),
        ));
    }
    assert_review_role_permission(command_name)?;

    let branch = current_git_branch(&options.project_dir)?;
    let head_sha = current_git_head(&options.project_dir)?;
    let context = current_review_pane_context(&options.project_dir)?;
    let mut state = load_review_state(&options.project_dir)?;
    let request = pending_review_request(&state, &branch, &head_sha, &context)?;
    let timestamp = generated_at();
    let reviewer = review_result_reviewer(&context);
    let evidence =
        review_result_evidence(&request, timestamp_key, via_key, command_name, &timestamp);
    let request_branch = request_string(&request, "branch");
    let request_head_sha = request_string(&request, "head_sha");

    state.insert(
        branch.clone(),
        json!({
            "status": status,
            "branch": request_branch,
            "head_sha": request_head_sha,
            "request": request,
            "reviewer": reviewer,
            "updatedAt": timestamp,
            "evidence": evidence,
        }),
    );
    save_review_state(&options.project_dir, state)?;
    let _ = mark_current_pane_review_result(
        &options.project_dir,
        &context,
        &branch,
        &head_sha,
        manifest_state,
    );
    println!("review {status} recorded for {branch}");
    Ok(())
}

fn pending_review_request(
    state: &Map<String, Value>,
    branch: &str,
    head_sha: &str,
    context: &ReviewPaneContext,
) -> io::Result<Value> {
    let Some(entry) = state.get(branch) else {
        return Err(pending_review_request_missing(branch));
    };
    let status = entry
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let Some(request) = entry.get("request").cloned() else {
        return Err(pending_review_request_missing(branch));
    };
    if status != "PENDING" || !request.is_object() {
        return Err(pending_review_request_missing(branch));
    }
    if !review_contract_present(&request) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("pending review request for {branch} is missing review_contract. Re-run: winsmux review-request"),
        ));
    }

    let request_pane_id = review_request_target_value(&request, "pane_id");
    if request_pane_id != context.pane_id {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "pending review request for {branch} is assigned to {request_pane_id}, not {}",
                context.pane_id
            ),
        ));
    }

    let request_branch = request_string(&request, "branch");
    if request_branch != branch {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "pending review request branch mismatch: expected {request_branch}, got {branch}"
            ),
        ));
    }

    let request_head_sha = request_string(&request, "head_sha");
    if request_head_sha != head_sha {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "pending review request head mismatch: expected {request_head_sha}, got {head_sha}"
            ),
        ));
    }

    Ok(request)
}

fn pending_review_request_missing(branch: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::NotFound,
        format!("review request pending for {branch} was not found. Run: winsmux review-request"),
    )
}

fn review_contract_present(request: &Value) -> bool {
    let Some(contract) = request.get("review_contract").and_then(Value::as_object) else {
        return false;
    };
    match contract.get("required_scope") {
        Some(Value::Array(items)) => !items.is_empty(),
        Some(Value::String(value)) => !value.trim().is_empty(),
        Some(Value::Null) | None => false,
        Some(_) => true,
    }
}

fn review_request_target_value(request: &Value, name: &str) -> String {
    let primary = format!("target_review_{name}");
    let legacy = format!("target_reviewer_{name}");
    let primary_value = request_string(request, &primary);
    if primary_value.trim().is_empty() {
        request_string(request, &legacy)
    } else {
        primary_value
    }
}

fn request_string(request: &Value, name: &str) -> String {
    request
        .get(name)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn review_result_reviewer(context: &ReviewPaneContext) -> Value {
    json!({
        "pane_id": context.pane_id,
        "label": context.label,
        "role": context.role,
        "agent_name": env::var("WINSMUX_AGENT_NAME").unwrap_or_default(),
    })
}

fn review_result_evidence(
    request: &Value,
    timestamp_key: &str,
    via_key: &str,
    command_name: &str,
    timestamp: &str,
) -> Value {
    let mut evidence = Map::new();
    evidence.insert(timestamp_key.to_string(), json!(timestamp));
    evidence.insert(
        via_key.to_string(),
        json!(format!("winsmux {command_name}")),
    );
    evidence.insert(
        "review_contract_snapshot".to_string(),
        request
            .get("review_contract")
            .cloned()
            .unwrap_or(Value::Null),
    );
    Value::Object(evidence)
}

fn mark_current_pane_review_requested(
    project_dir: &Path,
    context: &ReviewPaneContext,
    branch: &str,
    head_sha: &str,
) -> io::Result<bool> {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;
    let timestamp = generated_at();
    let updated = update_manifest_pane_fields(
        &mut manifest,
        &context.pane_id,
        &[
            ("review_state", "pending"),
            ("task_owner", &context.role),
            ("branch", branch),
            ("head_sha", head_sha),
            ("last_event", "review.requested"),
            ("last_event_at", &timestamp),
        ],
    );
    if !updated {
        return Ok(false);
    }
    let content = serde_yaml::to_string(&manifest).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize manifest: {err}"),
        )
    })?;
    write_text_file_with_lock(&manifest_path, &content)?;
    Ok(true)
}

fn mark_current_pane_review_result(
    project_dir: &Path,
    context: &ReviewPaneContext,
    branch: &str,
    head_sha: &str,
    review_state: &str,
) -> io::Result<bool> {
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;
    let timestamp = generated_at();
    let last_event = format!("review.{review_state}");
    let updated = update_manifest_pane_fields(
        &mut manifest,
        &context.pane_id,
        &[
            ("review_state", review_state),
            ("task_owner", "Operator"),
            ("branch", branch),
            ("head_sha", head_sha),
            ("last_event", &last_event),
            ("last_event_at", &timestamp),
        ],
    );
    if !updated {
        return Ok(false);
    }
    let content = serde_yaml::to_string(&manifest).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize manifest: {err}"),
        )
    })?;
    write_text_file_with_lock(&manifest_path, &content)?;
    Ok(true)
}

fn update_manifest_pane_fields(
    manifest: &mut serde_yaml::Value,
    pane_id: &str,
    fields: &[(&str, &str)],
) -> bool {
    let Some(panes) = manifest.get_mut("panes") else {
        return false;
    };

    match panes {
        serde_yaml::Value::Mapping(map) => map.iter_mut().any(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            update_manifest_pane_if_matches(label, pane, pane_id, fields)
        }),
        serde_yaml::Value::Sequence(items) => items
            .iter_mut()
            .any(|pane| update_manifest_pane_if_matches("", pane, pane_id, fields)),
        _ => false,
    }
}

fn update_manifest_pane_if_matches(
    label: &str,
    pane: &mut serde_yaml::Value,
    pane_id: &str,
    fields: &[(&str, &str)],
) -> bool {
    let serde_yaml::Value::Mapping(map) = pane else {
        return false;
    };
    let actual = manifest_string(map, "pane_id");
    if actual != pane_id {
        return false;
    }
    let role = manifest_string(map, "role");
    let canonical_role = canonical_manifest_role(&role, label);
    if !matches!(canonical_role.as_deref(), Some("Reviewer" | "Worker")) {
        return false;
    }
    for (name, value) in fields {
        map.insert(
            serde_yaml::Value::String((*name).to_string()),
            serde_yaml::Value::String((*value).to_string()),
        );
    }
    true
}

fn update_manifest_pane_restart_fields(
    manifest: &mut serde_yaml::Value,
    pane_id: &str,
    fields: &[(&str, &str)],
) -> bool {
    let Some(panes) = manifest.get_mut("panes") else {
        return false;
    };

    match panes {
        serde_yaml::Value::Mapping(map) => map
            .values_mut()
            .any(|pane| update_manifest_pane_by_id(pane, pane_id, fields)),
        serde_yaml::Value::Sequence(items) => items
            .iter_mut()
            .any(|pane| update_manifest_pane_by_id(pane, pane_id, fields)),
        _ => false,
    }
}

fn update_manifest_pane_by_id(
    pane: &mut serde_yaml::Value,
    pane_id: &str,
    fields: &[(&str, &str)],
) -> bool {
    let serde_yaml::Value::Mapping(map) = pane else {
        return false;
    };
    if manifest_string(map, "pane_id") != pane_id {
        return false;
    }
    for (name, value) in fields {
        map.insert(
            serde_yaml::Value::String((*name).to_string()),
            serde_yaml::Value::String((*value).to_string()),
        );
    }
    true
}

fn update_manifest_pane_paths(
    manifest: &mut serde_yaml::Value,
    pane_id: &str,
    launch_dir: &str,
    builder_worktree_path: &str,
) -> bool {
    let Some(panes) = manifest.get_mut("panes") else {
        return false;
    };

    match panes {
        serde_yaml::Value::Mapping(map) => map.iter_mut().any(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            update_manifest_pane_paths_if_matches(
                label,
                pane,
                pane_id,
                launch_dir,
                builder_worktree_path,
            )
        }),
        serde_yaml::Value::Sequence(items) => items.iter_mut().any(|pane| {
            update_manifest_pane_paths_if_matches(
                "",
                pane,
                pane_id,
                launch_dir,
                builder_worktree_path,
            )
        }),
        _ => false,
    }
}

fn update_manifest_pane_paths_if_matches(
    label: &str,
    pane: &mut serde_yaml::Value,
    pane_id: &str,
    launch_dir: &str,
    builder_worktree_path: &str,
) -> bool {
    let serde_yaml::Value::Mapping(map) = pane else {
        return false;
    };
    let actual = manifest_string(map, "pane_id");
    if actual != pane_id {
        return false;
    }
    let role = manifest_string(map, "role");
    let canonical_role = canonical_manifest_role(&role, label);
    if !matches!(canonical_role.as_deref(), Some("Builder" | "Worker")) {
        return false;
    }
    for (name, value) in [
        ("launch_dir", launch_dir),
        ("builder_worktree_path", builder_worktree_path),
    ] {
        map.insert(
            serde_yaml::Value::String(name.to_string()),
            serde_yaml::Value::String(value.to_string()),
        );
    }
    true
}

fn clear_current_pane_review_manifest_state(project_dir: &Path) -> io::Result<bool> {
    let pane_id = match env::var("WINSMUX_PANE_ID") {
        Ok(value) if !value.trim().is_empty() => value,
        _ => return Ok(false),
    };
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;

    let timestamp = generated_at();
    let updated = update_manifest_pane_review_state(&mut manifest, &pane_id, &timestamp);
    if !updated {
        return Ok(false);
    }

    let content = serde_yaml::to_string(&manifest).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize manifest: {err}"),
        )
    })?;
    write_text_file_with_lock(&manifest_path, &content)?;
    Ok(true)
}

fn update_manifest_pane_review_state(
    manifest: &mut serde_yaml::Value,
    pane_id: &str,
    timestamp: &str,
) -> bool {
    let Some(panes) = manifest.get_mut("panes") else {
        return false;
    };

    match panes {
        serde_yaml::Value::Mapping(map) => map
            .values_mut()
            .any(|pane| clear_manifest_pane_if_matches(pane, pane_id, timestamp)),
        serde_yaml::Value::Sequence(items) => items
            .iter_mut()
            .any(|pane| clear_manifest_pane_if_matches(pane, pane_id, timestamp)),
        _ => false,
    }
}

fn clear_manifest_pane_if_matches(
    pane: &mut serde_yaml::Value,
    pane_id: &str,
    timestamp: &str,
) -> bool {
    let serde_yaml::Value::Mapping(map) = pane else {
        return false;
    };
    let key = serde_yaml::Value::String("pane_id".to_string());
    let actual = map
        .get(&key)
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or_default();
    if actual != pane_id {
        return false;
    }
    let role = map
        .get(serde_yaml::Value::String("role".to_string()))
        .and_then(serde_yaml::Value::as_str)
        .unwrap_or_default();
    if !matches!(role, "Reviewer" | "Worker") {
        return false;
    }

    for name in ["review_state", "branch", "head_sha"] {
        map.insert(
            serde_yaml::Value::String(name.to_string()),
            serde_yaml::Value::String(String::new()),
        );
    }
    map.insert(
        serde_yaml::Value::String("last_event".to_string()),
        serde_yaml::Value::String("review.reset".to_string()),
    );
    map.insert(
        serde_yaml::Value::String("last_event_at".to_string()),
        serde_yaml::Value::String(timestamp.to_string()),
    );
    true
}

fn load_snapshot(project_dir: &Path) -> io::Result<LedgerSnapshot> {
    LedgerSnapshot::from_project_dir(project_dir).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to load winsmux ledger: {err}"),
        )
    })
}

fn compare_runs_payload(
    left: &crate::ledger::LedgerExplainProjection,
    right: &crate::ledger::LedgerExplainProjection,
) -> Value {
    let left_changed = left.evidence_digest.changed_files.clone();
    let right_changed = right.evidence_digest.changed_files.clone();
    let shared_changed: Vec<String> = left_changed
        .iter()
        .filter(|path| right_changed.contains(path))
        .cloned()
        .collect();
    let left_only: Vec<String> = left_changed
        .iter()
        .filter(|path| !right_changed.contains(path))
        .cloned()
        .collect();
    let right_only: Vec<String> = right_changed
        .iter()
        .filter(|path| !left_changed.contains(path))
        .cloned()
        .collect();

    let confidence_delta = match (
        left.run.experiment_packet.confidence,
        right.run.experiment_packet.confidence,
    ) {
        (Some(left_confidence), Some(right_confidence)) => {
            Some(round_half_to_even(left_confidence - right_confidence, 4))
        }
        _ => None,
    };

    let mut differences = Vec::new();
    for (field, left_value, right_value) in [
        ("branch", left.run.branch.clone(), right.run.branch.clone()),
        (
            "worktree",
            left.run.experiment_packet.worktree.clone(),
            right.run.experiment_packet.worktree.clone(),
        ),
        (
            "slot",
            left.run.experiment_packet.slot.clone(),
            right.run.experiment_packet.slot.clone(),
        ),
        (
            "task_state",
            left.run.task_state.clone(),
            right.run.task_state.clone(),
        ),
        (
            "review_state",
            left.run.review_state.clone(),
            right.run.review_state.clone(),
        ),
        ("state", left.run.state.clone(), right.run.state.clone()),
        (
            "next_action",
            left.evidence_digest.next_action.clone(),
            right.evidence_digest.next_action.clone(),
        ),
        (
            "hypothesis",
            left.run.experiment_packet.hypothesis.clone(),
            right.run.experiment_packet.hypothesis.clone(),
        ),
        (
            "result",
            left.run.experiment_packet.result.clone(),
            right.run.experiment_packet.result.clone(),
        ),
        (
            "env_fingerprint",
            left.run.experiment_packet.env_fingerprint.clone(),
            right.run.experiment_packet.env_fingerprint.clone(),
        ),
        (
            "command_hash",
            left.run.experiment_packet.command_hash.clone(),
            right.run.experiment_packet.command_hash.clone(),
        ),
    ] {
        if left_value != right_value {
            differences.push(json!({
                "field": field,
                "left": left_value,
                "right": right_value,
            }));
        }
    }
    if !left_only.is_empty() || !right_only.is_empty() {
        differences.push(json!({
            "field": "changed_files",
            "left": left_changed,
            "right": right_changed,
        }));
    }
    if let Some(delta) = confidence_delta {
        if delta != 0.0 {
            differences.push(json!({
                "field": "confidence",
                "left": left.run.experiment_packet.confidence,
                "right": right.run.experiment_packet.confidence,
            }));
        }
    }

    let left_recommendable = run_recommendable(&left.run);
    let right_recommendable = run_recommendable(&right.run);
    let winning_run_id = if left_recommendable && right_recommendable {
        match confidence_delta {
            Some(delta) if delta > 0.0 => left.run.run_id.clone(),
            Some(delta) if delta < 0.0 => right.run.run_id.clone(),
            _ => String::new(),
        }
    } else {
        String::new()
    };
    let reconcile_consult = differences.iter().any(|difference| {
        difference["field"]
            .as_str()
            .map(|field| {
                matches!(
                    field,
                    "branch" | "worktree" | "env_fingerprint" | "command_hash" | "result"
                )
            })
            .unwrap_or(false)
    }) || !(left_recommendable && right_recommendable);
    let (playbook_template, follow_up_run) = if !winning_run_id.trim().is_empty() {
        if winning_run_id == left.run.run_id {
            let playbook_template = playbook_template_contract(
                &left.run,
                &left.evidence_digest,
                "compare_winner_follow_up",
                "compare_runs",
                &[&left.run, &right.run],
            );
            let follow_up_run = compare_winner_follow_up_run_contract(
                &left.run,
                &left.evidence_digest,
                &playbook_template,
            );
            (playbook_template, follow_up_run)
        } else {
            let playbook_template = playbook_template_contract(
                &right.run,
                &right.evidence_digest,
                "compare_winner_follow_up",
                "compare_runs",
                &[&left.run, &right.run],
            );
            let follow_up_run = compare_winner_follow_up_run_contract(
                &right.run,
                &right.evidence_digest,
                &playbook_template,
            );
            (playbook_template, follow_up_run)
        }
    } else if reconcile_consult {
        (
            compare_reconcile_playbook_template(&left.run, &right.run),
            Value::Null,
        )
    } else {
        (Value::Null, Value::Null)
    };
    let next_action = if left.evidence_digest.next_action == right.evidence_digest.next_action {
        left.evidence_digest.next_action.clone()
    } else {
        "reconcile_consult".to_string()
    };

    json!({
        "generated_at": generated_at(),
        "left": compare_run_side(left, left_recommendable),
        "right": compare_run_side(right, right_recommendable),
        "shared_changed_files": shared_changed,
        "left_only_changed_files": left_only,
        "right_only_changed_files": right_only,
        "confidence_delta": confidence_delta,
        "differences": differences,
        "recommend": {
            "winning_run_id": winning_run_id,
            "reconcile_consult": reconcile_consult,
            "next_action": next_action,
            "playbook_template": playbook_template,
            "follow_up_run": follow_up_run,
        },
    })
}

fn conflict_preflight_payload(
    project_dir: &Path,
    left_ref: &str,
    right_ref: &str,
) -> io::Result<ConflictPreflightPayload> {
    let repo_root = resolve_conflict_preflight_repo_root(project_dir)?;
    let left_sha = resolve_conflict_commit(&repo_root, left_ref)?;
    let right_sha = resolve_conflict_commit(&repo_root, right_ref)?;
    let merge_base_result = git_probe(&repo_root, &["merge-base", left_ref, right_ref])?;
    if merge_base_result.exit_code != 0 || merge_base_result.output.trim().is_empty() {
        return Ok(ConflictPreflightPayload {
            command: "conflict-preflight".to_string(),
            status: "blocked".to_string(),
            reason: "no_merge_base".to_string(),
            project_dir: repo_root.display().to_string(),
            left_ref: left_ref.to_string(),
            right_ref: right_ref.to_string(),
            left_sha,
            right_sha,
            merge_base: String::new(),
            merge_tree_exit_code: None,
            conflict_detected: false,
            overlap_paths: Vec::new(),
            left_only_paths: Vec::new(),
            right_only_paths: Vec::new(),
            next_action:
                "Choose related refs with a shared merge base and rerun winsmux conflict-preflight."
                    .to_string(),
        });
    }

    let merge_base = merge_base_result.output;
    let left_paths = conflict_path_array(
        &git_probe(&repo_root, &["diff", "--name-only", &merge_base, left_ref])?.output,
    );
    let right_paths = conflict_path_array(
        &git_probe(&repo_root, &["diff", "--name-only", &merge_base, right_ref])?.output,
    );
    let overlap_paths: Vec<String> = left_paths
        .iter()
        .filter(|path| right_paths.contains(path))
        .cloned()
        .collect();
    let left_only_paths: Vec<String> = left_paths
        .iter()
        .filter(|path| !right_paths.contains(path))
        .cloned()
        .collect();
    let right_only_paths: Vec<String> = right_paths
        .iter()
        .filter(|path| !left_paths.contains(path))
        .cloned()
        .collect();
    let merge_tree_result = git_probe(
        &repo_root,
        &["merge-tree", "--write-tree", "--quiet", left_ref, right_ref],
    )?;
    let (status, reason, conflict_detected, next_action) = match merge_tree_result.exit_code {
        0 => (
            "clean",
            "",
            false,
            "Safe to continue to compare UI or follow-up review.",
        ),
        1 => (
            "conflict",
            "merge_conflict",
            true,
            "Inspect overlap paths before compare or merge.",
        ),
        _ => (
            "blocked",
            "merge_tree_failed",
            false,
            "Inspect git merge-tree output and rerun winsmux conflict-preflight.",
        ),
    };

    Ok(ConflictPreflightPayload {
        command: "conflict-preflight".to_string(),
        status: status.to_string(),
        reason: reason.to_string(),
        project_dir: repo_root.display().to_string(),
        left_ref: left_ref.to_string(),
        right_ref: right_ref.to_string(),
        left_sha,
        right_sha,
        merge_base,
        merge_tree_exit_code: Some(merge_tree_result.exit_code),
        conflict_detected,
        overlap_paths,
        left_only_paths,
        right_only_paths,
        next_action: next_action.to_string(),
    })
}

fn resolve_conflict_preflight_repo_root(project_dir: &Path) -> io::Result<PathBuf> {
    if !project_dir.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("project directory not found: {}", project_dir.display()),
        ));
    }
    let result = git_probe(project_dir, &["rev-parse", "--show-toplevel"])?;
    if result.exit_code != 0 || result.output.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "git repository root could not be resolved from: {}",
                project_dir.display()
            ),
        ));
    }
    Ok(PathBuf::from(result.output))
}

fn resolve_conflict_commit(project_dir: &Path, git_ref: &str) -> io::Result<String> {
    let rev = format!("{git_ref}^{{commit}}");
    let result = git_probe(project_dir, &["rev-parse", "--verify", &rev])?;
    if result.exit_code != 0 || result.output.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("git ref could not be resolved: {git_ref}"),
        ));
    }
    Ok(result.output)
}

fn git_probe(project_dir: &Path, args: &[&str]) -> io::Result<GitProbeResult> {
    let output = Command::new("git")
        .args(args)
        .current_dir(project_dir)
        .output()?;
    let mut text = String::new();
    text.push_str(&String::from_utf8_lossy(&output.stdout));
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    Ok(GitProbeResult {
        exit_code: output.status.code().unwrap_or(1),
        output: text.trim().to_string(),
    })
}

fn guard_report_payload(project_dir: &Path) -> Value {
    let branch = git_output_line(project_dir, &["rev-parse", "--abbrev-ref", "HEAD"])
        .ok()
        .flatten()
        .filter(|value| value != "HEAD")
        .unwrap_or_default();
    let head_sha = git_output_line(project_dir, &["rev-parse", "HEAD"])
        .ok()
        .flatten()
        .unwrap_or_default();
    let hooks_path = git_output_line(project_dir, &["config", "--get", "core.hooksPath"])
        .ok()
        .flatten()
        .unwrap_or_default();
    let baseline_file = project_dir
        .join("scripts")
        .join("gitleaks-history-baseline.txt");
    let baseline_commit = fs::read_to_string(&baseline_file)
        .ok()
        .map(|value| value.trim().to_string())
        .unwrap_or_default();
    let required_checks = vec![
        guard_check(
            "git_guard_full",
            "pwsh -NoProfile -File scripts/git-guard.ps1 -Mode full",
            "scripts/git-guard.ps1",
            "secret and private surface path guard",
            file_exists(project_dir, "scripts/git-guard.ps1"),
        ),
        guard_check(
            "public_surface_audit",
            "pwsh -NoProfile -File scripts/audit-public-surface.ps1",
            "scripts/audit-public-surface.ps1",
            "public, contributor, and private surface boundary guard",
            file_exists(project_dir, "scripts/audit-public-surface.ps1"),
        ),
        guard_check(
            "gitleaks_incremental",
            "pwsh -NoProfile -File scripts/gitleaks-history.ps1",
            "scripts/gitleaks-history.ps1",
            "incremental secret history scan from recorded baseline",
            file_exists(project_dir, "scripts/gitleaks-history.ps1")
                && !baseline_commit.trim().is_empty(),
        ),
        guard_check(
            "evidence_envelope",
            "winsmux runs --json",
            "run_projection",
            "verification evidence, security verdict, and audit chain are preserved in run packets",
            true,
        ),
        guard_check(
            "release_notes_contract",
            "pwsh -NoProfile -File scripts/generate-release-notes.ps1",
            "scripts/generate-release-notes.ps1",
            "English public release notes with traceable issue or PR references",
            file_exists(project_dir, "scripts/generate-release-notes.ps1"),
        ),
    ];
    let required_check_count = required_checks.len();
    let available_check_count = required_checks
        .iter()
        .filter(|check| check["available"].as_bool().unwrap_or(false))
        .count();

    json!({
        "contract_version": 1,
        "command": "guard",
        "task_ids": ["TASK-362", "TASK-383", "TASK-384"],
        "target_version": "v0.24.10",
        "generated_at": generated_at(),
        "project_dir": project_dir_string(project_dir),
        "product_version": VERSION,
        "summary": {
            "required_check_count": required_check_count,
            "available_check_count": available_check_count,
            "blocking_policy": "release automation must stop when any required check fails or evidence is missing",
            "next_action": "Run the listed guard commands before release tagging or automated merge."
        },
        "observed_state": {
            "branch": branch,
            "head_sha": head_sha,
            "hooks_path": hooks_path,
            "hooks_path_expected": ".githooks",
            "gitleaks_baseline_file": "scripts/gitleaks-history-baseline.txt",
            "gitleaks_baseline_commit": baseline_commit
        },
        "required_checks": required_checks,
        "evidence_contract": {
            "run_surfaces": ["winsmux runs --json", "winsmux digest --json", "winsmux explain <run_id> --json"],
            "required_fields": [
                "verification_envelope",
                "verification_evidence",
                "security_verdict",
                "audit_chain",
                "draft_pr_gate",
                "phase_gate"
            ],
            "audit_chain_events": [
                "operator.review_requested",
                "operator.review_failed",
                "pipeline.verify.pass",
                "pipeline.verify.fail",
                "pipeline.security.allowed",
                "pipeline.security.blocked"
            ],
            "envelope_required_fields": [
                "contract_version",
                "packet_type",
                "scope",
                "static_gates",
                "dynamic_gates",
                "release_decision"
            ],
            "release_decision": {
                "automatic_merge_allowed": false,
                "human_judgement_required": true
            }
        },
        "public_safety": {
            "tracked_private_paths_allowed": false,
            "maintainer_local_paths_allowed": false,
            "private_skill_bodies_allowed": false,
            "public_release_notes_language": "English"
        }
    })
}

fn guard_check(id: &str, command: &str, source: &str, purpose: &str, available: bool) -> Value {
    json!({
        "id": id,
        "command": command,
        "source": source,
        "purpose": purpose,
        "required": true,
        "available": available,
    })
}

fn file_exists(project_dir: &Path, relative_path: &str) -> bool {
    relative_path
        .split('/')
        .fold(project_dir.to_path_buf(), |path, segment| {
            path.join(segment)
        })
        .is_file()
}

fn conflict_path_array(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect()
}

fn compare_run_side(
    projection: &crate::ledger::LedgerExplainProjection,
    recommendable: bool,
) -> Value {
    json!({
        "run_id": projection.run.run_id,
        "label": projection.run.primary_label,
        "branch": projection.run.branch,
        "task_state": projection.run.task_state,
        "review_state": projection.run.review_state,
        "state": projection.run.state,
        "next_action": projection.evidence_digest.next_action,
        "confidence": projection.run.experiment_packet.confidence,
        "changed_files": projection.evidence_digest.changed_files,
        "observation_pack_ref": projection.run.experiment_packet.observation_pack_ref,
        "consultation_ref": projection.run.experiment_packet.consultation_ref,
        "recommendable": recommendable,
    })
}

fn run_recommendable(run: &crate::ledger::LedgerExplainRun) -> bool {
    if !matches!(
        run.task_state.as_str(),
        "completed" | "task_completed" | "commit_ready" | "done"
    ) {
        return false;
    }
    if !run.review_state.trim().is_empty() && !run.review_state.eq_ignore_ascii_case("PASS") {
        return false;
    }
    if json_string_field(&run.verification_result, "outcome").to_ascii_uppercase() != "PASS" {
        return false;
    }
    if !matches!(
        json_string_or_field(&run.security_verdict, "verdict")
            .to_ascii_uppercase()
            .as_str(),
        "ALLOW" | "PASS"
    ) {
        return false;
    }
    let architecture_score_regression = run
        .architecture_contract
        .get("score_regression")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let architecture_review_required = run
        .architecture_contract
        .get("baseline")
        .and_then(|baseline| baseline.get("review_required_on_drift"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if architecture_score_regression
        && architecture_review_required
        && !run.review_state.eq_ignore_ascii_case("PASS")
    {
        return false;
    }

    true
}

fn run_playbook_flow(
    run: &crate::ledger::LedgerExplainRun,
    evidence_digest: &crate::ledger::LedgerDigestItem,
    fallback: &str,
) -> &'static str {
    match fallback {
        "ci" => return "ci",
        "review" => return "review",
        "ui" => return "ui",
        "compare_winner_follow_up" => return "compare_winner_follow_up",
        "conflict_resolution" => return "conflict_resolution",
        _ => {}
    }

    let has_ci_path = evidence_digest.changed_files.iter().any(|path| {
        path.starts_with(".github/")
            || path.ends_with(".yml")
            || path.ends_with(".yaml")
            || path == "package.json"
            || path == "package-lock.json"
    });
    if has_ci_path {
        return "ci";
    }
    let next_action = format!(
        "{} {}",
        evidence_digest.next_action, run.experiment_packet.next_action
    )
    .to_ascii_lowercase();
    if matches!(run.review_state.as_str(), "PENDING" | "FAIL" | "FAILED")
        || next_action.contains("review")
    {
        return "review";
    }
    let has_ui_path = evidence_digest.changed_files.iter().any(|path| {
        path.ends_with(".css")
            || path.ends_with(".tsx")
            || path.ends_with(".jsx")
            || path.ends_with(".html")
            || path.contains("ui")
            || path.contains("desktop")
            || path.contains("viewport")
    });
    if has_ui_path {
        return "ui";
    }
    match fallback {
        "ci" => "ci",
        "review" => "review",
        "ui" => "ui",
        "compare_winner_follow_up" => "compare_winner_follow_up",
        "conflict_resolution" => "conflict_resolution",
        _ => "bugfix",
    }
}

fn playbook_required_evidence(flow: &str) -> Vec<&'static str> {
    match flow {
        "ci" => vec!["workflow_status", "build_log", "rerun_evidence"],
        "review" => vec!["findings", "review_decision", "evidence_refs"],
        "ui" => vec![
            "screenshot_or_manual_check",
            "interaction_check",
            "viewport_check",
        ],
        "compare_winner_follow_up" => {
            vec!["winning_run", "comparison_evidence", "promotion_candidate"]
        }
        "conflict_resolution" => vec!["overlap_paths", "reconcile_consult", "human_decision"],
        _ => vec!["reproduction", "fix", "regression_test"],
    }
}

fn playbook_template_contract(
    run: &crate::ledger::LedgerExplainRun,
    evidence_digest: &crate::ledger::LedgerDigestItem,
    flow: &str,
    source: &str,
    diversity_runs: &[&crate::ledger::LedgerExplainRun],
) -> Value {
    let resolved_flow = run_playbook_flow(run, evidence_digest, flow);
    let diversity_policy = diversity_policy_contract(diversity_runs);
    json!({
        "contract_version": 1,
        "packet_type": "playbook_template_contract",
        "source": source,
        "source_run_id": run.run_id,
        "flow": resolved_flow,
        "template_refs": [format!("playbook:{resolved_flow}")],
        "role_policy": {
            "builder": "implement smallest verified change",
            "reviewer": "return findings first with evidence references",
            "tester": "verify unit integration cli and contract coverage",
        },
        "required_evidence": playbook_required_evidence(resolved_flow),
        "team_memory_refs": crate::ledger::value_string_list(&run.team_memory, "team_memory_refs"),
        "handoff_refs": run.handoff_refs,
        "execution_backend": "operator_managed",
        "backend_profile_required": false,
        "approval_defaults": managed_follow_up_approval_defaults(),
        "diversity_policy": diversity_policy,
        "freeform_body_stored": false,
        "private_guidance_stored": false,
        "local_reference_paths_stored": false,
    })
}

fn managed_follow_up_approval_defaults() -> Value {
    json!({
        "contract_version": 1,
        "packet_type": "managed_follow_up_approval_defaults",
        "review_required": true,
        "human_approval_required": true,
        "auto_merge_allowed": false,
        "merge_requires_human": true,
        "operator_controls_merge": true,
    })
}

fn compare_winner_follow_up_run_contract(
    run: &crate::ledger::LedgerExplainRun,
    evidence_digest: &crate::ledger::LedgerDigestItem,
    playbook_template: &Value,
) -> Value {
    let mut source_evidence_refs = Vec::new();
    if !run.experiment_packet.observation_pack_ref.trim().is_empty() {
        source_evidence_refs.push(run.experiment_packet.observation_pack_ref.clone());
    }
    if !run.experiment_packet.consultation_ref.trim().is_empty() {
        source_evidence_refs.push(run.experiment_packet.consultation_ref.clone());
    }

    json!({
        "contract_version": 1,
        "packet_type": "managed_follow_up_run_contract",
        "source": "compare_runs",
        "source_run_id": run.run_id,
        "task_id": run.task_id,
        "flow": "compare_winner_follow_up",
        "run_mode": "operator_managed",
        "playbook_template_ref": "playbook:compare_winner_follow_up",
        "required_evidence": playbook_template["required_evidence"],
        "source_evidence_refs": source_evidence_refs,
        "changed_files": public_changed_files(&evidence_digest.changed_files),
        "team_memory_refs": playbook_template["team_memory_refs"],
        "approval_defaults": managed_follow_up_approval_defaults(),
        "review_required": true,
        "human_approval_required": true,
        "auto_merge_allowed": false,
        "merge_requires_human": true,
        "operator_controls_merge": true,
        "next_action": "start managed follow-up run and request human review before merge",
        "local_reference_paths_stored": false,
        "freeform_body_stored": false,
        "private_guidance_stored": false,
    })
}

fn compare_reconcile_playbook_template(
    left_run: &crate::ledger::LedgerExplainRun,
    right_run: &crate::ledger::LedgerExplainRun,
) -> Value {
    let diversity_policy = diversity_policy_contract(&[left_run, right_run]);
    json!({
        "contract_version": 1,
        "packet_type": "playbook_template_contract",
        "source": "compare_runs",
        "source_run_id": "",
        "flow": "conflict_resolution",
        "template_refs": ["playbook:conflict_resolution"],
        "role_policy": {
            "builder": "prepare minimal conflict evidence",
            "reviewer": "compare behavior and safety risks",
            "tester": "verify both branches before choosing",
        },
        "required_evidence": playbook_required_evidence("conflict_resolution"),
        "compare_run_ids": [left_run.run_id, right_run.run_id],
        "team_memory_refs": compare_team_memory_refs(left_run, right_run),
        "execution_backend": "operator_managed",
        "backend_profile_required": false,
        "approval_defaults": managed_follow_up_approval_defaults(),
        "diversity_policy": diversity_policy,
        "freeform_body_stored": false,
        "private_guidance_stored": false,
        "local_reference_paths_stored": false,
    })
}

fn diversity_policy_contract(runs: &[&crate::ledger::LedgerExplainRun]) -> Value {
    let provider_keys: Vec<String> = runs
        .iter()
        .filter_map(|run| {
            let (provider, _) = split_provider_target(&run.provider_target);
            (!provider.trim().is_empty()).then_some(provider)
        })
        .collect();
    let model_keys: Vec<String> = runs
        .iter()
        .filter_map(|run| {
            let (_, model) = split_provider_target(&run.provider_target);
            (!model.trim().is_empty()).then_some(model)
        })
        .collect();
    let provider_metadata_partial = provider_keys.len() != runs.len();
    let model_metadata_partial = model_keys.len() != runs.len();
    let harness_keys: Vec<String> = runs
        .iter()
        .map(|_| "operator_managed".to_string())
        .collect();

    json!({
        "contract_version": 1,
        "packet_type": "diversity_policy_contract",
        "scope": if runs.len() > 1 { "run_set" } else { "single_run" },
        "metadata_policy": {
            "stored_metadata": ["fixed_categories", "count_buckets", "capability_flags"],
            "provider_neutral": true,
            "raw_provider_ids_stored": false,
            "raw_model_names_stored": false,
            "raw_model_prompts_stored": false,
            "private_prompt_bodies_stored": false,
            "local_reference_paths_stored": false,
            "external_repository_names_stored": false,
        },
        "fixed_categories": {
            "mix": [
                "unknown",
                "single_provider",
                "mixed_provider",
                "single_model",
                "mixed_model",
                "single_harness",
                "mixed_harness",
            ],
            "count_bucket": ["none", "one", "two_or_more", "unknown"],
            "harness": ["operator_managed"],
        },
        "projection": {
            "run_count_bucket": count_bucket(runs.len()),
            "provider_mix": mix_category(&provider_keys, "provider", provider_metadata_partial),
            "model_mix": mix_category(&model_keys, "model", model_metadata_partial),
            "harness_mix": mix_category(&harness_keys, "harness", false),
            "provider_count_bucket": unique_count_bucket(&provider_keys, provider_metadata_partial),
            "model_count_bucket": unique_count_bucket(&model_keys, model_metadata_partial),
            "harness_count_bucket": unique_count_bucket(&harness_keys, false),
        },
    })
}

fn mix_category(values: &[String], subject: &str, metadata_partial: bool) -> String {
    if metadata_partial {
        return "unknown".to_string();
    }
    match unique_normalized_count(values) {
        0 => "unknown".to_string(),
        1 => format!("single_{subject}"),
        _ => format!("mixed_{subject}"),
    }
}

fn unique_count_bucket(values: &[String], metadata_partial: bool) -> &'static str {
    if metadata_partial {
        return "unknown";
    }
    count_bucket(unique_normalized_count(values))
}

fn count_bucket(count: usize) -> &'static str {
    match count {
        0 => "none",
        1 => "one",
        _ => "two_or_more",
    }
}

fn unique_normalized_count(values: &[String]) -> usize {
    let mut unique = Vec::new();
    for value in values {
        let normalized = value.trim().to_ascii_lowercase();
        if !normalized.is_empty() && !unique.contains(&normalized) {
            unique.push(normalized);
        }
    }
    unique.len()
}

fn compare_team_memory_refs(
    left_run: &crate::ledger::LedgerExplainRun,
    right_run: &crate::ledger::LedgerExplainRun,
) -> Vec<String> {
    let mut refs = crate::ledger::value_string_list(&left_run.team_memory, "team_memory_refs");
    for item in crate::ledger::value_string_list(&right_run.team_memory, "team_memory_refs") {
        if !refs.iter().any(|existing| existing == &item) {
            refs.push(item);
        }
    }
    refs.sort();
    refs
}

struct WrittenArtifact {
    path: String,
    reference: String,
}

fn promote_tactic_candidate(
    projection: &crate::ledger::LedgerExplainProjection,
    consultation_packet: &Value,
    options: &PromoteTacticOptions,
) -> Value {
    let run = &projection.run;
    let experiment = &run.experiment_packet;
    let recommendation = json_string_field(consultation_packet, "recommendation");
    let title = if !options.title.trim().is_empty() {
        options.title.clone()
    } else if !recommendation.trim().is_empty() {
        recommendation.clone()
    } else if !experiment.result.trim().is_empty() {
        experiment.result.clone()
    } else if !run.task.trim().is_empty() {
        run.task.clone()
    } else {
        format!("Tactic from {}", run.run_id)
    };
    let summary = if !recommendation.trim().is_empty() {
        recommendation
    } else {
        experiment.result.clone()
    };
    let playbook_flow = if options.kind == "verification" {
        "ci"
    } else {
        ""
    };

    json!({
        "run_id": run.run_id,
        "task_id": run.task_id,
        "pane_id": run.primary_pane_id,
        "slot": experiment.slot,
        "kind": options.kind,
        "title": title,
        "summary": summary,
        "hypothesis": experiment.hypothesis,
        "next_action": projection.evidence_digest.next_action,
        "confidence": experiment.confidence,
        "branch": run.branch,
        "head_sha": run.head_sha,
        "worktree": experiment.worktree,
        "env_fingerprint": experiment.env_fingerprint,
        "command_hash": experiment.command_hash,
        "changed_files": projection.evidence_digest.changed_files,
        "observation_pack_ref": experiment.observation_pack_ref,
        "consultation_ref": experiment.consultation_ref,
        "verification_result": run.verification_result,
        "security_verdict": run.security_verdict,
        "playbook_template": playbook_template_contract(
            run,
            &projection.evidence_digest,
            playbook_flow,
            "promote_tactic",
            &[run],
        ),
        "action_item_count": run.action_items.len(),
        "action_item_kinds": action_item_kinds(&run.action_items),
        "reuse_conditions": reuse_conditions(run),
        "packet_type": "playbook_candidate",
        "generated_at": generated_at(),
    })
}

fn action_item_kinds(items: &[crate::ledger::LedgerExplainActionItem]) -> Vec<String> {
    let mut values = Vec::new();
    for item in items {
        if !item.kind.trim().is_empty() && !values.contains(&item.kind) {
            values.push(item.kind.clone());
        }
    }
    values
}

fn reuse_conditions(run: &crate::ledger::LedgerExplainRun) -> Vec<String> {
    let mut values = Vec::new();
    if !run.branch.trim().is_empty() {
        values.push(format!("branch={}", run.branch));
    }
    if !run.experiment_packet.env_fingerprint.trim().is_empty() {
        values.push(format!(
            "env_fingerprint={}",
            run.experiment_packet.env_fingerprint
        ));
    }
    if !run.experiment_packet.command_hash.trim().is_empty() {
        values.push(format!(
            "command_hash={}",
            run.experiment_packet.command_hash
        ));
    }
    values
}

fn write_playbook_candidate(project_dir: &Path, candidate: &Value) -> io::Result<WrittenArtifact> {
    let dir = project_dir.join(".winsmux").join("playbook-candidates");
    fs::create_dir_all(&dir)?;
    let file_name = format!("playbook-candidate-{}.json", unique_artifact_id());
    let path = dir.join(file_name);
    let content = serde_json::to_string_pretty(candidate).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize playbook candidate: {err}"),
        )
    })?;
    write_text_file_with_lock(&path, &content)?;
    Ok(WrittenArtifact {
        reference: artifact_reference(project_dir, &path),
        path: path.display().to_string(),
    })
}

fn consultation_result_packet(
    context: &ConsultationContext,
    options: &ConsultResultOptions,
    timestamp: &str,
) -> Value {
    let mut packet = Map::new();
    let (cost_unit_ref, cost_unit) =
        consultation_governance_cost_unit(context, &options.mode, &options.target_slot);
    let has_existing_cost_unit = governance_cost_unit_exists(&options.project_dir, &cost_unit_ref);
    packet.insert("packet_type".to_string(), json!("consultation_packet"));
    packet.insert("generated_at".to_string(), json!(timestamp));
    packet.insert("run_id".to_string(), json!(context.run_id));
    packet.insert("task_id".to_string(), json!(context.task_id));
    packet.insert("pane_id".to_string(), json!(context.pane_id));
    packet.insert("slot".to_string(), json!(context.slot));
    packet.insert("kind".to_string(), json!("consult_result"));
    packet.insert("mode".to_string(), json!(options.mode));
    packet.insert("target_slot".to_string(), json!(options.target_slot));
    packet.insert("branch".to_string(), json!(context.branch));
    packet.insert("head_sha".to_string(), json!(context.head_sha));
    packet.insert("worktree".to_string(), json!(context.worktree));
    packet.insert("recommendation".to_string(), json!(options.message));
    packet.insert(
        "confidence".to_string(),
        json!(options.confidence.unwrap_or_default()),
    );
    packet.insert("next_test".to_string(), json!(options.next_test));
    packet.insert("risks".to_string(), json!(options.risks));
    packet.insert("cost_unit_refs".to_string(), json!([cost_unit_ref]));
    if !has_existing_cost_unit {
        packet.insert("governance_cost_units".to_string(), json!([cost_unit]));
    }
    Value::Object(packet)
}

fn consultation_request_packet(
    context: &ConsultationContext,
    options: &ConsultRequestOptions,
    timestamp: &str,
) -> Value {
    let mut packet = Map::new();
    let (_, cost_unit) =
        consultation_governance_cost_unit(context, &options.mode, &options.target_slot);
    packet.insert("packet_type".to_string(), json!("consultation_packet"));
    packet.insert("generated_at".to_string(), json!(timestamp));
    packet.insert("run_id".to_string(), json!(context.run_id));
    packet.insert("task_id".to_string(), json!(context.task_id));
    packet.insert("pane_id".to_string(), json!(context.pane_id));
    packet.insert("slot".to_string(), json!(context.slot));
    packet.insert("kind".to_string(), json!("consult_request"));
    packet.insert("mode".to_string(), json!(options.mode));
    packet.insert("target_slot".to_string(), json!(options.target_slot));
    packet.insert("branch".to_string(), json!(context.branch));
    packet.insert("head_sha".to_string(), json!(context.head_sha));
    packet.insert("worktree".to_string(), json!(context.worktree));
    packet.insert("request".to_string(), json!(options.message));
    packet.insert("governance_cost_units".to_string(), json!([cost_unit]));
    Value::Object(packet)
}

fn consultation_error_packet(
    context: &ConsultationContext,
    options: &ConsultRequestOptions,
    timestamp: &str,
) -> Value {
    let mut packet = Map::new();
    let (cost_unit_ref, cost_unit) =
        consultation_governance_cost_unit(context, &options.mode, &options.target_slot);
    let has_existing_cost_unit = governance_cost_unit_exists(&options.project_dir, &cost_unit_ref);
    packet.insert("packet_type".to_string(), json!("consultation_packet"));
    packet.insert("generated_at".to_string(), json!(timestamp));
    packet.insert("run_id".to_string(), json!(context.run_id));
    packet.insert("task_id".to_string(), json!(context.task_id));
    packet.insert("pane_id".to_string(), json!(context.pane_id));
    packet.insert("slot".to_string(), json!(context.slot));
    packet.insert("kind".to_string(), json!("consult_error"));
    packet.insert("mode".to_string(), json!(options.mode));
    packet.insert("target_slot".to_string(), json!(options.target_slot));
    packet.insert("branch".to_string(), json!(context.branch));
    packet.insert("head_sha".to_string(), json!(context.head_sha));
    packet.insert("worktree".to_string(), json!(context.worktree));
    packet.insert("error".to_string(), json!(options.message));
    packet.insert("cost_unit_refs".to_string(), json!([cost_unit_ref]));
    if !has_existing_cost_unit {
        packet.insert("governance_cost_units".to_string(), json!([cost_unit]));
    }
    Value::Object(packet)
}

fn consultation_governance_cost_unit_refs(
    context: &ConsultationContext,
    mode: &str,
    target_slot: &str,
) -> Vec<String> {
    let (unit_id, _) = consultation_governance_cost_unit(context, mode, target_slot);
    vec![unit_id]
}

fn consultation_governance_cost_unit(
    context: &ConsultationContext,
    mode: &str,
    target_slot: &str,
) -> (String, Value) {
    let normalized_mode = mode.trim().to_ascii_lowercase();
    let stage = format!("consult_{normalized_mode}");
    let effective_target = if target_slot.trim().is_empty() {
        context.slot.trim()
    } else {
        target_slot.trim()
    };
    let parts = [
        "governance",
        "consult",
        normalized_mode.as_str(),
        stage.as_str(),
        context.task_id.as_str(),
        context.run_id.as_str(),
        effective_target,
        "0",
    ];
    let unit_id = parts
        .iter()
        .filter_map(|part| {
            let trimmed = part.trim();
            (!trimmed.is_empty()).then_some(trimmed)
        })
        .collect::<Vec<_>>()
        .join(":");

    (
        unit_id.clone(),
        json!({
            "unit_id": unit_id,
            "unit_type": "governance_invocation",
            "kind": "consult",
            "mode": normalized_mode,
            "stage": stage,
            "task": context.task_id,
            "run_id": context.run_id,
            "role": context.role,
            "target": effective_target,
            "attempt": 0,
            "source": "consult-command",
            "quantity": 1,
        }),
    )
}

fn governance_cost_unit_exists(project_dir: &Path, unit_id: &str) -> bool {
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    let Ok(raw) = fs::read_to_string(events_path) else {
        return false;
    };
    raw.lines()
        .any(|line| line.contains("\"governance_cost_units\"") && line.contains(unit_id))
}

fn consultation_result_event(
    context: &ConsultationContext,
    options: &ConsultResultOptions,
    consultation_ref: &str,
    timestamp: &str,
) -> Value {
    let mut data = Map::new();
    data.insert("task_id".to_string(), json!(context.task_id));
    data.insert("run_id".to_string(), json!(context.run_id));
    data.insert("slot".to_string(), json!(context.slot));
    data.insert("branch".to_string(), json!(context.branch));
    data.insert("worktree".to_string(), json!(context.worktree));
    data.insert("consultation_ref".to_string(), json!(consultation_ref));
    let (cost_unit_ref, cost_unit) =
        consultation_governance_cost_unit(context, &options.mode, &options.target_slot);
    let has_existing_cost_unit = governance_cost_unit_exists(&options.project_dir, &cost_unit_ref);
    data.insert("cost_unit_refs".to_string(), json!([cost_unit_ref]));
    if !has_existing_cost_unit {
        data.insert("governance_cost_units".to_string(), json!([cost_unit]));
    }
    data.insert("result".to_string(), json!(options.message));
    if let Some(confidence) = options.confidence {
        data.insert("confidence".to_string(), json!(confidence));
    }
    if !options.next_test.trim().is_empty() {
        data.insert("next_action".to_string(), json!(options.next_test));
    }

    json!({
        "timestamp": timestamp,
        "session": context.session_name,
        "event": "pane.consult_result",
        "message": options.message,
        "label": context.label,
        "pane_id": context.pane_id,
        "role": context.role,
        "branch": context.branch,
        "head_sha": context.head_sha,
        "data": Value::Object(data),
    })
}

fn consultation_request_event(
    context: &ConsultationContext,
    options: &ConsultRequestOptions,
    consultation_ref: &str,
    timestamp: &str,
) -> Value {
    let mut data = Map::new();
    data.insert("task_id".to_string(), json!(context.task_id));
    data.insert("run_id".to_string(), json!(context.run_id));
    data.insert("slot".to_string(), json!(context.slot));
    data.insert("branch".to_string(), json!(context.branch));
    data.insert("worktree".to_string(), json!(context.worktree));
    data.insert("consultation_ref".to_string(), json!(consultation_ref));
    let (_, cost_unit) =
        consultation_governance_cost_unit(context, &options.mode, &options.target_slot);
    data.insert("governance_cost_units".to_string(), json!([cost_unit]));

    json!({
        "timestamp": timestamp,
        "session": context.session_name,
        "event": "pane.consult_request",
        "message": options.message,
        "label": context.label,
        "pane_id": context.pane_id,
        "role": context.role,
        "branch": context.branch,
        "head_sha": context.head_sha,
        "data": Value::Object(data),
    })
}

fn consultation_error_event(
    context: &ConsultationContext,
    options: &ConsultRequestOptions,
    consultation_ref: &str,
    timestamp: &str,
) -> Value {
    let mut data = Map::new();
    data.insert("task_id".to_string(), json!(context.task_id));
    data.insert("run_id".to_string(), json!(context.run_id));
    data.insert("slot".to_string(), json!(context.slot));
    data.insert("branch".to_string(), json!(context.branch));
    data.insert("worktree".to_string(), json!(context.worktree));
    data.insert("consultation_ref".to_string(), json!(consultation_ref));
    let (cost_unit_ref, cost_unit) =
        consultation_governance_cost_unit(context, &options.mode, &options.target_slot);
    let has_existing_cost_unit = governance_cost_unit_exists(&options.project_dir, &cost_unit_ref);
    data.insert("cost_unit_refs".to_string(), json!([cost_unit_ref]));
    if !has_existing_cost_unit {
        data.insert("governance_cost_units".to_string(), json!([cost_unit]));
    }

    json!({
        "timestamp": timestamp,
        "session": context.session_name,
        "event": "pane.consult_error",
        "message": options.message,
        "label": context.label,
        "pane_id": context.pane_id,
        "role": context.role,
        "branch": context.branch,
        "head_sha": context.head_sha,
        "data": Value::Object(data),
    })
}

fn write_consultation_packet(
    project_dir: &Path,
    file_prefix: &str,
    packet: &Value,
) -> io::Result<WrittenArtifact> {
    let dir = project_dir.join(".winsmux").join("consultations");
    fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{}-{}.json", file_prefix, unique_artifact_id()));
    let content = serde_json::to_string_pretty(packet).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize consultation packet: {err}"),
        )
    })?;
    write_text_file_with_lock(&path, &format!("{content}\n"))?;
    Ok(WrittenArtifact {
        reference: artifact_reference(project_dir, &path),
        path: path.display().to_string(),
    })
}

fn append_event_record(project_dir: &Path, event: &Value) -> io::Result<()> {
    let path = project_dir.join(".winsmux").join("events.jsonl");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    with_file_lock(&path, || {
        let mut content = if path.exists() {
            fs::read_to_string(&path)?
        } else {
            String::new()
        };
        let event = attach_evidence_chain_to_event(&content, event).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("failed to attach evidence chain: {err}"),
            )
        })?;
        let line = serde_json::to_string(&event).map_err(|err| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("failed to serialize event record: {err}"),
            )
        })?;
        if !content.is_empty() && !content.ends_with('\n') {
            content.push('\n');
        }
        content.push_str(&line);
        content.push('\n');
        write_text_file_locked(&path, &content)
    })
}

fn mark_current_review_pane_last_event(
    project_dir: &Path,
    last_event: &str,
    timestamp: &str,
) -> io::Result<bool> {
    let pane_id = env::var("WINSMUX_PANE_ID")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WINSMUX_PANE_ID not set"))?;
    let manifest_path = project_dir.join(".winsmux").join("manifest.yaml");
    let raw = fs::read_to_string(&manifest_path)?;
    let mut manifest = serde_yaml::from_str::<serde_yaml::Value>(&raw).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid manifest: {}: {err}", manifest_path.display()),
        )
    })?;
    let updated = update_manifest_review_capable_pane_fields(
        &mut manifest,
        &pane_id,
        &[("last_event", last_event), ("last_event_at", timestamp)],
    );
    if !updated {
        return Ok(false);
    }
    let content = serde_yaml::to_string(&manifest).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize manifest: {err}"),
        )
    })?;
    write_text_file_with_lock(&manifest_path, &content)?;
    Ok(true)
}

fn update_manifest_review_capable_pane_fields(
    manifest: &mut serde_yaml::Value,
    pane_id: &str,
    fields: &[(&str, &str)],
) -> bool {
    let Some(panes) = manifest.get_mut("panes") else {
        return false;
    };

    match panes {
        serde_yaml::Value::Mapping(map) => map.iter_mut().any(|(key, pane)| {
            let label = key.as_str().unwrap_or_default();
            update_manifest_pane_if_matches(label, pane, pane_id, fields)
        }),
        serde_yaml::Value::Sequence(items) => items
            .iter_mut()
            .any(|pane| update_manifest_pane_if_matches("", pane, pane_id, fields)),
        _ => false,
    }
}

fn artifact_reference(project_dir: &Path, path: &Path) -> String {
    path.strip_prefix(project_dir)
        .ok()
        .map(|relative| relative.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|| path.display().to_string().replace('\\', "/"))
}

fn unique_artifact_id() -> String {
    let counter = ATOMIC_WRITE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("{nanos:x}{:08x}{counter:08x}", std::process::id())
}

fn json_string_field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn json_string_or_field(value: &Value, key: &str) -> String {
    value
        .as_str()
        .map(str::to_string)
        .unwrap_or_else(|| json_string_field(value, key))
}

fn round_half_to_even(value: f64, digits: i32) -> f64 {
    let factor = 10_f64.powi(digits);
    let scaled = value * factor;
    let truncated = scaled.trunc();
    let fraction = scaled - truncated;
    let rounded = if fraction.abs() == 0.5 {
        if (truncated as i64).abs() % 2 == 0 {
            truncated
        } else {
            truncated + fraction.signum()
        }
    } else {
        scaled.round()
    };
    rounded / factor
}

fn compare_display_value(value: &Value) -> String {
    if let Some(values) = value.as_array() {
        return values
            .iter()
            .map(compare_display_value)
            .collect::<Vec<_>>()
            .join(", ");
    }
    if let Some(text) = value.as_str() {
        return text.to_string();
    }
    value.to_string()
}

fn desktop_summary_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> io::Result<Value> {
    let board = desktop_board_payload(snapshot, project_dir);
    let inbox = enveloped_payload(project_dir, snapshot.inbox_projection())?;
    let digest = snapshot.digest_projection();
    let run_projections: Vec<_> = digest
        .items
        .iter()
        .map(|item| desktop_run_projection(snapshot, item))
        .collect();
    let digest = enveloped_payload(project_dir, digest)?;

    Ok(json!({
        "generated_at": generated_at(),
        "project_dir": project_dir_string(project_dir),
        "board": board,
        "inbox": inbox,
        "digest": digest,
        "run_projections": run_projections,
    }))
}

fn desktop_board_payload(snapshot: &LedgerSnapshot, project_dir: &Path) -> Value {
    let mut panes = snapshot.pane_read_models();
    panes.sort_by(|left, right| left.label.cmp(&right.label));
    let panes: Vec<_> = panes
        .into_iter()
        .map(|pane| {
            json!({
                "label": pane.label,
                "role": pane.role,
                "pane_id": pane.pane_id,
                "state": pane.state,
                "tokens_remaining": pane.tokens_remaining,
                "task_id": pane.task_id,
                "task": pane.task,
                "task_state": pane.task_state,
                "task_owner": pane.task_owner,
                "review_state": pane.review_state,
                "branch": pane.branch,
                "worktree": pane.worktree,
                "head_sha": pane.head_sha,
                "changed_file_count": pane.changed_file_count,
                "changed_files": pane.changed_files,
                "last_event": pane.last_event,
                "last_event_at": pane.last_event_at,
                "parent_run_id": pane.parent_run_id,
                "goal": pane.goal,
                "task_type": pane.task_type,
                "priority": pane.priority,
                "blocking": pane.blocking,
                "write_scope": pane.write_scope,
                "read_scope": pane.read_scope,
                "constraints": pane.constraints,
                "expected_output": pane.expected_output,
                "verification_plan": pane.verification_plan,
                "review_required": pane.review_required,
                "provider_target": pane.provider_target,
                "agent_role": pane.agent_role,
                "timeout_policy": pane.timeout_policy,
                "handoff_refs": pane.handoff_refs,
                "security_policy": pane.security_policy,
            })
        })
        .collect();

    json!({
        "generated_at": generated_at(),
        "project_dir": project_dir_string(project_dir),
        "summary": snapshot.board_summary(),
        "panes": panes,
    })
}

fn print_board_table(payload: &Value) -> io::Result<()> {
    let panes = payload
        .get("panes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if panes.is_empty() {
        println!("(no panes)");
        return Ok(());
    }

    let columns = [
        ("Label", 14usize),
        ("Role", 10usize),
        ("PaneId", 8usize),
        ("State", 12usize),
        ("Tokens", 8usize),
        ("TaskState", 14usize),
        ("Review", 10usize),
        ("Changed", 8usize),
        ("Branch", 24usize),
        ("Head", 8usize),
    ];
    println!("{}", text_table_row(&columns));
    println!("{}", text_table_separator(&columns));
    for pane in panes {
        let changed = pane
            .get("changed_file_count")
            .and_then(Value::as_u64)
            .map(|value| value.to_string())
            .unwrap_or_default();
        let values = [
            json_string_field(&pane, "label"),
            json_string_field(&pane, "role"),
            json_string_field(&pane, "pane_id"),
            json_string_field(&pane, "state"),
            json_string_field(&pane, "tokens_remaining"),
            json_string_field(&pane, "task_state"),
            json_string_field(&pane, "review_state"),
            changed,
            json_string_field(&pane, "branch"),
            short_head_sha(&json_string_field(&pane, "head_sha")),
        ];
        println!("{}", text_table_value_row(&values, &columns));
    }
    Ok(())
}

fn print_inbox_table(payload: &Value) -> io::Result<()> {
    let items = payload
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if items.is_empty() {
        println!("(no inbox items)");
        return Ok(());
    }

    let columns = [
        ("Kind", 16usize),
        ("Label", 14usize),
        ("PaneId", 8usize),
        ("Role", 10usize),
        ("TaskState", 14usize),
        ("Review", 10usize),
        ("Branch", 24usize),
        ("Message", 40usize),
    ];
    println!("{}", text_table_row(&columns));
    println!("{}", text_table_separator(&columns));
    for item in items {
        let values = [
            json_string_field(&item, "kind"),
            json_string_field(&item, "label"),
            json_string_field(&item, "pane_id"),
            json_string_field(&item, "role"),
            json_string_field(&item, "task_state"),
            json_string_field(&item, "review_state"),
            json_string_field(&item, "branch"),
            json_string_field(&item, "message"),
        ];
        println!("{}", text_table_value_row(&values, &columns));
    }
    Ok(())
}

fn print_digest_text(payload: &Value) -> io::Result<()> {
    let items = payload
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if items.is_empty() {
        println!("(no digest items)");
        return Ok(());
    }

    for item in items {
        println!("Run: {}", json_string_field(&item, "run_id"));
        println!(
            "Primary: {} ({})",
            json_string_field(&item, "label"),
            json_string_field(&item, "pane_id")
        );
        let task = json_string_field(&item, "task");
        if !task.trim().is_empty() {
            println!("Task: {task}");
        }
        println!(
            "State: {} / {}",
            json_string_field(&item, "task_state"),
            json_string_field(&item, "review_state")
        );
        println!("Next: {}", json_string_field(&item, "next_action"));
        let branch = json_string_field(&item, "branch");
        if !branch.trim().is_empty() {
            println!(
                "Git: {} @ {}",
                branch,
                json_string_field(&item, "head_short")
            );
        }

        let changed_file_count = item
            .get("changed_file_count")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if changed_file_count > 0 {
            println!("Changed files ({changed_file_count}):");
            for changed_file in item
                .get("changed_files")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                println!("- {changed_file}");
            }
        } else {
            println!("Changed files: (none)");
        }
        println!();
    }

    Ok(())
}

fn print_runs_table(payload: &Value) -> io::Result<()> {
    let runs = payload
        .get("runs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if runs.is_empty() {
        println!("(no runs)");
        return Ok(());
    }

    let columns = [
        ("RunId", 18usize),
        ("Label", 14usize),
        ("Task", 30usize),
        ("TaskState", 14usize),
        ("Review", 10usize),
        ("State", 12usize),
        ("Branch", 24usize),
        ("Head", 8usize),
        ("ActionItems", 11usize),
    ];
    println!("{}", text_table_row(&columns));
    println!("{}", text_table_separator(&columns));
    for run in runs {
        let action_items = run
            .get("action_items")
            .and_then(Value::as_array)
            .map(|items| items.len().to_string())
            .unwrap_or_else(|| "0".to_string());
        let values = [
            json_string_field(&run, "run_id"),
            json_string_field(&run, "primary_label"),
            json_string_field(&run, "task"),
            json_string_field(&run, "task_state"),
            json_string_field(&run, "review_state"),
            json_string_field(&run, "state"),
            json_string_field(&run, "branch"),
            short_head_sha(&json_string_field(&run, "head_sha")),
            action_items,
        ];
        println!("{}", text_table_value_row(&values, &columns));
    }
    Ok(())
}

fn print_explain_text(payload: &Value) -> io::Result<()> {
    let null = Value::Null;
    let run = payload.get("run").unwrap_or(&null);
    let explanation = payload.get("explanation").unwrap_or(&null);
    let evidence_digest = payload.get("evidence_digest").unwrap_or(&null);

    println!("Run: {}", json_string_field(run, "run_id"));
    println!("Task: {}", json_string_field(explanation, "summary"));
    println!(
        "Primary: {} ({})",
        json_string_field(run, "primary_label"),
        json_string_field(run, "primary_pane_id")
    );
    println!(
        "State: {} / {} / {}",
        json_string_field(run, "state"),
        json_string_field(run, "task_state"),
        json_string_field(run, "review_state")
    );
    println!(
        "Next: {}",
        json_string_field(evidence_digest, "next_action")
    );

    let branch = json_string_field(run, "branch");
    if !branch.trim().is_empty() {
        println!("Branch: {branch}");
    }
    let head_sha = json_string_field(run, "head_sha");
    if !head_sha.trim().is_empty() {
        println!("Head: {head_sha}");
    }

    let changed_file_count = evidence_digest
        .get("changed_file_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    if changed_file_count > 0 {
        println!("Changed files:");
        for changed_file in evidence_digest
            .get("changed_files")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            println!("- {changed_file}");
        }
    }

    let reasons: Vec<_> = explanation
        .get("reasons")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    if !reasons.is_empty() {
        println!("Reasons:");
        for reason in reasons {
            println!("- {reason}");
        }
    }

    let recent_events: Vec<_> = payload
        .get("recent_events")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(10)
        .collect();
    if !recent_events.is_empty() {
        println!("Recent events:");
        for event_record in recent_events {
            println!(
                "- [{}] {} {}: {}",
                json_string_field(event_record, "timestamp"),
                json_string_field(event_record, "event"),
                json_string_field(event_record, "label"),
                json_string_field(event_record, "message")
            );
        }
    }

    Ok(())
}

fn print_explain_follow_header(payload: &Value) -> io::Result<()> {
    let null = Value::Null;
    let run = payload.get("run").unwrap_or(&null);
    let explanation = payload.get("explanation").unwrap_or(&null);

    println!("Run: {}", json_string_field(run, "run_id"));
    println!("Task: {}", json_string_field(explanation, "summary"));
    println!(
        "State: {} / {} / {}",
        json_string_field(run, "state"),
        json_string_field(run, "task_state"),
        json_string_field(run, "review_state")
    );
    let branch = json_string_field(run, "branch");
    if !branch.trim().is_empty() {
        println!("Branch: {branch}");
    }
    let head_sha = json_string_field(run, "head_sha");
    if !head_sha.trim().is_empty() {
        println!("Head: {head_sha}");
    }
    io::stdout().flush()
}

fn stream_explain_follow(project_dir: &Path, payload: Value, json_output: bool) -> io::Result<()> {
    let run = payload.get("run").cloned().unwrap_or(Value::Null);
    let mut cursor = read_desktop_summary_events_for_stream(project_dir)?.len();
    loop {
        let events = read_desktop_summary_events_for_stream(project_dir)?;
        if events.len() < cursor {
            cursor = 0;
        }
        for event in events.iter().skip(cursor) {
            if !run_matches_event_value(&run, event) {
                continue;
            }
            let item = explain_follow_item(event);
            if json_output {
                write_json(&item)?;
            } else {
                print_explain_follow_item(&item)?;
            }
        }
        cursor = events.len();
        thread::sleep(Duration::from_secs(2));
    }
}

fn print_explain_follow_item(item: &Value) -> io::Result<()> {
    println!(
        "[{}] {} {}: {}",
        json_string_field(item, "timestamp"),
        json_string_field(item, "event"),
        json_string_field(item, "label"),
        json_string_field(item, "message")
    );
    io::stdout().flush()
}

fn explain_follow_item(event: &EventRecord) -> Value {
    let data = event.data.as_object();
    json!({
        "timestamp": event.timestamp.as_str(),
        "event": event.event.as_str(),
        "status": event.status.as_str(),
        "message": event.message.as_str(),
        "label": event.label.as_str(),
        "pane_id": event.pane_id.as_str(),
        "role": event.role.as_str(),
        "task_id": first_non_empty(&event.task_id, &event_data_string(data, "task_id")),
        "branch": first_non_empty(&event.branch, &event_data_string(data, "branch")),
        "head_sha": first_non_empty(&event.head_sha, &event_data_string(data, "head_sha")),
        "source": event.source.as_str(),
        "hypothesis": event_data_string(data, "hypothesis"),
        "test_plan": event_data_string_array(data, "test_plan"),
        "result": event_data_string(data, "result"),
        "confidence": data.and_then(|map| map.get("confidence")).cloned().unwrap_or(Value::Null),
        "next_action": event_data_string(data, "next_action"),
        "observation_pack_ref": event_data_string(data, "observation_pack_ref"),
        "consultation_ref": event_data_string(data, "consultation_ref"),
        "run_id": first_non_empty(&event.run_id, &event_data_string(data, "run_id")),
        "slot": event_data_string(data, "slot"),
        "worktree": event_data_string(data, "worktree"),
        "env_fingerprint": event_data_string(data, "env_fingerprint"),
        "command_hash": event_data_string(data, "command_hash"),
    })
}

fn run_matches_event_value(run: &Value, event: &EventRecord) -> bool {
    let data = event.data.as_object();
    let event_run_id = first_non_empty(&event.run_id, &event_data_string(data, "run_id"));
    if !event_run_id.trim().is_empty() {
        return event_run_id == json_string_field(run, "run_id");
    }

    let event_task_id = first_non_empty(&event.task_id, &event_data_string(data, "task_id"));
    let run_task_id = json_string_field(run, "task_id");
    if !event_task_id.trim().is_empty() && !run_task_id.trim().is_empty() {
        return event_task_id == run_task_id;
    }

    if !event.pane_id.trim().is_empty()
        && json_string_array_contains(run, "pane_ids", &event.pane_id)
    {
        return true;
    }

    if !event.label.trim().is_empty() && json_string_array_contains(run, "labels", &event.label) {
        return true;
    }

    let event_branch = first_non_empty(&event.branch, &event_data_string(data, "branch"));
    if !event_branch.trim().is_empty() && event_branch == json_string_field(run, "branch") {
        return true;
    }

    let event_head_sha = first_non_empty(&event.head_sha, &event_data_string(data, "head_sha"));
    !event_head_sha.trim().is_empty() && event_head_sha == json_string_field(run, "head_sha")
}

fn event_data_string(data: Option<&Map<String, Value>>, key: &str) -> String {
    data.and_then(|map| map.get(key))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn event_data_string_array(data: Option<&Map<String, Value>>, key: &str) -> Vec<String> {
    let Some(value) = data.and_then(|map| map.get(key)) else {
        return Vec::new();
    };

    match value {
        Value::String(text) => trimmed_string_vec(text.split('|')),
        Value::Array(items) => trimmed_string_vec(items.iter().map(value_to_display_string)),
        Value::Null => Vec::new(),
        other => trimmed_string_vec([value_to_display_string(other)]),
    }
}

fn trimmed_string_vec<S: AsRef<str>>(values: impl IntoIterator<Item = S>) -> Vec<String> {
    values
        .into_iter()
        .map(|value| value.as_ref().trim().to_string())
        .filter(|value| !value.is_empty())
        .collect()
}

fn value_to_display_string(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_string)
        .unwrap_or_else(|| value.to_string())
}

fn json_string_array_contains(value: &Value, key: &str, needle: &str) -> bool {
    value
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .any(|item| item == needle)
}

fn text_table_row(columns: &[(&str, usize)]) -> String {
    columns
        .iter()
        .map(|(label, width)| text_table_cell(label, *width))
        .collect::<Vec<_>>()
        .join("  ")
        .trim_end()
        .to_string()
}

fn text_table_separator(columns: &[(&str, usize)]) -> String {
    columns
        .iter()
        .map(|(_, width)| "-".repeat(*width))
        .collect::<Vec<_>>()
        .join("  ")
}

fn text_table_value_row(values: &[String], columns: &[(&str, usize)]) -> String {
    values
        .iter()
        .zip(columns.iter())
        .map(|(value, (_, width))| text_table_cell(value, *width))
        .collect::<Vec<_>>()
        .join("  ")
        .trim_end()
        .to_string()
}

fn text_table_cell(value: &str, width: usize) -> String {
    let mut text: String = value.chars().take(width).collect();
    let count = text.chars().count();
    if count < width {
        text.push_str(&" ".repeat(width - count));
    }
    text
}

fn desktop_run_projection(snapshot: &LedgerSnapshot, item: &LedgerDigestItem) -> Value {
    let explain = snapshot.explain_projection(&item.run_id);
    let run = explain.as_ref().map(|projection| &projection.run);
    let explanation = explain.as_ref().map(|projection| &projection.explanation);
    let evidence_digest = explain
        .as_ref()
        .map(|projection| &projection.evidence_digest);

    let branch = run
        .filter(|run| !run.branch.trim().is_empty())
        .map(|run| run.branch.clone())
        .unwrap_or_else(|| item.branch.clone());
    let run_worktree = run.map(|run| run.worktree.clone()).unwrap_or_default();
    let experiment_worktree = run
        .map(|run| run.experiment_packet.worktree.clone())
        .unwrap_or_default();
    let worktree =
        first_non_empty_owned([run_worktree, experiment_worktree, item.worktree.clone()]);
    let head_sha = run
        .filter(|run| !run.head_sha.trim().is_empty())
        .map(|run| run.head_sha.clone())
        .unwrap_or_else(|| item.head_sha.clone());
    let head_short = if !head_sha.trim().is_empty() {
        short_head_sha(&head_sha)
    } else {
        item.head_short.clone()
    };
    let changed_files = evidence_digest
        .filter(|digest| !digest.changed_files.is_empty())
        .map(|digest| digest.changed_files.clone())
        .unwrap_or_else(|| item.changed_files.clone());
    let summary = explanation
        .filter(|explanation| !explanation.summary.trim().is_empty())
        .map(|explanation| explanation.summary.clone())
        .unwrap_or_else(|| {
            first_non_empty_owned([
                item.task.clone(),
                format!("Projected from {}", item.run_id),
                "Projected run".to_string(),
            ])
        });

    json!({
        "run_id": item.run_id,
        "pane_id": item.pane_id,
        "label": item.label,
        "branch": branch,
        "worktree": worktree,
        "head_sha": head_sha,
        "head_short": head_short,
        "provider_target": item.provider_target,
        "task": item.task,
        "task_state": run
            .filter(|run| !run.task_state.trim().is_empty())
            .map(|run| run.task_state.clone())
            .unwrap_or_else(|| item.task_state.clone()),
        "review_state": run
            .filter(|run| !run.review_state.trim().is_empty())
            .map(|run| run.review_state.clone())
            .unwrap_or_else(|| item.review_state.clone()),
        "verification_outcome": evidence_digest
            .filter(|digest| !digest.verification_outcome.trim().is_empty())
            .map(|digest| digest.verification_outcome.clone())
            .unwrap_or_else(|| item.verification_outcome.clone()),
        "security_blocked": evidence_digest
            .filter(|digest| !digest.security_blocked.trim().is_empty())
            .map(|digest| digest.security_blocked.clone())
            .unwrap_or_else(|| item.security_blocked.clone()),
        "changed_files": changed_files,
        "next_action": explanation
            .filter(|explanation| !explanation.next_action.trim().is_empty())
            .map(|explanation| explanation.next_action.clone())
            .unwrap_or_else(|| item.next_action.clone()),
        "summary": summary,
        "reasons": explanation
            .map(|explanation| explanation.reasons.clone())
            .unwrap_or_default(),
        "hypothesis": item.hypothesis,
        "confidence": item.confidence,
        "observation_pack_ref": item.observation_pack_ref,
        "consultation_ref": item.consultation_ref,
    })
}

fn first_non_empty_owned<const N: usize>(values: [String; N]) -> String {
    values
        .into_iter()
        .find(|value| !value.trim().is_empty())
        .unwrap_or_default()
}

fn short_head_sha(head_sha: &str) -> String {
    if head_sha.chars().count() <= 7 {
        head_sha.to_string()
    } else {
        head_sha.chars().take(7).collect()
    }
}

fn stream_desktop_summary(options: &DesktopSummaryOptions) -> io::Result<()> {
    let mut cursor = read_desktop_summary_events_for_stream(&options.project_dir)?.len();
    loop {
        let events = read_desktop_summary_events_for_stream(&options.project_dir)?;
        if events.len() < cursor {
            cursor = 0;
        }
        for event in events.iter().skip(cursor) {
            let Some(item) = desktop_summary_refresh_item(event) else {
                continue;
            };
            if options.json {
                write_json(&item)?;
            } else {
                println!("{}", desktop_summary_refresh_text(&item));
            }
        }
        cursor = events.len();
        thread::sleep(Duration::from_secs(2));
    }
}

fn read_desktop_summary_events(project_dir: &Path) -> io::Result<Vec<EventRecord>> {
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    if !events_path.exists() {
        return Ok(Vec::new());
    }
    let content = fs::read_to_string(&events_path)?;
    parse_event_jsonl(&content).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to parse desktop-summary events: {err}"),
        )
    })
}

fn read_desktop_summary_events_for_stream(project_dir: &Path) -> io::Result<Vec<EventRecord>> {
    let events_path = project_dir.join(".winsmux").join("events.jsonl");
    if !events_path.exists() {
        return Ok(Vec::new());
    }
    let content = fs::read_to_string(&events_path)?;
    match parse_event_jsonl(&content) {
        Ok(events) => Ok(events),
        Err(err) if !content.ends_with('\n') => {
            let Some(last_newline) = content.rfind('\n') else {
                return Ok(Vec::new());
            };
            parse_event_jsonl(&content[..=last_newline]).map_err(|prefix_err| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!(
                        "failed to parse desktop-summary events before partial tail: {prefix_err}; original error: {err}"
                    ),
                )
            })
        }
        Err(err) => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to parse desktop-summary events: {err}"),
        )),
    }
}

fn desktop_summary_refresh_item(event: &EventRecord) -> Option<Value> {
    let reason = first_non_empty_owned([event.event.clone(), event.status.clone()]);
    if reason.trim().is_empty() {
        return None;
    }

    let mut item = Map::new();
    item.insert("source".to_string(), json!("summary"));
    item.insert("reason".to_string(), json!(reason));
    if !event.timestamp.trim().is_empty() {
        item.insert("timestamp".to_string(), json!(event.timestamp));
    }
    if !event.pane_id.trim().is_empty() {
        item.insert("pane_id".to_string(), json!(event.pane_id));
    }
    let run_id = desktop_summary_refresh_run_id(event);
    if !run_id.trim().is_empty() {
        item.insert("run_id".to_string(), json!(run_id));
    }

    Some(Value::Object(item))
}

fn desktop_summary_refresh_run_id(event: &EventRecord) -> String {
    let run_id = json_field_string(&event.data, "run_id");
    if !run_id.trim().is_empty() {
        return run_id;
    }
    if !event.run_id.trim().is_empty() {
        return event.run_id.clone();
    }
    let task_id = json_field_string(&event.data, "task_id");
    if !task_id.trim().is_empty() {
        return format!("task:{task_id}");
    }
    if !event.task_id.trim().is_empty() {
        return format!("task:{}", event.task_id);
    }
    let branch = first_non_empty_owned([
        event.branch.clone(),
        json_field_string(&event.data, "branch"),
    ]);
    if !branch.trim().is_empty() {
        return format!("branch:{branch}");
    }
    String::new()
}

fn desktop_summary_refresh_text(item: &Value) -> String {
    let timestamp = item
        .get("timestamp")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(generated_at);
    let reason = item
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let mut details = Vec::new();
    if let Some(pane_id) = item.get("pane_id").and_then(Value::as_str) {
        details.push(format!("pane={pane_id}"));
    }
    if let Some(run_id) = item.get("run_id").and_then(Value::as_str) {
        details.push(format!("run={run_id}"));
    }
    if details.is_empty() {
        format!("[{timestamp}] summary {reason}")
    } else {
        format!("[{timestamp}] summary {reason} {}", details.join(" "))
    }
}

fn json_field_string(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn read_artifact_json(
    reference: &str,
    project_dir: &Path,
    expected_segments: &[&str],
    expected_run_id: &str,
) -> Value {
    if reference.trim().is_empty() {
        return Value::Null;
    }

    let mut expected_dir = project_dir.to_path_buf();
    for segment in expected_segments {
        expected_dir.push(segment);
    }

    let path = {
        let normalized = reference.replace('/', std::path::MAIN_SEPARATOR_STR);
        let candidate = PathBuf::from(&normalized);
        if candidate.is_absolute() {
            candidate
        } else {
            project_dir.join(candidate)
        }
    };

    let Ok(full_path) = fs::canonicalize(&path) else {
        return Value::Null;
    };
    let Ok(expected_dir) = fs::canonicalize(expected_dir) else {
        return Value::Null;
    };
    if !full_path.starts_with(&expected_dir) {
        return Value::Null;
    }

    let Ok(content) = fs::read_to_string(&full_path) else {
        return Value::Null;
    };
    let Ok(mut parsed) = serde_json::from_str::<Value>(&content) else {
        return Value::Null;
    };

    if let Some(run_id) = parsed.get("run_id").and_then(Value::as_str) {
        if !run_id.is_empty() && run_id != expected_run_id {
            return Value::Null;
        }
    }
    if let Value::Object(map) = &mut parsed {
        map.remove("packet_type");
    }
    parsed
}

fn write_enveloped_json<T: Serialize>(project_dir: &Path, value: T) -> io::Result<()> {
    let payload = enveloped_payload(project_dir, value)?;
    write_json(&payload)
}

fn payload_to_value<T: Serialize>(value: &T) -> io::Result<Value> {
    serde_json::to_value(value).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize Rust operator projection: {err}"),
        )
    })
}

fn enveloped_payload<T: Serialize>(project_dir: &Path, value: T) -> io::Result<Value> {
    let value = serde_json::to_value(value).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize Rust operator projection: {err}"),
        )
    })?;
    let payload = json!({
        "generated_at": generated_at(),
        "project_dir": project_dir_string(project_dir),
        "summary": value.get("summary").cloned().unwrap_or(Value::Null),
        "panes": value.get("panes").cloned().unwrap_or(Value::Null),
        "items": value.get("items").cloned().unwrap_or(Value::Null),
    });
    Ok(strip_null_fields(payload))
}

fn strip_null_fields(value: Value) -> Value {
    let Value::Object(mut map) = value else {
        return value;
    };
    map.retain(|_, value| !value.is_null());
    Value::Object(map)
}

fn generated_at() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn project_dir_string(project_dir: &Path) -> String {
    project_dir.display().to_string()
}

fn write_json<T: Serialize>(value: &T) -> io::Result<()> {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    serde_json::to_writer(&mut stdout, value).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize Rust operator projection: {err}"),
        )
    })?;
    writeln!(stdout)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn restart_plan(agent: &str, capability_adapter: &str) -> RestartPlan {
        RestartPlan {
            label: "worker-1".to_string(),
            pane_id: "%2".to_string(),
            role: "Worker".to_string(),
            session_name: "winsmux-orchestra".to_string(),
            launch_dir: "C:\\repo".to_string(),
            git_worktree_dir: "C:\\repo\\.git".to_string(),
            agent: agent.to_string(),
            model: String::new(),
            model_source: default_provider_model_source(),
            reasoning_effort: default_provider_reasoning_effort(),
            capability_adapter: capability_adapter.to_string(),
            launch_command: "noop".to_string(),
        }
    }

    fn test_project_dir(name: &str) -> PathBuf {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after epoch")
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("winsmux-{name}-{}-{suffix}", std::process::id()));
        std::fs::create_dir_all(path.join(".winsmux")).expect("create test project");
        path
    }

    #[test]
    fn stream_event_reader_ignores_partial_tail_line() {
        let project_dir = test_project_dir("stream-partial-tail");
        let events_path = project_dir.join(".winsmux").join("events.jsonl");
        std::fs::write(
            &events_path,
            concat!(
                r#"{"timestamp":"2026-04-24T12:00:01+09:00","event":"operator.followup","data":{"run_id":"task:TASK-1"}}"#,
                "\n",
                r#"{"timestamp":"2026-04-24T12:00:02+09:00","event":"#
            ),
        )
        .expect("write partial event log");

        let events =
            read_desktop_summary_events_for_stream(&project_dir).expect("stream reader succeeds");

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event, "operator.followup");
        assert!(read_desktop_summary_events(&project_dir).is_err());
    }

    fn meta_plan_role(provider: &str, plan_mode: &str) -> MetaPlanRole {
        MetaPlanRole {
            role_id: "planner".to_string(),
            label: "Planner".to_string(),
            provider: provider.to_string(),
            model: "provider-default".to_string(),
            model_source: default_provider_model_source(),
            reasoning_effort: default_provider_reasoning_effort(),
            plan_mode: plan_mode.to_string(),
            read_only: true,
            review_rounds: 1,
            capabilities: vec!["planning".to_string()],
            prompt: "Plan without editing files.".to_string(),
        }
    }

    #[test]
    fn restart_readiness_agent_resolves_known_adapters() {
        assert_eq!(
            restart_readiness_agent(&restart_plan("custom", "codex")),
            "codex"
        );
        assert_eq!(
            restart_readiness_agent(&restart_plan("claude-opus", "")),
            "claude"
        );
        assert_eq!(
            restart_readiness_agent(&restart_plan("gemini:flash", "")),
            "gemini"
        );
    }

    #[test]
    fn restart_readiness_agent_does_not_default_unknown_to_codex() {
        assert_eq!(restart_readiness_agent(&restart_plan("", "")), "");
        assert_eq!(
            restart_readiness_agent(&restart_plan("custom-agent", "")),
            ""
        );
        assert_eq!(
            restart_readiness_agent(&restart_plan("custom-agent", "custom-adapter")),
            ""
        );
    }

    #[test]
    fn meta_plan_role_uses_provider_capability_metadata_for_future_provider() {
        let project_dir = test_project_dir("meta-plan-provider-capability");
        let capability_path = provider_capability_registry_path(&project_dir);
        std::fs::write(
            &capability_path,
            r#"{
              "version": 1,
              "providers": {
                "gemini-planner": {
                  "adapter": "gemini",
                  "command": "gemini",
                  "prompt_transports": ["stdin"],
                  "supports_file_edit": false,
                  "supports_consultation": true
                }
              }
            }"#,
        )
        .expect("write provider capability registry");

        let role = meta_plan_role("gemini-planner", "read_only_equivalent");
        validate_meta_plan_role(&project_dir, &role).expect("role should validate");
        let adapter = meta_plan_provider_adapter(&project_dir, &role).expect("adapter");
        let command = meta_plan_provider_command(&project_dir, &role).expect("command");
        let launch =
            meta_plan_launch_contract(&project_dir, &role, &adapter, &command).expect("launch");

        assert_eq!(adapter, "gemini");
        assert_eq!(command, "gemini");
        assert_eq!(launch["provider"], "gemini-planner");
        assert_eq!(launch["provider_adapter"], "gemini");
        assert_eq!(launch["read_only_equivalent"], true);
        assert_eq!(launch["read_only"], true);

        let _ = std::fs::remove_dir_all(project_dir);
    }

    #[test]
    fn meta_plan_role_rejects_future_provider_without_capability_metadata() {
        let project_dir = test_project_dir("meta-plan-missing-provider-capability");
        let role = meta_plan_role("future-planner", "read_only_equivalent");
        let error = validate_meta_plan_role(&project_dir, &role).expect_err("role should fail");

        assert!(error
            .to_string()
            .contains("must be declared in .winsmux/provider-capabilities.json"));

        let _ = std::fs::remove_dir_all(project_dir);
    }

    #[test]
    fn meta_plan_role_rejects_custom_adapter_without_read_only_launch_args() {
        let project_dir = test_project_dir("meta-plan-custom-provider-no-read-only-args");
        let capability_path = provider_capability_registry_path(&project_dir);
        std::fs::write(
            &capability_path,
            r#"{
              "version": 1,
              "providers": {
                "future-planner": {
                  "adapter": "future-cli",
                  "command": "future",
                  "prompt_transports": ["stdin"],
                  "supports_file_edit": false,
                  "supports_consultation": true
                }
              }
            }"#,
        )
        .expect("write provider capability registry");

        let role = meta_plan_role("future-planner", "read_only_equivalent");
        let error = validate_meta_plan_role(&project_dir, &role).expect_err("role should fail");

        assert!(error
            .to_string()
            .contains("must declare read_only_launch_args"));

        let _ = std::fs::remove_dir_all(project_dir);
    }

    #[test]
    fn meta_plan_role_uses_custom_adapter_read_only_launch_args() {
        let project_dir = test_project_dir("meta-plan-custom-provider-read-only-args");
        let capability_path = provider_capability_registry_path(&project_dir);
        std::fs::write(
            &capability_path,
            r#"{
              "version": 1,
              "providers": {
                "future-planner": {
                  "adapter": "future-cli",
                  "command": "future",
                  "prompt_transports": ["stdin"],
                  "read_only_launch_args": ["--read-only", "--no-write"],
                  "supports_file_edit": false,
                  "supports_consultation": true
                }
              }
            }"#,
        )
        .expect("write provider capability registry");

        let role = meta_plan_role("future-planner", "read_only_equivalent");
        validate_meta_plan_role(&project_dir, &role).expect("role should validate");
        let adapter = meta_plan_provider_adapter(&project_dir, &role).expect("adapter");
        let command = meta_plan_provider_command(&project_dir, &role).expect("command");
        let launch =
            meta_plan_launch_contract(&project_dir, &role, &adapter, &command).expect("launch");

        assert_eq!(adapter, "future-cli");
        assert_eq!(command, "future");
        assert_eq!(launch["provider"], "future-planner");
        assert_eq!(launch["provider_adapter"], "future-cli");
        assert_eq!(launch["args"], json!(["--read-only", "--no-write"]));
        assert_eq!(launch["read_only_equivalent"], true);
        assert_eq!(launch["read_only"], true);

        let _ = std::fs::remove_dir_all(project_dir);
    }
}
