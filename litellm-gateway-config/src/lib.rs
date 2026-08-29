// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Cognitio S.r.l.

//! Feature-recipe-pipeline step that writes runtime controls into an AI
//! gateway's rendered configuration body.
//!
//! A gateway's realization renders its configuration as an embedded text block
//! inside a ConfigMap, and the proxy container reads that file through its
//! `--config` flag. A Feature that turns a runtime control on has to reach into
//! that body: the control is a setting the running proxy reads, not a resource
//! of its own, so an additive EMIT would land the control in a file the proxy
//! never opens. This step is the cross-entity PATCH that reaches it.
//!
//! Two layers sit between the step and the setting, and only the outer one is
//! structurally addressable:
//!
//!  - The ConfigMap document is a structured unit, so an RFC 6902 pointer
//!    addresses its `data` entries.
//!  - The configuration body inside that entry is a single string scalar. No
//!    JSON pointer descends into a scalar, so no patch addresses a key *within*
//!    the body. The guest receives the whole string, edits it, and emits one
//!    `replace` of the entry — which is how a control reaches a setting the
//!    proxy reads without a second file and without a new mechanism.
//!
//! The edit is line-scoped rather than a parse-and-reserialize: it rewrites only
//! the lines the requested settings touch and leaves every other byte of the
//! body as the Recipe authored it. That keeps the routing table in author order,
//! keeps the literal block intact, and keeps a build's diff to the settings an
//! attachment actually asked for.
//!
//! It declares — in `describe()` — `operates=patch`, `scope=host`, and `helm` as
//! its sole compatible provider: it patches the documents the Workload-synthesis
//! provider emits, so it is tested-compatible with that provider and no other.
//! The host checks this against the HOST component's provider — the provider
//! rendering the `/host` documents — before any guest runs.
//!
//! Selection is by content, never by filename: the guest cannot know the emitted
//! key ahead of time, so it looks for the ConfigMap data entry whose text
//! carries the routing table the gateway serves.
//!
//! Settings are applied in sorted key order rather than in the order the step
//! declared them, at every depth. Sorted order is what makes a run's output
//! depend only on the settings themselves, so identical input yields
//! byte-identical output whatever order the step happened to write them in.

use aggrega_pdk_rust::{
    encode_descriptor, PluginDescriptor, PluginDescriptorMeta, PluginExport, API_VERSION,
};
use extism_pdk::{plugin_fn, FnResult};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// The top-level key that identifies a gateway configuration body: the routing
/// table listing every alias the gateway publishes. A ConfigMap may carry any
/// number of data entries, so the step selects on the presence of this key
/// rather than on the entry's name.
const ROUTING_TABLE_KEY: &str = "model_list";

/// The indentation a newly created section's members are written at, used only
/// where the section does not exist yet and there is no authored member to read
/// an indentation from.
const DEFAULT_MEMBER_INDENT: usize = 2;

/// The static `describe()` self-report: a v1alpha1 `pipeline-step` plugin whose
/// `step` export patches the host component's rendered configuration and is
/// tested-compatible only with the `helm` provider (the provider that synthesizes
/// the gateway's workload and emits its ConfigMap).
fn descriptor() -> PluginDescriptor {
    PluginDescriptor {
        abi_version: API_VERSION.to_string(),
        plugin_type: "pipeline-step".to_string(),
        capabilities: vec!["helm".to_string()],
        exports: vec![PluginExport {
            name: "step".to_string(),
            operates: "patch".to_string(),
            scope: "host".to_string(),
            selector: "the ConfigMap data entry carrying the attached gateway's routing table"
                .to_string(),
            ..Default::default()
        }],
        metadata: Some(Box::new(PluginDescriptorMeta {
            author: "aggrega".to_string(),
            license: "Apache-2.0".to_string(),
            ..Default::default()
        })),
        ..Default::default()
    }
}

/// One addressable unit the host hands the guest. A structured unit carries a
/// `tree` (the RFC-6902-addressable view the guest content-selects and patches);
/// an opaque unit carries no `tree`, so it is never a PATCH target.
#[derive(Deserialize)]
struct Unit {
    #[serde(default)]
    tree: Option<Value>,
}

/// The keyed, scope-rooted unit set the host hands the guest. A component-scope
/// FeatureRecipe attached to a host receives both roots; this guest acts only on
/// `host`, because the setting it writes belongs to the gateway it is attached
/// to and not to any document of its own.
#[derive(Deserialize, Default)]
struct DocumentSet {
    #[serde(default)]
    host: BTreeMap<String, Unit>,
}

/// The subset of the host's FRPStepInput this plugin reads: the document set and
/// the step's rendered `with` block.
#[derive(Deserialize)]
struct StepInput {
    documents: DocumentSet,
    #[serde(default)]
    step_input: BTreeMap<String, Value>,
}

/// One RFC 6902 patch addressed to a document by scope and key.
#[derive(Serialize)]
struct JsonPatchOp {
    scope: String,
    key: String,
    op: String,
    path: String,
    value: Value,
}

/// The host's FRPStepOutput wire shape. `error` reports that the step ran and
/// could not complete: the host surfaces it as a failed invocation, which is
/// what keeps a control that cannot be placed from passing as a silent success.
#[derive(Serialize, Default)]
struct StepOutput {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    patches: Vec<JsonPatchOp>,
    #[serde(skip_serializing_if = "String::is_empty")]
    error: String,
}

/// The host calls `describe()` once at load to read the plugin's
/// self-declaration before dispatching `step`.
#[plugin_fn]
pub fn describe() -> FnResult<String> {
    Ok(encode_descriptor(&descriptor()))
}

/// `step` runs one cross-entity pipeline step: it content-selects the attached
/// gateway's configuration body, writes the requested settings into the named
/// section, and emits one `replace` of the whole data entry.
#[plugin_fn]
pub fn step(input: String) -> FnResult<String> {
    let parsed: StepInput = serde_json::from_str(&input)?;
    Ok(serde_json::to_string(&run(parsed))?)
}

fn run(parsed: StepInput) -> StepOutput {
    let section = match parsed.step_input.get("section").and_then(Value::as_str) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return failed("step input must name the configuration section to write into"),
    };
    let settings = match parsed.step_input.get("settings") {
        Some(Value::Object(m)) if !m.is_empty() => m.clone(),
        _ => return failed("step input must carry a non-empty settings map"),
    };

    let mut selected: Vec<(String, String, String)> = Vec::new();
    for (unit_key, unit) in parsed.documents.host.iter() {
        let tree = match unit.tree.as_ref() {
            // An opaque unit (a templated file) carries no tree and is never a
            // PATCH target.
            None => continue,
            Some(t) => t,
        };
        let data = match tree.get("data").and_then(Value::as_object) {
            None => continue,
            Some(d) => d,
        };
        for (data_key, body) in data.iter() {
            if let Some(text) = body.as_str() {
                if carries_routing_table(text) {
                    selected.push((unit_key.clone(), data_key.clone(), text.to_string()));
                }
            }
        }
    }

    match selected.len() {
        0 => failed(
            "no rendered document carries a gateway routing table, so there is no configuration body to write into",
        ),
        1 => {
            let (unit_key, data_key, body) = selected.remove(0);
            match set_in_section(&body, &section, &settings) {
                Err(message) => failed(&message),
                Ok(patched) => StepOutput {
                    patches: vec![JsonPatchOp {
                        scope: "host".to_string(),
                        key: unit_key,
                        op: "replace".to_string(),
                        path: format!("/data/{}", escape_pointer_token(&data_key)),
                        value: Value::String(patched),
                    }],
                    error: String::new(),
                },
            }
        }
        _ => failed(
            "more than one rendered document carries a gateway routing table, so the configuration body to write into is ambiguous",
        ),
    }
}

fn failed(message: &str) -> StepOutput {
    StepOutput {
        patches: Vec::new(),
        error: message.to_string(),
    }
}

/// Reports whether a text body is a gateway configuration: a block mapping
/// declaring the routing table at its top level.
fn carries_routing_table(text: &str) -> bool {
    let header = format!("{}:", ROUTING_TABLE_KEY);
    text.split('\n').any(|line| line == header)
}

/// Escapes an RFC 6901 pointer token: `~` first, then `/`, so an escape written
/// for one is never re-read as the other.
fn escape_pointer_token(token: &str) -> String {
    token.replace('~', "~0").replace('/', "~1")
}

fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start_matches(' ').len()
}

fn is_blank(line: &str) -> bool {
    line.trim().is_empty()
}

/// Writes each setting into the named top-level section of a block-mapping
/// configuration body, replacing a member the section already declares and
/// appending one it does not. Every line the settings do not touch is carried
/// through unchanged, so the body keeps its authored order and formatting.
fn set_in_section(
    body: &str,
    section: &str,
    settings: &Map<String, Value>,
) -> Result<String, String> {
    let ends_with_newline = body.ends_with('\n');
    let trimmed = if ends_with_newline {
        &body[..body.len() - 1]
    } else {
        body
    };
    let mut lines: Vec<String> = trimmed.split('\n').map(str::to_string).collect();

    let header = format!("{}:", section);
    match lines.iter().position(|line| *line == header) {
        None => {
            // The section is absent: append it, with its members at the default
            // indentation, after the body the Recipe authored.
            while lines.last().map(|l| is_blank(l)).unwrap_or(false) {
                lines.pop();
            }
            lines.push(header);
            for (key, value) in settings.iter() {
                lines.extend(render_member(key, value, DEFAULT_MEMBER_INDENT)?);
            }
        }
        Some(header_index) => {
            let block_start = header_index + 1;
            let mut block_end = block_start;
            while block_end < lines.len()
                && (is_blank(&lines[block_end]) || indent_of(&lines[block_end]) > 0)
            {
                block_end += 1;
            }
            // Trailing blank lines belong to whatever follows the section, not
            // to the section, so an appended member lands above them.
            while block_end > block_start && is_blank(&lines[block_end - 1]) {
                block_end -= 1;
            }

            let member_indent = (block_start..block_end)
                .find(|i| !is_blank(&lines[*i]))
                .map(|i| indent_of(&lines[i]))
                .unwrap_or(DEFAULT_MEMBER_INDENT);
            if member_indent == 0 {
                return Err(format!(
                    "configuration section {} declares a member at no indentation, so its extent cannot be read",
                    section
                ));
            }

            for (key, value) in settings.iter() {
                let rendered = render_member(key, value, member_indent)?;
                let prefix = format!("{}{}:", " ".repeat(member_indent), key);
                let existing = (block_start..block_end).find(|i| {
                    let line = &lines[*i];
                    line.starts_with(&prefix)
                        && (line.len() == prefix.len() || line.as_bytes()[prefix.len()] == b' ')
                });
                match existing {
                    Some(start) => {
                        // The member's extent runs to the next line at or above
                        // its own indentation, so a nested value is replaced whole.
                        let mut end = start + 1;
                        while end < block_end
                            && (is_blank(&lines[end]) || indent_of(&lines[end]) > member_indent)
                        {
                            end += 1;
                        }
                        let replaced = end - start;
                        lines.splice(start..end, rendered.iter().cloned());
                        block_end = block_end + rendered.len() - replaced;
                    }
                    None => {
                        lines.splice(block_end..block_end, rendered.iter().cloned());
                        block_end += rendered.len();
                    }
                }
            }
        }
    }

    let mut out = lines.join("\n");
    if ends_with_newline {
        out.push('\n');
    }
    Ok(out)
}

/// Renders one mapping member as the block lines that express it.
fn render_member(key: &str, value: &Value, indent: usize) -> Result<Vec<String>, String> {
    let pad = " ".repeat(indent);
    match value {
        Value::Object(map) if !map.is_empty() => {
            let mut out = vec![format!("{}{}:", pad, key)];
            for (k, v) in map.iter() {
                out.extend(render_member(k, v, indent + 2)?);
            }
            Ok(out)
        }
        Value::Array(items) if !items.is_empty() => {
            let mut out = vec![format!("{}{}:", pad, key)];
            for item in items.iter() {
                out.extend(render_sequence_item(item, indent + 2)?);
            }
            Ok(out)
        }
        _ => Ok(vec![format!("{}{}: {}", pad, key, render_scalar(value)?)]),
    }
}

/// Renders one sequence entry as the block lines that express it.
fn render_sequence_item(value: &Value, indent: usize) -> Result<Vec<String>, String> {
    let pad = " ".repeat(indent);
    match value {
        Value::Object(map) if !map.is_empty() => {
            let mut out = vec![format!("{}-", pad)];
            for (k, v) in map.iter() {
                out.extend(render_member(k, v, indent + 2)?);
            }
            Ok(out)
        }
        Value::Array(_) => Err("a nested sequence is not an expressible setting value".to_string()),
        _ => Ok(vec![format!("{}- {}", pad, render_scalar(value)?)]),
    }
}

/// Renders a scalar setting value. A string is written plain where a plain
/// scalar reads back as the same string, and double-quoted otherwise — so a
/// value that would otherwise be read as a number, a boolean or a null keeps its
/// authored type.
fn render_scalar(value: &Value) -> Result<String, String> {
    match value {
        Value::Null => Ok("null".to_string()),
        Value::Bool(b) => Ok(b.to_string()),
        Value::Number(n) => Ok(n.to_string()),
        Value::String(s) => Ok(if is_plain_safe(s) {
            s.clone()
        } else {
            Value::String(s.clone()).to_string()
        }),
        _ => Err("a nested value is not an expressible scalar".to_string()),
    }
}

/// Reports whether a string reads back as itself when written as a plain scalar.
fn is_plain_safe(s: &str) -> bool {
    if s.is_empty() || s.len() > 120 {
        return false;
    }
    if s.starts_with(' ') || s.ends_with(' ') {
        return false;
    }
    if !s
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '/' | '@' | '+' | ' '))
    {
        return false;
    }
    if !s
        .chars()
        .next()
        .map(|c| c.is_ascii_alphanumeric() || c == '_' || c == '/' || c == '.')
        .unwrap_or(false)
    {
        return false;
    }
    // A plain scalar spelling one of YAML's boolean or null words, or a number,
    // reads back as that type rather than as the string it was written from.
    let lowered = s.to_ascii_lowercase();
    if matches!(
        lowered.as_str(),
        "true" | "false" | "yes" | "no" | "on" | "off" | "null" | "none" | "~"
    ) {
        return false;
    }
    if s.parse::<f64>().is_ok() {
        return false;
    }
    true
}
