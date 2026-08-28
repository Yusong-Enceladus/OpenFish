#!/usr/bin/env swift

import Foundation
import ImageIO
import Vision

let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let defaults = [
    "docs/assets/openfish-macos-demo.png",
    "docs/assets/openfish-iphone-demo.png",
    "docs/assets/openfish-harness-picker-demo.png",
    "docs/assets/openfish-harness-runtime-demo.png",
    "apps/x-macos/Sources/XMac/Assets.xcassets/AppIcon.appiconset/OpenFish-1024.png",
]
let paths = Array(CommandLine.arguments.dropFirst())
let inputs = paths.isEmpty ? defaults : paths
let rules: [(String, String)] = [
    ("developer home path", #"(?:file:///)?/Users/[A-Za-z0-9._-]+/"#),
    ("email address", #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#),
    ("local hostname", #"\b[A-Z0-9][A-Z0-9.-]*\.local\b"#),
    ("private IPv4 address", #"\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b"#),
    ("credential-like value", #"(?:\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{36,}\b|\bsk-[A-Za-z0-9_-]{20,}\b|\bxox[baprs]-[A-Za-z0-9-]{20,}\b|-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----)"#),
]
let expressions = try rules.map { name, pattern in
    (name, try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
}
var findings: [String] = []

for path in inputs {
    let url = URL(fileURLWithPath: path, relativeTo: repositoryRoot).standardizedFileURL
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        findings.append("\(path): image could not be decoded")
        continue
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US", "zh-Hans"]
    do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
        findings.append("\(path): OCR failed")
        continue
    }

    let text = (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for (name, expression) in expressions where expression.firstMatch(in: text, range: range) != nil {
        findings.append("\(path): \(name)")
    }
}

if !findings.isEmpty {
    for finding in Set(findings).sorted() {
        FileHandle.standardError.write(Data("\(finding)\n".utf8))
    }
    FileHandle.standardError.write(Data("check_openfish_public_assets_ocr: public screenshot OCR privacy checks failed\n".utf8))
    exit(1)
}

print("Public screenshot OCR checks passed (\(inputs.count) assets)")
