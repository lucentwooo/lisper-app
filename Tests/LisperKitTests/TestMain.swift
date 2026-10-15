// CLT-only macOS test entry point: `swift test` builds but cannot execute test
// bundles without Xcode, so tests run as an executable via `swift run LisperKitTests`.
import Testing

@main
struct TestMain {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
