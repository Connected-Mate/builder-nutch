// Regenerate Builder Nutch's geometric N at every native macOS icon size.
// xcrun swift Scripts/render-app-icon.swift "$PWD"
import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let catalog = root.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset")
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog.appendingPathComponent("Contents.json"))) as! [String:Any]
for item in json["images"] as! [[String:String]] {
    guard let filename = item["filename"], let rawSize = item["size"]?.split(separator:"x").first,
          let scale = item["scale"]?.first, let multiplier = Int(String(scale)), let side = Int(rawSize) else { continue }
    let pixels = side * multiplier
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
    let transform=NSAffineTransform();transform.scale(by:CGFloat(pixels)/1024);transform.concat()
    let tile=NSBezierPath(roundedRect:NSRect(x:48,y:48,width:928,height:928),xRadius:205,yRadius:205)
    NSColor(calibratedWhite:36.0/255,alpha:1).setFill();tile.fill()
    NSColor(calibratedWhite:1,alpha:0.12).setStroke();tile.lineWidth=4;tile.stroke()
    // A large, solid mark survives the 16 px menu/Dock sizes. No tiny lettering.
    let mark=NSBezierPath()
    mark.move(to:NSPoint(x:270,y:254))
    for p in [NSPoint(x:270,y:770),NSPoint(x:389,y:770),NSPoint(x:638,y:438),
              NSPoint(x:638,y:770),NSPoint(x:754,y:770),NSPoint(x:754,y:254),
              NSPoint(x:635,y:254),NSPoint(x:386,y:586),NSPoint(x:386,y:254)] { mark.line(to:p) }
    mark.close()
    NSColor.white.setFill();mark.fill()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:catalog.appendingPathComponent(filename))
    if pixels == 1024 { try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("website/public/app-icon.png")) }
}
