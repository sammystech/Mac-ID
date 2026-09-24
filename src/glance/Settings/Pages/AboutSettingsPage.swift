//
//  AboutSettingsPage.swift
//  glance
//

import SwiftUI
import AppKit

struct AboutSettingsPage: View {
    @Bindable var updater: UpdaterController
    @Bindable var license = LicenseManager.shared
    let environment: AppEnvironment

    /// Secret-tap state for revealing the Debug/Face Lab sidebar section —
    /// see `AppEnvironment.isDebugSectionRevealed`. A pause over a second
    /// resets the count, so this requires 5 *consecutive* taps.
    @State private var licenseInput = ""
    @State private var licenseError: String?
    @State private var isActivating = false
    @State private var iconTapCount = 0
    @State private var lastTapDate: Date?
    private let requiredTapCount = 5
    private let tapResetInterval: TimeInterval = 1.0

    /// Reads the live trial state rather than a cached string so the day count is right whenever
    /// the page is shown.
    private var trialCaption: String {
        let trial = TrialManager.shared
        trial.refresh()
        switch trial.state {
        case .active(let days):
            return "Free trial — \(days) day\(days == 1 ? "" : "s") left. Enter a licence key to keep Mac ID after that."
        case .expired:
            return "Your free trial has ended. Enter a licence key to keep using face unlock."
        case .notStarted:
            return "Face unlock needs a licence key. Paste the one from your purchase email."
        }
    }

    static let supportEmail = "support@macid.net"

    /// Opens a pre-addressed email with the version details a support reply usually needs first.
    /// Deliberately nothing personal: no licence key, name or face data — only what identifies the
    /// build and the system it runs on.
    static func emailSupport() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Mac ID support"),
            URLQueryItem(name: "body", value: "\n\n\n—\nMac ID \(version) (\(build))\nmacOS \(os)"),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private var termsSubtitle: String {
        guard let version = Terms.acceptedVersion else { return "Not yet agreed" }
        guard let date = Terms.acceptedDate else { return "Agreed to version \(version)" }
        return "Agreed to version \(version) on \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 2) {
            Image("appicon")
                .resizable()
                .frame(width: 80, height: 80)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture(perform: handleIconTap)

            Text("Mac ID")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SettingsMetrics.textPrimary)

            Text(versionString)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)

        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Licence")
            SettingsGroup {
                if license.isLicensed {
                    SettingsRowContent(
                        title: "Licensed",
                        subtitle: license.licenseID.map { "Key \(String($0, radix: 36).uppercased())" },
                        subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                    ) {
                        Button("Remove") {
                            license.deactivate()
                            licenseInput = ""
                            licenseError = nil
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(SettingsMetrics.textSecondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsCaption(text: trialCaption)
                        HStack(spacing: 8) {
                            TextField("ABCD-EFGH-JKMN-PQRS", text: $licenseInput)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                            Button(isActivating ? "Activating…" : "Activate") { activate() }
                                .disabled(isActivating || licenseInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let licenseError {
                            Text(licenseError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .padding(.bottom, 12)

        if updater.isDeveloperBuild {
            // Otherwise the disabled Check button looks like a fault.
            SettingsCaption(text: "Developer build: updates are off, so a release can't replace this copy. "
                + "Install new versions from release.sh's local build instead.")
                .padding(.bottom, 8)
        }

        SettingsGroup {
            SettingsActionRowContent(
                title: "Check for Updates",
                buttonTitle: "Check",
                isEnabled: updater.canCheckForUpdates
            ) {
                updater.checkForUpdates()
            }

            SettingsGroupDivider()

            SettingsRowContent(title: "Automatically check for updates") {
                MacIDToggle(isOn: $updater.automaticallyChecksForUpdates)
            }

            SettingsGroupDivider()

            SettingsRowContent(
                title: "Support",
                subtitle: Self.supportEmail,
                subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
            ) {
                SettingsPrimaryButton(title: "Email", compact: true) { Self.emailSupport() }
            }

            SettingsGroupDivider()

            SettingsRowContent(
                title: "Terms of Use",
                subtitle: termsSubtitle,
                subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
            ) {
                SettingsPrimaryButton(title: "View", compact: true) { NSWorkspace.shared.open(Terms.webURL) }
            }

            SettingsGroupDivider()

            // Mac ID is a derivative of MIT-licensed work, and MIT requires the copyright notice
            // and permission notice to ship with every copy. `Acknowledgements.txt` in the bundle
            // is what satisfies that; this row only makes it reachable. Removing the file would
            // put the app out of compliance with the licence that permits it to exist.
            SettingsActionRowContent(
                title: "Acknowledgements",
                buttonTitle: "Open"
            ) {
                if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func activate() {
        guard !isActivating else { return }
        isActivating = true
        Task {
            defer { isActivating = false }
            do {
                try await license.activate(licenseInput)
                licenseError = nil
                licenseInput = ""
            } catch {
                licenseError = error.localizedDescription
            }
        }
    }

    private func handleIconTap() {
        let now = Date()
        if let lastTapDate, now.timeIntervalSince(lastTapDate) > tapResetInterval {
            iconTapCount = 0
        }
        lastTapDate = now
        iconTapCount += 1
        guard iconTapCount >= requiredTapCount else { return }
        iconTapCount = 0
        environment.isDebugSectionRevealed = true
    }
}
