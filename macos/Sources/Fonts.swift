//
//  Fonts.swift
//  Burrow
//
//  Registers the bundled brand typefaces at launch so SwiftUI's
//  Font.custom(...) can reach them:
//
//    * Geist       — UI text + numerics (the body voice)
//    * Geist Mono  — labels / the nav / the "instrument" voice
//    * Cal Sans    — the display / hero voice (headings, taglines)
//
//  Geist and Geist Mono ship as one STATIC file per weight we actually use,
//  each referenced by its own PostScript name (Fonts.geist(.semibold) etc).
//  They used to ship as a single variable file with only the Regular instance
//  registered, and every heavier weight came from `Font.weight(...)` asking
//  CoreText to synthesize one. That synthesis intermittently produced no
//  glyphs at all -- headings rendered as tofu boxes while regular-weight text
//  in the same view, in the same family, was fine. Real faces mean nothing has
//  to be derived at render time.
//
//  Cal Sans is genuinely single-weight (no variable axis to cut instances
//  from), so it keeps the synthesized path. It is static rather than variable,
//  which is the case that has always rendered correctly.
//
//  The TTFs ship in the app bundle. Xcode flattens resource subfolders on
//  copy, so we look in both the Resources root and a `Fonts` subdirectory
//  and register process-scoped — no Info.plist ATSApplicationFontsPath
//  dependency on where exactly the file lands.
//

import CoreText
import Foundation
import SwiftUI

enum Fonts {
    /// Family name for the one face that still resolves by family + synthesized
    /// weight. Used by Brand.display/serif.
    static let display = "Cal Sans"

    /// The concrete faces we ship, by PostScript name — what `Font.custom`
    /// resolves against so no weight is ever synthesized.
    private static let files = [
        "Geist-Regular", "Geist-Medium", "Geist-SemiBold",
        "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold", "GeistMono-Bold",
        "CalSans",
    ]

    /// The Geist face for a requested weight. Anything at or above semibold
    /// takes SemiBold — the family ships no heavier UI cut, and returning the
    /// nearest REAL face beats asking for one that would have to be derived.
    static func geist(_ weight: Font.Weight) -> String {
        switch weight {
        case .regular, .light, .thin, .ultraLight: return "Geist-Regular"
        case .medium:                              return "Geist-Medium"
        default:                                   return "Geist-SemiBold"
        }
    }

    /// The Geist Mono face for a requested weight. Mono is the only family the
    /// UI asks for a true bold, so it ships one.
    static func geistMono(_ weight: Font.Weight) -> String {
        switch weight {
        case .regular, .light, .thin, .ultraLight: return "GeistMono-Regular"
        case .medium:                              return "GeistMono-Medium"
        case .semibold:                            return "GeistMono-SemiBold"
        default:                                   return "GeistMono-Bold"
        }
    }

    /// Idempotent: CoreText ignores a second registration of the same URL.
    static func register() {
        for file in files {
            let url = Bundle.main.url(forResource: file, withExtension: "ttf")
                ?? Bundle.main.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
