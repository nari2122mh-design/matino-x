import SwiftUI
import Foundation
import Security
import UIKit

/// BaypassX activation gate for MATINO X.
///
/// A license key is bound to exactly one device. On the first successful
/// activation the device identifier is written into the Firestore document;
/// every later activation must come from the same device or it is rejected.
final class BaypassLicense: ObservableObject {
    static let shared = BaypassLicense()

    @Published private(set) var isActivated: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var statusMessage: String?
    /// License duration / start date from Firestore, used by the Settings card.
    @Published private(set) var licenseDuration: String?
    @Published private(set) var licenseStartDate: Date?

    private static let projectID = "baypass-x-dbabb"
    private static let apiKey = "AIzaSyDDk-5RZaPuOtCd86aFhgXpMUNGaTtx5EQ"
    private static let collectionID = "licenses"
    private static let storedKeyDefaultsKey = "baypassx.license.key"
    private static let deviceIDDefaultsKey = "baypassx.device.id"

    private init() {
        isActivated = UserDefaults.standard.string(forKey: Self.storedKeyDefaultsKey) != nil
    }

    var storedKey: String? {
        UserDefaults.standard.string(forKey: Self.storedKeyDefaultsKey)
    }

    /// Human-readable time left for the current license, shown in Settings.
    var remainingTimeText: String {
        guard let duration = licenseDuration, !duration.isEmpty else { return "—" }
        if duration.lowercased().contains("life") { return "Lifetime" }

        guard let start = licenseStartDate,
              let seconds = Self.durationInSeconds(duration) else {
            return duration
        }
        let left = start.addingTimeInterval(seconds).timeIntervalSinceNow
        if left <= 0 { return "Expired" }

        let days = Int(left / 86_400)
        let hours = Int(left.truncatingRemainder(dividingBy: 86_400) / 3_600)
        let minutes = Int(left.truncatingRemainder(dividingBy: 3_600) / 60)
        if days > 0 {
            return "\(days) day\(days == 1 ? "" : "s")\(hours > 0 ? " \(hours) hour\(hours == 1 ? "" : "s")" : "") left"
        }
        if hours > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s")\(minutes > 0 ? " \(minutes) min" : "") left"
        }
        return "\(max(1, minutes)) min left"
    }

    private static func durationInSeconds(_ text: String) -> TimeInterval? {
        let lowered = text.lowercased()
        let number: Double
        if let match = lowered.range(of: "[0-9]+(?:\\.[0-9]+)?", options: .regularExpression),
           let value = Double(lowered[match]) {
            number = value
        } else {
            switch lowered {
            case "one day": number = 1
            case "one week": number = 7
            case "one month": number = 30
            case "one year": number = 365
            default: return nil
            }
        }
        if lowered.contains("hour") { return number * 3_600 }
        if lowered.contains("day") { return number * 86_400 }
        if lowered.contains("week") { return number * 7 * 86_400 }
        if lowered.contains("month") { return number * 30 * 86_400 }
        if lowered.contains("year") { return number * 365 * 86_400 }
        return nil
    }

    /// Stable per-device identifier. Keychain survives reinstalls; the
    /// identifierForVendor is the fallback when Keychain is unavailable.
    var deviceID: String {
        if let saved = Keychain.string(forKey: Self.deviceIDDefaultsKey), !saved.isEmpty {
            return saved
        }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        Keychain.set(id, forKey: Self.deviceIDDefaultsKey)
        return id
    }

    // MARK: - Public API

    func activate(rawKey: String) {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Enter your license key."
            return
        }
        guard !isChecking else { return }

        isChecking = true
        statusMessage = nil
        checkAndClaim(key: trimmed) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                switch outcome {
                case .accepted(let doc):
                    UserDefaults.standard.set(trimmed, forKey: Self.storedKeyDefaultsKey)
                    self.isActivated = true
                    self.statusMessage = nil
                    self.applyLicenseInfo(doc)
                case .rejected(let message), .unavailable(let message):
                    self.statusMessage = message
                }
            }
        }
    }

    /// Silent re-check of the stored key. Only a definitive rejection locks
    /// the app; a network failure keeps the current session unlocked.
    func revalidateStoredKey() {
        guard let key = storedKey else { return }
        fetchDocument(key: key) { [weak self] doc, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil { return } // offline: keep unlocked
                guard let doc else { self.lock(); return }
                guard doc.status.lowercased() == "active",
                      doc.deviceID == self.deviceID else {
                    self.lock()
                    return
                }
                self.applyLicenseInfo(doc)
            }
        }
    }

    /// Called on the main thread whenever the license document is available.
    private func applyLicenseInfo(_ doc: LicenseDoc) {
        licenseDuration = doc.duration
        if let createdAt = doc.createdAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            licenseStartDate = formatter.date(from: createdAt)
                ?? ISO8601DateFormatter().date(from: createdAt)
        } else {
            licenseStartDate = nil
        }
    }

    func deactivate() {
        UserDefaults.standard.removeObject(forKey: Self.storedKeyDefaultsKey)
        isActivated = false
        statusMessage = nil
        licenseDuration = nil
        licenseStartDate = nil
        // Intentionally keep the server-side device binding: the key stays
        // tied to this device and cannot be reused on another one.
    }

    private func lock() {
        UserDefaults.standard.removeObject(forKey: Self.storedKeyDefaultsKey)
        isActivated = false
        statusMessage = "This license is no longer valid on this device."
        licenseDuration = nil
        licenseStartDate = nil
    }

    // MARK: - Outcome

    private enum Outcome {
        case accepted(LicenseDoc)
        case rejected(String)
        case unavailable(String)
    }

    private struct LicenseDoc {
        let name: String
        let status: String
        let deviceID: String?
        let duration: String?
        let createdAt: String?
    }

    // MARK: - Activation logic (single device)

    private func checkAndClaim(key: String, completion: @escaping (Outcome) -> Void) {
        fetchDocument(key: key) { [weak self] doc, error in
            guard let self else { return }
            if let error { completion(.unavailable(error)); return }
            guard let doc else { completion(.rejected("Invalid license key.")); return }

            guard doc.status.lowercased() == "active" else {
                completion(.rejected("This license is \(doc.status.lowercased())."))
                return
            }

            let mine = self.deviceID
            if let bound = doc.deviceID, !bound.isEmpty {
                if bound == mine {
                    completion(.accepted(doc))
                } else {
                    completion(.rejected("This key is already activated on another device."))
                }
                return
            }

            // First activation: bind the key to this device.
            self.claimDocument(name: doc.name, deviceID: mine) { success in
                if success {
                    completion(.accepted(doc))
                } else {
                    completion(.unavailable("Could not bind the license. Check your connection."))
                }
            }
        }
    }

    // MARK: - Firestore REST

    private func documentsURL() -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "firestore.googleapis.com"
        c.path = "/v1/projects/\(Self.projectID)/databases/(default)/documents:runQuery"
        c.queryItems = [URLQueryItem(name: "key", value: Self.apiKey)]
        return c.url
    }

    private func fetchDocument(key: String, completion: @escaping (LicenseDoc?, String?) -> Void) {
        guard let url = documentsURL() else {
            completion(nil, "License service URL is invalid.")
            return
        }
        let query: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": Self.collectionID]],
                "where": [
                    "fieldFilter": [
                        "field": ["fieldPath": "key"],
                        "op": "EQUAL",
                        "value": ["stringValue": key]
                    ]
                ],
                "limit": 1
            ]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: query) else {
            completion(nil, "License request could not be built.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(nil, "Could not reach the license server. Check your connection.")
                return
            }
            guard let http = response as? HTTPURLResponse, let data, !data.isEmpty else {
                completion(nil, "License server returned an unexpected response.")
                return
            }
            guard http.statusCode == 200 else {
                completion(nil, Self.serverMessage(from: data) ?? "License check failed (HTTP \(http.statusCode)).")
                return
            }
            completion(Self.parseDocument(from: data), nil)
        }.resume()
    }

    private func claimDocument(name: String, deviceID: String, completion: @escaping (Bool) -> Void) {
        // PATCH without updateMask REPLACES the whole document and deletes
        // `key` / `status`, breaking the license forever. A mask of ONLY
        // `deviceID` updates that one field and preserves everything else.
        guard let url = URL(string: "https://firestore.googleapis.com/v1/\(name)?key=\(Self.apiKey)&updateMask.fieldPaths=deviceID") else {
            completion(false)
            return
        }
        let payload: [String: Any] = [
            "fields": ["deviceID": ["stringValue": deviceID]]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                completion(false)
                return
            }
            completion(true)
        }.resume()
    }

    private static func parseDocument(from data: Data) -> LicenseDoc? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for entry in payload {
            guard let document = entry["document"] as? [String: Any],
                  let name = document["name"] as? String,
                  let fields = document["fields"] as? [String: Any] else { continue }
            let status = (fields["status"] as? [String: Any])?["stringValue"] as? String ?? "Active"
            let device = (fields["deviceID"] as? [String: Any])?["stringValue"] as? String
            let duration = (fields["duration"] as? [String: Any])?["stringValue"] as? String
            let createdAt = (fields["createdAt"] as? [String: Any])?["timestampValue"] as? String
            return LicenseDoc(name: name, status: status, deviceID: device,
                              duration: duration, createdAt: createdAt)
        }
        return nil
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

// MARK: - Minimal Keychain helpers

private enum Keychain {
    static func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Activation screen

struct BaypassActivationView: View {
    @ObservedObject private var license = BaypassLicense.shared
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Brand
                    VStack(spacing: 12) {
                        AppLogo(size: 84)
                        Text("MATINO X")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .tracking(0.5)
                        Text("Enter your license key to unlock the app.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                    .padding(.bottom, 30)

                    // License key card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(
                                    Color.black,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("LICENSE KEY")
                                    .font(.system(size: 14, weight: .bold))
                                    .tracking(0.6)
                                Text("Paste or type your key")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 8) {
                            TextField("Enter Your Key", text: $key)
                                .font(.body.monospaced())
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.go)
                                .focused($keyFocused)
                                .onSubmit(activate)

                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    key = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.clipboard")
                                    Text("Paste")
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(minHeight: 46)
                                .padding(.horizontal, 8)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 48)
                        .background(
                            Color(white: 0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(AppTheme.consoleBackground)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }

                    // Activate - custom dark style: AppTheme.accent is white,
                    // so a prominent button rendered white-on-white (invisible).
                    Button(action: activate) {
                        HStack(spacing: 8) {
                            if license.isChecking {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "lock.open.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Activate")
                                    .font(.system(size: 16, weight: .bold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(white: 0.10))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(license.isChecking || normalizedKey.isEmpty)
                    .opacity(license.isChecking || normalizedKey.isEmpty ? 0.55 : 1)
                    .padding(.top, 20)

                    if let message = license.statusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                    }

                    Text("No key? Contact the seller who provided this build.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 22)

                    Button {
                        if let link = URL(string: "https://t.me/DYNASTY_212") {
                            openURL(link)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black)
                                .frame(width: 46, height: 46)
                                .overlay {
                                    Image(systemName: "crown.fill")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("OWNER FOR BUY KEY")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.primary)
                                Text("DM @DYNASTY_212")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(AppTheme.consoleBackground)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            keyFocused = true
        }
    }


    private var normalizedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func activate() {
        license.activate(rawKey: key)
    }
}
