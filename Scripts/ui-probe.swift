#!/usr/bin/env swift
// Drives the *running* app through the Accessibility API, from outside it.
//
// ## Why this exists next to the snapshot tool
//
// `Scripts/snapshots.sh` renders views into an offscreen `NSHostingView` and is
// the right tool for "does this layout look right". It cannot answer the
// question this one is for: **can the user resize this window, and how does the
// layout behave when they do.** A snapshot has whatever size the catalog asked
// for; there is no window, no title bar, no resize handle and no minimum size.
//
// That gap shipped a bug. 0.1.1 "fixed" the window being unresizable with a
// SwiftUI modifier, the source-reading test passed, and the window stayed
// 2177 pt wide because the real cause was a persisted frame the modifier never
// touched. A test that cannot fail the way the user failed is not a test.
//
// ## Focus
//
// Nothing here activates the app. It is launched with `open -g` (LaunchServices
// "do not bring to the foreground"), and the Accessibility API reads and writes
// window geometry without making the window key. So this can run while the
// machine's owner is using something else — which is the whole point, since the
// agent shell lives in a `Background` launchd session and stealing the Aqua
// session's focus is a real interruption, not a theoretical one.
//
// ## Usage
//
//   xcrun swift Scripts/ui-probe.swift windows
//   xcrun swift Scripts/ui-probe.swift resize <windowIndex> <width> <height>
//   xcrun swift Scripts/ui-probe.swift limits <windowIndex>
//   xcrun swift Scripts/ui-probe.swift tree <windowIndex> [maxDepth]
//   xcrun swift Scripts/ui-probe.swift press <windowIndex> "<title or label>"
//   xcrun swift Scripts/ui-probe.swift selectrow <windowIndex> "<row label>"
//
// Requires the controlling process to be trusted for Accessibility. It is
// checked up front rather than failing later with an opaque -25204.

import ApplicationServices
import AppKit
import Foundation

let bundleID = "cz.mihalic.SopsGUI"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

guard AXIsProcessTrusted() else {
    fail("this process is not trusted for Accessibility — grant it in System Settings › Privacy & Security › Accessibility")
}

guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    fail("\(bundleID) is not running — launch it with: open -g <path to SopsGUI.app>")
}

let app = AXUIElementCreateApplication(running.processIdentifier)

// MARK: - Attribute helpers
//
// Every one returns an optional rather than trapping: an element that has gone
// away between two calls is ordinary during a live UI walk, and a probe that
// crashes on it tells you nothing about the app.

func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

func string(_ element: AXUIElement, _ attribute: String) -> String? {
    copyAttribute(element, attribute) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

func size(_ element: AXUIElement) -> CGSize? {
    guard let value = copyAttribute(element, kAXSizeAttribute as String) else { return nil }
    var result = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &result) else { return nil }
    return result
}

func position(_ element: AXUIElement) -> CGPoint? {
    guard let value = copyAttribute(element, kAXPositionAttribute as String) else { return nil }
    var result = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &result) else { return nil }
    return result
}

func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
        return false
    }
    return settable.boolValue
}

@discardableResult
func setSize(_ element: AXUIElement, _ newSize: CGSize) -> Bool {
    var mutable = newSize
    guard let value = AXValueCreate(.cgSize, &mutable) else { return false }
    return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
}

func windows() -> [AXUIElement] {
    copyAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
}

func describe(_ window: AXUIElement, index: Int) -> String {
    let title = string(window, kAXTitleAttribute as String) ?? "(untitled)"
    let subrole = string(window, kAXSubroleAttribute as String) ?? "-"
    let s = size(window).map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
    let p = position(window).map { "@\(Int($0.x)),\(Int($0.y))" } ?? ""
    // `AXSize` being settable is exactly what "the user can resize this" means
    // to the accessibility layer, and it is what a non-resizable style mask
    // turns off. This is the assertion the source-reading test could not make.
    let resizable = isSettable(window, kAXSizeAttribute as String) ? "resizable" : "FIXED"
    let movable = isSettable(window, kAXPositionAttribute as String) ? "movable" : "fixed-position"
    return "[\(index)] \(title) · \(subrole) · \(s)\(p) · \(resizable) · \(movable)"
}

func window(at index: Int) -> AXUIElement {
    let all = windows()
    guard all.indices.contains(index) else {
        fail("no window at index \(index); there are \(all.count)")
    }
    return all[index]
}

/// Walks the tree depth-first, printing role, title/description and frame.
func dump(_ element: AXUIElement, depth: Int, maxDepth: Int, indent: String = "") {
    guard depth <= maxDepth else { return }
    let role = string(element, kAXRoleAttribute as String) ?? "?"
    let label = string(element, kAXTitleAttribute as String)
        ?? string(element, kAXDescriptionAttribute as String)
        ?? string(element, kAXValueAttribute as String)
        ?? ""
    let frame: String = {
        guard let s = size(element), let p = position(element) else { return "" }
        return "  \(Int(s.width))x\(Int(s.height))@\(Int(p.x)),\(Int(p.y))"
    }()
    let trimmed = label.replacingOccurrences(of: "\n", with: "⏎").prefix(70)
    print("\(indent)\(role)\(trimmed.isEmpty ? "" : " “\(trimmed)”")\(frame)")
    for child in children(element) {
        dump(child, depth: depth + 1, maxDepth: maxDepth, indent: indent + "  ")
    }
}

func find(in element: AXUIElement, matching label: String, depth: Int = 0) -> AXUIElement? {
    if depth > 40 { return nil }
    let candidates = [string(element, kAXTitleAttribute as String),
                      string(element, kAXDescriptionAttribute as String),
                      string(element, kAXValueAttribute as String)]
    if candidates.compactMap({ $0 }).contains(where: { $0 == label }) { return element }
    for child in children(element) {
        if let hit = find(in: child, matching: label, depth: depth + 1) { return hit }
    }
    return nil
}

// MARK: - Commands

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: windows | resize <i> <w> <h> | limits <i> | tree <i> [depth] | press <i> <label>")
}

switch command {
case "windows":
    let all = windows()
    if all.isEmpty { print("(no windows)") }
    for (index, window) in all.enumerated() { print(describe(window, index: index)) }

case "resize":
    guard arguments.count == 4,
          let index = Int(arguments[1]),
          let width = Double(arguments[2]),
          let height = Double(arguments[3]) else { fail("usage: resize <i> <w> <h>") }
    let target = window(at: index)
    let before = size(target)
    setSize(target, CGSize(width: width, height: height))
    // Read back rather than trusting the write: AppKit clamps to the window's
    // min/max, and the clamped value is the interesting answer.
    let after = size(target)
    print("before: \(before.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")")
    print("asked:  \(Int(width))x\(Int(height))")
    print("after:  \(after.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")")

case "limits":
    guard arguments.count == 2, let index = Int(arguments[1]) else { fail("usage: limits <i>") }
    let target = window(at: index)
    let original = size(target)
    guard isSettable(target, kAXSizeAttribute as String) else {
        print("NOT RESIZABLE — AXSize is not settable")
        exit(0)
    }
    // Ask for absurd sizes in both directions; what comes back is the window's
    // real minimum and maximum, which is what a user discovers by dragging.
    setSize(target, CGSize(width: 1, height: 1))
    let minimum = size(target)
    setSize(target, CGSize(width: 99_999, height: 99_999))
    let maximum = size(target)
    if let original { setSize(target, original) }
    print("min: \(minimum.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")")
    print("max: \(maximum.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")")
    print("restored: \(size(target).map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")")

case "tree":
    guard arguments.count >= 2, let index = Int(arguments[1]) else { fail("usage: tree <i> [depth]") }
    let maxDepth = arguments.count > 2 ? Int(arguments[2]) ?? 6 : 6
    dump(window(at: index), depth: 0, maxDepth: maxDepth)

case "selectrow":
    // Selecting a list row is not a press: `AXPress` on the row's static text
    // does nothing, and the row itself often has no press action. The row is
    // selected by setting `AXSelected`, which is what an assistive client does.
    guard arguments.count == 3, let index = Int(arguments[1]) else {
        fail("usage: selectrow <i> <label>")
    }
    func rowContaining(_ element: AXUIElement, _ label: String, depth: Int = 0) -> AXUIElement? {
        if depth > 40 { return nil }
        let role = string(element, kAXRoleAttribute as String)
        if role == (kAXRowRole as String), find(in: element, matching: label) != nil {
            return element
        }
        for child in children(element) {
            if let hit = rowContaining(child, label, depth: depth + 1) { return hit }
        }
        return nil
    }
    guard let row = rowContaining(window(at: index), arguments[2]) else {
        fail("no row containing \(arguments[2])")
    }
    let selected = AXUIElementSetAttributeValue(
        row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    print(selected == .success ? "selected" : "select failed: \(selected.rawValue)")

case "press":
    guard arguments.count == 3, let index = Int(arguments[1]) else { fail("usage: press <i> <label>") }
    guard let element = find(in: window(at: index), matching: arguments[2]) else {
        fail("no element titled \(arguments[2])")
    }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    print(result == .success ? "pressed" : "press failed: \(result.rawValue)")

default:
    fail("unknown command \(command)")
}
