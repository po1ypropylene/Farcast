import AppKit

// Preserve the supplied SVG geometry and gradients; macOS supplies the app icon mask.
let source = URL(fileURLWithPath: "farcast-logo-v5.svg")
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let document = try XMLDocument(contentsOf: source)
guard let root = document.rootElement(),
    let definitions = root.elements(forName: "defs").first,
    let foreground = root.elements(forName: "g").first
else { fatalError("The supplied logo must contain SVG definitions and foreground artwork.") }
let background = root.elements(forName: "rect")
let parts = (foreground.children ?? []).compactMap { $0 as? XMLElement }
guard background.count == 2, parts.map(\.name) == ["rect", "rect", "rect", "rect", "rect", "g", "circle"] else {
    fatalError("The supplied logo structure changed; review its Icon Composer layers.")
}

func svg(elements: [XMLElement], viewBox: String = "0 0 1024 1024", height: Int = 1024) -> XMLDocument {
    let canvas = XMLElement(name: "svg")
    for (name, value) in [
        ("xmlns", "http://www.w3.org/2000/svg"), ("viewBox", viewBox),
        ("width", "1024"), ("height", String(height)),
    ] {
        canvas.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
    }
    canvas.addChild(definitions.copy() as! XMLNode)
    for element in elements { canvas.addChild(element.copy() as! XMLNode) }
    return XMLDocument(rootElement: canvas)
}

func group(_ elements: [XMLElement]) -> XMLElement {
    let result = XMLElement(name: "g")
    for attribute in foreground.attributes ?? [] { result.addAttribute(attribute.copy() as! XMLNode) }
    for element in elements { result.addChild(element.copy() as! XMLNode) }
    return result
}

func render(_ name: String, document: XMLDocument, height: Int = 1024) throws {
    let svgURL = destination.appendingPathComponent(name + ".svg")
    try document.xmlData.write(to: svgURL)
    defer { try? FileManager.default.removeItem(at: svgURL) }
    guard let artwork = NSImage(contentsOf: svgURL),
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
    else { fatalError("Unable to render supplied SVG artwork.") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    artwork.draw(in: NSRect(x: 0, y: 0, width: 1024, height: height))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode logo artwork.")
    }
    try png.write(to: destination.appendingPathComponent(name + ".png"))
}

// Unmasked background, separate monitor/stand/broadcast layers, editable native materials.
let unmaskedBackground = background.map { $0.copy() as! XMLElement }
for rectangle in unmaskedBackground { rectangle.removeAttribute(forName: "rx") }
try render("Background", document: svg(elements: unmaskedBackground))
try render("Stand", document: svg(elements: [group(Array(parts[0...1]))]))
try render("Monitor", document: svg(elements: [group(Array(parts[2...4]))]))
try render("Broadcast", document: svg(elements: [group(Array(parts[5...6]))]))

// A monochrome outline keeps the broadcast symbol legible in a tinted native sidebar.
let stand = parts[0...1].map { $0.copy() as! XMLElement }
for element in stand { element.removeAttribute(forName: "fill-opacity") }
let bezel = parts[2].copy() as! XMLElement
bezel.attribute(forName: "fill")?.stringValue = "none"
bezel.attribute(forName: "stroke-width")?.stringValue = "26"
bezel.removeAttribute(forName: "stroke-opacity")
let broadcast = parts[5].copy() as! XMLElement
for arcGroup in broadcast.elements(forName: "g") { arcGroup.removeAttribute(forName: "opacity") }
try render(
    "BrandMark",
    document: svg(
        elements: [group(stand + [bezel, broadcast, parts[6]])],
        viewBox: "164 200 696 620", height: 912
    ), height: 912)
try render("Farcast-preview", document: svg(elements: background + [foreground]))
