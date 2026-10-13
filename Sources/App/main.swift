import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !L10n.isChosen { askLanguage() }
        IslandWindowController.shared.start()
        setupStatusItem()
        ClaudeWatcher.shared.start()
        model.greet()
    }

    // MARK: - Иконка в строке меню (только чтобы выйти и настроить)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "flame", accessibilityDescription: "Notchling")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !model.accessibilityGranted {
            menu.addItem(item(tr("Открыть настройки Универсального доступа…", "Open Accessibility settings…"), #selector(openAXSettings)))
        }
        menu.addItem(.separator())

        let hide = item(tr("Прятать, когда ничего не происходит", "Hide when idle"), #selector(toggleHide))
        hide.state = model.hideWhenIdle ? .on : .off
        menu.addItem(hide)

        let sound = item(tr("Звук", "Sound"), #selector(toggleSound))
        sound.state = SoundEngine.shared.enabled ? .on : .off
        menu.addItem(sound)

        let wisps = NSMenuItem(title: tr("Огонёк", "Flame"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in WispVariant.allCases {
            let it = item(v.displayName, #selector(pickVariant(_:)))
            it.representedObject = v.rawValue
            it.state = model.variant == v ? .on : .off
            sub.addItem(it)
        }
        wisps.submenu = sub
        menu.addItem(wisps)

        let langs = NSMenuItem(title: tr("Язык", "Language"), action: nil, keyEquivalent: "")
        let lsub = NSMenu()
        for l in AppLanguage.allCases {
            let it = item(l.displayName, #selector(pickLanguage(_:)))
            it.representedObject = l.rawValue
            it.state = L10n.language == l ? .on : .off
            lsub.addItem(it)
        }
        langs.submenu = lsub
        menu.addItem(langs)

        menu.addItem(.separator())
        menu.addItem(item(tr("Сохранить диагностику", "Save diagnostics"), #selector(diagnostics)))
        let dbg = item(tr("Вести отладочный журнал", "Debug log"), #selector(toggleDebug))
        dbg.state = ClaudeWatcher.shared.debugLog ? .on : .off
        menu.addItem(dbg)
        menu.addItem(item(tr("Выйти", "Quit"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    private func statusLine() -> String {
        if !model.accessibilityGranted { return tr("Нет доступа «Универсальный доступ»", "No Accessibility access") }
        if !model.claudeRunning { return tr("Жду, когда запустится Claude", "Waiting for Claude to launch") }
        return tr("Слежу за Claude: \(model.title)", "Watching Claude: \(model.title)")
    }

    @objc private func toggleSound() { SoundEngine.shared.enabled.toggle() }
    @objc private func toggleHide() { model.hideWhenIdle.toggle() }
    @objc private func pickVariant(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let v = WispVariant(rawValue: raw) {
            model.variant = v
            model.greet()
        }
    }
    @objc private func pickLanguage(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let l = AppLanguage(rawValue: raw) {
            L10n.language = l
            model.objectWillChange.send()
        }
    }

    /// Первый запуск: выбор языка.
    private func askLanguage() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Notchling"
        a.informativeText = "Choose a language · Выберите язык"
        a.addButton(withTitle: "English")
        a.addButton(withTitle: "Русский")
        L10n.language = a.runModal() == .alertSecondButtonReturn ? .ru : .en
    }

    @objc private func toggleDebug() { ClaudeWatcher.shared.debugLog.toggle() }
    @objc private func openAXSettings() {
        // Локальная ссылка на раздел Системных настроек (не веб-адрес).
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        ClaudeWatcher.shared.requestAccessibility()
    }
    @objc private func diagnostics() {
        if let url = ClaudeWatcher.shared.writeDiagnostics() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
