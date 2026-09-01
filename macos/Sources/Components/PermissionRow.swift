//
//  PermissionRow.swift
//  Burrow / Components
//
//  One permission as a card row: status dot (gray → green when granted),
//  bold title, one-line benefit copy, and right-aligned secondary actions
//  ("Open Settings" / "Check"). Used by onboarding's permissions slide
//  and Settings ▸ General; Notifications and friends join later — the
//  row is deliberately permission-agnostic.
//

import SwiftUI

struct PermissionRow: View {
    let title: String
    let benefit: String
    let granted: Bool
    var onOpenSettings: () -> Void
    var onCheck: () -> Void
    /// When non-nil, the permission was granted *after* this process
    /// started, so the running app can't use it until relaunch (macOS
    /// prompts the same way). Surfaces a "Relaunch" button beside the
    /// granted chip.
    var onRelaunch: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(granted ? Brand.green : Brand.ink.opacity(0.22))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                Text(onRelaunch != nil
                     ? NSLocalizedString("Granted — relaunch Burrow to start using it.", comment: "")
                     : benefit)
                    .font(Brand.sans(11))
                    .foregroundStyle(onRelaunch != nil ? Brand.amber : Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let onRelaunch {
                secondaryButton(NSLocalizedString("Relaunch", comment: ""), action: onRelaunch)
            } else if granted {
                Chip(text: NSLocalizedString("Granted", comment: ""), color: Brand.green)
            } else {
                HStack(spacing: 8) {
                    secondaryButton(NSLocalizedString("Open Settings", comment: ""), action: onOpenSettings)
                    secondaryButton(NSLocalizedString("Check", comment: ""), action: onCheck)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(granted ? NSLocalizedString("Granted", comment: "")
                                    : NSLocalizedString("Not granted", comment: ""))
    }

    private func secondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Brand.sans(11, .semibold)).foregroundStyle(Brand.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Brand.chipFill))
                .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
