import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

function normalizeLineEndings(value) {
  return value.replaceAll("\r\n", "\n");
}

function quote(value) {
  return JSON.stringify(value);
}

function pythonTuple(values) {
  const inner = values.map((item) => `    ${quote(item)},`).join("\n");
  return `(\n${inner}\n)`;
}

function typescriptArray(values) {
  const inner = values.map((item) => `  ${quote(item)},`).join("\n");
  return `[\n${inner}\n]`;
}

function stringList(artifact, key) {
  const value = artifact[key];
  assert.ok(Array.isArray(value), `${key} must be an array`);
  for (const item of value) {
    assert.equal(typeof item, "string", `${key} entries must be strings`);
  }
  return value;
}

const NAME_LISTS = [
  ["methods", "CONTROL_PIPE_METHODS"],
  ["desktop_methods", "DESKTOP_METHODS"],
  ["pty_methods", "PTY_METHODS"],
  ["operator_methods", "OPERATOR_METHODS"],
  ["pairing_methods", "PAIRING_METHODS"],
  ["internal_desktop_methods_excluded", "INTERNAL_DESKTOP_METHODS_EXCLUDED"],
];

const SCHEMA_KEYWORDS = new Set([
  "$schema",
  "title",
  "type",
  "properties",
  "required",
  "definitions",
  "$ref",
  "items",
  "anyOf",
  "additionalProperties",
  "format",
  "minimum",
  "default",
]);

const IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const LOCAL_DEF_REF_RE = /^#\/definitions\/([A-Za-z_][A-Za-z0-9_]*)$/;
const PRIMITIVE_PY = {
  string: "str",
  boolean: "bool",
  integer: "int",
  number: "float",
};
const PRIMITIVE_TS = {
  string: "string",
  boolean: "boolean",
  integer: "number",
  number: "number",
};
const HONESTY =
  "Types mirror the v2 contract schemas; the desktop applies additional handler validation and accepts snake_case aliases not shown here. No runtime validation is performed.";

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function assertIdent(name, label) {
  assert.equal(typeof name, "string", `${label} must be a string`);
  assert.ok(IDENT_RE.test(name), `${label} is not a valid identifier`);
}

function assertKnownKeywords(node, path) {
  if (node === true) {
    return;
  }
  if (node === false) {
    assert.fail(`boolean schema false is not in the closed vocabulary at ${path}`);
  }
  if (Array.isArray(node)) {
    node.forEach((item, index) => {
      if (item && typeof item === "object") {
        assertKnownKeywords(item, `${path}[${index}]`);
      }
    });
    return;
  }
  if (!isPlainObject(node)) {
    return;
  }
  for (const key of Object.keys(node)) {
    assert.ok(
      SCHEMA_KEYWORDS.has(key),
      `unrecognized schema keyword ${quote(key)} at ${path}`,
    );
  }
  if (node.properties !== undefined) {
    assert.ok(isPlainObject(node.properties), `properties must be an object at ${path}`);
    for (const [key, value] of Object.entries(node.properties)) {
      assertKnownKeywords(value, `${path}.properties.${key}`);
    }
  }
  if (node.definitions !== undefined) {
    assert.ok(isPlainObject(node.definitions), `definitions must be an object at ${path}`);
    for (const [key, value] of Object.entries(node.definitions)) {
      assertIdent(key, "definition name");
      assertKnownKeywords(value, `${path}.definitions.${key}`);
    }
  }
  if (node.items !== undefined) {
    assertKnownKeywords(node.items, `${path}.items`);
  }
  if (node.anyOf !== undefined) {
    assert.ok(Array.isArray(node.anyOf), `anyOf must be an array at ${path}`);
    assertKnownKeywords(node.anyOf, `${path}.anyOf`);
  }
  if (node.additionalProperties !== undefined) {
    assertKnownKeywords(node.additionalProperties, `${path}.additionalProperties`);
  }
}

function isBareDefaultNull(node) {
  return (
    isPlainObject(node) &&
    Object.keys(node).length === 1 &&
    Object.prototype.hasOwnProperty.call(node, "default") &&
    node.default === null
  );
}

function primitiveExpr(jsonType, lang) {
  const table = lang === "python" ? PRIMITIVE_PY : PRIMITIVE_TS;
  const mapped = table[jsonType];
  assert.ok(mapped, `unsupported primitive type ${quote(String(jsonType))}`);
  return mapped;
}

function nullablePrimitive(type) {
  if (!Array.isArray(type) || type.length !== 2) {
    return null;
  }
  const [first, second] = type;
  if (first === "null" && PRIMITIVE_PY[second]) {
    return second;
  }
  if (second === "null" && PRIMITIVE_PY[first]) {
    return first;
  }
  return null;
}

function resolveRef(ref, path) {
  assert.equal(typeof ref, "string", `$ref must be a string at ${path}`);
  const match = LOCAL_DEF_REF_RE.exec(ref);
  assert.ok(match, `unsupported $ref at ${path}`);
  return match[1];
}

function optionUnion(inner, lang) {
  return lang === "python" ? `${inner} | None` : `${inner} | null`;
}

function arrayExpr(inner, lang) {
  if (lang === "python") {
    return `list[${inner}]`;
  }
  return inner.includes("|") ? `(${inner})[]` : `${inner}[]`;
}

function mapExpr(inner, lang) {
  return lang === "python" ? `dict[str, ${inner}]` : `Record<string, ${inner}>`;
}

function typeExpr(node, lang, path) {
  if (node === true) {
    return lang === "python" ? "Any" : "unknown";
  }
  if (node === false) {
    assert.fail(`boolean schema false is not in the closed vocabulary at ${path}`);
  }
  assert.ok(isPlainObject(node), `schema node must be an object at ${path}`);

  if (isBareDefaultNull(node)) {
    return lang === "python" ? "Any" : "unknown";
  }

  if (node.$ref !== undefined) {
    return resolveRef(node.$ref, path);
  }

  if (node.anyOf !== undefined) {
    assert.ok(Array.isArray(node.anyOf) && node.anyOf.length === 2, `anyOf must have two branches at ${path}`);
    let refName;
    let sawNull = false;
    for (const [index, branch] of node.anyOf.entries()) {
      const branchPath = `${path}.anyOf[${index}]`;
      assert.ok(isPlainObject(branch), `anyOf branch must be an object at ${branchPath}`);
      if (branch.$ref !== undefined) {
        assert.equal(refName, undefined, `anyOf has multiple $ref branches at ${path}`);
        refName = resolveRef(branch.$ref, branchPath);
      } else if (branch.type === "null") {
        sawNull = true;
      } else {
        assert.fail(`anyOf branch is not a local $ref or null type at ${branchPath}`);
      }
    }
    assert.ok(refName && sawNull, `anyOf must be a local $ref with a null branch at ${path}`);
    return optionUnion(refName, lang);
  }

  const nullable = nullablePrimitive(node.type);
  if (nullable) {
    return optionUnion(primitiveExpr(nullable, lang), lang);
  }

  if (typeof node.type === "string" && PRIMITIVE_PY[node.type]) {
    return primitiveExpr(node.type, lang);
  }

  if (node.type === "array") {
    assert.ok(node.items !== undefined, `array schema requires items at ${path}`);
    return arrayExpr(typeExpr(node.items, lang, `${path}.items`), lang);
  }

  if (node.type === "object") {
    const hasProperties = node.properties !== undefined;
    const hasAdditional = node.additionalProperties !== undefined;
    if (hasProperties && hasAdditional) {
      assert.fail(`object schema mixes properties and additionalProperties at ${path}`);
    }
    if (hasAdditional && !hasProperties) {
      return mapExpr(
        typeExpr(node.additionalProperties, lang, `${path}.additionalProperties`),
        lang,
      );
    }
    assert.fail(`inline object schema must be a named $ref at ${path}`);
  }

  assert.fail(`unsupported schema form at ${path}`);
}

function requiredSet(schema, path) {
  if (schema.required === undefined) {
    return new Set();
  }
  assert.ok(Array.isArray(schema.required), `required must be an array at ${path}`);
  const props = schema.properties ?? {};
  assert.ok(isPlainObject(props), `properties must be an object at ${path}`);
  const names = new Set();
  for (const name of schema.required) {
    assert.equal(typeof name, "string", `required entry must be a string at ${path}`);
    assert.ok(
      Object.prototype.hasOwnProperty.call(props, name),
      `required key is missing from properties at ${path}`,
    );
    names.add(name);
  }
  return names;
}

function tsKey(name) {
  return IDENT_RE.test(name) ? name : JSON.stringify(name);
}

function emitObjectType(name, schema, lang, path) {
  assertIdent(name, "type name");
  assert.ok(isPlainObject(schema), `named type must be an object schema at ${path}`);
  assert.equal(schema.type, "object", `named type must have type object at ${path}`);
  const hasProperties = schema.properties !== undefined;
  const hasAdditional = schema.additionalProperties !== undefined;
  if (hasProperties && hasAdditional) {
    assert.fail(`named type mixes properties and additionalProperties at ${path}`);
  }
  if (hasAdditional && !hasProperties) {
    assert.fail(`named type must not be a map schema at ${path}`);
  }
  const props = hasProperties ? schema.properties : {};
  assert.ok(isPlainObject(props), `properties must be an object at ${path}`);
  const required = requiredSet(schema, path);
  const fields = Object.keys(props);
  if (lang === "python") {
    if (fields.length === 0) {
      return `class ${name}(TypedDict):\n    pass`;
    }
    const lines = fields.map((field) => {
      assertIdent(field, "field name");
      const expr = typeExpr(props[field], lang, `${path}.properties.${field}`);
      const annotated = required.has(field) ? expr : `NotRequired[${expr}]`;
      return `    ${field}: ${annotated}`;
    });
    return `class ${name}(TypedDict):\n${lines.join("\n")}`;
  }
  if (fields.length === 0) {
    return `export interface ${name} {\n}`;
  }
  const lines = fields.map((field) => {
    assertIdent(field, "field name");
    const expr = typeExpr(props[field], lang, `${path}.properties.${field}`);
    const optional = required.has(field) ? "" : "?";
    return `  ${tsKey(field)}${optional}: ${expr};`;
  });
  return `export interface ${name} {\n${lines.join("\n")}\n}`;
}

function collectRefNames(node, acc = new Set()) {
  if (node === true || node === false || node == null) {
    return acc;
  }
  if (Array.isArray(node)) {
    for (const item of node) {
      collectRefNames(item, acc);
    }
    return acc;
  }
  if (!isPlainObject(node)) {
    return acc;
  }
  if (typeof node.$ref === "string") {
    const match = LOCAL_DEF_REF_RE.exec(node.$ref);
    if (match) {
      acc.add(match[1]);
    }
  }
  for (const [key, value] of Object.entries(node)) {
    if (key === "definitions") {
      continue;
    }
    collectRefNames(value, acc);
  }
  return acc;
}

function sortNamedTypes(namedOrder) {
  const byName = new Map(namedOrder.map((item) => [item.name, item]));
  const indexOf = new Map(namedOrder.map((item, index) => [item.name, index]));
  const indegree = new Map(namedOrder.map((item) => [item.name, 0]));
  const dependents = new Map(namedOrder.map((item) => [item.name, []]));

  for (const item of namedOrder) {
    for (const dep of collectRefNames(item.schema)) {
      if (!byName.has(dep)) {
        continue;
      }
      if (dep === item.name) {
        assert.fail(`typed schema graph has a cycle`);
      }
      dependents.get(dep).push(item.name);
      indegree.set(item.name, indegree.get(item.name) + 1);
    }
  }
  for (const names of dependents.values()) {
    names.sort((a, b) => indexOf.get(a) - indexOf.get(b));
  }

  const ready = namedOrder
    .filter((item) => indegree.get(item.name) === 0)
    .map((item) => item.name);
  const result = [];
  while (ready.length > 0) {
    const name = ready.shift();
    result.push(byName.get(name));
    for (const next of dependents.get(name)) {
      const remaining = indegree.get(next) - 1;
      indegree.set(next, remaining);
      if (remaining === 0) {
        ready.push(next);
        ready.sort((a, b) => indexOf.get(a) - indexOf.get(b));
      }
    }
  }
  assert.equal(
    result.length,
    namedOrder.length,
    "typed schema graph has a cycle",
  );
  return result;
}

function collectTypedSurface(artifact) {
  const schemas = artifact.schemas;
  assert.ok(isPlainObject(schemas), "schemas must be an object");
  const namedSchemas = new Map();
  const namedOrder = [];
  const methodBindings = [];

  function register(name, schema, path) {
    assertIdent(name, "type name");
    const existing = namedSchemas.get(name);
    if (existing !== undefined) {
      assert.deepEqual(
        existing,
        schema,
        `duplicate type name is not structurally equal at ${path}`,
      );
      return;
    }
    namedSchemas.set(name, schema);
    namedOrder.push({ name, schema, path });
  }

  for (const methodName of Object.keys(schemas)) {
    assert.equal(typeof methodName, "string", "schemas keys must be strings");
    const entry = schemas[methodName];
    assert.ok(isPlainObject(entry), `schema entry must be an object at ${methodName}`);
    const sides = [];
    for (const side of Object.keys(entry)) {
      const schema = entry[side];
      const path = `${methodName}.${side}`;
      assert.ok(isPlainObject(schema), `schema must be an object at ${path}`);
      assertKnownKeywords(schema, path);
      if (schema.definitions !== undefined) {
        assert.ok(isPlainObject(schema.definitions), `definitions must be an object at ${path}`);
        for (const defName of Object.keys(schema.definitions)) {
          register(defName, schema.definitions[defName], `${path}.definitions.${defName}`);
        }
      }
      assert.equal(typeof schema.title, "string", `schema title must be a string at ${path}`);
      register(schema.title, schema, path);
      sides.push({ side, title: schema.title });
    }
    methodBindings.push({ methodName, sides });
  }

  return { namedOrder: sortNamedTypes(namedOrder), methodBindings };
}

function renderPythonTyped(surface) {
  const classes = surface.namedOrder.map(({ name, schema, path }) =>
    emitObjectType(name, schema, "python", path),
  );
  return `# ${HONESTY}
# Requires Python >= 3.11 (TypedDict + typing.NotRequired).

from typing import Any, NotRequired, TypedDict

${classes.join("\n\n")}`;
}

function renderTypeScriptTyped(surface) {
  const interfaces = surface.namedOrder.map(({ name, schema, path }) =>
    emitObjectType(name, schema, "typescript", path),
  );
  const indexLines = surface.methodBindings.map(({ methodName, sides }) => {
    const inner = sides
      .map(({ side, title }) => `    ${tsKey(side)}: ${title};`)
      .join("\n");
    return `  ${tsKey(methodName)}: {\n${inner}\n  };`;
  });
  return `// ${HONESTY}

${interfaces.join("\n\n")}

export interface ControlPlaneSchemas {
${indexLines.join("\n")}
}`;
}

function renderPython(artifact) {
  assert.equal(typeof artifact.version, "number", "version must be a number");
  const lists = NAME_LISTS.map(
    ([key, name]) => `${name} = ${pythonTuple(stringList(artifact, key))}`,
  ).join("\n\n");
  const surface = collectTypedSurface(artifact);
  return `# <auto-generated>
# Source: docs/control-plane-contract.v2.json
# Generated by winsmux-app/scripts/generate-control-plane-bindings.mjs.
# Do not edit by hand.

CONTROL_PLANE_CONTRACT_VERSION = ${artifact.version}

${lists}

${renderPythonTyped(surface)}
`;
}

function renderTypeScript(artifact) {
  assert.equal(typeof artifact.version, "number", "version must be a number");
  const lists = NAME_LISTS.map(
    ([key, name]) => `export const ${name} = ${typescriptArray(stringList(artifact, key))} as const;`,
  ).join("\n\n");
  const surface = collectTypedSurface(artifact);
  return `// <auto-generated>
// Source: docs/control-plane-contract.v2.json
// Generated by winsmux-app/scripts/generate-control-plane-bindings.mjs.
// Do not edit by hand.

export const CONTROL_PLANE_CONTRACT_VERSION = ${artifact.version} as const;

${lists}

${renderTypeScriptTyped(surface)}
`;
}

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..", "..");
const artifactPath = path.join(repoRoot, "docs", "control-plane-contract.v2.json");
const pythonPath = path.join(repoRoot, "sdk", "python", "control_plane_contract.py");
const typescriptPath = path.join(repoRoot, "sdk", "typescript", "control-plane-contract.ts");

const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
const pythonRendered = renderPython(artifact);
const typescriptRendered = renderTypeScript(artifact);

const args = new Set(process.argv.slice(2));
const checkOnly = args.has("--check");

if (checkOnly) {
  const pythonCurrent = await readFile(pythonPath, "utf8");
  assert.equal(
    normalizeLineEndings(pythonCurrent),
    pythonRendered,
    `${pythonPath} is stale; run npm run generate:control-plane-bindings`,
  );
  const typescriptCurrent = await readFile(typescriptPath, "utf8");
  assert.equal(
    normalizeLineEndings(typescriptCurrent),
    typescriptRendered,
    `${typescriptPath} is stale; run npm run generate:control-plane-bindings`,
  );
  console.log("control-plane-bindings: ok");
} else {
  await writeFile(pythonPath, pythonRendered, "utf8");
  await writeFile(typescriptPath, typescriptRendered, "utf8");
  console.log(`control-plane-bindings: wrote ${path.relative(process.cwd(), pythonPath)}`);
  console.log(`control-plane-bindings: wrote ${path.relative(process.cwd(), typescriptPath)}`);
}
