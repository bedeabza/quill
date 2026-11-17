import Foundation

/// A self-contained copy of the displayed discussion, never an edit to its
/// recording. All transcript/title/name content is rendered as escaped text.
enum RecordingHTMLExport {
    struct Document: Sendable {
        let html: String
        let suggestedFilename: String

        func write(to destination: URL) throws {
            guard destination.isFileURL, ["html", "htm"].contains(destination.pathExtension.lowercased()) else {
                throw TranscriptionFailure("Choose an HTML file for the export.")
            }
            try Data(html.utf8).write(to: destination, options: .atomic)
        }
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func filename(for entry: RecordingEntry, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let title = entry.title.components(separatedBy: forbidden).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var name = String(title.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 180 { name.removeLast() }
        return formatter.string(from: entry.startedAt) + (name.isEmpty ? "" : " - " + name) + ".html"
    }

    static func make(entry: RecordingEntry, preview: TranscriptPreview, names: [String: String] = [:]) throws -> Document {
        let palette = ["#2563eb", "#b45309", "#15803d", "#7e22ce", "#be185d", "#0f766e", "#4338ca", "#92400e"]
        var voices: [(identity: String, name: String, label: String, first: Int)] = []
        let content: String
        switch preview {
        case .turns(let turns):
            guard !turns.isEmpty else { throw TranscriptionFailure("There is no speech to export in this recording.") }
            content = turns.enumerated().map { index, turn in
                let identity = turn.navigationID
                let label = turn.speakerID.map(SpeakerNames.label) ?? turn.speaker
                let name = turn.speakerID.flatMap { names[$0] }.map { SpeakerAttribution.cleanName($0) ?? label } ?? turn.speaker
                let voice: Int
                if let existing = voices.firstIndex(where: { $0.identity == identity }) { voice = existing }
                else { voice = voices.count; voices.append((identity, name, label, index)) }
                let original = label != name && label.hasPrefix("Speaker ") ? "<span class=\"voice-id\">\(escape(label))</span>" : ""
                return """
                <article class="turn" id="turn-\(index)">
                  <a class="timestamp" href="#turn-\(index)">\(RecordingFormat.clock(turn.start))</a>
                  <div><h2 class="voice-\(voice % palette.count)">\(escape(name)) \(original)</h2><p>\(escape(turn.text))</p></div>
                </article>
                """
            }.joined(separator: "\n")
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptionFailure("The transcript is empty.") }
            content = "<pre class=\"plain-transcript\">\(escape(text))</pre>"
        case .empty(let reason): throw TranscriptionFailure(reason)
        }
        let voiceStyles = palette.enumerated().map { ".voice-\($0.offset) { color: \($0.element); }" }.joined(separator: "\n")
        let links = voices.enumerated().map { index, voice in
            "<a class=\"voice-link voice-\(index % palette.count)\" href=\"#turn-\(voice.first)\">\(escape(voice.name))</a>"
        }.joined(separator: "\n")
        let navigation = links.isEmpty ? "" : "<nav aria-label=\"Speakers\"><span>Speakers</span>\(links)</nav>"
        let participants = entry.participants.isEmpty ? "" : "<p class=\"participants\"><strong>Participants recorded:</strong> \(escape(entry.participants.joined(separator: ", ")))</p>"
        let zone = TimeZone.autoupdatingCurrent.abbreviation(for: entry.startedAt) ?? TimeZone.autoupdatingCurrent.identifier
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="referrer" content="no-referrer">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
          <title>\(escape(entry.title))</title>
          <style>
            :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; color: #172033; background: #f4f6fa; }
            * { box-sizing: border-box; }
            body { margin: 0; line-height: 1.65; }
            main { max-width: 960px; margin: 36px auto; background: #fff; padding: 40px; border: 1px solid #e1e6ef; border-radius: 16px; }
            header { margin-bottom: 28px; }
            .eyebrow { color: #667085; text-transform: uppercase; letter-spacing: .12em; font-size: 12px; font-weight: 600; }
            h1 { font-size: clamp(24px, 4vw, 34px); line-height: 1.25; margin: 10px 0 18px; overflow-wrap: anywhere; }
            .metadata, .participants { color: #667085; margin: 8px 0; }
            nav { position: sticky; top: 0; display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 12px 0; background: #fff; border-bottom: 1px solid #e1e6ef; z-index: 1; }
            nav > span { font-size: 13px; font-weight: 600; margin-right: 4px; }
            .voice-link { text-decoration: none; border: 1px solid #e1e6ef; border-radius: 20px; padding: 3px 12px; font-size: 14px; font-weight: 600; overflow-wrap: anywhere; }
            .turn { display: grid; grid-template-columns: 78px minmax(0, 1fr); gap: 16px; padding: 22px 0; border-bottom: 1px solid #eef0f5; scroll-margin-top: 120px; }
            .turn:target { background: #f0f5ff; border-radius: 8px; }
            .timestamp { color: #667085; font-size: 12px; text-decoration: none; font-variant-numeric: tabular-nums; padding-top: 3px; }
            h2 { font-size: 15px; line-height: 1.5; margin: 0 0 5px; overflow-wrap: anywhere; }
            .voice-id { color: #667085; font-size: 12px; font-weight: 400; margin-left: 8px; }
            p { margin: 0; overflow-wrap: anywhere; }
            .turn p, .plain-transcript { white-space: pre-wrap; }
            .plain-transcript { font: inherit; overflow-wrap: anywhere; }
            footer { color: #667085; font-size: 12px; padding-top: 24px; }
            a:focus-visible { outline: 2px solid #2563eb; outline-offset: 3px; }
            \(voiceStyles)
            @media (max-width: 620px) { main { margin: 0; border: 0; border-radius: 0; padding: 24px 18px; } .turn { grid-template-columns: 1fr; gap: 4px; } }
            @media print { :root { background: #fff; } main { margin: 0; border: 0; padding: 0; max-width: none; } nav { display: none; } .turn { break-inside: avoid; } a { color: inherit; } }
          </style>
        </head>
        <body>
          <main>
            <header>
              <div class="eyebrow">Meeting transcript</div>
              <h1>\(escape(entry.title))</h1>
              <p class="metadata">\(escape(RecordingFormat.when(entry))) · \(escape(zone))</p>
              \(participants)
            </header>
            \(navigation)
            <section aria-label="Transcript">\(content)</section>
            <footer>Exported from Quill</footer>
          </main>
        </body>
        </html>
        """
        return Document(html: html, suggestedFilename: filename(for: entry))
    }
}
