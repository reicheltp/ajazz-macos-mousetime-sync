// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

import Foundation

/// A very small option parser.
///
/// Hand-rolled on purpose: five subcommands and a handful of flags do not
/// justify pulling in swift-argument-parser and giving up the "no dependencies"
/// property of this package.
///
/// Understands `--flag`, `--key value` and `--key=value`. Options that take a
/// value must be declared, which is what removes the ambiguity between
/// `--verbose next-thing` and `--interval 900`.
struct Arguments {
    private var flags: Set<String> = []
    private var values: [String: String] = [:]
    private(set) var positional: [String] = []
    private(set) var unknown: [String] = []

    private let valueOptions: Set<String>

    init(_ argv: [String], valueOptions: Set<String> = []) {
        self.valueOptions = valueOptions

        var index = argv.startIndex
        while index < argv.endIndex {
            let token = argv[index]
            index += 1

            guard token.hasPrefix("-"), token != "-" else {
                positional.append(token)
                continue
            }

            let name = Self.normalize(token)
            if let separator = name.firstIndex(of: "=") {
                let key = String(name[name.startIndex..<separator])
                values[key] = String(name[name.index(after: separator)...])
                continue
            }

            if valueOptions.contains(name) {
                guard index < argv.endIndex else {
                    unknown.append("--\(name) needs a value")
                    continue
                }
                values[name] = argv[index]
                index += 1
            } else {
                flags.insert(name)
            }
        }
    }

    private static func normalize(_ token: String) -> String {
        var name = token
        while name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    func has(_ names: String...) -> Bool {
        names.contains { flags.contains($0) }
    }

    func value(_ names: String...) -> String? {
        for name in names {
            if let found = values[name] { return found }
        }
        return nil
    }

    /// Flags that were passed but never asked about — almost always a typo, and
    /// silently ignoring them is how a daemon ends up running with defaults
    /// nobody intended.
    func unrecognized(known: Set<String>) -> [String] {
        flags.subtracting(known).sorted().map { "--\($0)" }
            + values.keys.filter { !known.contains($0) }.sorted().map { "--\($0)" }
    }
}

/// Parses `15m`, `90s`, `1h`, or a bare number of seconds into a `TimeInterval`.
func parseDuration(_ text: String) -> TimeInterval? {
    let multipliers: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600]

    var digits = text
    var multiplier: TimeInterval = 1
    if let last = text.last, let unit = multipliers[last] {
        multiplier = unit
        digits.removeLast()
    }

    guard let scalar = TimeInterval(digits), scalar > 0 else { return nil }
    return scalar * multiplier
}
