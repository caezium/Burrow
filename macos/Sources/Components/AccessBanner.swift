//
//  AccessBanner.swift
//  Burrow / Components
//
//  The ambient "something about privileges isn't set up" state, demoted
//  from blocking gate cards to one bottom-anchored banner over the whole
//  window. It informs — the page behind stays fully usable. RootView owns
//  the copy and mounts at most one at a time (Full Disk Access first, then
//  the privileged helper), re-probing on every app activation so granting
//  the thing in System Settings dismisses the banner without a click.
//

import SwiftUI

struct AccessBanner: View {
    var glyph: String = "lock.shield"
    var title: String
    var detail: String
    var actionTitle: String = NSLocalizedString("Open Settings", comment: "")
    var onAction: () -> Void = { Privacy.openFullDiskAccessSettings() }
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.amber)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.amber.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Brand.sans(12, .semibold)).foregroundStyle(Brand.textPrimary)
                Text(detail)
                    .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
            }
            Spacer(minLength: 14)
            Button(action: onAction) {
                Text(actionTitle)
                    .font(Brand.sans(11, .semibold)).foregroundStyle(Brand.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Brand.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Dismiss", comment: ""))
            .accessibilityLabel(NSLocalizedString("Dismiss", comment: ""))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0x1A1812).opacity(0.96))
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.amber.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
