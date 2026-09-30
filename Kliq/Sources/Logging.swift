import os

/// Unified logging. View with:
///   log stream --level info --predicate 'subsystem == "dev.vansh.Kliq"'
enum Log {
    static let subsystem = "dev.vansh.Kliq"
    static let output = Logger(subsystem: subsystem, category: "output")
    static let keys = Logger(subsystem: subsystem, category: "keys")
    static let app = Logger(subsystem: subsystem, category: "app")
}
