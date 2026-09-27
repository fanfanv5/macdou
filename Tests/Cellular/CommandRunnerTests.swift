import Foundation

@main enum CommandRunnerTests {
    static func main() async {
        let runner = CommandRunner()
        let result = await runner.run(URL(fileURLWithPath:"/usr/bin/head"),["-c","262144","/dev/zero"],timeout:3)
        precondition(!result.timedOut && result.code == 0 && result.output.count == 262144,"Large helper output must not block a full pipe")
        print("PASS: helper pipe drains 256 KiB without blocking; SMS output is not limited by pipe capacity.")
    }
}
