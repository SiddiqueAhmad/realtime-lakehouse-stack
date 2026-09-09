use std::collections::HashMap;

use iceberg::io::{
    S3_ACCESS_KEY_ID, S3_DISABLE_CONFIG_LOAD, S3_DISABLE_EC2_METADATA, S3_ENDPOINT,
    S3_PATH_STYLE_ACCESS, S3_REGION, S3_SECRET_ACCESS_KEY,
};

// Credentials belong to the deployment, never to SQL or a fixture row.
pub fn s3_options() -> HashMap<String, String> {
    ["AWS_ENDPOINT_URL", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION",
     "AWS_ALLOW_HTTP", "AWS_VIRTUAL_HOSTED_STYLE_REQUEST", "AWS_S3_ALLOW_UNSAFE_RENAME"]
        .into_iter().filter_map(|key| std::env::var(key).ok().map(|value| (key.to_string(), value)))
        .collect()
}

// Translate the same deployment environment into Iceberg/OpenDAL S3
// properties. MinIO uses path-style requests in this demo; real S3 can set
// AWS_VIRTUAL_HOSTED_STYLE_REQUEST=true and the mapping flips accordingly.
pub fn iceberg_s3_options() -> HashMap<String, String> {
    let mut out = HashMap::new();
    for (env_name, iceberg_name) in [
        ("AWS_ENDPOINT_URL", S3_ENDPOINT),
        ("AWS_ACCESS_KEY_ID", S3_ACCESS_KEY_ID),
        ("AWS_SECRET_ACCESS_KEY", S3_SECRET_ACCESS_KEY),
        ("AWS_REGION", S3_REGION),
    ] {
        if let Ok(value) = std::env::var(env_name) {
            out.insert(iceberg_name.to_string(), value);
        }
    }
    if let Ok(value) = std::env::var("AWS_VIRTUAL_HOSTED_STYLE_REQUEST") {
        let virtual_hosted = matches!(value.to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on");
        out.insert(S3_PATH_STYLE_ACCESS.to_string(), (!virtual_hosted).to_string());
    }
    if out.contains_key(S3_ENDPOINT) {
        // A custom endpoint is explicit deployment configuration; do not spend
        // time probing local cloud metadata/config files for credentials.
        out.insert(S3_DISABLE_CONFIG_LOAD.to_string(), "true".to_string());
        out.insert(S3_DISABLE_EC2_METADATA.to_string(), "true".to_string());
    }
    out
}
