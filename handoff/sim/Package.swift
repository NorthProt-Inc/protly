// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "sim", targets: [
  .target(name: "ProtlyCore", resources: [.copy("Resources/en_50k.txt"), .copy("Resources/ko_50k.txt"), .copy("Resources/keyboard-prompt.txt")]),
  .target(name: "UIKit"), .target(name: "os"),
  .executableTarget(name: "sim", dependencies: ["ProtlyCore", "UIKit", "os"], swiftSettings: [.swiftLanguageMode(.v5)]),
])
