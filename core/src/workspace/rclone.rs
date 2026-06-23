use crate::connection::{S3ConnectionConfig, S3Credential};

pub struct MountExecPlan {
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
}

pub fn rclone_env(
    remote: &str,
    config: &S3ConnectionConfig,
    cred: &S3Credential,
) -> Vec<(String, String)> {
    let prefix = format!("RCLONE_CONFIG_{}", remote.to_ascii_uppercase());
    vec![
        (format!("{prefix}_TYPE"), "s3".into()),
        (format!("{prefix}_PROVIDER"), "Other".into()),
        (
            format!("{prefix}_ACCESS_KEY_ID"),
            cred.access_key_id.clone(),
        ),
        (
            format!("{prefix}_SECRET_ACCESS_KEY"),
            cred.secret_access_key.clone(),
        ),
        (format!("{prefix}_ENDPOINT"), config.endpoint.clone()),
        (format!("{prefix}_REGION"), config.region.clone()),
        (
            format!("{prefix}_FORCE_PATH_STYLE"),
            config.path_style.to_string(),
        ),
    ]
}

pub fn remote_path(remote: &str, config: &S3ConnectionConfig) -> String {
    let prefix = config.base_prefix.trim_matches('/');
    if prefix.is_empty() {
        format!("{remote}:{}", config.bucket)
    } else {
        format!("{remote}:{}/{prefix}", config.bucket)
    }
}

pub fn mount_exec_plan(
    container: &str,
    remote: &str,
    config: &S3ConnectionConfig,
    cred: &S3Credential,
    mountpoint: &str,
) -> MountExecPlan {
    let env = rclone_env(remote, config, cred);
    let mut argv = vec!["docker", "exec", "-d"]
        .into_iter()
        .map(String::from)
        .collect::<Vec<_>>();
    for (name, _) in &env {
        argv.push("-e".into());
        argv.push(name.clone());
    }
    argv.extend([
        container.to_string(),
        "rclone".into(),
        "mount".into(),
        remote_path(remote, config),
        mountpoint.to_string(),
        "--vfs-cache-mode".into(),
        "writes".into(),
        "--vfs-write-back".into(),
        "0s".into(),
        "--allow-other".into(),
    ]);

    MountExecPlan { argv, env }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(base_prefix: &str) -> S3ConnectionConfig {
        S3ConnectionConfig {
            display_name: "Minio".into(),
            endpoint: "http://127.0.0.1:9000".into(),
            region: "us-east-1".into(),
            bucket: "bucket".into(),
            base_prefix: base_prefix.into(),
            path_style: true,
        }
    }

    fn credential() -> S3Credential {
        S3Credential {
            access_key_id: "AKIA_TEST".into(),
            secret_access_key: "SECRET_TEST".into(),
        }
    }

    #[test]
    fn maps_s3_config_and_credentials_to_rclone_env() {
        let env = rclone_env("tf", &config("prefix"), &credential());

        assert_eq!(
            env,
            vec![
                ("RCLONE_CONFIG_TF_TYPE".into(), "s3".into()),
                ("RCLONE_CONFIG_TF_PROVIDER".into(), "Other".into()),
                ("RCLONE_CONFIG_TF_ACCESS_KEY_ID".into(), "AKIA_TEST".into()),
                (
                    "RCLONE_CONFIG_TF_SECRET_ACCESS_KEY".into(),
                    "SECRET_TEST".into()
                ),
                (
                    "RCLONE_CONFIG_TF_ENDPOINT".into(),
                    "http://127.0.0.1:9000".into()
                ),
                ("RCLONE_CONFIG_TF_REGION".into(), "us-east-1".into()),
                ("RCLONE_CONFIG_TF_FORCE_PATH_STYLE".into(), "true".into()),
            ]
        );
    }

    #[test]
    fn remote_path_includes_base_prefix_when_present() {
        assert_eq!(
            remote_path("tf", &config("base/prefix")),
            "tf:bucket/base/prefix"
        );
    }

    #[test]
    fn remote_path_omits_empty_base_prefix() {
        assert_eq!(remote_path("tf", &config("")), "tf:bucket");
    }

    #[test]
    fn mount_exec_plan_argv_contains_env_names_without_secret_values() {
        let plan = mount_exec_plan(
            "workspace",
            "tf",
            &config("prefix"),
            &credential(),
            "/mnt/minio",
        );

        assert!(plan.argv.contains(&"RCLONE_CONFIG_TF_ACCESS_KEY_ID".into()));
        assert!(
            plan.argv
                .contains(&"RCLONE_CONFIG_TF_SECRET_ACCESS_KEY".into())
        );
        assert!(!plan.argv.iter().any(|arg| arg.contains("AKIA_TEST")));
        assert!(!plan.argv.iter().any(|arg| arg.contains("SECRET_TEST")));
        assert!(plan.env.iter().any(|(_, value)| value == "SECRET_TEST"));
    }

    #[test]
    fn mount_exec_plan_includes_required_rclone_mount_options() {
        let plan = mount_exec_plan(
            "workspace",
            "tf",
            &config("prefix"),
            &credential(),
            "/mnt/minio",
        );

        assert!(plan.argv.ends_with(&[
            "tf:bucket/prefix".into(),
            "/mnt/minio".into(),
            "--vfs-cache-mode".into(),
            "writes".into(),
            "--vfs-write-back".into(),
            "0s".into(),
            "--allow-other".into(),
        ]));
    }
}
