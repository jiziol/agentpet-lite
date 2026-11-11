import SwiftUI
import AppKit
import AgentPetCore

struct AgentPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives in a status-item popover and floating windows managed by
        // AppDelegate; this scene only satisfies the App protocol. It used to be
        // `Settings { EmptyView() }`, which macOS 26 presents at launch (and on
        // ⌘,) as a blank "AgentPet Settings" window. A never-inserted
        // MenuBarExtra owns no window, so nothing blank can appear.
        // simplify: `.defaultLaunchBehavior(.suppressed)` is the direct fix once
        // the deployment target reaches macOS 15.
        MenuBarExtra("AgentPet Lite", isInserted: .constant(false)) { EmptyView() }
            .commands {
                // Keep the app menu's "Settings…" (⌘,) and route it to the real
                // Settings window.
                CommandGroup(replacing: .appSettings) {
                    Button {
                        SettingsWindowController.shared.show()
                    } label: {
                        // Reuses the existing "Settings" translation.
                        Text(NSLocalizedString("Settings", comment: "app menu") + "…")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

/// Runs the app as a menu bar accessory (no Dock icon) and boots the daemon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Held strongly so the Sparkle updater delegate and background timers are
    // never deallocated for the lifetime of the app.
    private var updater: UpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        BubbleSettings.shared.applyAppearance()
        _ = AppLanguage.shared   // apply the saved language before any UI renders
        // Commit the offline starter before any library/background slicing starts.
        DefaultPetBootstrap.installIfNeeded()
        // Load only the selected pet up front so the menu bar + pet appear at
        // once; the rest of the library slices in on later run-loop ticks.
        ImagePetStore.shared.loadFast(priorityID: PetController.shared.selectedPetID)
        if PetController.shared.selectedPetID == nil {
            PetController.shared.selectedPetID = ImagePetStore.shared.packs.first?.id
        }
        // Agent brand icons aren't needed for first paint; warm them after launch.
        Task { @MainActor in AgentIcons.prewarm() }
        PetController.shared.start()
        PetWindowController.shared.start()
        AppDaemon.shared.start()
        // Local builds also need automatic Codex quota monitoring; opening
        // Status for a one-off read must not be required to receive reminders.
        NativeUsageProbe.shared.start()
        DailyTokenUsageController.shared.start()
        PomodoroController.shared.activate()
        if !AgentPetPaths.isLocal {
        OpenUsageClient.shared.start()
        SettingsModel.shared.migrateInstalledHooksIfNeeded()
        SettingsModel.shared.repairStaleHookPathsIfNeeded()
        updater = UpdaterController.shared
        }
        StatusBarController.shared.start()
        SettingsWindowController.shared.showOnFirstLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let result = AppDaemon.shared.flushSnapshots()
        if result.isFlushed { return .terminateNow }
        // Keep the failed value in memory and let the user fix storage or
        // explicitly choose to quit. Do not silently claim a successful flush.
        let alert = NSAlert()
        alert.messageText = "未读记录保存失败"
        alert.informativeText = "最新记录尚未保存。可以取消退出并检查存储，或仍然退出。"
        alert.addButton(withTitle: "取消退出")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        PomodoroController.shared.prepareForTermination()
        DailyTokenUsageController.shared.stop()
        StatusBarController.shared.stop()
        AppDaemon.shared.stop()
        PetController.shared.stop()
        PetWindowController.shared.stop()
    }

}
