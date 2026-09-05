import AppKit
import ApplicationServices

struct MeetingApp: Sendable {
    let pid: pid_t
    let name: String
    let service: String?

    @MainActor static func running() -> [MeetingApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundle = app.bundleIdentifier?.lowercased() else { return nil }
            let service: String?
            if bundle == "us.zoom.xos" { service = "Zoom" }
            else if bundle == "com.microsoft.teams2" || bundle == "com.microsoft.teams" { service = "Microsoft Teams" }
            else { service = nil }
            let browsers = ["com.brave.browser", "com.google.chrome", "com.microsoft.edgemac",
                            "com.apple.safari", "org.mozilla.firefox", "company.thebrowser.browser",
                            "com.vivaldi.vivaldi", "com.operasoftware.opera", "com.kagi.kagimacOS".lowercased(),
                            "org.mozilla.zen", "app.zen-browser.zen", "net.imput.helium"]
            let types = app.bundleURL.flatMap(Bundle.init(url:))?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
            let documentTypes = app.bundleURL.flatMap(Bundle.init(url:))?.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
            let handlesHTML = documentTypes.contains { type in
                (type["LSItemContentTypes"] as? [String] ?? []).contains("public.html")
                    || (type["CFBundleTypeExtensions"] as? [String] ?? []).contains("html")
            }
            let handlesWebURLs = types.contains { type in
                let schemes = type["CFBundleURLSchemes"] as? [String] ?? []
                return schemes.contains("http") || schemes.contains("https")
            }
            guard service != nil || (handlesWebURLs && handlesHTML) || browsers.contains(where: { bundle == $0 || bundle.hasPrefix($0 + ".") }) else { return nil }
            // Helper processes do not own the meeting's windows.
            guard app.activationPolicy == .regular else { return nil }
            return MeetingApp(pid: app.processIdentifier, name: app.localizedName ?? "Browser", service: service)
        }
    }
}

struct MeetingScan: Sendable {
    var observations: [String: MeetingObservation] = [:]
    var needsPermission = false
}

/// Accessibility objects stay on this actor. Only value snapshots reach UI code.
actor MeetingScanner {
    private struct Known {
        let meeting: DetectedMeeting
        let pid: pid_t
        let window: AXUIElement
        var tab: AXUIElement?
        var document: AXUIElement?
        let code: String?
    }
    private struct Node {
        let element: AXUIElement
        let role: String
        let text: String
        let url: String
        let isTab: Bool
        let selected: Bool
    }
    private struct Window {
        let element: AXUIElement
        var nodes: [Node]
        let complete: Bool
    }
    private var known: [String: Known] = [:]
    private var serial = 0
    private var enabledAccessibility: Set<pid_t> = []
    private var endedSince: [String: TimeInterval] = [:]
    private var endState = MeetingEndState()

    func scan(apps: [MeetingApp]) -> MeetingScan {
        var result = MeetingScan()
        let pids = Set(apps.map(\.pid))
        enabledAccessibility.formIntersection(pids)
        for entry in known.values where !pids.contains(entry.pid) {
            result.observations[entry.meeting.id] = .ended
        }
        guard AXIsProcessTrusted() else {
            result.needsPermission = true
            return result
        }
        for app in apps {
            let root = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(root, 0.15)
            // Chromium and Electron lazily expose their accessibility trees.
            if enabledAccessibility.insert(app.pid).inserted {
                AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            guard let elements = children(root, attribute: kAXWindowsAttribute) else { continue }
            let windows = elements.map { readWindow($0, browser: app.service == nil) }

            for window in windows {
                let leave = hasCallControls(window)
                let ended = window.nodes.contains { MeetingEvidence.isEndMessage($0.text) }
                if let service = app.service {
                    if leave && !ended {
                        let existing = known.values.first { $0.pid == app.pid && CFEqual($0.window, window.element) }
                        let id = existing?.meeting.id ?? nextID(pid: app.pid)
                        known[id] = Known(meeting: DetectedMeeting(id: id, app: app.name, service: service),
                                          pid: app.pid, window: window.element, tab: nil, document: nil, code: nil)
                    }
                    continue
                }

                // A URL establishes a meeting. Tab labels only maintain an already
                // established identity, so arbitrary page titles cannot start capture.
                for node in window.nodes where node.isTab || node.role == "AXWebArea" {
                    let code = MeetingEvidence.meetCode(in: node.url) ?? MeetingEvidence.meetCode(in: node.text)
                    if ended && !node.isTab { continue }
                    let matchingTab = node.isTab ? node.element : window.nodes.first(where: { $0.isTab && $0.selected })?.element
                    let existing = known.values.first { entry in
                        entry.pid == app.pid && (code != nil ? entry.code == code : matchingTab.map { tab in entry.tab.map { CFEqual($0, tab) } == true } == true)
                    }
                    guard let service = MeetingEvidence.service(url: node.url) ?? existing?.meeting.service,
                          code != nil || leave || existing != nil else { continue }
                    let id = existing?.meeting.id ?? nextID(pid: app.pid)
                    let tab = matchingTab ?? existing?.tab
                    known[id] = Known(meeting: DetectedMeeting(id: id, app: app.name, service: service),
                                      pid: app.pid, window: window.element, tab: tab,
                                      document: node.isTab ? existing?.document : node.element, code: code)
                }
            }

            for entry in known.values where entry.pid == app.pid {
                guard let window = windows.first(where: { CFEqual($0.element, entry.window) }) else {
                    // A closed call window is a positive end signal. If another native
                    // call window appeared, keep recording through layout transitions.
                    let anotherCall = app.service != nil && windows.contains(where: hasCallControls)
                    result.observations[entry.meeting.id] = anotherCall ? .present(entry.meeting) : .ended
                    continue
                }
                let leave = hasCallControls(window)
                let ended = window.nodes.contains { MeetingEvidence.isEndMessage($0.text) }
                if app.service != nil {
                    // Never infer end merely from a temporarily hidden Leave button.
                    result.observations[entry.meeting.id] = ended && !leave && window.complete ? .ended : (leave ? .present(entry.meeting) : .unknown)
                    continue
                }
                let tabPresent = window.nodes.contains { node in
                    guard node.isTab else { return false }
                    return entry.tab.map { CFEqual($0, node.element) } == true
                        || (entry.code != nil && MeetingEvidence.meetCode(in: node.text) == entry.code)
                }
                let documentPresent = window.nodes.contains { node in
                    guard node.role == "AXWebArea" else { return false }
                    return entry.document.map { CFEqual($0, node.element) } == true
                        || (entry.code != nil && MeetingEvidence.meetCode(in: node.url) == entry.code)
                }
                if endState.isEnded(entry.meeting.id, endScreen: documentPresent && ended && !leave, inCall: documentPresent && leave) {
                    result.observations[entry.meeting.id] = .ended
                } else if tabPresent || documentPresent {
                    result.observations[entry.meeting.id] = .present(entry.meeting)
                } else if let tab = entry.tab, window.complete,
                          window.nodes.contains(where: \.isTab) || isDestroyed(tab) {
                    result.observations[entry.meeting.id] = .ended
                } else {
                    result.observations[entry.meeting.id] = .unknown
                }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for (id, observation) in result.observations {
            if observation == .ended {
                if endedSince[id] == nil { endedSince[id] = now }
                // Longer than the stop countdown; never prune uncertain meetings.
                if now - (endedSince[id] ?? now) > 120 {
                    known.removeValue(forKey: id)
                    endedSince.removeValue(forKey: id)
                    endState.forget(id)
                }
            } else { endedSince.removeValue(forKey: id) }
        }
        return result
    }

    private func hasCallControls(_ window: Window) -> Bool {
        MeetingEvidence.hasCallControls(window.nodes.filter { $0.role == kAXButtonRole }.map(\.text))
    }

    private func nextID(pid: pid_t) -> String {
        serial += 1
        return "\(pid):\(serial)"
    }

    private func readWindow(_ window: AXUIElement, browser: Bool) -> Window {
        var result = readTree(window, skipWebContent: browser)
        if browser {
            let documents = result.nodes.filter { $0.role == "AXWebArea" }
            for document in documents where MeetingEvidence.service(url: document.url) != nil || MeetingEvidence.meetCode(in: document.text) != nil {
                result.nodes.append(contentsOf: readTree(document.element, skipWebContent: false).nodes.dropFirst())
            }
        }
        return result
    }

    private func readTree(_ window: AXUIElement, skipWebContent: Bool) -> Window {
        var nodes: [Node] = []
        var queue = [window]
        var visited: Set<CFHashCode> = []
        var complete = true
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while let element = queue.popLast() {
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard nodes.count < 2500, ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false
                break
            }
            let role = string(element, kAXRoleAttribute)
            guard !role.isEmpty else { complete = false; continue }
            let description = string(element, kAXDescriptionAttribute)
            let title = string(element, kAXTitleAttribute)
            let roleDescription = string(element, kAXRoleDescriptionAttribute).lowercased()
            let isTab = role == "AXTab" || roleDescription == "tab" || string(element, kAXSubroleAttribute) == "AXTabButton"
            var text = [title, description].filter { !$0.isEmpty }.joined(separator: " ")
            if title == description { text = title }
            if role == kAXStaticTextRole { text = string(element, kAXValueAttribute) }
            let axURL = role == "AXWebArea" ? string(element, "AXURL") : ""
            let url = axURL.isEmpty && role == "AXWebArea" ? string(element, kAXDocumentAttribute) : axURL
            let selected = isTab && (bool(element, kAXValueAttribute) || bool(element, kAXSelectedAttribute))
            nodes.append(Node(element: element, role: role, text: text, url: url, isTab: isTab, selected: selected))
            if skipWebContent && role == "AXWebArea" { continue }
            if let childElements = children(element, attribute: kAXChildrenAttribute) {
                queue.append(contentsOf: childElements.reversed())
            } else { complete = false }
        }
        return Window(element: window, nodes: nodes, complete: complete)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        if let url = value as? URL { return url.absoluteString }
        return String((value as? String ?? "").prefix(2000))
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func isDestroyed(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
    }

    private func children(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if attribute == kAXWindowsAttribute && error != .success { return nil }
        if error == .noValue || error == .attributeUnsupported { return [] }
        guard error == .success else { return nil }
        return value as? [AXUIElement] ?? []
    }
}
