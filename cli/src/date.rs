//! Calendar dates without a date library: today's UTC date as YYYY-MM-DD.

use std::time::{SystemTime, UNIX_EPOCH};

/// Today's date in UTC, formatted as YYYY-MM-DD.
pub fn today() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    from_days(secs.div_euclid(86_400))
}

/// Seconds since 1970-01-01 UTC.
pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The current UTC time as YYYYMMDD-HHMMSS, for branch and log names.
pub fn stamp() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let day = from_days(secs.div_euclid(86_400)).replace('-', "");
    let t = secs.rem_euclid(86_400);
    format!("{day}-{:02}{:02}{:02}", t / 3600, t % 3600 / 60, t % 60)
}

/// Converts days since 1970-01-01 to YYYY-MM-DD (proleptic Gregorian calendar).
pub fn from_days(days: i64) -> String {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

#[cfg(test)]
mod tests {
    use super::from_days;

    #[test]
    fn known_dates() {
        assert_eq!(from_days(0), "1970-01-01");
        assert_eq!(from_days(18_993), "2022-01-01");
        assert_eq!(from_days(19_782), "2024-02-29");
        assert_eq!(from_days(-1), "1969-12-31");
    }
}
