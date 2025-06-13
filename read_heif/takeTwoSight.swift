import Foundation
import ArgumentParser

@main
struct SideBySideBatch: AsyncParsableCommand {
    @Option(help: "Input directory path (default: input)")
    var inputDir: String = "input"
    @Option(help: "Output directory path (default: output)")
    var outputDir: String = "output"

    mutating func run() async throws {
        let fm = FileManager.default
        let inURL = URL(fileURLWithPath: inputDir)
        let outURL = URL(fileURLWithPath: outputDir)
        let files = try fm.contentsOfDirectory(at: inURL,
                                              includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mov" }
        for file in files {
            let base = file.deletingPathExtension().lastPathComponent
            let converter = try await SideBySideConverter(from: file)
            try await converter.transcodeToSideBySide(
                output: outURL.appendingPathComponent(base + "_sideBySide.mp4")
            )
            try await converter.transcodeDepth(
                output: outURL.appendingPathComponent(base + "_depth.mp4")
            )
            print("Processed: \(base)")
        }
    }
}
