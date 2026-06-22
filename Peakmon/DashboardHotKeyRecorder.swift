//
//  DashboardHotKeyRecorder.swift
//  Peakmon
//
//  Settings control for the global Dashboard shortcut.
//

import AppKit
import Carbon
import SwiftUI

struct DashboardHotKeyRecorder: View {
    @AppStorage(DashboardHotKey.keyCodeStorageKey) private var keyCode = DashboardHotKey.defaultKeyCode
    @AppStorage(DashboardHotKey.modifiersStorageKey) private var modifiers = DashboardHotKey.defaultModifiers
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                toggleRecording()
            } label: {
                shortcutLabel
            }
            .buttonStyle(.plain)
            .help("Record shortcut")

            Button {
                stopRecording()
                DashboardHotKey.resetToDefault()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Reset shortcut")
        }
        .onDisappear {
            stopRecording()
        }
    }

    @ViewBuilder
    private var shortcutLabel: some View {
        if isRecording {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .semibold))
                Text("Press shortcut")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.blue)
            .frame(minWidth: 132, minHeight: 28)
            .padding(.horizontal, 8)
            .background(Color.blue.opacity(0.10), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue.opacity(0.35), lineWidth: 0.8)
            }
        } else {
            HStack(spacing: 4) {
                ForEach(Array(shortcutParts.enumerated()), id: \.offset) { index, part in
                    ShortcutKeycap(text: part, isPrimary: index == shortcutParts.count - 1)
                }
            }
            .frame(minWidth: 132, minHeight: 28)
            .padding(.horizontal, 8)
            .background(Color.gray.opacity(0.10), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.20), lineWidth: 0.5)
            }
        }
    }

    private var shortcutParts: [String] {
        var parts: [String] = []
        if modifiers & Int(controlKey) != 0 { parts.append("⌃") }
        if modifiers & Int(optionKey) != 0 { parts.append("⌥") }
        if modifiers & Int(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & Int(cmdKey) != 0 { parts.append("⌘") }
        parts.append(DashboardHotKey.displayString(keyCode: keyCode, modifiers: 0))
        return parts
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == Int(kVK_Escape) {
                stopRecording()
                return nil
            }

            let nextModifiers = DashboardHotKey.carbonModifiers(from: event.modifierFlags)
            guard DashboardHotKey.isValid(
                keyCode: Int(event.keyCode),
                carbonModifiers: nextModifiers,
            ) else {
                return nil
            }

            keyCode = Int(event.keyCode)
            modifiers = nextModifiers
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        isRecording = false
    }
}

private struct ShortcutKeycap: View {
    let text: String
    let isPrimary: Bool

    var body: some View {
        Text(text)
            .font(.system(size: isPrimary ? 13 : 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(minWidth: isPrimary ? 28 : 20, minHeight: 22)
            .padding(.horizontal, isPrimary ? 3 : 0)
            .background(.background, in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.gray.opacity(0.24), lineWidth: 0.5)
            }
    }
}
