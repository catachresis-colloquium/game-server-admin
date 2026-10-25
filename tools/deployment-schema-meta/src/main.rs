// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Development-only independent full Draft checker; no GSA runtime dependency.
use serde_json::Value;
use std::{collections::HashSet, error::Error, fs};
fn main() -> Result<(), Box<dyn Error>> {
    let path = std::env::args().nth(1).ok_or("expected schema path")?;
    let schema: Value = serde_json::from_slice(&fs::read(path)?)?;
    if schema["$schema"] != "https://json-schema.org/draft/2020-12/schema" {
        return Err("expected Draft 2020-12".into());
    }
    jsonschema::draft202012::meta::validate(&schema).map_err(|e| e.to_string())?;
    let validator = jsonschema::validator_for(&schema)?;
    let root = "fixtures/deployment-instances";
    let mut valid_count = 0;
    for entry in fs::read_dir(format!("{root}/valid"))? {
        let path = entry?.path();
        if path.extension().and_then(|x| x.to_str()) != Some("json") {
            continue;
        }
        let value: Value = serde_json::from_slice(&fs::read(path)?)?;
        validator.validate(&value).map_err(|e| e.to_string())?;
        valid_count += 1;
    }
    let cases: Value = serde_json::from_slice(&fs::read(format!("{root}/invalid-cases.json"))?)?;
    for case in cases.as_array().ok_or("invalid manifest")? {
        let value: Value = serde_json::from_slice(&fs::read(format!(
            "{root}/invalid/{}",
            case["file"].as_str().ok_or("missing file")?
        ))?)?;
        if case["collection"] == true {
            let mut ids = HashSet::new();
            let mut duplicate = false;
            for instance in value.as_array().ok_or("invalid collection")? {
                validator.validate(instance).map_err(|e| e.to_string())?;
                if !ids.insert(instance["id"].as_str().ok_or("missing id")?) {
                    duplicate = true;
                }
            }
            if !duplicate {
                return Err("expected duplicate collection ID".into());
            }
        } else {
            let keyword = case["schema_keyword"]
                .as_str()
                .ok_or("missing expected keyword")?;
            if !validator.iter_errors(&value).any(|e| {
                e.schema_path()
                    .to_string()
                    .ends_with(&format!("/{keyword}"))
            }) {
                return Err(format!("unexpected schema result: {}", case["file"]).into());
            }
        }
    }
    println!(
        "Draft 2020-12 meta-schema and arbitrary-precision fixture validation passed ({valid_count} valid / {} invalid)",
        cases.as_array().unwrap().len()
    );
    Ok(())
}
#[test]
fn integer_semantics_preserve_source_precision() {
    let schema = serde_json::json!({"type":"integer","minimum":1,"maximum":65535});
    let validator = jsonschema::validator_for(&schema).unwrap();
    for (raw, valid) in [
        ("25565", true),
        ("25565.0", true),
        ("2.5565e4", true),
        ("25565.5", false),
        ("25565.0000000000000000000000000000000001", false),
        ("\"25565\"", false),
    ] {
        let value: Value = serde_json::from_str(raw).unwrap();
        assert_eq!(validator.is_valid(&value), valid, "{raw}");
    }
}
