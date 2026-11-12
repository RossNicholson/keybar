import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        Screen {
            ScreenHeader(title: "Settings", subtitle: "KeyBar \(AppInfo.keyBar.version)")

            SectionLabel(text: "Keys")
            SettingToggle(title: "Ask for Touch ID",
                          detail: OwnerCheck.isAvailable
                            ? "Before showing or copying a key. macOS asks; KeyBar only learns yes or no."
                            : "This Mac has no Touch ID or password set up, so keys are shown straight away.",
                          isOn: $settings.requireTouchID)
            SettingCard(title: "Clear the clipboard after", detail: "A copied key is wiped from the clipboard after this, unless you've copied something else since. Clipboard managers are asked to skip it.", below: {
                PillPicker(selection: $settings.clipboardSeconds, options: AppSettings.clipboardChoices, track: AppColors.ground) {
                    AppSettings.label(forSeconds: $0)
                }
            })

            SettingCard(title: "Ask before Claude uses a key",
                        detail: "Touch ID before Claude Code (or any app using KeyBar's MCP server) runs a command with one of your keys. The prompt shows the command. With a time, one yes covers the same keys from the same project until it's up.",
                        below: {
                PillPicker(selection: $settings.approvalSeconds, options: AppSettings.approvalChoices, track: AppColors.ground) {
                    AppSettings.approvalLabel($0)
                }
            })

            SettingToggle(title: "Remind me before keys expire",
                          detail: "A notification two weeks before a key's expiry date, and on the day. Set the date when you add or edit a key; Test fills it in for GitHub and Cloudflare tokens.",
                          isOn: $settings.expiryReminders)

            SectionLabel(text: "Your other Macs")
            SettingToggle(title: "Sync with iCloud Keychain",
                          detail: state.canSync
                            ? "Keys, with their groups, notes and folders, go to iCloud Keychain, so KeyBar on each Mac signed in to your Apple Account has them. Apple encrypts them end to end. Needs Passwords & Keychain on in System Settings → Apple Account → iCloud."
                            : "This copy of KeyBar can't use iCloud Keychain. The version from Homebrew or GitHub can.",
                          isOn: Binding(get: { settings.syncWithICloud }, set: { on in Task { await state.setSync(on) } })) {
                if state.isMovingKeys { SettingNote("Moving keys…") }
                if let note = state.syncNote { SettingNote(note) }
            }
            .disabled(!state.canSync || state.isMovingKeys)

            SectionLabel(text: "App")
            SettingToggle(title: "Quick copy \(GlobalHotKey.displayName)",
                          detail: "Press \(GlobalHotKey.displayName) in any app, type a few letters of a key's name and press Return to copy it (after Touch ID). Esc closes it.",
                          isOn: $settings.quickCopyShortcut) {
                if settings.quickCopyShortcut && settings.shortcutTaken {
                    SettingNote("Another app already uses \(GlobalHotKey.displayName), so it isn't available.")
                }
            }
            SettingToggle(title: "Show in the Dock", detail: "Off, KeyBar lives in the menu bar and only shows in the Dock while this window is open.",
                          isOn: $settings.showInDock)
            SettingToggle(title: "Dot when Claude Code is off",
                          detail: "A coral dot on the menu bar key while Claude Code isn't connected to KeyBar.",
                          isOn: $settings.disconnectedDot)
            SettingToggle(title: "Open at login", detail: "Start KeyBar quietly in the menu bar when you log in. Claude Code also starts it when it needs a key.",
                          isOn: Binding(get: { settings.openAtLogin }, set: { settings.setOpenAtLogin($0) })) {
                if let error = settings.loginError { SettingNote(error) }
            }
            UpdateBlock(updater: state.updater, app: .keyBar)

            SectionLabel(text: "Where things are")
            VStack(alignment: .leading, spacing: 6) {
                place("Key values", state.store.syncs
                      ? "iCloud Keychain, as items named “KeyBar: NAME” (open the Passwords app to see them)"
                      : "Your login keychain, as items named “KeyBar: NAME”")
                place("Names, groups, notes, folders", "~/.keybar/index.json")
                place("Activity log", "~/.keybar/activity.json")
                place("Claude Code connection", "~/.claude.json (and the note in ~/.claude/CLAUDE.md)")
                HStack {
                    GhostButton(title: "Open ~/.keybar", symbol: "folder") {
                        NSWorkspace.shared.open(Storage.directory)
                    }
                    GhostButton(title: "Open Keychain Access", symbol: "key") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
                    }
                }
                .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: Radius.window)

            SectionLabel(text: "Danger zone")
            DangerZone()

            HStack(spacing: 12) {
                MonoLink(title: "GitHub", destination: AppInfo.keyBar.repoURL)
                MonoLink(title: "Get help", destination: URL(string: "https://rossnicholson.dev/support")!)
                MonoLink(title: "Privacy", destination: URL(string: "https://rossnicholson.dev/privacy")!)
                Spacer()
                Text("Made by Ross Nicholson · MIT licence")
                    .font(.mono(10))
                    .foregroundStyle(AppColors.secondaryText)
            }
            .padding(.top, 8)
        }
    }

    private func place(_ what: String, _ where_: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(what)
                .font(.mono(10.5, weight: .semibold))
                .foregroundStyle(AppColors.text)
                .frame(width: 200, alignment: .leading)
            Text(where_)
                .font(.mono(10.5))
                .foregroundStyle(AppColors.secondaryText)
                .textSelection(.enabled)
        }
    }
}

/// Deletes every key, the index and the log, and disconnects Claude Code
private struct DangerZone: View {
    @Environment(AppState.self) private var state
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingLabel(title: "Delete everything",
                         detail: "Removes all \(state.store.records.count) keys from your Keychain\(state.store.syncs ? " and from iCloud Keychain, so from all your Macs" : ""), clears the activity log and disconnects Claude Code. This can't be undone.")
            HStack {
                ConfirmButton(title: "Delete everything", confirmTitle: "Really delete all keys?") {
                    Task {
                        guard await OwnerCheck.confirm("delete all your keys", required: state.settings.requireTouchID && !state.isDemo) else { return }
                        do {
                            try state.deleteEverything()
                            await state.claude.disconnect()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
            if let error { SettingNote(error) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Radius.window)
    }
}
