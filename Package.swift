// swift-tools-version:5.9
import PackageDescription

// Second build path, added by the fork.
//
// Upstream builds with XcodeGen + xcodebuild, which needs a full Xcode install.
// This manifest builds the same sources with the Command Line Tools alone, so
// the app can be compiled on a machine that has never downloaded Xcode. It
// produces a bare executable; `build-spm.sh` wraps it into the .app bundle.
//
// Upstream's build.sh is untouched and still works for anyone who has Xcode.
let package = Package(
    name: "BeszelBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BeszelBar",
            path: "Sources"
        )
    ]
)
