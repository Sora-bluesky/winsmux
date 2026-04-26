use serde::{Deserialize, Deserializer};
use serde_json::{Map, Value};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EventRecord {
    pub timestamp: String,
    pub event: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub session: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub message: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub label: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub pane_id: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub role: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub status: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub exit_reason: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub source: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub branch: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub run_id: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub task_id: String,
    #[serde(default, deserialize_with = "deserialize_event_string")]
    pub head_sha: String,
    #[serde(default, deserialize_with = "deserialize_event_data")]
    pub data: Value,
}

impl EventRecord {
    pub fn validate(&self) -> Result<(), String> {
        if self.timestamp.trim().is_empty() {
            return Err("event.timestamp must be non-empty".to_string());
        }

        if self.event.trim().is_empty() {
            return Err("event.event must be non-empty".to_string());
        }

        Ok(())
    }
}

pub fn parse_event_jsonl(content: &str) -> Result<Vec<EventRecord>, String> {
    let mut records = Vec::new();

    for (index, line) in content.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }

        let record: EventRecord = serde_json::from_str(line)
            .map_err(|err| format!("failed to parse event line {}: {}", index + 1, err))?;
        record
            .validate()
            .map_err(|err| format!("event line {}: {}", index + 1, err))?;
        records.push(record);
    }

    Ok(records)
}

fn deserialize_event_string<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(Option::<String>::deserialize(deserializer)?.unwrap_or_default())
}

fn deserialize_event_data<'de, D>(deserializer: D) -> Result<Value, D::Error>
where
    D: Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    match value {
        None => Ok(Value::Object(Map::new())),
        Some(Value::Null) => Ok(Value::Object(Map::new())),
        Some(Value::Object(map)) => Ok(Value::Object(map)),
        Some(_) => Err(serde::de::Error::custom(
            "event.data must be an object or null",
        )),
    }
}
