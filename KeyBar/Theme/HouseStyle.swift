// The shared look (colours, fonts, buttons, cards, the menu bar panel and the
// updater) lives in the HouseStyle package, shared with Ross's other Mac apps.
// Re-exported so every file here can use it without its own import.
@_exported import HouseStyle

extension AppInfo {
    static let keyBar = AppInfo(name: "KeyBar", repo: "keybar", cask: "keybar",
                                coffeeLine: "If KeyBar keeps your API keys safe")
}
