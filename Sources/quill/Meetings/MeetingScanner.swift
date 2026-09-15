import AppKit
import ApplicationServices

struct MeetingApp: Sendable {
    let pid: pid_t
    let name: String
    let service: String?

    @MainActor static func running() -> [MeetingApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundle = app.bundleIdentifier?.lowercased() else { return nil }
            let service = MeetingEvidence.nativeService(bundleID: bundle)
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
    var needsZoomScreenPermission = false
    var speakerNameWarnings: [String: String] = [:]
    var rosters: [SpeakerObservation] = []
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
        let isBrowser: Bool
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
        let subrole: String
        let roleDescription: String
    }
    private struct Window {
        let element: AXUIElement
        var nodes: [Node]
        let complete: Bool
        let startedAt: Double
        let endedAt: Double
        var documents: [AXUIElement: Window] = [:]
        var browserTabs: [Node] = []
        var browserDocuments: [Node] = []
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
        let kind: SpeakerUITileKind
    }
    private var tiles: [String: [CachedTile]] = [:]
    private var rosters: [String: SpeakerObservation] = [:]
    private var speakerRefresh: [String: SpeakerTreeRefresh<AXUIElement>] = [:]
    private var slackSpeakerWindows: [pid_t: AXUIElement] = [:]
    private var zoomVideos: [String: [AXUIElement]] = [:]
    private let zoomDetector = ZoomWindowSpeakerDetector()
    private var zoomScores: [String: [String: Double]] = [:]

    func zoomBorderScores() -> [String: [String: Double]] { zoomScores }
    func zoomCaptureStatus() async -> String { await zoomDetector.diagnostic }

    /// Fast path while recording: read only cached tile indicators and names,
    /// rather than walking every browser window four times per second.
    func speakerActivity(for meetingID: String) async -> SpeakerObservation? {
        guard AXIsProcessTrusted(), let entry = known[meetingID], !bool(speakerWindow(entry), kAXMinimizedAttribute) else { return nil }
        if let tab = entry.tab, !bool(tab, kAXValueAttribute) && !bool(tab, kAXSelectedAttribute) {
            // Speaking indicators in a hidden tab may be stale. Keep discovering
            // membership from the established document through the slower poll.
            return nil
        }
        refreshSpeakerTiles(entry)
        guard speakerRefresh[meetingID]?.isFresh(at: ProcessInfo.processInfo.systemUptime) == true else { return nil }
        if entry.meeting.service == "Zoom", let controls = zoomVideos[meetingID], !controls.isEmpty {
            zoomScores.removeValue(forKey: meetingID)
            guard let windowFrame = frame(entry.window), let before = zoomSnapshots(controls) else {
                invalidateSpeakerTiles(meetingID)
                return nil
            }
            guard let sample = await zoomDetector.sample(meetingID: meetingID, pid: entry.pid, frame: windowFrame, videos: before),
                  frame(entry.window) == windowFrame, zoomSnapshots(controls) == before else { return nil }
            zoomScores[meetingID] = sample.scores
            return SpeakerObservation(observed_at: sample.observedAt, meeting_id: meetingID, names: sample.names, source: "zoom_border")
        }
        guard
              let cached = tiles[meetingID], !cached.isEmpty else { return nil }
        let started = Date().timeIntervalSince1970
        var names: [String] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        let localName = Config.localSpeakerName()
        for tile in cached {
            let currentName = tile.kind == .slackPeer
                ? SlackTileEvidence.name(in: string(tile.nameElement, kAXDescriptionAttribute))
                : SpeakerAttribution.cleanName(string(tile.nameElement, kAXValueAttribute))
            guard !isDestroyed(tile.indicator), currentName == tile.name else {
                invalidateSpeakerTiles(meetingID)
                return nil
            }
            let classes = Set(strings(tile.indicator, "AXDOMClassList"))
            guard tile.kind.recognizes(classes) else {
                invalidateSpeakerTiles(meetingID)
                return nil
            }
            let isLocal = tile.isLocal || SpeakerAttribution.isLocalName(tile.name, localName: localName)
                || (tile.kind == .meet && classes.contains("eQJ1qd"))
            guard !isLocal else { continue }
            if tile.kind == .slackPeer {
                guard let speaking = SlackTileEvidence.activity(root: tile.indicator, expectedName: tile.name,
                    hasTime: { ProcessInfo.processInfo.systemUptime < deadline }, read: { element in
                        let role = string(element, kAXRoleAttribute)
                        guard !role.isEmpty, let descendants = children(element, attribute: kAXChildrenAttribute) else { return nil }
                        let node = SpeakerUINode(parent: nil, role: role,
                            text: role == "AXCell" ? string(element, kAXDescriptionAttribute) : "",
                            classes: Set(strings(element, "AXDOMClassList")))
                        return (node, descendants)
                    }) else {
                    invalidateSpeakerTiles(meetingID)
                    return nil
                }
                if speaking { names.append(tile.name) }
            } else if tile.kind.isSpeaking(classes) { names.append(tile.name) }
        }
        let ended = Date().timeIntervalSince1970
        guard ended - started <= 0.2 else { return nil }
        return SpeakerObservation(observed_at: (started + ended) / 2, meeting_id: meetingID,
                                  names: Array(Set(names)).sorted(), source: "meeting_tile")
    }

    private func invalidateSpeakerTiles(_ id: String) {
        tiles.removeValue(forKey: id)
        zoomVideos.removeValue(forKey: id)
        rosters.removeValue(forKey: id)
        speakerRefresh[id]?.invalidate()
    }

    private func speakerWindow(_ entry: Known) -> AXUIElement {
        // Native Slack's chat and pop-out expose the same joined huddle. The
        // recording may be linked to chat while the participant grid is popped out.
        if !entry.isBrowser, entry.meeting.service == "Slack" {
            return slackSpeakerWindows[entry.pid] ?? entry.window
        }
        return entry.window
    }

    private func refreshSpeakerTiles(_ entry: Known) {
        let id = entry.meeting.id
        guard let root = entry.isBrowser ? entry.document : speakerWindow(entry),
              !isDestroyed(root) else {
            invalidateSpeakerTiles(id)
            return
        }
        if let expected = entry.code {
            let url = string(root, "AXURL")
            let document = url.isEmpty ? string(root, kAXDocumentAttribute) : url
            if !document.isEmpty && MeetingEvidence.meetCode(in: document) != expected {
                invalidateSpeakerTiles(id)
                return
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let deadline = now + 0.04
        var refresh = speakerRefresh[id] ?? SpeakerTreeRefresh<AXUIElement>()
        let snapshot = refresh.step(root: root, now: now, hasTime: { ProcessInfo.processInfo.systemUptime < deadline }) { element, parent in
            let role = string(element, kAXRoleAttribute)
            guard !role.isEmpty, let descendants = children(element, attribute: kAXChildrenAttribute) else { return nil }
            var text = ""
            if role == kAXStaticTextRole { text = string(element, kAXValueAttribute) }
            else if ["AXMenuItem", "AXButton", "AXTab", "AXHeading", "AXTabGroup", "AXCell"].contains(role) {
                let title = string(element, kAXTitleAttribute), description = string(element, kAXDescriptionAttribute)
                text = title == description || description.isEmpty ? title : (title.isEmpty ? description : title + " " + description)
                if ["AXTabGroup", "AXCell"].contains(role), !description.isEmpty { text = description }
                if ["AXButton", "AXTab", "AXHeading"].contains(role), !title.isEmpty, !description.isEmpty, title != description { text = title + "\n" + description }
            }
            let node = SpeakerUINode(parent: parent, role: role, text: text,
                                     classes: Set(strings(element, "AXDOMClassList")),
                                     subrole: role == "AXGroup" ? string(element, kAXSubroleAttribute) : "",
                                     roleDescription: entry.meeting.service == "Zoom" ? string(element, kAXRoleDescriptionAttribute).lowercased() : "")
            return (node, descendants)
        }
        speakerRefresh[id] = refresh
        if !refresh.isFresh(at: now) {
            tiles.removeValue(forKey: id)
            zoomVideos.removeValue(forKey: id)
            rosters.removeValue(forKey: id)
        }
        guard let snapshot else { return }
        let nodes = snapshot.map(\.node)
        let members = ParticipantEvidence.members(nodes, service: entry.meeting.service, localName: Config.localSpeakerName())
        // Slack chat can contain counts for unrelated conversations. Its peer
        // grid proves membership, but no complete headcount was exposed in testing.
        let count = entry.meeting.service == "Slack" ? nil : ParticipantEvidence.participantCount(nodes)
        let complete = count == members.filter { !$0.is_local }.count + 1 && Config.localSpeakerName() != nil
        rosters[id] = SpeakerObservation(observed_at: Date().timeIntervalSince1970, meeting_id: id, names: [],
            source: "meeting_roster", participants: members, participant_count: count, roster_complete: complete)
        let detected: [SpeakerUITile]
        switch entry.meeting.service {
        case "Google Meet": detected = MeetTileEvidence.tiles(nodes)
        case "Microsoft Teams": detected = TeamsTileEvidence.tiles(nodes)
        case "Slack": detected = SlackTileEvidence.tiles(nodes)
        default: detected = []
        }
        tiles[id] = detected.map {
            CachedTile(indicator: snapshot[$0.indicatorIndex].element, nameElement: snapshot[$0.nameIndex].element,
                       name: $0.name, isLocal: $0.isLocal, kind: $0.kind)
        }
        if entry.meeting.service == "Zoom" {
            zoomVideos[id] = snapshot.filter { $0.node.role == "AXTabGroup" && $0.node.roleDescription == "video render" }.map(\.element)
        }
    }

    func scan(apps: [MeetingApp], captureSpeakers: Bool = false, enableCaptions: Bool = false, inspectBoxes: Bool = false,
              captionMeetingID: String? = nil) -> MeetingScan {
        var result = MeetingScan()
        let pids = Set(apps.map(\.pid))
        enabledAccessibility.formIntersection(pids)
        slackSpeakerWindows = slackSpeakerWindows.filter { pids.contains($0.key) }
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
            if app.service == "Slack" {
                let huddles = windows.filter { window in
                    hasCallControls(window, service: "Slack") && window.nodes.contains { node in
                        node.role == "AXCell" && SlackTileEvidence.name(in: node.text) != nil
                            && strings(node.element, "AXDOMClassList").contains(SlackTileEvidence.peerClass)
                    }
                }
                slackSpeakerWindows[app.pid] = huddles.count == 1 ? huddles.first?.element : nil
            }

            for window in windows {
                let leave = hasCallControls(window, service: app.service)
                let ended = window.nodes.contains { MeetingEvidence.isEndMessage($0.text) }
                if let service = app.service {
                    if leave && (service == "Slack" || !ended) {
                        let existing = known.values.first { $0.pid == app.pid && CFEqual($0.window, window.element) }
                        let id = existing?.meeting.id ?? nextID(pid: app.pid)
                        known[id] = Known(meeting: DetectedMeeting(id: id, app: app.name, service: service),
                                          pid: app.pid, window: window.element, tab: nil, document: nil, code: nil, isBrowser: false)
                    }
                    continue
                }

                // A URL establishes a meeting. Tab labels only maintain an already
                // established identity, so arbitrary page titles cannot start capture.
                for node in window.browserTabs + window.browserDocuments {
                    let code = MeetingEvidence.service(url: node.url) == "Slack" ? nil
                        : MeetingEvidence.meetCode(in: node.url) ?? MeetingEvidence.meetCode(in: node.text)
                    if ended && !node.isTab && MeetingEvidence.service(url: node.url) != "Slack" { continue }
                    let matchingTab = node.isTab ? node.element : window.browserTabs.first(where: {
                        $0.isTab && (code != nil ? MeetingEvidence.meetCode(in: $0.text) == code : $0.selected)
                    })?.element
                    let existing = known.values.first { entry in
                        entry.pid == app.pid && (code != nil ? entry.code == code
                            : matchingTab.map { tab in entry.tab.map { CFEqual($0, tab) } == true } == true
                                || (!node.isTab && entry.document.map { CFEqual($0, node.element) } == true))
                    }
                    guard let service = MeetingEvidence.service(url: node.url) ?? existing?.meeting.service,
                          service == "Slack" || code != nil || leave || existing != nil else { continue }
                    if existing?.meeting.service == "Slack", service != "Slack" { continue }
                    if service == "Slack", existing == nil {
                        // Never borrow another tab's call controls or a meeting
                        // code mentioned in Slack chat to establish a huddle.
                        let visible = !bool(window.element, kAXMinimizedAttribute) && (matchingTab.map { tab in
                            window.browserTabs.contains { $0.selected && CFEqual($0.element, tab) }
                        } ?? true)
                        guard let document = window.documents[node.element],
                              slackState(document, visible: visible) == .joined else { continue }
                    }
                    let id = existing?.meeting.id ?? nextID(pid: app.pid)
                    let tab = matchingTab ?? existing?.tab
                    known[id] = Known(meeting: DetectedMeeting(id: id, app: app.name, service: service),
                                      pid: app.pid, window: window.element, tab: tab,
                                      document: node.isTab ? existing?.document : node.element,
                                      code: service == "Slack" ? nil : code, isBrowser: true)
                }
            }

            for entry in known.values where entry.pid == app.pid {
                guard let window = windows.first(where: { CFEqual($0.element, entry.window) }) else {
                    // A closed call window is a positive end signal. If another native
                    // call window appeared, keep recording through layout transitions.
                    let anotherCall = app.service != nil && windows.contains { hasCallControls($0, service: app.service) }
                    result.observations[entry.meeting.id] = anotherCall ? .present(entry.meeting) : .ended
                    continue
                }
                let leave = hasCallControls(window, service: app.service)
                let ended = window.nodes.contains { MeetingEvidence.isEndMessage($0.text) }
                if captureSpeakers && !ended {
                    // Read only this call's established AX document, including
                    // when its browser tab or window is in the background.
                    refreshSpeakerTiles(entry)
                    if let roster = rosters[entry.meeting.id], speakerRefresh[entry.meeting.id]?.isFresh(at: ProcessInfo.processInfo.systemUptime) == true {
                        result.rosters.append(roster)
                    }
                }
                if captureSpeakers && !ended && !bool(entry.window, kAXMinimizedAttribute) {
                    // Browser windows may contain several calls. Read only the
                    // established meeting document, never names from another tab.
                    let nodes: [Node]
                    var captureStarted = Date().timeIntervalSince1970
                    var captureEnded: Double?
                    if !inspectBoxes && !enableCaptions {
                        // Reuse the scoped lifecycle snapshot for explicit active
                        // labels. Tile discovery has its own incremental reader.
                        let captured = entry.isBrowser ? entry.document.flatMap { window.documents[$0] } : window
                        nodes = captured?.nodes ?? []
                        captureStarted = captured?.startedAt ?? captureStarted
                        captureEnded = captured?.endedAt
                    } else if app.service != nil { nodes = readTree(entry.window, skipWebContent: false, readClasses: true).nodes }
                    else if let document = entry.document, !isDestroyed(document),
                            window.nodes.contains(where: { $0.role == "AXWebArea" && CFEqual($0.element, document) }),
                            entry.tab.map({ tab in window.browserTabs.contains(where: { $0.selected && CFEqual($0.element, tab) }) }) ?? true {
                        nodes = readTree(document, skipWebContent: false, readClasses: true).nodes
                    } else { nodes = [] }
                    let observedEnd = captureEnded ?? Date().timeIntervalSince1970
                    result.speakerCaptureStatus[entry.meeting.id] = "\(nodes.count) nodes; \(nodes.filter { $0.text == "Captions" }.count) caption regions"
                    result.speakers[entry.meeting.id] = observedEnd - captureStarted <= 0.8
                        ? Array(Set(nodes.compactMap(\.activeSpeaker))).sorted() : []
                    result.speakerObservedAt[entry.meeting.id] = (captureStarted + observedEnd) / 2
                    if inspectBoxes {
                        result.speakerBoxes[entry.meeting.id] = nodes.prefix(700).enumerated().map { index, node in
                            var value: CFTypeRef?
                            AXUIElementCopyAttributeValue(node.element, "AXDOMClassList" as CFString, &value)
                            var row: [String: String] = ["index": String(index), "parent": node.parentIndex.map(String.init) ?? "", "role": node.role, "text": String(node.text.prefix(160)),
                                                        "classes": (value as? [String] ?? []).joined(separator: " ")]
                            row["identifier"] = string(node.element, "AXIdentifier")
                            row["help"] = String(string(node.element, kAXHelpAttribute).prefix(200))
                            row["description"] = String(string(node.element, kAXDescriptionAttribute).prefix(200))
                            row["value"] = String(string(node.element, kAXValueAttribute).prefix(200))
                            row["subrole"] = string(node.element, kAXSubroleAttribute)
                            row["role_description"] = string(node.element, kAXRoleDescriptionAttribute)
                            row["title"] = String(string(node.element, kAXTitleAttribute).prefix(200))
                            if row["role_description"] == "Video render" {
                                var attributes: CFArray?
                                if AXUIElementCopyAttributeNames(node.element, &attributes) == .success {
                                    row["attribute_names"] = (attributes as? [String] ?? []).joined(separator: " ")
                                }
                                for attribute in ["AXSelected", "AXFocused", "AXValue", "AXExpanded", "AXEnabled", "AXCustomContent"] {
                                    var raw: CFTypeRef?
                                    if AXUIElementCopyAttributeValue(node.element, attribute as CFString, &raw) == .success, let raw {
                                        if let number = raw as? NSNumber { row[attribute] = number.stringValue }
                                        else if let text = raw as? String { row[attribute] = String(text.prefix(300)) }
                                    }
                                }
                            }
                            var sizeValue: CFTypeRef?
                            if AXUIElementCopyAttributeValue(node.element, kAXSizeAttribute as CFString, &sizeValue) == .success,
                               let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                                var size = CGSize.zero
                                if AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) { row["size"] = "\(size.width),\(size.height)" }
                            }
                            return row
                        }
                    }
                    let tileCount = tiles[entry.meeting.id]?.count ?? 0
                    result.speakerCaptureStatus[entry.meeting.id, default: ""] += "; \(tileCount) speaker tiles; discovery \(speakerRefresh[entry.meeting.id]?.isFresh(at: ProcessInfo.processInfo.systemUptime) == true ? "current" : "refreshing")"
                    if entry.meeting.service == "Zoom" {
                        let videos = zoomVideos[entry.meeting.id] ?? []
                        result.speakerCaptureStatus[entry.meeting.id] = "\(videos.count) native Zoom video tiles"
                        if !videos.isEmpty && Config.zoomVisualSpeakerDetection() && !ZoomWindowSpeakerDetector.hasPermission {
                            result.needsZoomScreenPermission = true
                            result.speakerCaptureStatus[entry.meeting.id] = "Zoom speaker names need Screen Recording permission"
                            result.speakerNameWarnings[entry.meeting.id] = "Zoom speaker names need Screen Recording permission"
                        } else if Config.zoomVisualSpeakerDetection(), let snapshot = zoomSnapshots(videos), !snapshot.contains(where: \.isLocal) {
                            result.speakerNameWarnings[entry.meeting.id] = "Zoom names unavailable: show your tile and match your Zoom display name"
                        }
                    }
                    if entry.meeting.service == "Google Meet" {
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
                    if entry.meeting.service == "Slack" {
                        let state = slackState(window, visible: !bool(entry.window, kAXMinimizedAttribute))
                        let isEnded = endState.isEnded(entry.meeting.id, endScreen: state == .ended, inCall: state == .joined)
                        result.observations[entry.meeting.id] = isEnded ? .ended : (state == .joined ? .present(entry.meeting) : .unknown)
                        continue
                    }
                    // Never infer end merely from a temporarily hidden Leave button.
                    result.observations[entry.meeting.id] = ended && !leave && window.complete ? .ended : (leave ? .present(entry.meeting) : .unknown)
                    continue
                }
                let tabPresent = window.browserTabs.contains { node in
                    guard node.isTab else { return false }
                    return entry.tab.map { CFEqual($0, node.element) } == true
                        || (entry.code != nil && MeetingEvidence.meetCode(in: node.text) == entry.code)
                }
                let documentPresent = window.browserDocuments.contains { node in
                    guard node.role == "AXWebArea" else { return false }
                    return entry.document.map { CFEqual($0, node.element) } == true
                        || (entry.code != nil && MeetingEvidence.meetCode(in: node.url) == entry.code)
                }
                if entry.meeting.service == "Slack" {
                    let visible = !bool(entry.window, kAXMinimizedAttribute) && (entry.tab.map { tab in
                        window.browserTabs.contains { $0.selected && CFEqual($0.element, tab) }
                    } ?? documentPresent)
                    let document = entry.document.flatMap { window.documents[$0] }
                    let state = document.map { slackState($0, visible: visible) } ?? .unknown
                    let navigatedAway = visible && window.complete && window.browserDocuments.contains { node in
                        node.role == "AXWebArea" && entry.document.map { CFEqual($0, node.element) } == true
                            && !node.url.isEmpty && MeetingEvidence.service(url: node.url) != "Slack"
                    }
                    if endState.isEnded(entry.meeting.id, endScreen: state == .ended || navigatedAway, inCall: state == .joined) {
                        result.observations[entry.meeting.id] = .ended
                    } else if state == .joined || (!visible && (tabPresent || documentPresent)) {
                        result.observations[entry.meeting.id] = .present(entry.meeting)
                    } else if !tabPresent && !documentPresent, let tab = entry.tab, window.complete,
                              !window.browserTabs.isEmpty || isDestroyed(tab) {
                        result.observations[entry.meeting.id] = .ended
                    } else {
                        result.observations[entry.meeting.id] = .unknown
                    }
                    continue
                }
                if endState.isEnded(entry.meeting.id, endScreen: documentPresent && ended && !leave, inCall: documentPresent && leave) {
                    result.observations[entry.meeting.id] = .ended
                } else if tabPresent || documentPresent {
                    result.observations[entry.meeting.id] = .present(entry.meeting)
                } else if let tab = entry.tab, window.complete,
                          !window.browserTabs.isEmpty || isDestroyed(tab) {
                    result.observations[entry.meeting.id] = .ended
                } else {
                    result.observations[entry.meeting.id] = .unknown
                }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for (id, observation) in result.observations {
            if observation == .ended {
                invalidateSpeakerTiles(id)
                speakerRefresh.removeValue(forKey: id)
                zoomScores.removeValue(forKey: id)
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

    private func slackState(_ window: Window, visible: Bool) -> SlackHuddleEvidence.State {
        SlackHuddleEvidence.state(controls: window.nodes.filter { SlackHuddleEvidence.isControl(role: $0.role) }.map(\.text),
                                  complete: window.complete, visible: visible)
    }

    private func hasCallControls(_ window: Window, service: String? = nil) -> Bool {
        if service == "Slack" {
            return SlackHuddleEvidence.hasJoinedControls(window.nodes.filter { SlackHuddleEvidence.isControl(role: $0.role) }.map(\.text))
        }
        if MeetingEvidence.hasCallControls(window.nodes.filter { $0.role == kAXButtonRole }.map(\.text)) { return true }
        guard service == "Zoom" else { return false }
        let labels = window.nodes.filter { $0.role == "AXTabGroup" && $0.roleDescription == "video render" }.map(\.text)
        return MeetingEvidence.isZoomConferenceWindow(title: string(window.element, kAXTitleAttribute), videoLabels: labels)
    }

    private func nextID(pid: pid_t) -> String {
        serial += 1
        return "\(pid):\(serial)"
    }

    private func readWindow(_ window: AXUIElement, browser: Bool) -> Window {
        var result = readTree(window, skipWebContent: browser)
        if browser {
            // Keep browser chrome separate from Slack's own Home/Messages tabs.
            result.browserTabs = result.nodes.filter(\.isTab)
            result.browserDocuments = result.nodes.filter { $0.role == "AXWebArea" }
            for document in result.browserDocuments where MeetingEvidence.service(url: document.url) != nil || MeetingEvidence.meetCode(in: document.text) != nil {
                let contents = readTree(document.element, skipWebContent: false)
                result.documents[document.element] = contents
                result.nodes.append(contentsOf: contents.nodes.dropFirst())
            }
        }
        return result
    }

    private func readTree(_ window: AXUIElement, skipWebContent: Bool, readClasses: Bool = false) -> Window {
        let startedAt = Date().timeIntervalSince1970
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
                              parentIndex: parentIndex, classNames: readClasses ? strings(element, "AXDOMClassList") : [],
                              subrole: string(element, kAXSubroleAttribute), roleDescription: roleDescription))
            if skipWebContent && role == "AXWebArea" { continue }
            if let childElements = children(element, attribute: kAXChildrenAttribute) {
                queue.append(contentsOf: childElements.reversed().map { ($0, nodes.count - 1) })
            } else { complete = false }
        }
        return Window(element: window, nodes: nodes, complete: complete,
                      startedAt: startedAt, endedAt: Date().timeIntervalSince1970)
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

    private func frame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func zoomSnapshots(_ controls: [AXUIElement]) -> [ZoomVideoSnapshot]? {
        let localName = Config.zoomLocalSpeakerName()
        var snapshots: [ZoomVideoSnapshot] = []
        for control in controls {
            guard !isDestroyed(control), let rect = frame(control),
                  let video = ZoomSpeakerEvidence.participant(description: string(control, kAXDescriptionAttribute), frame: rect, localName: localName) else { return nil }
            snapshots.append(video)
        }
        return snapshots
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
