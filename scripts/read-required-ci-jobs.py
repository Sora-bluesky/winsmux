"""Derive every required CI matrix member from frozen workflow bytes.

This is a read-only producer of a job inventory, not an approval or CI result.
"""
import hashlib
import itertools
import json
import re
import sys
from pathlib import Path

import yaml

for stream in (sys.stdout, sys.stderr):
    stream.reconfigure(encoding="utf-8")

REQUIRED = (
    "secret-scan", "public-surface", "install-e2e", "native-lifecycle-source",
    "common-contract-drift", "pester", "core-build-test", "desktop-build-test",
    "desktop-nsis-lifecycle", "task811-receipt-bind", "helper-linux-negatives",
    "workspace-journey-native",
)


class StrictLoader(yaml.SafeLoader):
    pass


def mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError("Duplicate workflow mapping key")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)


def derive(raw):
    workflow = yaml.load(raw.decode("utf-8", errors="strict"), Loader=StrictLoader)
    jobs = workflow["jobs"]
    needs = jobs["merge-gate"]["needs"]
    if not set(REQUIRED).issubset(jobs) or not isinstance(needs, list) or len(needs) != len(REQUIRED) or set(needs) != set(REQUIRED):
        raise ValueError("Required twelve CI categories or aggregate dependencies differ")
    names = {}
    for job_id in (*REQUIRED, "merge-gate"):
        job = jobs[job_id]
        template = job.get("name", job_id)
        if not isinstance(template, str) or not template.strip():
            raise ValueError("Nonempty static CI job name required")
        matrix = job.get("strategy", {}).get("matrix")
        if matrix is None:
            rows = [{}]
        elif not isinstance(matrix, dict) or "exclude" in matrix:
            raise ValueError("Unsupported dynamic/exclusion matrix; refreeze workflow contract")
        elif set(matrix) == {"include"}:
            rows = matrix["include"]
            if not isinstance(rows, list) or not rows or not all(isinstance(row, dict) for row in rows):
                raise ValueError("Closed static include matrix required")
        else:
            if "include" in matrix or not matrix:
                raise ValueError("Mixed include/axes matrix needs an explicit contract")
            if not all(isinstance(values, list) and values and all(isinstance(value, str) for value in values)
                       for values in matrix.values()):
                raise ValueError("Static string matrix axes required")
            rows = [dict(zip(matrix, values)) for values in itertools.product(*matrix.values())]
        expanded = []
        for row in rows:
            def replace(match):
                value = row.get(match.group(1))
                if not isinstance(value, str) or not value or "${{" in value:
                    raise ValueError("Static matrix name value required")
                return value
            name = re.sub(r"\$\{\{\s*matrix\.([a-zA-Z0-9_]+)\s*\}\}", replace, template)
            if "${{" in name or name in expanded:
                raise ValueError("Unresolved/duplicate expanded CI name")
            expanded.append(name)
        names[job_id] = expanded
    all_names = [name for group in names.values() for name in group]
    if len(set(all_names)) != len(all_names):
        raise ValueError("Required CI categories have ambiguous display names")
    return {"schema": "winsmux-required-ci-inventory/v1", "workflow_sha256": hashlib.sha256(raw).hexdigest(),
            "required_categories": list(REQUIRED), "names": names, "required_job_count": len(all_names),
            "python_version": sys.version.split()[0], "yaml_version": yaml.__version__,
            "publication_admitted": False}


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3 or not re.fullmatch(r"[a-f0-9]{64}", sys.argv[2]):
            raise ValueError("Exact workflow file and independently observed SHA required")
        raw = Path(sys.argv[1]).read_bytes()
        if hashlib.sha256(raw).hexdigest() != sys.argv[2]:
            raise ValueError("Workflow differs from observed bytes")
        print(json.dumps(derive(raw), ensure_ascii=False))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
