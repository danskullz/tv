import Foundation
import Security

/// Checks that a downloaded `.app` is really the build it claims to be.
///
/// Two independent questions. *Is it Marquee, at the right version?* is answered from the bundle's
/// own Info.plist and catches a wrong or truncated archive. *Did we write it?* is answered by the
/// code signature, and is the one that matters now that the update host also serves the binaries.
public enum BundleValidation {
    /// The requirement a Marquee app has to satisfy.
    ///
    /// With no team identifier — every build is ad-hoc signed today, and `AppInfo` reads the team
    /// from the bundle that `scripts/bundle.sh` builds — this still rejects a bundle signed by
    /// anyone else, which is enough to keep the wrong app out. Once Developer ID is configured the
    /// team pins the signing identity itself.
    ///
    /// The team is compiled in rather than discovered at run time. Reading it from the app being
    /// replaced would mean taking the answer to that question from the thing being questioned.
    public static func requirement(bundleIdentifier: String, teamIdentifier: String?) -> String {
        var text = "anchor apple generic and identifier \"\(bundleIdentifier)\""
        if let teamIdentifier, !teamIdentifier.isEmpty {
            text += " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }
        return text
    }

    /// - Parameter requirement: nil accepts any valid signature. Never pass nil for a released
    ///   build — that would accept an app signed by anybody, which is exactly what this stops.
    public static func validateSignature(of bundle: URL, requirement: String?) throws {
        guard let code = staticCode(for: bundle) else {
            throw UpdateError.signatureRejected("The app could not be read as a signed bundle.")
        }
        var requirementRef: SecRequirement?
        if let requirement {
            let status = SecRequirementCreateWithString(requirement as CFString, [], &requirementRef)
            guard status == errSecSuccess else {
                throw UpdateError.signatureRejected("Marquee's own signing rule is unreadable (\(status)).")
            }
        }
        var failure: Unmanaged<CFError>?
        // Both slices of a universal binary, and the dylibs in Contents/Frameworks — the LGPL
        // player libraries are re-signed with the app and are part of what we are shipping.
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirementRef, &failure)
        guard status == errSecSuccess else {
            let detail = failure?.takeRetainedValue().localizedDescription ?? "OSStatus \(status)"
            throw UpdateError.signatureRejected(detail)
        }
    }

    /// Confirms the bundle identifies as `expectedVersion` of `expectedBundleIdentifier` and has its
    /// executable in place.
    public static func validateIdentity(
        of bundle: URL,
        expectedBundleIdentifier: String,
        expectedVersion: UpdateVersion
    ) throws {
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else {
            throw UpdateError.missingAppBundle("The app has no readable Info.plist.")
        }
        let identifier = info["CFBundleIdentifier"] as? String
        guard identifier == expectedBundleIdentifier else {
            throw UpdateError.bundleMismatch("it's \(identifier ?? "unidentified")")
        }
        let version = (info["CFBundleShortVersionString"] as? String).map(UpdateVersion.init)
        guard version == expectedVersion else {
            throw UpdateError.bundleMismatch("it reports \(version?.description ?? "no version")")
        }
        // The bundle names its own executable; trust that rather than hardcoding a second copy.
        guard let executable = info["CFBundleExecutable"] as? String else {
            throw UpdateError.missingAppBundle("The app names no executable.")
        }
        let binary = bundle.appendingPathComponent("Contents/MacOS/\(executable)")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw UpdateError.missingAppBundle("The app has no \(executable) inside it.")
        }
    }

    private static func staticCode(for bundle: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }
}