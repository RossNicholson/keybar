import AppKit
import SwiftUI

/// Swaps a key for a new one: make it, paste it, test it, send it wherever
/// the old one went, then revoke the old one
struct RotateKeyView: View {
    @Environment(AppState.self) private var state
    let name: String
    let done: () -> Void

    @State private var value = ""
    @State private var newFile: (name: String, contents: String)?
    @State private var testResult: KeyTester.Result?
    @State private var testing = false
    @State private var working = false
    @State private var saved = false
    @State private var results: [(String, Bool)] = []
    @State private var error: String?

    private var record: SecretRecord? { state.store.record(name) }
    private var newValue: String { newFile?.contents ?? value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PopoverHeader(title: "Rotate \(name)",
                          subtitle: "Swap in a new key, send it everywhere the old one went, then turn the old one off.")
            if let record {
                step(1, "Make a new key") {
                    if let page = KeyPages.url(for: record) {
                        GhostButton(title: "Open \(record.service?.name ?? "the") keys page", symbol: "arrow.up.right.square") {
                            NSWorkspace.shared.open(page)
                        }
                    } else {
                        Text("Make one wherever you got this key.")
                            .font(.mono(10))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                step(2, record.isFile ? "Choose the new file" : "Paste it here") {
                    VStack(alignment: .leading, spacing: 8) {
                        if record.isFile {
                            HStack(spacing: 8) {
                                if let newFile { FileValueRow(fileName: newFile.name, size: newFile.contents.utf8.count) }
                                GhostButton(title: newFile == nil ? "Choose a file…" : "Another file…", symbol: "doc.badge.plus", action: chooseFile)
                            }
                        } else {
                            HouseField(placeholder: "The new key", text: $value, secure: true)
                        }
                        if KeyTester.canTest(record) {
                            HStack(spacing: 8) {
                                GhostButton(title: testing ? "Testing…" : "Test it", symbol: "checkmark.seal", action: test)
                                    .disabled(newValue.isEmpty || testing)
                                if let testResult {
                                    Text(testResult.summary)
                                        .font(.mono(9.5))
                                        .foregroundStyle(testResult.outcome == .works ? AppColors.text : AppColors.destructive)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                step(3, record.sentTo.isEmpty ? "Save it" : "Save it and send it to \(record.sentTo.count) place\(record.sentTo.count == 1 ? "" : "s")") {
                    VStack(alignment: .leading, spacing: 6) {
                        if !record.sentTo.isEmpty && !saved {
                            Text(record.sentTo.map(\.label).joined(separator: ", "))
                                .font(.mono(9.5))
                                .foregroundStyle(AppColors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: result.1 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(result.1 ? AppColors.mint : AppColors.coral)
                                Text(result.0)
                                    .font(.mono(9.5))
                                    .foregroundStyle(AppColors.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                step(4, "Turn the old key off") {
                    Text(saved
                         ? "Done here. Now delete or revoke the old key on \(record.service?.name ?? "its service")'s site, so a leaked copy stops working."
                         : "Once it's saved, delete or revoke the old key on \(record.service?.name ?? "its service")'s site.")
                        .font(.mono(10))
                        .foregroundStyle(saved ? AppColors.text : AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error { SettingNote(error) }

            HStack {
                GhostButton(title: saved ? "Done" : "Cancel", action: done)
                Spacer()
                if !saved {
                    PillButton(title: working ? "Saving…" : "Save", symbol: "checkmark", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(newValue.isEmpty || working)
                        .opacity(newValue.isEmpty || working ? 0.5 : 1)
                }
            }
        }
        .popoverChrome(width: 500)
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.display(15, relativeTo: .headline))
                .foregroundStyle(AppColors.ink)
                .frame(width: 22, height: 22)
                .background(AppColors.pastels[(number - 1) % AppColors.pastels.count], in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.mono(11, weight: .semibold))
                    .foregroundStyle(AppColors.text)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseFile() {
        guard let file = KeyFile.choose(title: "Choose the new \(name) file") else { return }
        switch file {
        case .success(let (fileName, contents)): newFile = (fileName, contents)
        case .failure(let problem): error = problem.localizedDescription
        }
    }

    private func test() {
        guard let record else { return }
        testing = true
        let candidate = newValue
        Task {
            testResult = await KeyTester.test(record, value: candidate)
            testing = false
        }
    }

    private func save() {
        guard let record else { return }
        let candidate = newValue
        let places = record.sentTo
        error = nil
        if candidate == state.store.quietValue(name) {
            error = "That's the same key as before. Make a new one first."
            return
        }
        working = true
        Task {
            defer { working = false }
            let reason = places.isEmpty ? "replace \(name) with a new key" : "replace \(name) and send it to \(places.count) place\(places.count == 1 ? "" : "s")"
            guard await OwnerCheck.confirm(reason, required: !state.isDemo) else {
                error = "Not changed: Touch ID wasn't confirmed."
                return
            }
            do {
                try state.rotate(name, to: candidate)
            } catch {
                self.error = error.localizedDescription
                return
            }
            if let expires = testResult?.expiresAt { state.setExpiry(name, expires) }
            saved = true
            for destination in places {
                switch await state.sendConfirmed(name, to: destination, source: .you) {
                case .success(let message): results.append((message, true))
                case .failure(let failure): results.append(("\(destination.label): \(failure.localizedDescription)", false))
                }
            }
        }
    }
}
