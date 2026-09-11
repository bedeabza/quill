import ArgumentParser
import Foundation

extension PostProcessingMode: ExpressibleByArgument {}

struct Postprocess: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Optional transcript cleanup through a signed-in Codex or Claude Code CLI. Uses cloud models.",
        subcommands: [PostprocessStatus.self, PostprocessConfigure.self, PostprocessRun.self])
}

struct PostprocessStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Check configuration and signed-in harness availability.")

    func run() throws {
        Task { @MainActor in
            let options = Config.postProcessing()
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("quill-harness-check-" + UUID().uuidString)
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? fm.removeItem(at: work) }
                var harnesses: [[String: Any]] = []
                for kind in [PostProcessingMode.codex, .claude] {
                    let harness = TranscriptHarness.find(kind)
                    let ready = await harness?.isReady(directory: work) ?? false
                    harnesses.append(["harness": kind.rawValue, "installed": harness != nil, "ready": ready])
                }
                let json: [String: Any] = ["mode": options.mode.rawValue, "cloud_processing": true,
                                           "timeout_seconds": options.timeout, "harnesses": harnesses]
                let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Could not check transcript cleanup availability.\n".utf8))
                Darwin.exit(1)
            }
        }
        dispatchMain()
    }
}

struct PostprocessConfigure: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "configure", abstract: "Choose off, auto, codex, or claude for future completed recordings.")
    @Option(help: "Enabling cleanup sends transcript text to the selected harness's cloud provider.") var mode: PostProcessingMode

    func run() throws {
        guard Config.setPostProcessingMode(mode) else { throw ValidationError("Could not save Quill's configuration.") }
        print(mode == .off ? "Transcript cleanup is off." : "Transcript cleanup: \(mode.rawValue). Completed transcripts may be sent to the harness's cloud provider.")
    }
}

struct PostprocessRun: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Clean up a completed transcript once using a cloud harness, retaining an exact backup.")
    @Argument(help: "Completed recording folder. Audio is not uploaded.") var recording: String
    @Option(help: "Harness to use for this run, independent of the automatic setting.") var harness: PostProcessingMode = .auto

    func run() throws {
        let directory = URL(fileURLWithPath: (recording as NSString).expandingTildeInPath).standardizedFileURL
        _ = try SessionMeta.read(from: directory)
        let mode = harness
        Task {
            var options = Config.postProcessing()
            options.mode = mode
            let report = await TranscriptPostProcessor.process(directory, options: options)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report) { print(String(decoding: data, as: UTF8.self)) }
            Darwin.exit(report.status == "completed" || report.status == "skipped_already_processed" ? 0 : 1)
        }
        dispatchMain()
    }
}
