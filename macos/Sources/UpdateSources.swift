//
//  UpdateSources.swift
//  Burrow
//
//  Update-source detection + per-source version checkers (design 2.3).
//  v1 scope: detect HOW an app updates (App Store receipt → Sparkle
//  feed → Electron framework), check Sparkle/MAS versions on demand,
//  and deep-link the right updater. Checks are manual-only — the
//  network is touched when the user clicks refresh, never silently
//  (documented in SECURITY.md's network story).
//

import Foundation
import AppKit
import Darwin

enum UpdateSources {
    enum Source: String {
        case appStore, sparkle, electron, homebrew

        var badge: String {
            switch self {
            case .appStore: return NSLocalizedString("App Store", comment: "update source")
            case .sparkle:  return NSLocalizedString("Sparkle", comment: "update source")
            case .electron: return NSLocalizedString("Electron", comment: "update source")
            case .homebrew: return NSLocalizedString("Homebrew", comment: "update source")
            }
        }
    }

    // MARK: - Detection (bundle shape, no network)

    /// Which mechanism updates the app at `appPath`. Receipt beats feed:
    /// a MAS copy updates through the store even if the binary embeds
    /// Sparkle. nil = no known self-update mechanism.
    static func detect(appPath: String) -> Source? {
        let contents = (appPath as NSString).appendingPathComponent("Contents")
        let fm = FileManager.default
        if fm.fileExists(atPath: (contents as NSString).appendingPathComponent("_MASReceipt/receipt")) {
            return .appStore
        }
        if let info = NSDictionary(contentsOfFile: (contents as NSString).appendingPathComponent("Info.plist")),
           info["SUFeedURL"] != nil {
            return .sparkle
        }
        if fm.fileExists(atPath: (contents as NSString)
            .appendingPathComponent("Frameworks/Electron Framework.framework")) {
            return .electron
        }
        return nil
    }

    /// Files whose identity/content metadata can change update-source
    /// detection without changing InstalledApp's stable id or path. `lstat`
    /// keeps this fingerprint cheap and does not follow a planted symlink.
    static func detectionFingerprint(appPath: String) -> String {
        let contents = (appPath as NSString).appendingPathComponent("Contents")
        let paths = [
            (contents as NSString).appendingPathComponent("Info.plist"),
            (contents as NSString).appendingPathComponent("_MASReceipt/receipt"),
            (contents as NSString).appendingPathComponent("Frameworks/Electron Framework.framework"),
            (contents as NSString).appendingPathComponent("Resources/app-update.yml"),
        ]
        return paths.map(fileFingerprint).joined(separator: "|")
    }

    private static func fileFingerprint(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "missing" }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):" +
            "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    }

    /// The app's Sparkle feed URL, when it advertises one.
    static func feedURL(appPath: String) -> URL? {
        let plist = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOfFile: plist),
              let feed = info["SUFeedURL"] as? String else { return nil }
        return URL(string: feed)
    }

    // MARK: - Sparkle appcast

    /// Highest version advertised by an appcast. Prefers
    /// sparkle:shortVersionString (the human version, comparable to
    /// CFBundleShortVersionString) and falls back to sparkle:version.
    static func parseAppcast(_ data: Data) -> String? {
        let delegate = AppcastDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() || !delegate.versions.isEmpty else { return nil }
        return delegate.versions.max { UpdateCheck.isNewer($1, than: $0) }
    }

    private final class AppcastDelegate: NSObject, XMLParserDelegate {
        var versions: [String] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            guard elementName == "enclosure" else { return }
            if let short = attributeDict["sparkle:shortVersionString"] {
                versions.append(short)
            } else if let raw = attributeDict["sparkle:version"] {
                versions.append(raw)
            }
        }
    }

    // MARK: - Mac App Store (iTunes lookup)

    struct MASResult {
        let version: String
        let pageURL: URL?
        let minimumOsVersion: String?
    }

    static func parseITunesLookup(_ data: Data) -> MASResult? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]],
              let first = results.first,
              let version = first["version"] as? String else { return nil }
        let page = (first["trackViewUrl"] as? String).flatMap(URL.init(string:))
        return MASResult(version: version, pageURL: page,
                         minimumOsVersion: first["minimumOsVersion"] as? String)
    }

    static func itunesLookupURL(bundleID: String) -> URL {
        URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleID)")!
    }
}
