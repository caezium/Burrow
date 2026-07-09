//
//  Samples.swift
//  Burrow Cards — canned layouts for the debug harness and the compose gallery.
//

import Foundation

public enum BurrowSamples {
    public static let disk = BurrowLayout(
        version: 1,
        title: "Disk 99% full",
        subtitle: "6.1 GB free",
        accentColorHex: "#FF3B30",
        root: .vstack(spacing: 12, children: [
            .statusBadge(label: "99% full", colorHex: "#FF3B30"),
            .progressBar(value: 0.99, colorHex: "#FF3B30"),
            .section(title: "Details", children: [
                .keyValueRow(key: "Free", value: "6.1 GB"),
                .keyValueRow(key: "Used", value: "99%"),
                .keyValueRow(key: "Full in", value: "~6 days"),
                .keyValueRow(key: "Top", value: "Library (160 GB)"),
            ]),
        ]),
        actions: [
            BurrowAction(id: "clean", label: "Open Burrow to clean",
                         systemImage: "sparkles", deepLinkURL: "burrow://action?id=clean"),
        ]
    )

    public static let cpu = BurrowLayout(
        version: 1,
        title: "High CPU",
        subtitle: "node sustained 240% for 10m",
        accentColorHex: "#FF9F0A",
        root: .vstack(spacing: 12, children: [
            .statusBadge(label: "Sustained load", colorHex: "#FF9F0A"),
            .gauge(label: "CPU", value: 0.85, colorHex: "#FF9F0A"),
            .section(title: "Top process", children: [
                .keyValueRow(key: "Name", value: "node"),
                .keyValueRow(key: "Avg CPU", value: "240%"),
                .keyValueRow(key: "Window", value: "10 min"),
            ]),
        ]),
        actions: [
            BurrowAction(id: "inspect", label: "Open Burrow",
                         systemImage: "cpu", deepLinkURL: "burrow://action?id=inspect"),
        ]
    )

    public static let health = BurrowLayout(
        version: 1,
        title: "Weekly cleanup",
        subtitle: "23 GB reclaimable",
        accentColorHex: "#34C759",
        root: .vstack(spacing: 12, children: [
            .statusBadge(label: "Ready to tidy", colorHex: "#34C759"),
            .section(title: "Reclaimable", children: [
                .keyValueRow(key: "Caches", value: "11 GB"),
                .keyValueRow(key: "Xcode", value: "8 GB"),
                .keyValueRow(key: "Trash", value: "4 GB"),
            ]),
        ]),
        actions: [
            BurrowAction(id: "clean", label: "Review in Burrow",
                         systemImage: "sparkles", deepLinkURL: "burrow://action?id=clean"),
        ]
    )

    /// Named list for pickers and the compose gallery.
    public static let all: [(name: String, layout: BurrowLayout)] = [
        ("Disk", disk), ("CPU", cpu), ("Cleanup", health),
    ]
}
