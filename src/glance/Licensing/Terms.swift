//
//  Terms.swift
//  Mac ID
//
//  The Terms of Use the user agrees to before anything else runs.
//
//  The text ships inside the app (Resources/Terms.md, generated from src/tools/terms/Terms.md along
//  with the website's terms.html), so the user always agrees to the exact words they were shown —
//  offline, and without depending on what the website says today.
//
//  Agreement is recorded twice: locally, which is what gates the app, and with the fulfilment
//  service, which is what the admin dashboard shows. The service copy is keyed by the same hashed
//  Mac fingerprint as activation and carries nothing identifying. It's best-effort: if the Mac is
//  offline the report is retried at the next launch, and the app never waits on it.
//

import Foundation

nonisolated enum Terms {
    /// The version the bundled text declares on its "Version YYYY-MM-DD" line. Changing the terms
    /// means changing that line, and everyone is asked again. The literal is only a fallback for a
    /// bundle whose Terms.md is missing or unparseable, and must match the file.
    static let currentVersion: String = {
        let text = bundledText
        if let range = text.range(of: #"Version (\d{4}-\d{2}-\d{2})"#, options: .regularExpression) {
            return String(text[range].dropFirst("Version ".count))
        }
        return "2026-09-25"
    }()

    static let webURL = URL(string: "https://macid.net/terms.html")!
    static let reportEndpoint = URL(string: "https://macid.net/api/terms/accept")!

    private static let acceptedVersionKey = "MacID.acceptedTermsVersion"
    private static let acceptedDateKey = "MacID.acceptedTermsDate"
    private static let reportedVersionKey = "MacID.reportedTermsVersion"

    static var bundledText: String {
        guard let url = Bundle.main.url(forResource: "Terms", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    static var acceptedVersion: String? {
        UserDefaults.standard.string(forKey: acceptedVersionKey)
    }

    static var acceptedDate: Date? {
        UserDefaults.standard.object(forKey: acceptedDateKey) as? Date
    }

    static var isAccepted: Bool {
        acceptedVersion == currentVersion
    }

    /// True when an earlier version was accepted, so the gate can say the terms changed rather than
    /// greeting a long-time user as if they were new.
    static var isUpdate: Bool {
        acceptedVersion != nil && !isAccepted
    }

    static func accept() {
        UserDefaults.standard.set(currentVersion, forKey: acceptedVersionKey)
        UserDefaults.standard.set(Date(), forKey: acceptedDateKey)
        Task { await reportIfNeeded() }
    }

    /// Sends the agreement to the service once per version. Safe to call at every launch.
    static func reportIfNeeded() async {
        guard isAccepted,
              UserDefaults.standard.string(forKey: reportedVersionKey) != currentVersion else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let body: [String: String] = [
            "machine": Activation.machineFingerprint,
            "version": currentVersion,
            "app_version": version,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        var request = URLRequest(url: reportEndpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MacID/\(version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        UserDefaults.standard.set(currentVersion, forKey: reportedVersionKey)
    }
}
