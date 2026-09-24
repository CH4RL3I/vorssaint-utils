// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

SuperKeyMappingGuard.runIfRequestedAndExit()
Defaults.register()
MouseAccelerationGuard.runIfRequestedAndExit()
MouseAccelerationService.recoverPendingAtLaunch()

// Fork addition (Phase 3 prototype): warm up the menu-bar-manager singleton
// and force-enable it so the placeholder ControlItems show up in the menu
// bar right after launch. Force is TEMPORARY — in Phase 4 the toggle lives
// in Vorssaint's Settings UI and reads user intent.
MainActor.assumeIsolated {
    let svc = MenuBarManagerService.shared
    #if VORSSAINT_DEVELOPMENT
    svc.isEnabled = true
    #endif
    _ = svc
}

#if VORSSAINT_DEVELOPMENT
if CommandLine.arguments.contains("--notch-presentation-test") {
    NotchPresentationProbe.runAndExit()
}
#endif

if CommandLine.arguments.contains("--selftest") {
    SelfTest.runAndExit()
}
if CommandLine.arguments.contains("--sensors") {
    SensorDump.runAndExit()
}
if CommandLine.arguments.contains("--uninstall") {
    Uninstaller.runAndExit()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
