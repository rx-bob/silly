// RFC 9110 section 5.6.7. UTC calendar arithmetic, independent of locale and timezone.
namespace silly;

struct HttpDate {
    valid: bool = false,
    seconds: i64 = 0,
}
struct HttpDateParts {
    year: i64 = 0,
    month: i64 = 0,
    day: i64 = 0,
    hour: i64 = 0,
    minute: i64 = 0,
    second: i64 = 0,
}
fn date_number(value: u8[:]) -> i64 {
    var result: i64 = 0;
    for byte in value {
        if byte < '0' || byte > '9' {
            return -1;
        }
        result = result * 10 + (byte - '0');
    }
    return result;
}

fn date_month(value: u8[:]) -> i64 {
    let months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    for index in 12 {
        if value == months[index * 3..index * 3 + 3] {
            return index + 1;
        }
    }
    return 0;
}

fn date_weekday(value: u8[:]) -> bool {
    for day in["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"] {
        if value == day {
            return true;
        }
    }
    return false;
}

fn date_leap(year: i64) -> bool {
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

fn date_month_days(year: i64, month: i64) -> i64 {
    if month == 2 {
        return if date_leap(year) {
            29
        } else {
            28
        };
    }
    if month == 4 || month == 6 || month == 9 || month == 11 {
        return 30;
    }
    return 31;
}

fn date_year_days(year: i64) -> i64 {
    let prior = year - 1;
    return 365 * (year - 1970) + prior / 4 - 1969 / 4 - prior / 100 + 1969 / 100
        + prior / 400 - 1969 / 400;
}

fn date_parts(seconds: i64) -> HttpDateParts {
    var parts = HttpDateParts {
    };
    var days = seconds / 86400;
    parts.year = 1970 + days / 366;
    while date_year_days(parts.year + 1) <= days {
        parts.year += 1;
    }
    days -= date_year_days(parts.year);
    parts.month = 1;
    while days >= date_month_days(parts.year, parts.month) {
        days -= date_month_days(parts.year, parts.month);
        parts.month += 1;
    }
    parts.day = days + 1;
    parts.hour = seconds / 3600 % 24;
    parts.minute = seconds / 60 % 60;
    parts.second = seconds % 60;
    return parts;
}

fn date_timestamp(parts: HttpDateParts) -> HttpDate {
    if parts.year < 1970 || parts.year > 9999 || parts.month < 1 || parts.month > 12
        || parts.day < 1 || parts.day > date_month_days(parts.year, parts.month)
        || parts.hour < 0 || parts.hour > 23 || parts.minute < 0 || parts.minute > 59
        || parts.second < 0 || parts.second > 60 {
        return HttpDate {
        };
    }
    var days = date_year_days(parts.year) + parts.day - 1;
    var month: i64 = 1;
    while month < parts.month {
        days += date_month_days(parts.year, month);
        month += 1;
    }
    let seconds = days * 86400 + parts.hour * 3600 + parts.minute * 60 + parts.second;
    if seconds > 253402300799 {
        return HttpDate {
        };
    }
    return HttpDate {
        valid: true,
        seconds: seconds
    };
}

fn date_clock(value: u8[:], parts: HttpDateParts&) -> bool {
    if value[2] != ':' || value[5] != ':' {
        return false;
    }
    parts.hour = date_number(value[0..2]);
    parts.minute = date_number(value[3..5]);
    parts.second = date_number(value[6..8]);
    return true;
}

fn date_imf(value: u8[:]) -> HttpDate {
    if value[3..5] != ", " || value[7] != ' ' || value[11] != ' ' || value[16] != ' '
        || value[25..29] != " GMT" || !date_weekday(value[0..3]) {
        return HttpDate {
        };
    }
    var parts = HttpDateParts {
        year: date_number(value[12..16]),
        month: date_month(value[8..11]),
        day: date_number(value[5..7]),
        ..
    };
    if !date_clock(value[17..25], parts) {
        return HttpDate {
        };
    }
    return date_timestamp(parts);
}

fn date_asctime(value: u8[:]) -> HttpDate {
    if value[3] != ' ' || value[7] != ' ' || value[10] != ' ' || value[19] != ' '
        || !date_weekday(value[0..3]) {
        return HttpDate {
        };
    }
    var parts = HttpDateParts {
        year: date_number(value[20..24]),
        month: date_month(value[4..7]),
        day: date_number(if value[8] == ' ' {
                value[9..10]
            } else {
                value[8..10]
            }),
        ..
    };
    if !date_clock(value[11..19], parts) {
        return HttpDate {
        };
    }
    return date_timestamp(parts);
}

fn date_future(parts: HttpDateParts, now: HttpDateParts) -> bool {
    if parts.year != now.year + 50 {
        return parts.year > now.year + 50;
    }
    if parts.month != now.month {
        return parts.month > now.month;
    }
    if parts.day != now.day {
        return parts.day > now.day;
    }
    if parts.hour != now.hour {
        return parts.hour > now.hour;
    }
    if parts.minute != now.minute {
        return parts.minute > now.minute;
    }
    return parts.second > now.second;
}

fn date_rfc850(value: u8[:], now_seconds: i64) -> HttpDate {
    if value.len < 30 || value.len > 33 || now_seconds < 0 || now_seconds > 253402300799 {
        return HttpDate {
        };
    }
    let prefix = value.len - 24;
    if !date_weekday(value[0..prefix]) || value[prefix..prefix + 2] != ", " {
        return HttpDate {
        };
    }
    let tail = value[prefix + 2..];
    if tail[2] != '-' || tail[6] != '-' || tail[9] != ' ' || tail[18..22] != " GMT" {
        return HttpDate {
        };
    }
    let now = date_parts(now_seconds);
    let year = date_number(tail[7..9]);
    if year < 0 {
        return HttpDate {
        };
    }
    var parts = HttpDateParts {
        year: (now.year + 50) / 100 * 100 + year,
        month: date_month(tail[3..6]),
        day: date_number(tail[0..2]),
        ..
    };
    if !date_clock(tail[10..18], parts) {
        return HttpDate {
        };
    }
    if date_future(parts, now) {
        parts.year -= 100;
    }
    return date_timestamp(parts);
}

fn parse_http_date(value: u8[:], now_seconds: i64) -> HttpDate {
    if value.len == 29 {
        return date_imf(value);
    }
    if value.len == 24 {
        return date_asctime(value);
    }
    return date_rfc850(value, now_seconds);
}

fn date_write_pair(out: u8[:], value: i64) {
    out[0] = ('0' + value / 10)as u8;
    out[1] = ('0' + value % 10)as u8;
}

fn format_http_date(seconds: i64) -> u8[..29] {
    var out: u8[..29] = [];
    if seconds < 0 || seconds > 253402300799 {
        return out;
    }
    out.append("Thu, 01 Jan 1970 00:00:00 GMT");
    let parts = date_parts(seconds);
    let weekdays = "SunMonTueWedThuFriSat";
    let months = "JanFebMarAprMayJunJulAugSepOctNovDec";
    let weekday = (seconds / 86400 + 4) % 7;
    for index in 3 {
        out[index] = weekdays[weekday * 3 + index];
        out[8 + index] = months[(parts.month - 1) * 3 + index];
    }
    date_write_pair(out[5..7], parts.day);
    date_write_pair(out[12..14], parts.year / 100);
    date_write_pair(out[14..16], parts.year % 100);
    date_write_pair(out[17..19], parts.hour);
    date_write_pair(out[20..22], parts.minute);
    date_write_pair(out[23..25], parts.second);
    return out;
}
