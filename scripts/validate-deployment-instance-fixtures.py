#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
"""Offline Draft 2020-12 meta-validation + fixture checks. Requires jsonschema 4.x.

No host/path/profile/runtime/policy is resolved. Collection ID uniqueness
checks supplement JSON Schema, matching the fixture-only Zig helper.
"""
import json
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures/deployment-instances"


def load(path):
    # Match Zig's strict JSON boundary: duplicate object keys are invalid.
    def strict_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("DuplicateField")
            result[key] = value
        return result

    return json.loads(path.read_text(), object_pairs_hook=strict_object)


def semantic_error(instances):
    ids = set()
    for instance in instances:
        if instance["id"] in ids:
            return "DuplicateInstanceId"
        ids.add(instance["id"])
    return None


def check(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    schema = load(ROOT / "schemas/deployment-instance-0.1.schema.json")
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    valid = []
    for path in sorted((FIXTURES / "valid").glob("*.json")):
        instance = load(path)
        validator.validate(instance)
        valid.append(instance)
    check(len(valid) >= 5, "Missing valid fixtures")
    check(semantic_error(valid) is None, "Invalid valid-fixture collection")

    manifest = load(FIXTURES / "invalid-cases.json")
    listed = [case["file"] for case in manifest]
    check(len(listed) == len(set(listed)), "Duplicate manifest entries")
    check(set(listed) == {p.name for p in (FIXTURES / "invalid").glob("*.json")},
          "Invalid fixture/manifest mismatch")
    for case in manifest:
        document = load(FIXTURES / "invalid" / case["file"])
        instances = document if case.get("collection") else [document]
        errors = [error for instance in instances for error in validator.iter_errors(instance)]
        if "schema_keyword" in case:
            check(any(error.validator == case["schema_keyword"] for error in errors),
                  f"Unexpected schema result: {case['file']}")
        else:
            check(not errors, f"Unexpected schema failure: {case['file']}")
            check(semantic_error(instances) == case["semantic_error"],
                  f"Unexpected semantic result: {case['file']}")

    print(f"Schema meta-validation passed; {len(valid)} valid and "
          f"{len(manifest)} invalid fixtures checked (including semantic/collection checks).")


if __name__ == "__main__":
    main()
