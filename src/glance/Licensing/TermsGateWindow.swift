//
//  TermsGateWindow.swift
//  Mac ID
//
//  The Terms of Use screen shown at first launch, and again whenever the terms change, before the
//  licence gate and before anything else starts. Nothing — trial, activation, onboarding, face
//  unlock — runs until the box is ticked and "Agree and Continue" is pressed.
//
//  Same window mechanics as LicenseGateWindow (a real titled window, `.regular` while it's up, no
//  close button): see that file for why.
//

import AppKit
import SwiftUI

@MainActor
final class TermsGateWindow {
    private static var shared: TermsGateWindow?

    private var window: NSWindow?
    private let onAccepted: () -> Void

    private init(onAccepted: @escaping () -> Void) {
        self.onAccepted = onAccepted
    }

    /// Shows the terms and calls `onAccepted` once they're agreed to. Never calls back if the user
    /// quits instead.
    static func present(onAccepted: @escaping () -> Void) {
        if let existing = shared, existing.window != nil {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let gate = TermsGateWindow(onAccepted: onAccepted)
        shared = gate
        gate.show()
    }

    private func show() {
        let view = TermsGateView(
            onAccepted: { [weak self] in self?.finish() },
            onQuit: { NSApp.terminate(nil) }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: view)
        window.center()
        // No way out but Agree or Quit; the disabled minimise and zoom buttons would only be clutter.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        self.window = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        Terms.accept()
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)
        TermsGateWindow.shared = nil
        onAccepted()
    }
}

private struct TermsGateView: View {
    let onAccepted: () -> Void
    let onQuit: () -> Void

    @State private var agreed = false
    private let blocks = TermsBlock.parse(Terms.bundledText)
    private let isUpdate = Terms.isUpdate

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image("appicon")
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isUpdate ? "We've updated our Terms of Use" : "Before you start")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SettingsMetrics.textPrimary)
                    Text(isUpdate
                         ? "Please read and agree to the new terms to keep using Mac ID."
                         : "Please read and agree to the Terms of Use to use Mac ID.")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 34)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        block.view
                    }
                }
                .textSelection(.enabled)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $agreed) {
                    Text("I have read and agree to the Terms of Use. I understand Mac ID can be fooled and that its makers aren't responsible if someone else gets into my Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)

                HStack(spacing: 10) {
                    Link("Open in browser", destination: Terms.webURL)
                        .font(.system(size: 11))
                    Text("·").foregroundStyle(SettingsMetrics.textTertiary)
                    Button("Quit", action: onQuit)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                    Spacer()
                    Button(action: onAccepted) {
                        Text("Agree and Continue").padding(.horizontal, 6)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!agreed)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 640)
        .background(.ultraThickMaterial)
    }
}

/// Just enough Markdown for Terms.md: a title, section headings, one call-out, bullets and
/// paragraphs, with inline bold and links handled by `AttributedString`.
private enum TermsBlock {
    case title(String)
    case heading(String)
    case callout(String)
    case bullet(String)
    case paragraph(String)

    static func parse(_ text: String) -> [TermsBlock] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
            if line.hasPrefix("> ") { return .callout(String(line.dropFirst(2))) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    private static func inline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }

    @ViewBuilder var view: some View {
        switch self {
        case .title(let text):
            Text(text)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SettingsMetrics.textPrimary)
        case .heading(let text):
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsMetrics.textPrimary)
                .padding(.top, 6)
        case .callout(let text):
            Text(Self.inline(text))
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(SettingsMetrics.textSecondary)
                Text(Self.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(SettingsMetrics.textSecondary)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
