import Foundation

/// Update preferences and the small amount of state a check produces. Backed by `UserDefaults`, so
/// it costs nothing to keep and survives relaunches.
///
/// `unchecked Sendable`: `UserDefaults` is itself thread-safe, and every value here is a primitive
/// or a plain string.
public final class UpdatePreferences: @unchecked Sendable {
    private enum Key {
        static let etag = "updates.etag"
        static let lastCheck = "updates.lastCheckAt"
        static let lastSuccess = "updates.lastSuccessAt"
        static let lastKnownVersion = "updates.lastKnownVersion"
        static let skippedVersion = "updates.skippedVersion"
        static let includeBeta = "updates.includeBetaReleases"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Validator for the next request; cleared whenever a new manifest is accepted.
    public var etag: String? {
        get { defaults.string(forKey: Key.etag) }
        set { defaults.setOrRemove(newValue, Key.etag) }
    }

    /// When any check last ran, successful or not.
    public var lastCheckAt: Date? { defaults.object(forKey: Key.lastCheck) as? Date }
    /// When a check last completed without error. Decides which cooldown applies.
    public var lastSuccessAt: Date? { defaults.object(forKey: Key.lastSuccess) as? Date }

    public func recordCheck(at date: Date, succeeded: Bool) {
        defaults.set(date, forKey: Key.lastCheck)
        if succeeded { defaults.set(date, forKey: Key.lastSuccess) }
    }

    /// The newest version the feed has ever offered, so a 304 can still report something useful.
    public var lastKnownVersion: UpdateVersion? {
        get { defaults.string(forKey: Key.lastKnownVersion).map(UpdateVersion.init) }
        set { defaults.setOrRemove(newValue?.description, Key.lastKnownVersion) }
    }

    /// A version the user chose not to install; not offered again.
    public var skippedVersion: UpdateVersion? {
        get { defaults.string(forKey: Key.skippedVersion).map(UpdateVersion.init) }
        set { defaults.setOrRemove(newValue?.description, Key.skippedVersion) }
    }

    /// Pre-1.0: the project publishes every build as a beta, so beta is the default.
    public var includeBetaReleases: Bool {
        get { defaults.object(forKey: Key.includeBeta) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.includeBeta) }
    }

    public var channel: UpdateChannel { includeBetaReleases ? .beta : .stable }

    /// Forgets the cached validator. Used when a check fails in a way that suggests our copy is
    /// stale, and by the diagnostics pane.
    public func reset() {
        for key in [Key.etag, Key.lastCheck, Key.lastSuccess, Key.lastKnownVersion, Key.skippedVersion] {
            defaults.removeObject(forKey: key)
        }
    }
}

extension UserDefaults {
    fileprivate func setOrRemove(_ value: String?, _ key: String) {
        if let value, !value.isEmpty { set(value, forKey: key) } else { removeObject(forKey: key) }
    }
}