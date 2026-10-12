import AppKit
import SwiftUI
import VibeCore

/// First launch: permissions, speech model, API key.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var priming = false
    @State private var primeResult: PermissionPrimer.Result?
    @State private var key = ""
    @State private var keyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                Text("VibeMeeting")
                    .font(.largeTitle.weight(.bold))
            }

            step(number: 1, title: "Audio") {
                Text("VibeMeeting needs to hear your calls. Audio stays on this Mac. Only text is sent to Claude to draft replies.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow audio capture") {
                        Task {
                            priming = true
                            primeResult = await PermissionPrimer.run()
                            priming = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(priming)
                    if priming {
                        ProgressView().controlSize(.small)
                        Text("Setting up… the English speech model may take a minute to download.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let primeResult {
                    Text(primeResult.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            step(number: 2, title: "Claude API key") {
                SecureField("sk-ant-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                if app.settings.hasAPIKey && key.isEmpty {
                    Label("Key saved in Keychain.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(.red)
                }
            }

            step(number: 3, title: "About me") {
                Text("Your brand, stack and pricing rules go into every reply. A template is filled in; you can finish it in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Edit About me") { app.windows.showSettings() }
                    .controlSize(.small)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func step<Content: View>(number: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(Brand.accent.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    private func finish() {
        if !key.trimmingCharacters(in: .whitespaces).isEmpty {
            do {
                try app.settings.setAPIKey(key)
            } catch {
                keyError = error.localizedDescription
                return
            }
        }
        app.settings.hasCompletedOnboarding = true
        app.windows.close("welcome")
    }
}
