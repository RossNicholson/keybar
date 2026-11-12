import SwiftUI

/// Sends a key to GitHub repos' Actions secrets, or to a Cloudflare Worker
/// or Pages project, after one Touch ID
struct SendKeyView: View {
    @Environment(AppState.self) private var state
    let name: String
    let done: () -> Void

    @State private var kind: Destination.Kind = .githubActions
    @State private var nameThere = ""
    @State private var search = ""
    @State private var repos: [String] = []
    @State private var chosen: Set<String> = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var target = ""
    @State private var sendingNow = false
    @State private var results: [(String, Bool)] = []
    @State private var error: String?

    private var destinations: [Destination] {
        let secretName = nameThere.trimmingCharacters(in: .whitespaces).isEmpty ? name : nameThere.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .githubActions:
            return chosen.sorted().map { Destination(kind: kind, target: $0, secretName: secretName) }
        case .cloudflareWorker, .cloudflarePages:
            let typed = target.trimmingCharacters(in: .whitespaces)
            return typed.isEmpty ? [] : [Destination(kind: kind, target: typed, secretName: secretName)]
        }
    }

    /// owner/repo typed that isn't in the list, offered as is
    private var typedRepo: String? {
        let typed = search.trimmingCharacters(in: .whitespaces)
        let candidate = Destination(kind: .githubActions, target: typed, secretName: name)
        guard candidate.problem == nil, !repos.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) else { return nil }
        return typed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PopoverHeader(title: "Send \(name)",
                          subtitle: "So a deploy can use it. Touch ID first; the value goes straight to gh or wrangler, never on screen.")

            PillPicker(selection: $kind, options: Destination.Kind.allCases, track: AppColors.ground) { $0.title }

            switch kind {
            case .githubActions: repoPicker
            case .cloudflareWorker, .cloudflarePages:
                VStack(alignment: .leading, spacing: 5) {
                    FieldLabel(text: kind.targetLabel, detail: "as wrangler knows it")
                    HouseField(placeholder: kind.targetExample, text: $target)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                FieldLabel(text: "Name there", detail: "leave empty to use \(name)")
                HouseField(placeholder: name, text: $nameThere)
            }

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: result.1 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.1 ? AppColors.mint : AppColors.coral)
                            Text(result.0)
                                .font(.mono(10))
                                .foregroundStyle(AppColors.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let error { SettingNote(error) }

            HStack {
                GhostButton(title: results.isEmpty ? "Cancel" : "Done", action: done)
                Spacer()
                PillButton(title: sendingNow ? "Sending…" : destinations.count > 1 ? "Send to \(destinations.count)" : "Send",
                           symbol: "paperplane.fill", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(destinations.isEmpty || sendingNow)
                    .opacity(destinations.isEmpty || sendingNow ? 0.5 : 1)
            }
        }
        .popoverChrome(width: 480)
        .onAppear(perform: loadRepos)
    }

    private var repoPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Repositories", detail: chosen.isEmpty ? "tick one or more" : "\(chosen.count) ticked")
            SearchField(text: $search, placeholder: "Find a repo, or type owner/repo")
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking gh for your repos…").font(.mono(10)).foregroundStyle(AppColors.secondaryText)
                }
            } else if let loadError {
                SettingNote(loadError)
            }
            ScrollView {
                VStack(spacing: 2) {
                    if let typedRepo { repoRow(typedRepo) }
                    ForEach(repos.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } + chosen.filter { !repos.contains($0) }.sorted(), id: \.self) { repo in
                        repoRow(repo)
                    }
                }
            }
            .frame(height: 170)
            .card(radius: Radius.small)
        }
    }

    private func repoRow(_ repo: String) -> some View {
        let on = chosen.contains(repo)
        return Button {
            if on { chosen.remove(repo) } else { chosen.insert(repo) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? AppColors.text : AppColors.secondaryText)
                Text(repo)
                    .font(.mono(10.5))
                    .foregroundStyle(AppColors.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadRepos() {
        guard repos.isEmpty, !state.isDemo else {
            if state.isDemo { repos = ["RossNicholson/shop", "RossNicholson/website", "RossNicholson/keybar"] }
            return
        }
        loading = true
        Task {
            let result = await Task.detached { Result { try Sender.githubRepos() } }.value
            loading = false
            switch result {
            case .success(let list): repos = list
            case .failure(let error): loadError = error.localizedDescription + " You can still type owner/repo."
            }
        }
    }

    private func send() {
        let targets = destinations
        error = nil
        if let problem = targets.lazy.compactMap(\.problem).first {
            error = problem
            return
        }
        let reason = targets.count == 1 ? "send \(name) to \(targets[0].label)" : "send \(name) to \(targets.count) places"
        sendingNow = true
        Task {
            defer { sendingNow = false }
            guard await OwnerCheck.confirm(reason, required: !state.isDemo) else {
                error = "Not sent: Touch ID wasn't confirmed."
                return
            }
            results = []
            for destination in targets {
                switch await state.sendConfirmed(name, to: destination, source: .you) {
                case .success(let message): results.append((message, true))
                case .failure(let failure): results.append(("\(destination.label): \(failure.localizedDescription)", false))
                }
            }
        }
    }
}
