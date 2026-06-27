//! Mountpoint naming helpers for runtime-private workspace paths.

const FALLBACK_SLUG: &str = "conn";

/// Keep ASCII alphanumerics as lowercase and collapse every other run into `-`.
pub fn slugify(name: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;

    for ch in name.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            prev_dash = false;
        } else if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }

    let trimmed = out.trim_matches('-');
    if trimmed.is_empty() {
        FALLBACK_SLUG.to_string()
    } else {
        trimmed.to_string()
    }
}

/// Build `<root>/<slug>`, appending `-2`, `-3`, ... until it is unique.
pub fn mountpoint_for(root: &str, display_name: &str, taken: &[String]) -> String {
    let base = format!("{}/{}", root.trim_end_matches('/'), slugify(display_name));
    if !taken.iter().any(|t| t == &base) {
        return base;
    }

    let mut n = 2;
    loop {
        let candidate = format!("{base}-{n}");
        if !taken.iter().any(|t| t == &candidate) {
            return candidate;
        }
        n += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_keeps_alnum_lowercases_and_replaces_others() {
        assert_eq!(slugify("My Minio!"), "my-minio");
        assert_eq!(slugify("prod_bucket.01"), "prod-bucket-01");
        assert_eq!(slugify(""), "conn");
        assert_eq!(slugify("---"), "conn");
    }

    #[test]
    fn mountpoint_under_given_root_is_unique_against_taken() {
        let taken = ["/mnt/minio".to_string()];
        assert_eq!(mountpoint_for("/mnt", "Minio", &[]), "/mnt/minio");
        assert_eq!(mountpoint_for("/mnt", "Minio", &taken), "/mnt/minio-2");
    }

    #[test]
    fn mountpoint_respects_arbitrary_root() {
        assert_eq!(
            mountpoint_for("/workspace", "Minio", &[]),
            "/workspace/minio"
        );
    }
}
