// swift-tools-version: 6.0
import PackageDescription
import Foundation

// swift-testing's `@Test`/`@Suite` macros are expanded by the ACTIVE toolchain and must link
// the matching Testing.framework, or expansion mismatches the framework (e.g. `__uncheckedFileID`
// vs `fileID`). Pick the first candidate that actually contains the framework binary — the Xcode
// platform dir when Xcode is selected, else CLT. Resilient to an `xcode-select` switch / CLT update.
let testingFrameworks: String = {
    let fm = FileManager.default
    let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        ?? "/Applications/Xcode.app/Contents/Developer"
    let candidates = [
        "\(developer)/Platforms/MacOSX.platform/Developer/Library/Frameworks",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks",
        "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
    ]
    return candidates.first { fm.fileExists(atPath: "\($0)/Testing.framework/Testing") } ?? candidates[0]
}()

let package = Package(
    name: "Lisper",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "LisperKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Lisper",
            dependencies: ["LisperKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CLT-only macOS test runner: `swift test` builds but cannot execute test
        // bundles without Xcode, so tests run as an executable via `swift run LisperKitTests`.
        // macOS test runner: tests run as an executable via `swift run LisperKitTests`
        // (swift-testing's `@Test`/`@Suite` macros + the linked Testing.framework must come
        // from the SAME active toolchain, or the macro expansion mismatches the framework).
        // NOTE: hardcoded framework path — machine-specific, pinned to whichever toolchain is
        // active. If Testing.framework moves (Xcode install/move, CLT update, `xcode-select`
        // switch), update `testingFrameworks` below. Find the live path with:
        //   dirname "$(find "$(xcode-select -p)" -name Testing.framework -path '*MacOSX*' | head -1)"
        .executableTarget(
            name: "LisperKitTests",
            dependencies: ["LisperKit"],
            path: "Tests/LisperKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags([
                    "-F", testingFrameworks,
                    // Testing.framework declares a cross-import overlay (`Testing.swiftcrossimport`)
                    // that the compiler auto-loads whenever a file imports BOTH `Testing` and
                    // `Foundation` — but the CLT ships `_Testing_Foundation.framework` with NO
                    // `Modules/` dir, so that overlay has no `.swiftmodule` to load and every such
                    // test file dies with "no such module '_Testing_Foundation'". The overlay only
                    // adds sugar we don't use, so decline it.
                    "-Xfrontend", "-disable-cross-import-overlays"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", testingFrameworks,
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", testingFrameworks
                ])
            ]
        ),
    ]
)
