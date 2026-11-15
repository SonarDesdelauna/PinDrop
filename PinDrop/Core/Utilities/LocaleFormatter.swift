import Foundation

/// Locale-aware formatting for distances and times.
/// Compiled into both the app and the widget extension.
enum LocaleFormatter {
    /// `true` for regions that use feet/miles for distances (United States, United Kingdom…).
    static func usesImperialDistances(locale: Locale = .current) -> Bool {
        switch locale.measurementSystem {
        case .us, .uk:
            return true
        default:
            return false
        }
    }

    /// Formats a distance with `Measurement<UnitLength>` + `MeasurementFormatter`:
    /// `350 m` / `1,2 km` in metric regions, `1,150 ft` / `0.7 mi` in imperial ones.
    static func distance(meters: Double, locale: Locale = .current) -> String {
        let safeMeters = max(0, meters)
        let numberFormatter = NumberFormatter()
        numberFormatter.locale = locale
        numberFormatter.numberStyle = .decimal
        numberFormatter.minimumFractionDigits = 0

        let measurement: Measurement<UnitLength>
        if usesImperialDistances(locale: locale) {
            let base = Measurement(value: safeMeters, unit: UnitLength.meters)
            let feet = base.converted(to: .feet).value
            if feet < 1_320 {
                numberFormatter.maximumFractionDigits = 0
                measurement = Measurement(value: max(10, (feet / 10).rounded() * 10), unit: UnitLength.feet)
            } else {
                let miles = base.converted(to: .miles).value
                numberFormatter.maximumFractionDigits = miles < 10 ? 1 : 0
                measurement = Measurement(value: miles, unit: UnitLength.miles)
            }
        } else {
            if safeMeters < 1_000 {
                numberFormatter.maximumFractionDigits = 0
                measurement = Measurement(value: max(10, (safeMeters / 10).rounded() * 10), unit: UnitLength.meters)
            } else {
                let kilometers = safeMeters / 1_000
                numberFormatter.maximumFractionDigits = kilometers < 10 ? 1 : 0
                measurement = Measurement(value: kilometers, unit: UnitLength.kilometers)
            }
        }

        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter = numberFormatter
        return formatter.string(from: measurement)
    }

    /// Relative timestamp such as `8 min ago` / `8 min fa` / `hace 8 min`.
    static func relativeTimestamp(_ date: Date, relativeTo reference: Date = .now, locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        let clampedDate = min(date, reference)
        return formatter.localizedString(for: clampedDate, relativeTo: reference)
    }

    /// Compact remaining time until a date, e.g. `5h 32m` (localized units).
    static func remaining(until date: Date, from reference: Date = .now) -> String {
        let seconds = max(0, date.timeIntervalSince(reference))
        let roundedSeconds = max(60, (seconds / 60).rounded(.up) * 60)
        return Duration.seconds(roundedSeconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    /// How long you've been somewhere, e.g. `12m`, `2h 5m`, `3d 4h` (localized units).
    static func dwell(since start: Date, now: Date = .now) -> String {
        let seconds = max(60, now.timeIntervalSince(start))
        let minutes = (seconds / 60).rounded(.down) * 60
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 86_400 ? [.days, .hours] : [.hours, .minutes]
        return Duration.seconds(minutes).formatted(.units(allowed: units, width: .narrow, maximumUnitCount: 2))
    }

    /// Speed in km/h or mph depending on the region, e.g. `23 km/h`.
    static func speed(metersPerSecond: Double, locale: Locale = .current) -> String {
        let measurement = Measurement(value: max(0, metersPerSecond), unit: UnitSpeed.metersPerSecond)
        let converted = measurement.converted(to: usesImperialDistances(locale: locale) ? .milesPerHour : .kilometersPerHour)
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: converted.value.rounded(), unit: converted.unit))
    }

    /// Walking duration, e.g. `6 min` / `1 hr, 5 min` (localized units).
    static func walkingDuration(seconds: TimeInterval) -> String {
        let roundedSeconds = max(60, (seconds / 60).rounded() * 60)
        return Duration.seconds(roundedSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
