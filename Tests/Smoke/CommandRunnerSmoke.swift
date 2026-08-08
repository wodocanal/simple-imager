import Foundation

@main
enum CommandRunnerSmoke {
    static func main() throws {
        let output = try CommandRunner.run(
            "/bin/dd",
            ["if=/dev/zero", "bs=1048576", "count=2"]
        )
        guard output.status == 0, output.stdout.count == 2 * 1024 * 1024 else {
            throw SmokeError.failed("large subprocess output was not captured")
        }
        print("Command runner smoke test passed (2 MiB captured without a pipe deadlock).")
    }
}

private enum SmokeError: Error {
    case failed(String)
}
