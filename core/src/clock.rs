use std::time::{SystemTime, UNIX_EPOCH};

use tracing_subscriber::fmt::{format::Writer, time::FormatTime};

const KUALA_LUMPUR_OFFSET_SECONDS: i32 = 8 * 60 * 60;
const SECONDS_PER_DAY: i64 = 86_400;

pub struct KualaLumpurTimer;

impl FormatTime for KualaLumpurTimer {
    fn format_time(&self, writer: &mut Writer<'_>) -> std::fmt::Result {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| kuala_lumpur_timestamp_from_unix_seconds(duration.as_secs() as i64))
            .unwrap_or_else(|_| "before-unix-epoch".to_string());

        writer.write_str(&timestamp)
    }
}

pub fn kuala_lumpur_timestamp_from_unix_seconds(unix_seconds: i64) -> String {
    format_offset_timestamp(unix_seconds, KUALA_LUMPUR_OFFSET_SECONDS)
}

fn format_offset_timestamp(unix_seconds: i64, offset_seconds: i32) -> String {
    let local_seconds = unix_seconds + i64::from(offset_seconds);
    let days = local_seconds.div_euclid(SECONDS_PER_DAY);
    let seconds_of_day = local_seconds.rem_euclid(SECONDS_PER_DAY);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    let offset = format_offset(offset_seconds);

    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}{offset}")
}

fn format_offset(offset_seconds: i32) -> String {
    let sign = if offset_seconds >= 0 { '+' } else { '-' };
    let offset_seconds = offset_seconds.unsigned_abs();
    let hours = offset_seconds / 3_600;
    let minutes = (offset_seconds % 3_600) / 60;

    format!("{sign}{hours:02}:{minutes:02}")
}

fn civil_from_days(days_since_unix_epoch: i64) -> (i64, u32, u32) {
    let z = days_since_unix_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    let year = year + if month <= 2 { 1 } else { 0 };

    (year, month as u32, day as u32)
}

#[cfg(test)]
mod tests {
    use super::kuala_lumpur_timestamp_from_unix_seconds;

    #[test]
    fn formats_unix_epoch_as_kuala_lumpur_time() {
        assert_eq!(
            kuala_lumpur_timestamp_from_unix_seconds(0),
            "1970-01-01T08:00:00+08:00"
        );
    }

    #[test]
    fn formats_utc_day_boundary_as_next_kuala_lumpur_day() {
        assert_eq!(
            kuala_lumpur_timestamp_from_unix_seconds(1_704_067_199),
            "2024-01-01T07:59:59+08:00"
        );
    }

    #[test]
    fn formats_utc_new_year_boundary_as_kuala_lumpur_new_year() {
        assert_eq!(
            kuala_lumpur_timestamp_from_unix_seconds(1_704_067_200),
            "2024-01-01T08:00:00+08:00"
        );
    }
}
