// The icon, drawn (MANTRA_MANIFEST swift-apps.md 4): what the app does, a recording written down as a script.
// A dark tile; a red record dot at the top left; under it the script, four lines, each an amber command word and
// sand arguments (Click x, y · Sleep · Send "text"); the version at the bottom (version-visible.md).
// Writes icon_1024.png; build.sh makes the .icns from it.
import AppKit
let S: CGFloat = 1024
let version = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "1"
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 180, cornerHeight: 180, transform: nil))
ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.05, blue: 0.06, alpha: 1).cgColor); ctx.fillPath()
// the record dot: a ring and a red dot (CAMERA's record circle)
let c = CGPoint(x: 290, y: 740)
ctx.setStrokeColor(NSColor(srgbRed: 0.78, green: 0.8, blue: 0.82, alpha: 1).cgColor); ctx.setLineWidth(14)
ctx.strokeEllipse(in: CGRect(x: c.x - 82, y: c.y - 82, width: 164, height: 164))
ctx.setFillColor(NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: c.x - 56, y: c.y - 56, width: 112, height: 112))
// "REC" beside it, in the dot's red
("REC" as NSString).draw(at: NSPoint(x: 410, y: 690), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 110, weight: .bold),
                                                                       .foregroundColor: NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)])
// the script: a command word in amber, its arguments in sand
let amber = NSColor(srgbRed: 0.91, green: 0.64, blue: 0.24, alpha: 1), sand = NSColor(srgbRed: 0.95, green: 0.87, blue: 0.71, alpha: 0.55)
for (i, (cw, aw)) in [(150, 230), (150, 120), (130, 300), (150, 200)].enumerated() {
    let y = 540 - CGFloat(i) * 78
    ctx.addPath(CGPath(roundedRect: CGRect(x: 200, y: y, width: CGFloat(cw), height: 40), cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(amber.cgColor); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 200 + CGFloat(cw) + 26, y: y, width: CGFloat(aw), height: 40), cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(sand.cgColor); ctx.fillPath()
}
// the version, light on the dark ground
("v" + version as NSString).draw(at: NSPoint(x: 210, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 92, weight: .semibold),
                                                                                 .foregroundColor: NSColor(white: 0.78, alpha: 1)])
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("icon_1024.png v" + version)
