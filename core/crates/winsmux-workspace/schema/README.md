# Workspace contract projections

Rust declarations and validators in `winsmux-workspace` own this protocol. Run
`cargo run -p winsmux-workspace --example export_contract` to generate the three
Draft 7 schemas and `winsmux-app/src/generated/workspace-contract.ts`. Add
`-- --check` for a read-only comparison that fails on missing or changed files.
TypeScript is emitted from these schemas, without a second field inventory.

The TypeScript projection preserves required and optional properties, explicit
nulls, references, array elements, literal discriminants, and grouped unions and
intersections. A closed empty object rejects fresh extra keys. An unconstrained
object factor in a union is `object`, so it does not add an index signature that
either removes valid branches or admits extra keys. Only the enclosing closed
branches give this factor its JSON object shape; TypeScript's bare `object` also
includes arrays and other JavaScript objects. Extra-key checks apply to fresh
object literals, not arbitrary structurally assignable variables.

TypeScript does not enforce integer/range restrictions, string patterns or
lengths, collection sizes or uniqueness, exclusive `oneOf` matching, `not`, or
the `if`/`then` predicates. The schemas and Rust validators retain those checks;
in particular an events array's length, a nonzero exit code, conditional grants,
and selection dependencies cannot be inferred from type checking alone. Boolean
true schemas, empty schemas and predicates without a structural restriction use
`unknown`; missing array `items` means unconstrained elements. Known element
types survive nullable types and intersections with such array predicates.
The exporter supports the current three Rust-generated schemas, including their
closed objects, `oneOf`/`anyOf` unions and properties-only constraint branches.
It rejects `allOf`, unrecognized schema vocabulary, tuple `items`, schema-valued
`additionalProperties`, and open typed property objects rather than silently
widening or narrowing them. Both export and `--check` prepare all four artifacts
through the same validation before any output can be written; unsupported input
returns no artifact set and preserves the existing files. This is not a general
Draft 7 compiler.

Use `parse_request`, `parse_response`, and `parse_snapshot` with raw UTF-8 bytes.
Use `canonical_request`, `serialize_response`, and `serialize_snapshot` to emit
validated bytes. Both response functions require the originating valid request.
Parsing failures return only one of the fixed `ContractError` codes; adapters
must not extract an operation ID from a rejected request or fabricate a response.

The schemas enforce object structure, required explicit nulls, ID syntax, scalar
ranges, set uniqueness, operation payloads and representable local state rules.
They cannot detect duplicate JSON keys, integer lexemes, UTF-8 byte counts or
container depth. Cross-reference identity, request correlation, scope subsets
and runtime-state relations remain Rust checks. A successful schema validation
alone is therefore insufficient to accept a message or snapshot.

Counters use decimal JSON integer lexemes in `0..=9007199254740991`; positive
values start at one. Fractional/exponent spellings and negative zero are rejected
even if another JSON parser converts them to mathematical integers. Exit codes
use signed 32-bit decimal integers, also excluding negative zero. IDs are
domain-specific lowercase RFC-variant UUID v4 values. Timestamps preserve their
input spelling and use the v1 UTC RFC3339 subset with mandatory seconds `00..59`,
optional fractional seconds and a final `Z`. Second `60` is rejected; no leap-second
table or external lookup is involved. Calendar validity is also in the schema
pattern and does not depend on optional JSON Schema format plugins.

Every input and output is at most 1 MiB. The existing serde_json recursion guard
is retained. Layout construction and serialization use the same total JSON
container depth; deep private test values are rejected and dropped iteratively.
Canonical JSON sorts object keys and declared string sets, preserves other array
orders, and does not normalize strings, Unicode, newlines or layout child order.
Snapshot project, pane and layout collections are sorted by ID.

`WireError` messages and retryability are fixed by `ErrorCode`. Seventeen codes
describe service failures of valid requests. `unsupported_version` is reserved
in v1; a request parse failure is never converted to that response. Retryability
does not authorize automatic replay. Run observations carry a checked state
relationship, not proof that an OS or provider event actually occurred.

This crate performs no authorization, PTY input, process observation, file-handle
validation, persistence or GUI/CLI/MCP dispatch. Those owners must consume these
types and prove their own effects, input sequencing and privacy projections.

Run `cargo test -p winsmux-workspace` for the whole contract suite. Its schema
comparison uses the existing Python `jsonschema` package. The TypeScript test
uses the existing `winsmux-app/node_modules/typescript` installation. These tests
compile real literals from the same full positive and structural-negative fixture
inventory, all success/error payloads, all event kinds, snapshots, nullable
element use, and sibling schema composition cases. No type casts or untyped JSON
parsing stand in for constructing valid values. These tests do not install
packages. Windows tests run without a PTY; the existing MSVC
environment resolver can select an installed toolchain when the ambient linker
environment is incomplete.

The four generated paths have explicit `text eol=lf` Git attributes so a Windows
checkout preserves the bytes checked by `export_contract --check`.

`shell.launch` and `agent.launch` accept two closed request shapes. The legacy
shape omits `expected_current_run_id`. The guarded shape requires that field:
null means no current run, and a UUID means that exact current run. Identity is
checked after pane authorization and again before resuming the prepared child.
The guard does not prove process exit; existing occupancy rules still apply.
Omission, null, and UUID have distinct canonical bytes and replay identities.
Clients using this guarantee must never retry a rejected guarded request without
its guard. Schema version 1 and legacy request semantics remain unchanged.
