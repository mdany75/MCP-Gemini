// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MCP-Gemini",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mcp-gemini", targets: ["MCPGemini"]),
    ],
    targets: [
        .target(name: "MCPGeminiKit"),
        .executableTarget(name: "MCPGemini", dependencies: ["MCPGeminiKit"]),
        .testTarget(name: "MCPGeminiKitTests", dependencies: ["MCPGeminiKit"]),
    ]
)
