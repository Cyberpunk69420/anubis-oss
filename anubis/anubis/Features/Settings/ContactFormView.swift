//
//  ContactFormView.swift
//  anubis
//
//  Bug report / contact form that submits to Formspark.
//

import SwiftUI

struct ContactFormView: View {
    var onClose: (() -> Void)? = nil

    @State private var name = ""
    @State private var email = ""
    @State private var subject: SubjectType = .bug
    @State private var message = ""
    @State private var submitting = false
    @State private var submitted = false
    @State private var errorMessage: String?

    private let formsparkURL = "YOUR_FORMSPARK_ID"

    enum SubjectType: String, CaseIterable {
        case bug = "Bug Report"
        case feature = "Feature Request"
        case support = "Support"
        case general = "General"
    }

    // Auto-collected system info
    private var systemInfo: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return "Anubis v\(version) (\(build)) · macOS \(osVersion)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Contact & Bug Reports")
                    .font(.headline)
                Spacer()
                Button { onClose?() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding()

            Divider()

            if submitted {
                successView
            } else {
                formView
            }
        }
        .frame(width: 480, height: 520)
    }

    // MARK: - Form

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // Name
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextField("Your name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                // Email
                VStack(alignment: .leading, spacing: 4) {
                    Text("Email").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextField("your@email.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                }

                // Subject
                VStack(alignment: .leading, spacing: 4) {
                    Text("Subject").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Picker("", selection: $subject) {
                        ForEach(SubjectType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                // Message
                VStack(alignment: .leading, spacing: 4) {
                    Text("Message").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextEditor(text: $message)
                        .font(.body)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.cardBackground)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                                }
                        }
                }

                // System info (auto-attached)
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.tertiary)
                    Text(systemInfo)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Privacy notice
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.tertiary)
                        .font(.caption2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your message will be sent securely to our support team.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Link("View Privacy Policy", destination: Constants.URLs.privacyPolicy)
                            .font(.caption2)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                // Submit
                Button {
                    submit()
                } label: {
                    HStack {
                        if submitting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(submitting ? "Sending..." : "Send")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isValid || submitting)
            }
            .padding()
        }
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Message Sent")
                .font(.title2.weight(.semibold))
            Text("We'll get back to you within 24-48 hours.")
                .foregroundStyle(.secondary)
            Button("Done") { onClose?() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Logic

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        email.contains("@") &&
        !message.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        submitting = true
        errorMessage = nil

        let payload: [String: String] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "email": email.trimmingCharacters(in: .whitespaces),
            "subject": subject.rawValue,
            "message": message.trimmingCharacters(in: .whitespaces),
            "_app_info": systemInfo
        ]

        guard let url = URL(string: formsparkURL),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            errorMessage = "Failed to prepare request."
            submitting = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                submitting = false
                if let error = error {
                    errorMessage = "Failed to send: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, http.statusCode >= 200 && http.statusCode < 300 {
                    submitted = true
                } else {
                    errorMessage = "Server error. Please try again."
                }
            }
        }.resume()
    }
}

#Preview {
    ContactFormView()
}
