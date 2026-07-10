//
//  BurrowCardsHostApp.swift
//  Host app for the Burrow Cards iMessage extension. Doubles as a debug harness:
//  flip through sample layouts or paste live JSON and watch it render — no
//  Messages, no sending required. Fastest way to iterate on the renderer.
//

import SwiftUI

@main
struct BurrowCardsHostApp: App {
    var body: some Scene {
        WindowGroup { HarnessView() }
    }
}

struct HarnessView: View {
    @State private var index = 0
    @State private var jsonText = ""
    @State private var pasted: BurrowLayout?
    @State private var parseError: String?

    private var current: BurrowLayout {
        pasted ?? BurrowSamples.all[index].layout
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Sample", selection: $index) {
                        ForEach(Array(BurrowSamples.all.enumerated()), id: \.offset) { i, s in
                            Text(s.name).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(pasted != nil)

                    // Card preview in a bubble-ish container.
                    BurrowLayoutView(layout: current) { action in
                        parseError = "Tapped action: \(action.id) → \(action.deepLinkURL)"
                    }
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    DisclosureGroup("Paste live JSON") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $jsonText)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(height: 180)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                            HStack {
                                Button("Render") { render() }
                                    .buttonStyle(.borderedProminent)
                                Button("Clear") { pasted = nil; parseError = nil; jsonText = "" }
                                    .buttonStyle(.bordered)
                            }

                            if let parseError {
                                Text(parseError)
                                    .font(.caption)
                                    .foregroundStyle(pasted == nil ? .red : .secondary)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Burrow Cards")
        }
    }

    private func render() {
        guard let data = jsonText.data(using: .utf8) else { return }
        do {
            pasted = try JSONDecoder().decode(BurrowLayout.self, from: data)
            parseError = "Rendered ✓"
        } catch {
            pasted = nil
            parseError = "Parse error: \(error)"
        }
    }
}
