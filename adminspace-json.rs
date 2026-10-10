use serde_json::Value;
use std::io::{self, Read};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let operation = args.next().ok_or("missing operation")?;
    let owner = args.next().unwrap_or_default();
    let peer = args.next().unwrap_or_default();

    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let rows: Vec<Value> = serde_json::from_str(&input)?;

    match operation.as_str() {
        "transport" => {
            let key = format!("@/{owner}/session/transport/unicast/{peer}");
            let found = rows
                .iter()
                .any(|row| row.get("key").and_then(Value::as_str) == Some(key.as_str()));
            println!("{}", if found { "yes" } else { "no" });
        }
        "graph" => {
            let key = format!("@/{owner}/router/linkstate/north");
            let found = rows.iter().any(|row| {
                row.get("key").and_then(Value::as_str) == Some(key.as_str())
                    && row
                        .get("value")
                        .is_some_and(|value| value.to_string().contains(&peer))
            });
            println!("{}", if found { "yes" } else { "no" });
        }
        "dump" => println!("{}", serde_json::to_string_pretty(&rows)?),
        _ => return Err(format!("unknown operation: {operation}").into()),
    }

    Ok(())
}
