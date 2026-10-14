import AppKit
import CoreGraphics
import Foundation
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let space=CGColorSpaceCreateDeviceRGB()
func rgb(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ a:CGFloat=1)->CGColor { CGColor(red:r/255,green:g/255,blue:b/255,alpha:a) }
// Two wind strokes share one tangent at the apex. A broad crown and upright
// shoulders make the open span read as a bridge even at notification sizes.
let left=CGMutablePath();left.move(to:CGPoint(x:234,y:612));left.addLine(to:CGPoint(x:288,y:612));left.addCurve(to:CGPoint(x:512,y:412),control1:CGPoint(x:362,y:612),control2:CGPoint(x:332,y:412))
let right=CGMutablePath();right.move(to:CGPoint(x:512,y:412));right.addCurve(to:CGPoint(x:736,y:612),control1:CGPoint(x:692,y:412),control2:CGPoint(x:662,y:612));right.addLine(to:CGPoint(x:790,y:612))
for variant in ["Dark","Light","Tinted"] {
    let alpha:CGImageAlphaInfo = variant == "Tinted" ? .premultipliedLast : .noneSkipLast
    let context=CGContext(data:nil,width:1024,height:1024,bitsPerComponent:8,bytesPerRow:4096,space:space,bitmapInfo:alpha.rawValue)!
    context.translateBy(x:0,y:1024);context.scaleBy(x:1,y:-1)
    if variant != "Tinted" {
        let colors = variant == "Dark" ? [rgb(20,23,28),rgb(11,13,16)] : [rgb(249,250,251),rgb(239,242,245)]
        let gradient=CGGradient(colorsSpace:space,colors:colors as CFArray,locations:[0,1])!
        context.drawLinearGradient(gradient,start:CGPoint(x:512,y:0),end:CGPoint(x:512,y:1024),options:[])
    }
    let full=CGMutablePath();full.addPath(left);full.addPath(right)
    context.setLineWidth(64);context.setLineCap(.round);context.setLineJoin(.round)
    context.addPath(full);context.replacePathWithStrokedPath();context.clip()
    if variant == "Tinted" { context.setFillColor(rgb(255,255,255));context.fill(CGRect(x:0,y:0,width:1024,height:1024)) }
    else {
        // Subtle 8% upper highlight, base teal remains #2DB6C9.
        let gradient=CGGradient(colorsSpace:space,colors:[rgb(62,192,209),rgb(45,182,201)] as CFArray,locations:[0,1])!
        context.drawLinearGradient(gradient,start:CGPoint(x:512,y:380),end:CGPoint(x:512,y:500),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    }
    let data=NSBitmapImageRep(cgImage:context.makeImage()!).representation(using:.png,properties:[:])!
    try data.write(to:destination.appendingPathComponent("VayuSetu-\(variant)-1024.png"))
}
try Data(contentsOf:destination.appendingPathComponent("VayuSetu-Dark-1024.png")).write(to:destination.appendingPathComponent("VayuSetu-Master-1024.png"))
