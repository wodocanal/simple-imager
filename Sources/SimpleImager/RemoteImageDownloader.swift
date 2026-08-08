import Foundation

struct RemoteDownloadResult {
    let fileURL: URL
    let format: ImageFileFormat
    let effectiveURL: URL
}

enum RemoteImageDownloader {
    private static let curl = "/usr/bin/curl"

    static func validatedURL(from value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else { return nil }
        return url
    }

    static func download(
        from remoteURL: URL,
        to destinationURL: URL,
        cancelURL: URL
    ) throws -> RemoteDownloadResult {
        guard validatedURL(from: remoteURL.absoluteString) != nil else {
            throw AppError.invalidArguments("Введите прямую HTTP- или HTTPS-ссылку на файл образа.")
        }

        let identifier = UUID().uuidString
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let headerURL = temporaryDirectory.appendingPathComponent("sd-download-\(identifier).headers")
        let outputURL = temporaryDirectory.appendingPathComponent("sd-download-\(identifier).out")
        let errorURL = temporaryDirectory.appendingPathComponent("sd-download-\(identifier).err")
        for url in [destinationURL, headerURL, outputURL, errorURL] {
            try? FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        var completed = false
        defer {
            try? FileManager.default.removeItem(at: headerURL)
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
            if !completed { try? FileManager.default.removeItem(at: destinationURL) }
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: curl)
        process.arguments = [
            "--fail", "--location", "--max-redirs", "10",
            "--proto", "=http,https", "--proto-redir", "=http,https",
            "--connect-timeout", "30", "--silent", "--show-error",
            "--user-agent", "Simple-Imager/0.1.0",
            "--dump-header", headerURL.path,
            "--output", destinationURL.path,
            "--write-out", "%{url_effective}",
            remoteURL.absoluteString
        ]
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
            while process.isRunning {
                if FileManager.default.fileExists(atPath: cancelURL.path) {
                    process.terminate()
                    process.waitUntilExit()
                    throw AppError.cancelled
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            process.waitUntilExit()
            try outputHandle.close()
            try errorHandle.close()
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? outputHandle.close()
            try? errorHandle.close()
            throw error
        }

        let details = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            let message = details.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.archiveInvalid(
                message.isEmpty
                    ? "Не удалось скачать образ по указанному URL."
                    : "Не удалось скачать образ. \(message)"
            )
        }
        guard let fileSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.uint64Value,
              fileSize > 0 else {
            throw AppError.archiveInvalid("Сервер вернул пустой файл образа.")
        }

        let effectiveValue = ((try? String(contentsOf: outputURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveURL = URL(string: effectiveValue) ?? remoteURL
        let headers = (try? String(contentsOf: headerURL, encoding: .utf8)) ?? ""
        guard let format = detectedFormat(
            fileURL: destinationURL,
            originalURL: remoteURL,
            effectiveURL: effectiveURL,
            headers: headers
        ) else {
            throw AppError.archiveInvalid(
                "Не удалось определить формат загруженного файла. Нужна прямая ссылка на IMG, RAW или DD с поддерживаемым сжатием."
            )
        }

        completed = true
        return RemoteDownloadResult(
            fileURL: destinationURL,
            format: format,
            effectiveURL: effectiveURL
        )
    }

    private static func detectedFormat(
        fileURL: URL,
        originalURL: URL,
        effectiveURL: URL,
        headers: String
    ) -> ImageFileFormat? {
        var names = contentDispositionFileNames(in: headers)
        names.append(effectiveURL.lastPathComponent)
        names.append(originalURL.lastPathComponent)
        return ImageFileFormat.detect(
            fileURL: fileURL,
            suggestedNames: names.filter { !$0.isEmpty }
        )
    }

    private static func contentDispositionFileNames(in headers: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)filename\*?\s*=\s*(?:UTF-8''|\")?([^\";\r\n]+)"#
        ) else { return [] }
        return expression.matches(
            in: headers,
            range: NSRange(headers.startIndex..., in: headers)
        ).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: headers) else { return nil }
            return String(headers[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                .removingPercentEncoding
        }
    }
}
