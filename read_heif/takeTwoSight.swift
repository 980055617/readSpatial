//
//  main.swift
//  read_heif
//
//  Created by 長尾確 on 2024/07/12.
//
import Foundation
import ArgumentParser // Available from Apple: https://github.com/apple/swift-argument-parser

@main
struct SideBySideToMVHEVC: AsyncParsableCommand {

    @Argument(help: "The MV-HEVC video file to convert.")
    var sideBySideVideoPath: String

    mutating func run() async throws {

        // Determine an appropriate output file URL.
        let inputURL = URL(fileURLWithPath: sideBySideVideoPath)
        let converter = try await SideBySideConverter(from: inputURL)

        // Perform the video conversion.
        await converter.transcodeToTwoSight(output: inputURL)
        print("two sight video written to \(inputURL).")

    }

}




