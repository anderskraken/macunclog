import Foundation

/// Numbers, sizes and dates follow the user's current locale.
enum Format {
    static let gigabyte: Int64 = 1_000_000_000

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    /// A disk's size the way Finder shows it: "995 GB", without decimals.
    static func capacity(_ value: Int64) -> String {
        Int64((Double(value) / 1e9).rounded() * 1e9).formatted(.byteCount(style: .file))
    }

    static func bytes(_ value: UInt64) -> String {
        bytes(Int64(clamping: value))
    }

    /// RAM in binary units, the way Activity Monitor and About This Mac count it.
    static func memory(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .memory))
    }

    /// "84%". A localisation can add the space Norwegian puts before the sign.
    static func percent(_ value: Double) -> String {
        String(localized: "\(Int(value.rounded()))%")
    }

    static func cores(_ cpuPercent: Double) -> String {
        let cores = cpuPercent / 100
        if cores < 1.25 { return String(localized: "one core") }
        let number = cores.formatted(.number.precision(.fractionLength(0...1)))
        return String(localized: "\(number) cores")
    }

    /// "40 seconds", "3 minutes", "2 hours": the largest unit only.
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
