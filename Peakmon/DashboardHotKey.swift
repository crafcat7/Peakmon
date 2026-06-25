//
//  DashboardHotKey.swift
//  Peakmon
//
//  Global shortcut plumbing for opening the main Dashboard window.
//

import AppKit
import Carbon
import Foundation

struct DashboardHotKey: Equatable {
    static let keyCodeStorageKey = "dashboardHotKeyKeyCode"
    static let modifiersStorageKey = "dashboardHotKeyModifiers"

    static let defaultKeyCode = Int(kVK_ANSI_D)
    static let defaultModifiers = Int(controlKey) | Int(optionKey) | Int(cmdKey)

    let keyCode: UInt32
    let modifiers: UInt32

    static var current: DashboardHotKey {
        let defaults = UserDefaults.standard
        let storedKeyCode = defaults.object(forKey: keyCodeStorageKey) as? Int ?? defaultKeyCode
        let storedModifiers = defaults.object(forKey: modifiersStorageKey) as? Int ?? defaultModifiers
        return DashboardHotKey(
            keyCode: UInt32(max(storedKeyCode, 0)),
            modifiers: UInt32(max(storedModifiers, 0)),
        )
    }

    static func resetToDefault() {
        let defaults = UserDefaults.standard
        defaults.set(defaultKeyCode, forKey: keyCodeStorageKey)
        defaults.set(defaultModifiers, forKey: modifiersStorageKey)
    }

    static func isValid(keyCode: Int, carbonModifiers: Int) -> Bool {
        guard !modifierOnlyKeyCodes.contains(keyCode) else { return false }
        let requiredModifiers = Int(controlKey) | Int(optionKey) | Int(cmdKey) | Int(shiftKey)
        return carbonModifiers & requiredModifiers != 0
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 0
        if flags.contains(.control) { modifiers |= Int(controlKey) }
        if flags.contains(.option) { modifiers |= Int(optionKey) }
        if flags.contains(.command) { modifiers |= Int(cmdKey) }
        if flags.contains(.shift) { modifiers |= Int(shiftKey) }
        return modifiers
    }

    static func displayString(keyCode: Int, modifiers: Int) -> String {
        "\(modifierDisplayString(modifiers))\(keyDisplayString(keyCode))"
    }

    private static func modifierDisplayString(_ modifiers: Int) -> String {
        var result = ""
        if modifiers & Int(controlKey) != 0 { result += "⌃" }
        if modifiers & Int(optionKey) != 0 { result += "⌥" }
        if modifiers & Int(shiftKey) != 0 { result += "⇧" }
        if modifiers & Int(cmdKey) != 0 { result += "⌘" }
        return result
    }

    private static func keyDisplayString(_ keyCode: Int) -> String {
        keyLabels[keyCode] ?? "Key \(keyCode)"
    }

    private static let modifierOnlyKeyCodes: Set<Int> = [
        Int(kVK_Shift),
        Int(kVK_RightShift),
        Int(kVK_Control),
        Int(kVK_RightControl),
        Int(kVK_Option),
        Int(kVK_RightOption),
        Int(kVK_Command),
        Int(kVK_RightCommand),
        Int(kVK_CapsLock),
        Int(kVK_Function),
    ]

    private static let keyLabels: [Int: String] = [
        Int(kVK_ANSI_A): "A",
        Int(kVK_ANSI_B): "B",
        Int(kVK_ANSI_C): "C",
        Int(kVK_ANSI_D): "D",
        Int(kVK_ANSI_E): "E",
        Int(kVK_ANSI_F): "F",
        Int(kVK_ANSI_G): "G",
        Int(kVK_ANSI_H): "H",
        Int(kVK_ANSI_I): "I",
        Int(kVK_ANSI_J): "J",
        Int(kVK_ANSI_K): "K",
        Int(kVK_ANSI_L): "L",
        Int(kVK_ANSI_M): "M",
        Int(kVK_ANSI_N): "N",
        Int(kVK_ANSI_O): "O",
        Int(kVK_ANSI_P): "P",
        Int(kVK_ANSI_Q): "Q",
        Int(kVK_ANSI_R): "R",
        Int(kVK_ANSI_S): "S",
        Int(kVK_ANSI_T): "T",
        Int(kVK_ANSI_U): "U",
        Int(kVK_ANSI_V): "V",
        Int(kVK_ANSI_W): "W",
        Int(kVK_ANSI_X): "X",
        Int(kVK_ANSI_Y): "Y",
        Int(kVK_ANSI_Z): "Z",
        Int(kVK_ANSI_0): "0",
        Int(kVK_ANSI_1): "1",
        Int(kVK_ANSI_2): "2",
        Int(kVK_ANSI_3): "3",
        Int(kVK_ANSI_4): "4",
        Int(kVK_ANSI_5): "5",
        Int(kVK_ANSI_6): "6",
        Int(kVK_ANSI_7): "7",
        Int(kVK_ANSI_8): "8",
        Int(kVK_ANSI_9): "9",
        Int(kVK_Space): "Space",
        Int(kVK_Return): "Return",
        Int(kVK_Tab): "Tab",
        Int(kVK_Delete): "Delete",
        Int(kVK_Escape): "Esc",
        Int(kVK_ForwardDelete): "Forward Delete",
        Int(kVK_Home): "Home",
        Int(kVK_End): "End",
        Int(kVK_PageUp): "Page Up",
        Int(kVK_PageDown): "Page Down",
        Int(kVK_LeftArrow): "←",
        Int(kVK_RightArrow): "→",
        Int(kVK_UpArrow): "↑",
        Int(kVK_DownArrow): "↓",
        Int(kVK_F1): "F1",
        Int(kVK_F2): "F2",
        Int(kVK_F3): "F3",
        Int(kVK_F4): "F4",
        Int(kVK_F5): "F5",
        Int(kVK_F6): "F6",
        Int(kVK_F7): "F7",
        Int(kVK_F8): "F8",
        Int(kVK_F9): "F9",
        Int(kVK_F10): "F10",
        Int(kVK_F11): "F11",
        Int(kVK_F12): "F12",
    ]
}

struct PopoverHotKey: Equatable {
    static let keyCodeStorageKey = "popoverHotKeyKeyCode"
    static let modifiersStorageKey = "popoverHotKeyModifiers"

    static let defaultKeyCode = Int(kVK_ANSI_P)
    static let defaultModifiers = Int(controlKey) | Int(shiftKey) | Int(cmdKey)

    let keyCode: UInt32
    let modifiers: UInt32

    static var current: PopoverHotKey {
        let defaults = UserDefaults.standard
        let storedKeyCode = defaults.object(forKey: keyCodeStorageKey) as? Int ?? defaultKeyCode
        let storedModifiers = defaults.object(forKey: modifiersStorageKey) as? Int ?? defaultModifiers
        return PopoverHotKey(
            keyCode: UInt32(max(storedKeyCode, 0)),
            modifiers: UInt32(max(storedModifiers, 0)),
        )
    }

    static func resetToDefault() {
        let defaults = UserDefaults.standard
        defaults.set(defaultKeyCode, forKey: keyCodeStorageKey)
        defaults.set(defaultModifiers, forKey: modifiersStorageKey)
    }
}

final class DashboardHotKeyController {
    static let shared = DashboardHotKeyController()

    private static let dashboardSignature: OSType = 0x506B4448 // "PkDH"
    private static let popoverSignature: OSType = 0x506B5048 // "PkPH"
    private static let hotKeyID: UInt32 = 1

    private var dashboardHotKeyRef: EventHotKeyRef?
    private var popoverHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var defaultsObserver: NSObjectProtocol?
    private var dashboardAction: (() -> Void)?
    private var popoverAction: (() -> Void)?

    private init() {}

    func start(action: @escaping () -> Void) {
        dashboardAction = action
        start()
    }

    func startPopover(action: @escaping () -> Void) {
        popoverAction = action
        start()
    }

    private func start() {
        installEventHandlerIfNeeded()
        observeDefaultsIfNeeded()
        registerCurrentShortcuts()
    }

    private func observeDefaultsIfNeeded() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            self?.registerCurrentShortcuts()
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed),
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event,
                      let userData
                else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID,
                )
                guard status == noErr else { return noErr }

                let controller = Unmanaged<DashboardHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                let action: (() -> Void)?
                switch (hotKeyID.signature, hotKeyID.id) {
                case (DashboardHotKeyController.dashboardSignature, DashboardHotKeyController.hotKeyID):
                    action = controller.dashboardAction
                case (DashboardHotKeyController.popoverSignature, DashboardHotKeyController.hotKeyID):
                    action = controller.popoverAction
                default:
                    action = nil
                }

                guard let action else { return noErr }
                DispatchQueue.main.async {
                    action()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPointer,
            &eventHandler,
        )
    }

    private func registerCurrentShortcuts() {
        registerDashboardShortcut()
        registerPopoverShortcut()
    }

    private func registerDashboardShortcut() {
        unregisterDashboardShortcut()
        guard dashboardAction != nil else { return }
        let shortcut = DashboardHotKey.current
        guard DashboardHotKey.isValid(
            keyCode: Int(shortcut.keyCode),
            carbonModifiers: Int(shortcut.modifiers),
        ) else {
            return
        }

        registerShortcut(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers,
            signature: Self.dashboardSignature,
            name: "dashboard",
            hotKeyRef: &dashboardHotKeyRef,
        )
    }

    private func registerPopoverShortcut() {
        unregisterPopoverShortcut()
        guard popoverAction != nil else { return }
        let shortcut = PopoverHotKey.current
        guard DashboardHotKey.isValid(
            keyCode: Int(shortcut.keyCode),
            carbonModifiers: Int(shortcut.modifiers),
        ) else {
            return
        }

        registerShortcut(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.modifiers,
            signature: Self.popoverSignature,
            name: "popover",
            hotKeyRef: &popoverHotKeyRef,
        )
    }

    private func registerShortcut(
        keyCode: UInt32,
        modifiers: UInt32,
        signature: OSType,
        name: String,
        hotKeyRef: inout EventHotKeyRef?,
    ) {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = signature
        hotKeyID.id = Self.hotKeyID

        var nextHotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &nextHotKeyRef,
        )
        if status == noErr {
            hotKeyRef = nextHotKeyRef
        } else {
            NSLog("Peakmon failed to register \(name) hotkey: \(status)")
        }
    }

    private func unregisterDashboardShortcut() {
        guard let dashboardHotKeyRef else { return }
        UnregisterEventHotKey(dashboardHotKeyRef)
        self.dashboardHotKeyRef = nil
    }

    private func unregisterPopoverShortcut() {
        guard let popoverHotKeyRef else { return }
        UnregisterEventHotKey(popoverHotKeyRef)
        self.popoverHotKeyRef = nil
    }
}
