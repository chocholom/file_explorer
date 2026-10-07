import AppKit

// Renders the app icon (two bright panes on a blue tile) into an .iconset folder.
// Usage: swift Scripts/make-icon.swift <output.iconset>

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixels)
    // Rounded tile with the standard macOS icon margin.
    let margin = s * 0.08
    let tile = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(
        starting: NSColor(calibratedRed: 0.27, green: 0.55, blue: 1.00, alpha: 1),
        ending: NSColor(calibratedRed: 0.09, green: 0.27, blue: 0.75, alpha: 1))!
        .draw(in: tilePath, angle: -90)

    // Two panes side by side.
    let paneTop = s * 0.24
    let paneBottom = s * 0.22
    let paneSide = s * 0.19
    let gap = s * 0.05
    let paneWidth = (s - 2 * paneSide - gap) / 2
    let paneHeight = s - paneTop - paneBottom
    for index in 0..<2 {
        let x = paneSide + CGFloat(index) * (paneWidth + gap)
        let pane = NSRect(x: x, y: paneBottom, width: paneWidth, height: paneHeight)
        NSColor.white.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: pane, xRadius: s * 0.035, yRadius: s * 0.035).fill()

        // File rows: a short "name" bar per row, the first one highlighted (the cursor).
        let rowHeight = paneHeight / 5.2
        let barHeight = rowHeight * 0.34
        for row in 0..<4 {
            let y = pane.maxY - rowHeight * CGFloat(row + 1) + (rowHeight - barHeight) / 2
            let widthFactor: CGFloat = [0.78, 0.55, 0.66, 0.48][row]
            let bar = NSRect(
                x: pane.minX + paneWidth * 0.12, y: y,
                width: paneWidth * widthFactor, height: barHeight)
            if index == 0, row == 0 {
                NSColor(calibratedRed: 0.27, green: 0.55, blue: 1.00, alpha: 1).setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: pane.minX + paneWidth * 0.06, y: y - (rowHeight - barHeight) / 2 + rowHeight * 0.08,
                        width: paneWidth * 0.88, height: rowHeight * 0.84),
                    xRadius: s * 0.02, yRadius: s * 0.02
                ).fill()
                NSColor.white.setFill()
            } else {
                NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.85, alpha: 0.45).setFill()
            }
            NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        }
    }
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let rep = render(pixels: base * scale)
        guard let png = rep.representation(using: .png, properties: [:]) else { continue }
        try png.write(to: outputDirectory.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
