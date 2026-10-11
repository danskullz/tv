import Foundation

public enum AppInfo {
    public static let name = "Marquee"

    /// The Developer ID team that signs released builds, as written into Info.plist by
    /// `scripts/bundle.sh`. Empty until signing is wired up.
    ///
    /// Compiled in rather than discovered at run time: the in-app updater compares a downloaded
    /// build against this value, and reading it from the running app would mean trusting the very
    /// thing being replaced to name its own signer.
    public static var developerTeamIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MarqueeDeveloperTeamIdentifier") as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return value
    }
}