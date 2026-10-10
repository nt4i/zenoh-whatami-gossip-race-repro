use serde_json::Value;
use std::io::{self, Read};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let operation = args.next().ok_or("missing operation")?;
    let locator = args.next().unwrap_or_default();
    let owner = args.next().unwrap_or_default();
    let peer = args.next().unwrap_or_default();

    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let rows: Vec<Value> = serde_json::from_str(&input)?;

    match operation.as_str() {
        "id" => {
            let zid = rows.iter().find_map(|row| {
                let key = row.get("key")?.as_str()?;
                if !key.ends_with("/router") {
                    return None;
                }
                let value = row.get("value")?;
                let locators = value.get("locators")?.as_array()?;
                if !locators
                    .iter()
                    .any(|item| item.as_str() == Some(locator.as_str()))
                {
                    return None;
                }
                value.get("zid")?.as_str()
            });
            match zid {
                Some(zid) => println!("{zid}"),
                None => std::process::exit(1),
            }
        }
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
