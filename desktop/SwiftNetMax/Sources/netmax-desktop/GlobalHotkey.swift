//
//  GlobalHotkey.swift
//  netmax-desktop
//
//  W12 T5-a (S-001) · NSEvent monitors replaced with Carbon
//  RegisterEventHotKey — the old global/local NSEvent monitors starve the
//  main event loop (app drew but ignored clicks; App.swift disabled them).
//  Carbon hotkeys are delivered through the normal event stream, so no
//  monitor loop runs. ⌥⌘R posts `.netmaxRerunLast` (same notification the
//  in-app ⌘R shortcut posts).
//

import AppKit
import Carbon.HIToolbox

enum GlobalHotkey {
    /// 'NMHK' — private signature identifying our hotkey registration.
    private static let signature = OSType(0x4E4D_484B)
    private static let hotKeyID = EventHotKeyID(signature: signature, id: 1)

    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?

    /// Idempotent install. Call once at app init.
    static func install() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        // ⌥⌘R — mirrors the in-app ⌘R without colliding with it.
        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    static func uninstall() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = handlerRef {
            RemoveEventHandler(h)
            handlerRef = nil
        }
    }

    /// Carbon callback (C convention — no captures). Filters by signature,
    /// then posts on the main queue so SwiftUI observers update safely.
    private static let hotKeyHandler: EventHandlerUPP = { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hkID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hkID
        )
        guard status == noErr,
              hkID.signature == GlobalHotkey.signature,
              hkID.id == GlobalHotkey.hotKeyID.id
        else { return OSStatus(eventNotHandledErr) }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .netmaxRerunLast, object: nil)
        }
        return noErr
    }
}
