//
//  ComposeGallery.swift
//  Shown in the extension when no card is selected — tap a sample to insert it
//  into the thread. Lets you test the full send → bubble → tap loop by hand.
//

import SwiftUI

struct ComposeGallery: View {
    let onInsert: (BurrowLayout) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Insert a Burrow card")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                ForEach(BurrowSamples.all, id: \.name) { sample in
                    Button {
                        onInsert(sample.layout)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sample.layout.title).font(.subheadline).fontWeight(.semibold)
                                if let s = sample.layout.subtitle {
                                    Text(s).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
    }
}
