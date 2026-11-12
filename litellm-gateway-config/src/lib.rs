// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Cognitio s.r.l.

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
//! A configuration section comes in one of two shapes and the step says which it
//! is writing. A section of named settings is written with `settings`, and each
//! member is replaced where the section already declares it and appended where it
//! does not. A section that is a list is written with `entries`, and
//! `identifiedBy` names the key inside an entry that identifies it: an entry
//! whose identity the section already carries is replaced, and one it does not
//! carry is appended. Identity rather than position is what makes a run
//! repeatable — an entry some other attachment appended, or a reordering upstream,
//! would move a positional target onto a different entry with nothing to say so.
//! Asking for the shape a section does not hold is refused rather than written,
//! because a setting written into the wrong shape reaches the deployed file as a
//! configuration the proxy cannot read.
//!
//! Settings are applied in sorted key order rather than in the order the step
//! declared them, at every depth. Sorted order is what makes a run's output
//! depend only on the settings themselves, so identical input yields
//! byte-identical output whatever order the step happened to write them in.
//! Entries are applied in the order the step declared them, because a list's
//! order is part of what the list means.
//!
//! The pipeline-step socket carries canonical CBOR in both directions, so `step`
//! takes and returns bytes: it reads its input with `FRPStepInput::decode_cbor`
//! and returns its output's `encode_cbor()`, through the codec generated into
//! the `aggrega-abi` crate. The document trees and the `with` values ride as the
//! bytes of their JSON documents, which the step parses.

use aggrega_abi::{FRPStepInput, FRPStepOutput, JSONPatchOp};
use aggrega_pdk_rust::{PluginDescriptor, PluginDescriptorMeta, PluginExport, API_VERSION};
use extism_pdk::{plugin_fn, FnResult};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// The top-level key that identifies a gateway configuration body: the routing
/// table listing every alias the gateway publishes. A ConfigMap may carry any
/// number of data entries, so the step selects on the presence of this key
/// rather than on the entry's name.
const ROUTING_TABLE_KEY: &str = "model_list";

/// The indentation a newly created section's members are written at, used only
/// where the section does not exist yet and there is no authored member to read
/// an indentation from. It covers a section's entries as well as its named
/// settings: both are members of the section, and a body reads consistently only
/// where they are written at one indentation.
const DEFAULT_MEMBER_INDENT: usize = 2;

/// What a step asks to be written into a configuration section: the named
/// settings of a section that is a mapping, or the entries of a section that is
/// a list.
enum SectionWrite<'a> {
    Settings(&'a Map<String, Value>),
    Entries {
        identity: &'a str,
        entries: &'a [Value],
    },
}

/// The shape a configuration section already holds, read from the first member
/// its body declares. A section that declares no member yet holds neither shape,
/// so what the step asks for decides what is written into it.
enum SectionShape {
    Empty,
    Mapping { member_indent: usize },
    Sequence { entry_indent: usize },
}

/// The static `describe()` self-report: a `pipeline-step` plugin whose
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
struct Unit {
    tree: Option<Value>,
}

/// The keyed, scope-rooted unit set the host hands the guest. A component-scope
/// FeatureRecipe attached to a host receives both roots; this guest acts only on
/// `host`, because the setting it writes belongs to the gateway it is attached
/// to and not to any document of its own.
#[derive(Default)]
struct DocumentSet {
    host: BTreeMap<String, Unit>,
}

/// The subset of the host's FRPStepInput this plugin reads: the document set and
/// the step's rendered `with` block.
struct StepInput {
    documents: DocumentSet,
    step_input: BTreeMap<String, Value>,
}

/// One RFC 6902 patch addressed to a document by scope and key.
struct JsonPatchOp {
    scope: String,
    key: String,
    op: String,
    path: String,
    value: Value,
}

/// What the step answers: key-addressed patches, or `error` reporting that the
/// step ran and could not complete. The host surfaces an error as a failed
/// invocation, which is what keeps a control that cannot be placed from passing
/// as a silent success.
#[derive(Default)]
struct StepOutput {
    patches: Vec<JsonPatchOp>,
    error: String,
}

/// The host calls `describe()` once at load to read the plugin's
/// self-declaration before dispatching `step`. The kit's `describe!` macro
/// expands here, in this crate, so the version and commit the build script
/// stamps at compile time reach the self-report.
#[plugin_fn]
pub fn describe() -> FnResult<String> {
    Ok(aggrega_pdk_rust::describe!(descriptor()))
}

/// `step` runs one cross-entity pipeline step: it content-selects the attached
/// gateway's configuration body, writes what the step asked for into the named
/// section, and emits one `replace` of the whole data entry.
#[plugin_fn]
pub fn step(input: Vec<u8>) -> FnResult<Vec<u8>> {
    let parsed = read_input(&FRPStepInput::decode_cbor(&input)?)?;
    Ok(write_output(run(parsed))?.encode_cbor()?)
}

/// Reads the subset of the decoded payload this step acts on. Each host unit's
/// tree and each `with` value arrives as the bytes of its JSON document and is
/// parsed here; a document that does not parse fails the step. The units and
/// the `with` keys are held in sorted maps, so the step's selection and its
/// output do not depend on the order either arrived in.
fn read_input(wire: &FRPStepInput) -> Result<StepInput, serde_json::Error> {
    let mut host = BTreeMap::new();
    for (key, unit) in wire.documents.host.iter() {
        let tree = match unit.tree.as_deref() {
            Some(raw) => Some(serde_json::from_str(raw.get())?),
            None => None,
        };
        host.insert(key.clone(), Unit { tree });
    }
    let mut step_input = BTreeMap::new();
    for (key, raw) in wire.step_input.iter() {
        step_input.insert(key.clone(), serde_json::from_str(raw.get())?);
    }
    Ok(StepInput {
        documents: DocumentSet { host },
        step_input,
    })
}

/// Writes the step's answer as the payload the host reads. A patch's value rides
/// as the bytes of its JSON document.
fn write_output(out: StepOutput) -> Result<FRPStepOutput, serde_json::Error> {
    let mut patches = Vec::with_capacity(out.patches.len());
    for p in out.patches {
        patches.push(JSONPatchOp {
            scope: p.scope,
            key: p.key,
            op: p.op,
            path: p.path,
            value: Some(serde_json::value::to_raw_value(&p.value)?),
            ..Default::default()
        });
    }
    Ok(FRPStepOutput {
        patches,
        error: out.error,
        ..Default::default()
    })
}

fn run(parsed: StepInput) -> StepOutput {
    let section = match parsed.step_input.get("section").and_then(Value::as_str) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return failed("step input must name the configuration section to write into"),
    };
    let has_settings = parsed.step_input.contains_key("settings");
    let has_entries = parsed.step_input.contains_key("entries");
    let write = if has_settings && has_entries {
        return failed(
            "step input carries both settings and entries, and a configuration section is written with one or the other",
        );
    } else if has_settings {
        match parsed.step_input.get("settings") {
            Some(Value::Object(m)) if !m.is_empty() => SectionWrite::Settings(m),
            _ => return failed("step input must carry a non-empty settings map"),
        }
    } else if has_entries {
        let identity = match parsed.step_input.get("identifiedBy").and_then(Value::as_str) {
            Some(s) if !s.is_empty() => s,
            _ => return failed(
                "a step writing entries must name, in identifiedBy, the key inside an entry that identifies it, so an entry is replaced rather than duplicated",
            ),
        };
        match parsed.step_input.get("entries") {
            Some(Value::Array(items)) if !items.is_empty() => SectionWrite::Entries {
                identity,
                entries: items.as_slice(),
            },
            _ => return failed("step input must carry a non-empty entries list"),
        }
    } else {
        return failed("step input must carry either a settings map or an entries list");
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
            match set_in_section(&body, &section, &write) {
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

/// Writes what a step asks into the named top-level section of a configuration
/// body: the named settings of a section that is a mapping, or the entries of a
/// section that is a list. A member the section already declares is replaced and
/// one it does not is appended. Every line the request does not touch is carried
/// through unchanged, so the body keeps its authored order and formatting.
///
/// Asking for the shape a section does not hold is refused. Writing a named
/// setting into a list, or an entry into a mapping, produces a body the proxy
/// cannot read, and a build that emitted one would report nothing wrong.
fn set_in_section(body: &str, section: &str, write: &SectionWrite) -> Result<String, String> {
    // Every entry the step asks for is checked before any line is written, so a
    // request that cannot be addressed later is refused rather than half applied.
    let identities = match write {
        SectionWrite::Settings(_) => Vec::new(),
        SectionWrite::Entries { identity, entries } => entry_identities(entries, identity)?,
    };

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
            lines.extend(render_section_body(write, DEFAULT_MEMBER_INDENT)?);
        }
        Some(header_index) => {
            let block_start = header_index + 1;
            match (write, section_shape(&lines, block_start)) {
                (SectionWrite::Settings(settings), shape) => {
                    let member_indent = match shape {
                        SectionShape::Sequence { .. } => {
                            return Err(format!(
                                "configuration section {} is a list of entries: write it with entries rather than settings",
                                section
                            ))
                        }
                        SectionShape::Mapping { member_indent } => member_indent,
                        SectionShape::Empty => DEFAULT_MEMBER_INDENT,
                    };
                    let block_end = mapping_block_end(&lines, block_start);
                    set_members(&mut lines, block_start, block_end, member_indent, settings)?;
                }
                (SectionWrite::Entries { identity, entries }, shape) => {
                    let entry_indent = match shape {
                        SectionShape::Mapping { .. } => {
                            return Err(format!(
                                "configuration section {} holds named settings: write it with settings rather than entries",
                                section
                            ))
                        }
                        SectionShape::Sequence { entry_indent } => entry_indent,
                        SectionShape::Empty => DEFAULT_MEMBER_INDENT,
                    };
                    let block_end = sequence_block_end(&lines, block_start, entry_indent);
                    set_entries(
                        &mut lines,
                        block_start,
                        block_end,
                        entry_indent,
                        identity,
                        entries,
                        &identities,
                    )?;
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

/// Renders the whole body of a section being created, at the indentation its
/// members are written at.
fn render_section_body(write: &SectionWrite, indent: usize) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    match write {
        SectionWrite::Settings(settings) => {
            for (key, value) in settings.iter() {
                out.extend(render_member(key, value, indent)?);
            }
        }
        SectionWrite::Entries { entries, .. } => {
            for entry in entries.iter() {
                out.extend(render_sequence_item(entry, indent)?);
            }
        }
    }
    Ok(out)
}

/// Reads the shape a section holds from the first member line after its header.
///
/// A line at no indentation belongs to the section only where it opens an entry;
/// every other line at that indentation is the next top-level key, so the section
/// declares no member of its own.
fn section_shape(lines: &[String], block_start: usize) -> SectionShape {
    let first = match (block_start..lines.len()).find(|i| !is_blank(&lines[*i])) {
        None => return SectionShape::Empty,
        Some(i) => i,
    };
    let indent = indent_of(&lines[first]);
    if opens_entry(&lines[first]) {
        return SectionShape::Sequence {
            entry_indent: indent,
        };
    }
    if indent == 0 {
        return SectionShape::Empty;
    }
    SectionShape::Mapping {
        member_indent: indent,
    }
}

/// Reports whether a line opens a list entry: a hyphen at the start of its
/// content, alone or followed by the entry's first member.
fn opens_entry(line: &str) -> bool {
    let content = line.trim_start_matches(' ');
    content == "-" || content.starts_with("- ")
}

/// The line one past the end of a mapping section's block. Its members are the
/// indented lines below the header; trailing blank lines belong to whatever
/// follows the section, so an appended member lands above them.
fn mapping_block_end(lines: &[String], block_start: usize) -> usize {
    let mut end = block_start;
    while end < lines.len() && (is_blank(&lines[end]) || indent_of(&lines[end]) > 0) {
        end += 1;
    }
    while end > block_start && is_blank(&lines[end - 1]) {
        end -= 1;
    }
    end
}

/// The line one past the end of a list section's block. An entry opens at the
/// section's entry indentation and its own members sit further in, so a line
/// belongs to the section while it is blank, indented past that, or opens another
/// entry at it. Reading the extent this way is what lets a list sit at no
/// indentation at all, which is how a configuration body is often authored.
fn sequence_block_end(lines: &[String], block_start: usize, entry_indent: usize) -> usize {
    let mut end = block_start;
    while end < lines.len() {
        let line = &lines[end];
        let belongs = is_blank(line)
            || indent_of(line) > entry_indent
            || (indent_of(line) == entry_indent && opens_entry(line));
        if !belongs {
            break;
        }
        end += 1;
    }
    while end > block_start && is_blank(&lines[end - 1]) {
        end -= 1;
    }
    end
}

/// Writes each named setting into a mapping section's block.
fn set_members(
    lines: &mut Vec<String>,
    block_start: usize,
    block_end: usize,
    member_indent: usize,
    settings: &Map<String, Value>,
) -> Result<(), String> {
    let mut block_end = block_end;
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
                // The member's extent runs to the next line at or above its own
                // indentation, so a nested value is replaced whole.
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
    Ok(())
}

/// Writes each entry into a list section's block, replacing the entry the
/// section already carries under the same identity and appending one it does not.
fn set_entries(
    lines: &mut Vec<String>,
    block_start: usize,
    block_end: usize,
    entry_indent: usize,
    identity: &str,
    entries: &[Value],
    identities: &[String],
) -> Result<(), String> {
    let mut block_end = block_end;
    for (entry, wanted) in entries.iter().zip(identities.iter()) {
        let rendered = render_sequence_item(entry, entry_indent)?;
        let existing = entry_ranges(lines, block_start, block_end, entry_indent)
            .into_iter()
            .find(|(start, end)| {
                declared_identity(lines, *start, *end, entry_indent, identity).as_deref()
                    == Some(wanted.as_str())
            });
        match existing {
            Some((start, end)) => {
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
    Ok(())
}

/// The identity each entry a step asked for declares, in the order the step
/// declared them. An entry that declares none could never be addressed again, so
/// a step carrying one is refused rather than written.
fn entry_identities(entries: &[Value], identity: &str) -> Result<Vec<String>, String> {
    entries
        .iter()
        .map(|entry| match entry {
            Value::Object(map) if !map.is_empty() => {
                map.get(identity).and_then(scalar_text).ok_or_else(|| {
                    format!(
                        "every entry must carry {}, the key that identifies it, holding a scalar value",
                        identity
                    )
                })
            }
            _ => Err("an entry must be a mapping carrying the key that identifies it".to_string()),
        })
        .collect()
}

/// The text a scalar setting value stands for, used to compare an entry's
/// identity against the one a body already carries.
fn scalar_text(value: &Value) -> Option<String> {
    match value {
        Value::Null => Some("null".to_string()),
        Value::Bool(b) => Some(b.to_string()),
        Value::Number(n) => Some(n.to_string()),
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        _ => None,
    }
}

/// The line range each entry of a list section's block occupies, half-open. An
/// entry runs from the line opening it to the line opening the next one, with
/// trailing blank lines left to what follows so a replacement keeps the
/// separation the body was authored with.
fn entry_ranges(
    lines: &[String],
    block_start: usize,
    block_end: usize,
    entry_indent: usize,
) -> Vec<(usize, usize)> {
    let opens: Vec<usize> = (block_start..block_end)
        .filter(|i| indent_of(&lines[*i]) == entry_indent && opens_entry(&lines[*i]))
        .collect();
    opens
        .iter()
        .enumerate()
        .map(|(n, start)| {
            let mut end = opens.get(n + 1).copied().unwrap_or(block_end);
            while end > start + 1 && is_blank(&lines[end - 1]) {
                end -= 1;
            }
            (*start, end)
        })
        .collect()
}

/// The identity an entry in the body declares, read from the line opening it or
/// from one of the entry's own member lines. A member of the same name nested
/// deeper inside the entry is not the entry's identity and is never read as one.
fn declared_identity(
    lines: &[String],
    start: usize,
    end: usize,
    entry_indent: usize,
    identity: &str,
) -> Option<String> {
    let after_hyphen = lines[start].get(entry_indent + 1..).unwrap_or("");
    let inline = after_hyphen.trim_start_matches(' ');
    let member_indent = if inline.is_empty() {
        // The entry opens with a bare hyphen, so its members begin on the lines
        // below it and their indentation is read from the first of them.
        indent_of(&lines[(start + 1..end).find(|i| !is_blank(&lines[*i]))?])
    } else {
        if let Some(text) = member_value(inline, identity) {
            return Some(text);
        }
        entry_indent + 1 + (after_hyphen.len() - inline.len())
    };
    (start + 1..end)
        .filter(|i| !is_blank(&lines[*i]) && indent_of(&lines[*i]) == member_indent)
        .find_map(|i| member_value(lines[i].trim_start_matches(' '), identity))
}

/// The value a `<key>: <value>` line declares for one key, given the line with
/// its indentation stripped. A line declaring a different key, or declaring the
/// key with a value that is not a scalar on the same line, declares nothing here.
fn member_value(text: &str, key: &str) -> Option<String> {
    let rest = text.strip_prefix(key)?.strip_prefix(':')?;
    if !rest.starts_with(' ') {
        return None;
    }
    let value = read_scalar_text(rest.trim_start_matches(' '));
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

/// The string a body line's scalar text stands for: the content of a quoted
/// scalar, or a plain scalar up to any comment following it. A scalar written
/// across more than one line is not a spelling a configuration body carries here,
/// and stands for nothing.
fn read_scalar_text(text: &str) -> String {
    match text.chars().next() {
        Some('"') => {
            let mut out = String::new();
            let mut escaped = false;
            for c in text[1..].chars() {
                if escaped {
                    out.push(match c {
                        'n' => '\n',
                        't' => '\t',
                        other => other,
                    });
                    escaped = false;
                } else if c == '\\' {
                    escaped = true;
                } else if c == '"' {
                    break;
                } else {
                    out.push(c);
                }
            }
            out
        }
        Some('\'') => {
            let mut out = String::new();
            let mut chars = text[1..].chars().peekable();
            while let Some(c) = chars.next() {
                if c != '\'' {
                    out.push(c);
                } else if chars.peek() == Some(&'\'') {
                    chars.next();
                    out.push('\'');
                } else {
                    break;
                }
            }
            out
        }
        Some('#') => String::new(),
        _ => match text.find(" #") {
            Some(i) => text[..i].trim_end().to_string(),
            None => text.trim_end().to_string(),
        },
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn as_map(value: Value) -> Map<String, Value> {
        match value {
            Value::Object(m) => m,
            other => panic!("fixture is not a mapping: {}", other),
        }
    }

    fn as_list(value: Value) -> Vec<Value> {
        match value {
            Value::Array(a) => a,
            other => panic!("fixture is not a list: {}", other),
        }
    }

    // A configuration body carrying every section spelling under test: a list
    // indented under its key, whose first entry opens on the same line as its
    // first member and whose second opens with a bare hyphen; a section declared
    // with nothing in it; a mapping of named settings; and a list at no
    // indentation at all.
    const BODY: &str = "model_list:\n  - model_name: fast\n    litellm_params:\n      model: openai/gpt-4o-mini\nguardrails:\n  - guardrail_name: prompt-injection\n    litellm_params:\n      mode: during_call\n  -\n    guardrail_name: pii-redaction\n    litellm_params:\n      mode: post_call\ncallbacks:\nrouter_settings:\n  routing_strategy: simple-shuffle\nflat_list:\n- name: alpha\n  weight: 1\n";

    #[test]
    fn settings_write_named_members_and_refuse_a_list() {
        let cases: Vec<(&str, &str, Value, Result<&str, &str>)> = vec![
            (
                "an existing member is replaced in place",
                "router_settings",
                json!({ "routing_strategy": "least-busy" }),
                Ok("routing_strategy: least-busy"),
            ),
            (
                "a member the section does not declare is appended",
                "router_settings",
                json!({ "num_retries": 2 }),
                Ok("  routing_strategy: simple-shuffle\n  num_retries: 2\n"),
            ),
            (
                "an absent section is created with its members",
                "general_settings",
                json!({ "disable_spend_logs": false }),
                Ok("general_settings:\n  disable_spend_logs: false"),
            ),
            (
                "a list indented under its key takes entries, not settings",
                "guardrails",
                json!({ "num_retries": 2 }),
                Err("configuration section guardrails is a list of entries: write it with entries rather than settings"),
            ),
            (
                "a list at no indentation takes entries, not settings",
                "flat_list",
                json!({ "num_retries": 2 }),
                Err("configuration section flat_list is a list of entries: write it with entries rather than settings"),
            ),
        ];

        for (name, section, settings, want) in cases {
            let map = as_map(settings);
            let got = set_in_section(BODY, section, &SectionWrite::Settings(&map));
            match (want, got) {
                (Ok(fragment), Ok(body)) => assert!(
                    body.contains(fragment),
                    "{name}: emitted body does not carry {fragment:?}:\n{body}"
                ),
                (Err(message), Err(actual)) => assert_eq!(actual, message, "{name}"),
                (want, got) => panic!("{name}: wanted {want:?}, got {got:?}"),
            }
        }
    }

    #[test]
    fn entries_are_addressed_by_identity_never_by_position() {
        let cases: Vec<(&str, &str, Value, Result<&str, &str>)> = vec![
            (
                "an absent section is created carrying the entry",
                "post_call_rules",
                json!([{ "rule_name": "budget-guard" }]),
                Ok("post_call_rules:\n  -\n    rule_name: budget-guard"),
            ),
            (
                "a section declared with nothing in it takes the entry",
                "callbacks",
                json!([{ "callback_name": "langfuse" }]),
                Ok("callbacks:\n  -\n    callback_name: langfuse\nrouter_settings:"),
            ),
            (
                "an identity the section does not carry is appended below the last entry",
                "guardrails",
                json!([{ "guardrail_name": "secret-detection" }]),
                Ok("      mode: post_call\n  -\n    guardrail_name: secret-detection\ncallbacks:"),
            ),
            (
                "an entry opening on the same line as its identity is replaced whole",
                "guardrails",
                json!([{ "guardrail_name": "prompt-injection", "litellm_params": { "mode": "pre_call" } }]),
                Ok("guardrails:\n  -\n    guardrail_name: prompt-injection\n    litellm_params:\n      mode: pre_call\n  -\n    guardrail_name: pii-redaction"),
            ),
            (
                "an entry opened by a bare hyphen is replaced whole",
                "guardrails",
                json!([{ "guardrail_name": "pii-redaction", "litellm_params": { "mode": "logging_only" } }]),
                Ok("  - guardrail_name: prompt-injection\n    litellm_params:\n      mode: during_call\n  -\n    guardrail_name: pii-redaction\n    litellm_params:\n      mode: logging_only\ncallbacks:"),
            ),
            (
                "a list at no indentation is read and appended to at its own indentation",
                "flat_list",
                json!([{ "name": "beta", "weight": 2 }]),
                Ok("flat_list:\n- name: alpha\n  weight: 1\n-\n  name: beta\n  weight: 2"),
            ),
            (
                "two entries are applied in the order the step declared them",
                "callbacks",
                json!([{ "callback_name": "langfuse" }, { "callback_name": "datadog" }]),
                Ok("callbacks:\n  -\n    callback_name: langfuse\n  -\n    callback_name: datadog"),
            ),
            (
                "a mapping of named settings takes settings, not entries",
                "router_settings",
                json!([{ "name": "alpha" }]),
                Err("configuration section router_settings holds named settings: write it with settings rather than entries"),
            ),
        ];

        for (name, section, entries, want) in cases {
            let list = as_list(entries);
            let write = SectionWrite::Entries {
                identity: identity_key_for(section),
                entries: &list,
            };
            let got = set_in_section(BODY, section, &write);
            match (want, got) {
                (Ok(fragment), Ok(body)) => assert!(
                    body.contains(fragment),
                    "{name}: emitted body does not carry {fragment:?}:\n{body}"
                ),
                (Err(message), Err(actual)) => assert_eq!(actual, message, "{name}"),
                (want, got) => panic!("{name}: wanted {want:?}, got {got:?}"),
            }
        }
    }

    fn identity_key_for(section: &str) -> &'static str {
        match section {
            "guardrails" => "guardrail_name",
            "callbacks" => "callback_name",
            "post_call_rules" => "rule_name",
            _ => "name",
        }
    }

    #[test]
    fn an_identity_is_read_in_every_spelling_a_body_carries_it_in() {
        let cases: Vec<(&str, &str, &str, bool)> = vec![
            (
                "a plain scalar",
                "guardrails:\n  - guardrail_name: aporia\n",
                "aporia",
                true,
            ),
            (
                "a double-quoted scalar",
                "guardrails:\n  - guardrail_name: \"aporia\"\n",
                "aporia",
                true,
            ),
            (
                "a single-quoted scalar",
                "guardrails:\n  - guardrail_name: 'aporia'\n",
                "aporia",
                true,
            ),
            (
                "a plain scalar followed by a comment",
                "guardrails:\n  - guardrail_name: aporia # the vendor\n",
                "aporia",
                true,
            ),
            (
                "a member of the same name nested inside the entry",
                "guardrails:\n  - guardrail_name: outer\n    litellm_params:\n      guardrail_name: inner\n",
                "inner",
                false,
            ),
            (
                "an identity the section does not carry",
                "guardrails:\n  - guardrail_name: aporia\n",
                "presidio",
                false,
            ),
        ];

        for (name, body, wanted, replaces) in cases {
            let list = as_list(json!([{ "guardrail_name": wanted, "mode": "pre_call" }]));
            let write = SectionWrite::Entries {
                identity: "guardrail_name",
                entries: &list,
            };
            let got = set_in_section(body, "guardrails", &write).expect(name);
            let entry_count = got.lines().filter(|l| l.trim_start().starts_with('-')).count();
            let want_count = if replaces { 1 } else { 2 };
            assert_eq!(entry_count, want_count, "{name}: emitted body\n{got}");
        }
    }

    #[test]
    fn a_shape_the_step_cannot_express_is_refused() {
        let cases: Vec<(&str, Value, &str)> = vec![
            (
                "an entry that is not a mapping",
                json!(["just-a-string"]),
                "an entry must be a mapping carrying the key that identifies it",
            ),
            (
                "an entry that does not carry the identity key",
                json!([{ "litellm_params": { "mode": "pre_call" } }]),
                "every entry must carry guardrail_name, the key that identifies it, holding a scalar value",
            ),
            (
                "an entry whose identity is not a scalar",
                json!([{ "guardrail_name": { "nested": true } }]),
                "every entry must carry guardrail_name, the key that identifies it, holding a scalar value",
            ),
            (
                "an entry carrying a sequence inside a sequence",
                json!([{ "guardrail_name": "aporia", "modes": [["pre_call"]] }]),
                "a nested sequence is not an expressible setting value",
            ),
        ];

        for (name, entries, message) in cases {
            let list = as_list(entries);
            let write = SectionWrite::Entries {
                identity: "guardrail_name",
                entries: &list,
            };
            match set_in_section(BODY, "guardrails", &write) {
                Err(actual) => assert_eq!(actual, message, "{name}"),
                Ok(body) => panic!("{name}: should refuse; emitted\n{body}"),
            }
        }
    }

    #[test]
    fn every_line_the_request_does_not_touch_is_carried_through() {
        let list = as_list(json!([{ "guardrail_name": "secret-detection" }]));
        let write = SectionWrite::Entries {
            identity: "guardrail_name",
            entries: &list,
        };
        let got = set_in_section(BODY, "guardrails", &write).expect("append");
        for untouched in [
            "model_list:\n  - model_name: fast\n    litellm_params:\n      model: openai/gpt-4o-mini\n",
            "router_settings:\n  routing_strategy: simple-shuffle\n",
            "flat_list:\n- name: alpha\n  weight: 1\n",
            "  - guardrail_name: prompt-injection\n    litellm_params:\n      mode: during_call\n",
        ] {
            assert!(
                got.contains(untouched),
                "the request rewrote a line it did not ask for; {untouched:?} is gone from\n{got}"
            );
        }
        assert!(got.ends_with('\n'), "the body's trailing newline is dropped");
    }
}
