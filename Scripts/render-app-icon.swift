// Regenerate the neutral app icon: xcrun swift Scripts/render-app-icon.swift "$PWD"
import AppKit
import CoreText
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fontURL = root.appendingPathComponent("Sources/Fonts/BricolageGrotesque.ttf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as! [CTFontDescriptor]
let name = CTFontDescriptorCopyAttribute(descriptors[0], kCTFontNameAttribute) as! String
let descriptor = CTFontDescriptorCreateWithAttributes([
  kCTFontNameAttribute: name,
  kCTFontVariationAttribute: [NSNumber(value: 0x77676874):700,NSNumber(value:0x77647468):100,NSNumber(value:0x6f70737a):96]
] as CFDictionary)
let font = CTFontCreateWithFontDescriptor(descriptor, 480, nil)
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
    let shape=NSBezierPath(roundedRect:NSRect(x:48,y:48,width:928,height:928),xRadius:205,yRadius:205)
    NSColor(calibratedWhite:0.98,alpha:1).setFill();shape.fill()
    NSColor(calibratedWhite:0.88,alpha:1).setStroke();shape.lineWidth=2;shape.stroke()
    let title=NSAttributedString(string:"bn.",attributes:[.font:font,.foregroundColor:NSColor(calibratedWhite:0.14,alpha:1),.kern:-25])
    let bounds=title.size()
    title.draw(at:NSPoint(x:(1024-bounds.width)/2+8,y:(1024-bounds.height)/2+12))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:catalog.appendingPathComponent(filename))
}
