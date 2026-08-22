import AppKit
import Foundation

let outputs = CommandLine.arguments.dropFirst()
guard !outputs.isEmpty else {
    fputs("usage: swift render-openfish-icon.swift OUTPUT...\n", stderr)
    exit(2)
}

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let masterURL = repositoryRoot.appendingPathComponent("apps/brand/openfish-mark.png")
let macMarkURL = repositoryRoot.appendingPathComponent(
    "apps/x-macos/Sources/XMac/Assets.xcassets/OpenFishMark.imageset/OpenFishMark.png"
)

guard let master = NSImage(contentsOf: masterURL) else {
    fputs("could not load OpenFish brand master at \(masterURL.path)\n", stderr)
    exit(1)
}
guard let macMark = NSImage(contentsOf: macMarkURL) else {
    fputs("could not load transparent macOS mark at \(macMarkURL.path)\n", stderr)
    exit(1)
}

func pixelSize(for output: String) -> Int {
    let filename = URL(fileURLWithPath: output).lastPathComponent
    let pattern = #"OpenFish-(\d+)\.png"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
              in: filename,
              range: NSRange(filename.startIndex..., in: filename)
          ),
          let range = Range(match.range(at: 1), in: filename),
          let size = Int(filename[range]) else {
        return 1024
    }
    return size
}

for output in outputs {
    let pixels = pixelSize(for: String(output))
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("could not allocate \(output)\n", stderr)
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))

    if String(output).contains("/x-macos/") {
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()

        let available = CGFloat(pixels) * 0.55
        let scale = min(available / macMark.size.width, available / macMark.size.height)
        let markSize = NSSize(
            width: macMark.size.width * scale,
            height: macMark.size.height * scale
        )
        let markRect = NSRect(
            x: (CGFloat(pixels) - markSize.width) / 2,
            y: (CGFloat(pixels) - markSize.height) / 2,
            width: markSize.width,
            height: markSize.height
        )
        macMark.draw(
            in: markRect,
            from: NSRect(origin: .zero, size: macMark.size),
            operation: .sourceOver,
            fraction: 1
        )
    } else {
        master.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: NSRect(origin: .zero, size: master.size),
            operation: .copy,
            fraction: 1
        )
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("could not render \(output)\n", stderr)
        exit(1)
    }

    let url = URL(fileURLWithPath: String(output))
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: url, options: .atomic)
}
