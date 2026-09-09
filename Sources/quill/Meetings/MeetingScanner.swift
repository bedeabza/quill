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
    var speakers: [String: [String]] = [:]
    var speakerObservedAt: [String: Double] = [:]
    var captions: [SpeakerObservation] = []
    var speakerCaptureStatus: [String: String] = [:]
    var speakerBoxes: [String: [[String: String]]] = [:]
    var observedAt = Date().timeIntervalSince1970
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
        let activeSpeaker: String?
        let parentIndex: Int?
        let classNames: [String]
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
    private var captionRequests: Set<String> = []
    private struct CachedTile {
        let indicator: AXUIElement
        let nameElement: AXUIElement
        let name: String
        let isLocal: Bool
    }
    private var tiles: [String: [CachedTile]] = [:]

    /// Fast path while recording: read only cached tile indicators and names,
    /// rather than walking every browser window four times per second.
    func speakerActivity(for meetingID: String) -> SpeakerObservation? {
        guard AXIsProcessTrusted(), let entry = known[meetingID], !bool(entry.window, kAXMinimizedAttribute),
              let cached = tiles[meetingID], !cached.isEmpty else { return nil }
        if let tab = entry.tab, !bool(tab, kAXValueAttribute) && !bool(tab, kAXSelectedAttribute) { return nil }
        let started = Date().timeIntervalSince1970
        var names: [String] = []
        for tile in cached {
            guard !isDestroyed(tile.indicator), SpeakerAttribution.cleanName(string(tile.nameElement, kAXValueAttribute)) == tile.name else { return nil }
            let classes = Set(strings(tile.indicator, "AXDOMClassList"))
            guard classes.isSuperset(of: ["lH9pqf", "atLQQ"]) else { return nil }
            if !tile.isLocal && MeetTileEvidence.isSpeaking(classes: classes) { names.append(tile.name) }
        }
        let ended = Date().timeIntervalSince1970
        guard ended - started <= 0.2 else { return nil }
        return SpeakerObservation(observed_at: (started + ended) / 2, meeting_id: meetingID,
                                  names: Array(Set(names)).sorted(), source: "meeting_tile")
    }

    func scan(apps: [MeetingApp], captureSpeakers: Bool = false, enableCaptions: Bool = false, inspectBoxes: Bool = false,
              captionMeetingID: String? = nil) -> MeetingScan {
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
                if captureSpeakers && !ended && !bool(entry.window, kAXMinimizedAttribute) {
                    // Browser windows may contain several calls. Read only the
                    // established meeting document, never names from another tab.
                    let nodes: [Node]
                    let captureStarted = Date().timeIntervalSince1970
                    if app.service != nil { nodes = readTree(entry.window, skipWebContent: false).nodes }
                    else if let document = entry.document, !isDestroyed(document),
                            window.nodes.contains(where: { $0.role == "AXWebArea" && CFEqual($0.element, document) }),
                            entry.tab.map({ tab in window.nodes.contains(where: { $0.isTab && $0.selected && CFEqual($0.element, tab) }) }) ?? true {
                        nodes = readTree(document, skipWebContent: false, readClasses: true).nodes
                    } else { nodes = [] }
                    let captureEnded = Date().timeIntervalSince1970
                    result.speakerCaptureStatus[entry.meeting.id] = "\(nodes.count) nodes; \(nodes.filter { $0.text == "Captions" }.count) caption regions"
                    result.speakers[entry.meeting.id] = captureEnded - captureStarted <= 0.8
                        ? Array(Set(nodes.compactMap(\.activeSpeaker))).sorted() : []
                    result.speakerObservedAt[entry.meeting.id] = (captureStarted + captureEnded) / 2
                    if entry.meeting.service == "Google Meet" {
                        let tileNodes = nodes.map { MeetTileNode(parent: $0.parentIndex, role: $0.role, text: $0.text, classes: Set($0.classNames)) }
                        tiles[entry.meeting.id] = MeetTileEvidence.tiles(tileNodes).map {
                            CachedTile(indicator: nodes[$0.indicatorIndex].element, nameElement: nodes[$0.nameIndex].element,
                                       name: $0.name, isLocal: $0.isLocal)
                        }
                        result.speakerCaptureStatus[entry.meeting.id, default: ""] += "; \(tiles[entry.meeting.id]?.count ?? 0) speaker tiles"
                        if inspectBoxes {
                            result.speakerBoxes[entry.meeting.id] = nodes.prefix(700).enumerated().map { index, node in
                                var value: CFTypeRef?
                                AXUIElementCopyAttributeValue(node.element, "AXDOMClassList" as CFString, &value)
                                var row = ["index": String(index), "parent": node.parentIndex.map(String.init) ?? "", "role": node.role, "text": String(node.text.prefix(160)),
                                           "classes": (value as? [String] ?? []).joined(separator: " ")]
                                var sizeValue: CFTypeRef?
                                if AXUIElementCopyAttributeValue(node.element, kAXSizeAttribute as CFString, &sizeValue) == .success,
                                   let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                                    var size = CGSize.zero
                                    if AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) { row["size"] = "\(size.width),\(size.height)" }
                                }
                                return row
                            }
                        }
                        if nodes.contains(where: { $0.text == "Captions" }) {
                            captionRequests.insert(entry.meeting.id)
                        }
                        if enableCaptions && captionMeetingID == entry.meeting.id && !captionRequests.contains(entry.meeting.id),
                           let button = nodes.first(where: { $0.role == kAXButtonRole && $0.text == "Turn on captions" }) {
                            // Once per call. Respect a later manual choice to
                            // switch captions off; diagnostics never press it.
                            if AXUIElementPerformAction(button.element, kAXPressAction as CFString) == .success {
                                captionRequests.insert(entry.meeting.id)
                            }
                        }
                        for region in nodes where region.text == "Captions" {
                            for block in children(region.element, attribute: kAXChildrenAttribute) ?? [] {
                                let texts = readTree(block, skipWebContent: false).nodes.filter { $0.role == kAXStaticTextRole }.map(\.text)
                                if let caption = SpeakerEvidence.caption(texts: texts, meetingID: entry.meeting.id,
                                                                         observedAt: Date().timeIntervalSince1970) {
                                    result.captions.append(caption)
                                }
                            }
                        }
                    }
                }
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
                tiles.removeValue(forKey: id)
                if endedSince[id] == nil { endedSince[id] = now }
                // Longer than the stop countdown; never prune uncertain meetings.
                if now - (endedSince[id] ?? now) > 120 {
                    known.removeValue(forKey: id)
                    endedSince.removeValue(forKey: id)
                    endState.forget(id)
                    captionRequests.remove(id)
                }
            } else { endedSince.removeValue(forKey: id) }
        }
        result.observedAt = Date().timeIntervalSince1970
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

    private func readTree(_ window: AXUIElement, skipWebContent: Bool, readClasses: Bool = false) -> Window {
        var nodes: [Node] = []
        var queue: [(AXUIElement, Int?)] = [(window, nil)]
        var visited: Set<CFHashCode> = []
        var complete = true
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while let (element, parentIndex) = queue.popLast() {
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
            let activeSpeaker = SpeakerEvidence.activeName(label: description, role: role)
                ?? SpeakerEvidence.activeName(label: title, role: role)
            nodes.append(Node(element: element, role: role, text: text, url: url, isTab: isTab, selected: selected, activeSpeaker: activeSpeaker,
                              parentIndex: parentIndex, classNames: readClasses ? strings(element, "AXDOMClassList") : []))
            if skipWebContent && role == "AXWebArea" { continue }
            if let childElements = children(element, attribute: kAXChildrenAttribute) {
                queue.append(contentsOf: childElements.reversed().map { ($0, nodes.count - 1) })
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

    private func strings(_ element: AXUIElement, _ attribute: String) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [String] ?? []
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
