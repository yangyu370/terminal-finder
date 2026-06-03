//
//  BackendProcessLauncher.swift
//  MacOS
//
//  Created by Wang on 2026/6/3.
//

import Darwin
import Foundation

protocol BackendProcessLaunching: AnyObject {
    func launchBackendIfNeeded() throws
}

final class BackendProcessLauncher: BackendProcessLaunching {
    private let environment: [String: String]
    private let fileManager: FileManager
    private let sourceFilePath: String
    private var process: Process?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        sourceFilePath: String = #filePath
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.sourceFilePath = sourceFilePath
    }

    deinit {
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    func launchBackendIfNeeded() throws {
        if process?.isRunning == true {
            return
        }

        let command = try resolveLaunchCommand()
        let backendProcess = Process()
        backendProcess.executableURL = command.executableURL
        backendProcess.arguments = command.arguments
        backendProcess.currentDirectoryURL = backendWorkingDirectory(fallback: command.currentDirectoryURL)
        backendProcess.environment = backendEnvironment()
        let outputHandle = FileHandle(forWritingAtPath: "/dev/null")
        backendProcess.standardOutput = outputHandle
        backendProcess.standardError = outputHandle

        do {
            try backendProcess.run()
        } catch {
            throw BackendProcessLauncherError.launchFailed(command.displayName, error)
        }

        process = backendProcess
    }

    private func resolveLaunchCommand() throws -> BackendLaunchCommand {
        if let configuredPath = environment["TERMINAL_FINDER_CORE_PATH"],
           !configuredPath.isEmpty,
           fileManager.isExecutableFile(atPath: configuredPath) {
            let executableURL = URL(fileURLWithPath: configuredPath)
            return BackendLaunchCommand(
                executableURL: executableURL,
                arguments: [],
                currentDirectoryURL: executableURL.deletingLastPathComponent(),
                displayName: configuredPath
            )
        }

        if let bundledBackendURL = Bundle.main.url(forResource: "core", withExtension: nil),
           fileManager.isExecutableFile(atPath: bundledBackendURL.path) {
            return BackendLaunchCommand(
                executableURL: bundledBackendURL,
                arguments: [],
                currentDirectoryURL: bundledBackendURL.deletingLastPathComponent(),
                displayName: bundledBackendURL.path
            )
        }

        if let repositoryRoot = findRepositoryRoot() {
            let debugBinaryURL = repositoryRoot
                .appendingPathComponent("core")
                .appendingPathComponent("target")
                .appendingPathComponent("debug")
                .appendingPathComponent("core")

            if fileManager.isExecutableFile(atPath: debugBinaryURL.path) {
                return BackendLaunchCommand(
                    executableURL: debugBinaryURL,
                    arguments: [],
                    currentDirectoryURL: debugBinaryURL.deletingLastPathComponent(),
                    displayName: debugBinaryURL.path
                )
            }

            let manifestURL = repositoryRoot
                .appendingPathComponent("core")
                .appendingPathComponent("Cargo.toml")

            if fileManager.fileExists(atPath: manifestURL.path) {
                return BackendLaunchCommand(
                    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["cargo", "run", "--manifest-path", manifestURL.path],
                    currentDirectoryURL: repositoryRoot.appendingPathComponent("core"),
                    displayName: "cargo run --manifest-path \(manifestURL.path)"
                )
            }
        }

        throw BackendProcessLauncherError.backendExecutableNotFound
    }

    private func findRepositoryRoot() -> URL? {
        let candidates = [
            URL(fileURLWithPath: sourceFilePath),
            URL(fileURLWithPath: fileManager.currentDirectoryPath),
            Bundle.main.bundleURL
        ]

        for candidate in candidates {
            if let repositoryRoot = nearestRepositoryRoot(from: candidate) {
                return repositoryRoot
            }
        }

        return nil
    }

    private func nearestRepositoryRoot(from candidate: URL) -> URL? {
        var directory = candidate.hasDirectoryPath ? candidate : candidate.deletingLastPathComponent()

        for _ in 0..<12 {
            let manifestURL = directory
                .appendingPathComponent("core")
                .appendingPathComponent("Cargo.toml")

            if fileManager.fileExists(atPath: manifestURL.path) {
                return directory
            }

            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                break
            }
            directory = parent
        }

        return nil
    }

    private func backendEnvironment() -> [String: String] {
        var backendEnvironment = environment

        if let homeDirectoryPath = realUserHomeDirectoryPath() {
            backendEnvironment["HOME"] = homeDirectoryPath
            backendEnvironment["PWD"] = homeDirectoryPath
        }

        return backendEnvironment
    }

    private func backendWorkingDirectory(fallback: URL) -> URL {
        guard let homeDirectoryPath = realUserHomeDirectoryPath() else {
            return fallback
        }

        return URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
    }

    private func realUserHomeDirectoryPath() -> String? {
        guard let passwordRecord = getpwuid(getuid()),
              let homeDirectory = passwordRecord.pointee.pw_dir
        else {
            return nil
        }

        return String(cString: homeDirectory)
    }
}

private struct BackendLaunchCommand {
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let displayName: String
}

enum BackendProcessLauncherError: LocalizedError {
    case backendExecutableNotFound
    case launchFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .backendExecutableNotFound:
            return "Core executable was not found. Build the Rust backend or set TERMINAL_FINDER_CORE_PATH."
        case .launchFailed(let command, let error):
            return "Unable to start core with \(command): \(error.localizedDescription)"
        }
    }
}
