import CryptoKit
import Darwin
import Foundation

enum RuntimeCheckState: String, Sendable {
    case ready
    case warning
    case failed
}

struct RuntimeCheck: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let state: RuntimeCheckState
}

struct RuntimeReadinessReport: Sendable {
    let checks: [RuntimeCheck]

    var isReady: Bool {
        !checks.contains { $0.state == .failed }
    }
}

enum RuntimeEnvironment {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let platform: String
        let architecture: String
        let files: [ManifestFile]
    }

    private struct ManifestFile: Decodable {
        let path: String
        let sha256: String
        let kind: String
    }

    private static let bundledToolNames = [
        "zstd", "xz", "lz4", "7zz",
        "debugfs", "e2fsck", "resize2fs", "tune2fs"
    ]

    static func executable(named name: String, fallbacks: [String] = []) -> String? {
        let bundledURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(name)
        let candidates = [bundledURL.path] + fallbacks
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func audit(bundleURL: URL = Bundle.main.bundleURL) -> RuntimeReadinessReport {
        var checks: [RuntimeCheck] = []

#if arch(arm64)
        checks.append(RuntimeCheck(
            id: "architecture",
            title: "Apple Silicon",
            detail: "Архитектура arm64 поддерживается.",
            state: .ready
        ))
#else
        checks.append(RuntimeCheck(
            id: "architecture",
            title: "Apple Silicon",
            detail: "Эта версия предназначена только для Mac с процессором серии M.",
            state: .failed
        ))
#endif

        checks.append(runtimeCheck(bundleURL: bundleURL))
        checks.append(systemToolsCheck())
        checks.append(signatureCheck(bundleURL: bundleURL))
        checks.append(RuntimeCheck(
            id: "disk-access",
            title: "Доступ к накопителям",
            detail: "macOS запросит пароль администратора. Если прямой доступ будет заблокирован, включите для приложения «Полный доступ к диску».",
            state: .warning
        ))

        return RuntimeReadinessReport(checks: checks)
    }

    static func thirdPartyLicensesURL(bundleURL: URL = Bundle.main.bundleURL) -> URL? {
        let url = bundleURL
            .appendingPathComponent("Contents/Resources/ThirdPartyLicenses", isDirectory: true)
            .appendingPathComponent("THIRD-PARTY-NOTICES.md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func runtimeCheck(bundleURL: URL) -> RuntimeCheck {
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let manifestURL = resourcesURL.appendingPathComponent("RuntimeManifest.plist")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListDecoder().decode(Manifest.self, from: data),
              manifest.schemaVersion == 1,
              manifest.platform == "macos",
              manifest.architecture == "arm64" else {
            return RuntimeCheck(
                id: "runtime",
                title: "Встроенные компоненты",
                detail: "Манифест автономного runtime отсутствует или повреждён. Переустановите приложение.",
                state: .failed
            )
        }

        let invalidFiles = manifest.files.compactMap { entry -> String? in
            let fileURL = bundleURL.appendingPathComponent("Contents/" + entry.path)
            guard let digest = sha256(of: fileURL), digest == entry.sha256.lowercased() else {
                return entry.path
            }
            if entry.kind == "executable",
               !FileManager.default.isExecutableFile(atPath: fileURL.path) {
                return entry.path
            }
            return nil
        }
        let expectedTools = Set(bundledToolNames.map { "Helpers/" + $0 })
        let manifestTools = Set(manifest.files.filter { $0.kind == "executable" }.map(\.path))
        guard invalidFiles.isEmpty, expectedTools.isSubset(of: manifestTools) else {
            let details = invalidFiles.isEmpty ? "набор утилит неполон" : invalidFiles.joined(separator: ", ")
            return RuntimeCheck(
                id: "runtime",
                title: "Встроенные компоненты",
                detail: "Проверка SHA-256 не пройдена: " + details + ". Переустановите приложение.",
                state: .failed
            )
        }

        return RuntimeCheck(
            id: "runtime",
            title: "Встроенные компоненты",
            detail: "Проверено файлов: " + String(manifest.files.count)
                + ", утилит: " + String(manifestTools.count)
                + ". Homebrew для работы не требуется.",
            state: .ready
        )
    }

    private static func systemToolsCheck() -> RuntimeCheck {
        let paths = [
            "/usr/bin/gzip", "/usr/bin/bzip2", "/usr/bin/zip", "/usr/bin/unzip",
            "/usr/bin/bsdtar", "/usr/bin/curl", "/usr/bin/hdiutil",
            "/usr/bin/osascript", "/usr/sbin/diskutil"
        ]
        let missing = paths.filter { !FileManager.default.isExecutableFile(atPath: $0) }
        return RuntimeCheck(
            id: "system-tools",
            title: "Компоненты macOS",
            detail: missing.isEmpty
                ? "Все необходимые системные компоненты доступны."
                : "Не найдены: " + missing.joined(separator: ", ") + ".",
            state: missing.isEmpty ? .ready : .failed
        )
    }

    private static func signatureCheck(bundleURL: URL) -> RuntimeCheck {
        guard bundleURL.pathExtension == "app" else {
            return RuntimeCheck(
                id: "signature",
                title: "Подпись приложения",
                detail: "Проверка доступна в собранном .app.",
                state: .warning
            )
        }
        let result = run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", bundleURL.path]
        )
        return RuntimeCheck(
            id: "signature",
            title: "Подпись приложения",
            detail: result == 0
                ? "Подпись и вложенные исполняемые файлы действительны."
                : "Подпись повреждена. Переустановите приложение из доверенного источника.",
            state: result == 0 ? .ready : .failed
        )
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func run(executable: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
