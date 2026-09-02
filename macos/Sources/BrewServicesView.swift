//
//  BrewServicesView.swift
//  Burrow
//
//  The "Services" segment of the Software pane: Homebrew background services
//  with a start/stop switch and a restart, shelling through BrewClient. Read
//  on appear; refreshes after each action.
//
//  NOTE (hand-test): shells `brew services` — verify the list matches
//  `brew services list` and that the toggle actually starts/stops the service.
//

import SwiftUI

struct BrewServicesView: View {
    @ObservedObject var model: BrewServicesModel

    var body: some View {
        Group {
            if !model.brewInstalled {
                note("homissue", systemImage: "mug",
                     text: NSLocalizedString("Homebrew isn't installed, so there are no services to manage.", comment: ""))
            } else if model.loading && model.services.isEmpty {
                VStack { Spacer()
                    ProgressView(NSLocalizedString("Reading services…", comment: ""))
                        .controlSize(.large).tint(Tool.apps.accent).font(Brand.mono(11))
                    Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.services.isEmpty {
                note("checkmark.seal.fill", systemImage: "checkmark.seal.fill",
                     text: NSLocalizedString("No Homebrew services are set up.", comment: ""))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.services) { row($0) }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .onAppear { model.startIfNeeded() }
    }

    private func note(_ id: String, systemImage: String, text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: systemImage).font(.system(size: Brand.scaled(22))).foregroundStyle(Brand.textTertiary)
            Text(text).font(Brand.sans(13)).foregroundStyle(Brand.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func row(_ s: BrewService) -> some View {
        let isBusy = model.busy.contains(s.name)
        HStack(spacing: 12) {
            Circle().fill(s.running ? Brand.green : Brand.textTertiary).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary)
                Text(statusText(s)).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                if s.running {
                    Button { model.restart(s.name) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: Brand.scaled(11), weight: .semibold))
                            .foregroundStyle(Brand.textSecondary)
                    }
                    .buttonStyle(.plain).help(NSLocalizedString("Restart", comment: ""))
                }
                Toggle("", isOn: Binding(
                    get: { s.running },
                    set: { model.setRunning($0, s.name) }
                ))
                .labelsHidden().toggleStyle(.switch).tint(Tool.apps.accent)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 18)
        }
    }

    private func statusText(_ s: BrewService) -> String {
        var parts = [s.status]
        if let u = s.user, !u.isEmpty { parts.append(u) }
        return parts.joined(separator: " · ")
    }
}
