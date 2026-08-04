//
//  HelperCodeRequirement.swift
//  Burrow / BurrowHelper (shared)
//
//  Who may talk to the root daemon at all.
//
//  Authorization (HelperAuthorization) answers "may this operation run".
//  This answers the question that comes first: "is the process on the other
//  end of this XPC connection actually Burrow". Both are required, and the
//  order matters — without this check, any local process could open the Mach
//  service and drive the authentication prompt, phishing the user for
//  administrator credentials behind a dialog the system itself renders and
//  that therefore looks entirely legitimate.
//
//  ── Identifying the peer correctly ──────────────────────────────────────
//  The requirement built here is handed to
//  `NSXPCListener.setConnectionCodeSigningRequirement`, so the SYSTEM
//  evaluates it against the connecting peer before the delegate is ever
//  called. That matters more than it looks:
//
//  The obvious hand-rolled check — read `connection.processIdentifier`, look
//  the process up, verify its signature — is the classic vulnerable pattern.
//  A PID can be recycled between being read and being checked, and the
//  standard exploit hands the helper the PID of a legitimate app and then
//  races a hostile process into that slot. Doing it properly means the audit
//  token, and reaching an NSXPCConnection's audit token means private API,
//  which is not a dependency worth taking inside a root daemon.
//
//  The macOS 13 requirement API sidesteps both problems: it is supported, and
//  the evaluation happens in the kernel against the real peer, with no window
//  between check and use.
//
//  ── Nothing personal is hardcoded ───────────────────────────────────────
//  The requirement is assembled at RUNTIME from the daemon's own signing
//  information: the helper asks what team signed IT, and demands the caller be
//  the Burrow app signed by that same team. No team ID, certificate, or
//  developer name appears in this repository, and the check keeps working
//  across certificate renewals.
//

import Foundation
import Security

enum HelperCodeRequirement {

    /// A syntactically valid requirement that no code can satisfy, used
    /// whenever a safe requirement cannot be built.
    ///
    /// It is deliberately not the empty string: an empty requirement fails to
    /// PARSE, and several Security APIs treat a parse failure as "no
    /// requirement given", which is the exact opposite of failing closed. This
    /// one parses fine and simply matches nothing, because no bundle
    /// identifier may contain a space.
    static let unsatisfiable = #"identifier "dev.caezium.Burrow.no such caller""#

    // MARK: - Input validation
    //
    // The requirement string is a small language parsed by the Security
    // framework, and identifiers are interpolated into it. A value containing
    // a quote could close the literal early and append its own clause —
    // `identifier "x" or anchor apple generic` would admit every Apple-signed
    // process on the machine.
    //
    // Hostile values are REFUSED rather than escaped. A legitimate bundle
    // identifier or team ID is drawn from a small alphabet, so rejecting
    // anything outside it costs nothing and removes a whole class of parser
    // subtleties — there is no "correctly escaped" case left to get wrong.

    /// The characters a real bundle identifier or team ID is built from.
    private static let permitted = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")

    /// The value if it can ride inertly inside a requirement string, else nil.
    static func validated(identifier: String) -> String? {
        guard !identifier.isEmpty, identifier.count <= 255 else { return nil }
        guard identifier.unicodeScalars.allSatisfy({ permitted.contains($0) }) else { return nil }
        return identifier
    }

    // MARK: - Building the requirement

    /// The designated requirement a caller must satisfy.
    ///
    /// With a team ID, three clauses are pinned and every one is mandatory:
    ///   * `identifier` — this exact bundle, not merely something of ours;
    ///   * `anchor apple generic` — a chain terminating at Apple, so a
    ///     self-signed build cannot claim the identifier;
    ///   * `certificate leaf[subject.OU]` — signed by the same team as the
    ///     helper, so another developer's notarized app cannot impersonate us.
    ///
    /// Without a team ID (a local ad-hoc Debug build) it falls back to the
    /// identifier alone so development works. That is explicitly NOT
    /// distribution grade, and `isDistributionGrade` is what the release gate
    /// checks so an ad-hoc helper can never ship.
    static func string(bundleID: String, teamID: String?) -> String {
        guard let identifier = validated(identifier: bundleID) else { return unsatisfiable }

        guard let teamID, !teamID.trimmingCharacters(in: .whitespaces).isEmpty else {
            return #"identifier "\#(identifier)""#
        }
        guard let team = validated(identifier: teamID) else { return unsatisfiable }

        return #"identifier "\#(identifier)" and anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
    }

    /// Whether a requirement built from this team is strong enough to ship.
    /// An ad-hoc helper has no team, so it can be impersonated by any local
    /// build that claims the identifier — fine for development, never for a
    /// release.
    static func isDistributionGrade(teamID: String?) -> Bool {
        guard let teamID, !teamID.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return validated(identifier: teamID) != nil
    }

    // MARK: - System witnesses

    /// The team that signed the given code, or nil when it is unsigned or
    /// ad-hoc signed. Used by the daemon to learn its OWN team, so the
    /// requirement never needs a hardcoded value.
    static func teamIdentifier(of code: SecCode?) -> String? {
        guard let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return teamIdentifier(ofStatic: staticCode)
    }

    static func teamIdentifier(ofStatic staticCode: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return team.flatMap { validated(identifier: $0) }
    }

    /// The team that signed the currently running process.
    static func selfTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
        return teamIdentifier(of: code)
    }

    /// A requirement matching any code signed by `teamID` with an Apple-issued
    /// chain, without pinning a bundle identifier.
    ///
    /// Used for the nested ENGINE binary, which carries its own identifier but
    /// is re-signed with our identity by the release pipeline. Returns nil
    /// when a safe requirement can't be built, and callers treat that as
    /// "refuse to run" rather than "skip the check".
    static func sameTeam(teamID: String) -> String? {
        guard let team = validated(identifier: teamID) else { return nil }
        return #"anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
    }
}
