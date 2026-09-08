use std::collections::HashMap;

// Credentials belong to the deployment, never to SQL or a fixture row.
pub fn s3_options() -> HashMap<String, String> {
    ["AWS_ENDPOINT_URL", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION",
     "AWS_ALLOW_HTTP", "AWS_VIRTUAL_HOSTED_STYLE_REQUEST", "AWS_S3_ALLOW_UNSAFE_RENAME"]
        .into_iter().filter_map(|key| std::env::var(key).ok().map(|value| (key.to_string(), value)))
        .collect()
}
