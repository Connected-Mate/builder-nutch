// Resize the approved BN master; never redraw or replace the brand artwork.
// xcrun swift Scripts/render-app-icon.swift "$PWD"
import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let catalog = root.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset")
let masterName = "icon_512x512@2x.png"
let masterURL = catalog.appendingPathComponent(masterName)
let masterData = try Data(contentsOf: masterURL)
guard let master = NSImage(data: masterData),
      let bitmap = NSBitmapImageRep(data: masterData),
      bitmap.pixelsWide == 1024, bitmap.pixelsHigh == 1024 else {
    fatalError("The approved 1024 px BN master is missing or invalid.")
}
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog.appendingPathComponent("Contents.json"))) as! [String:Any]
for item in json["images"] as! [[String:String]] {
    guard let filename = item["filename"], let rawSize = item["size"]?.split(separator:"x").first,
          let scale = item["scale"]?.first, let multiplier = Int(String(scale)), let side = Int(rawSize) else { continue }
    let pixels = side * multiplier
    if filename == masterName { continue }
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:catalog.appendingPathComponent(filename))
}
let menu = root.appendingPathComponent("Sources/Assets.xcassets/MenuBarIcon.imageset")
for (source, destination) in [("icon_32x32.png", "menubar-bn.png"),
                              ("icon_32x32@2x.png", "menubar-bn@2x.png")] {
    try Data(contentsOf: catalog.appendingPathComponent(source))
        .write(to: menu.appendingPathComponent(destination), options: .atomic)
}
try masterData.write(to: root.appendingPathComponent("website/public/app-icon.png"), options: .atomic)
