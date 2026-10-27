// Draws the app icon (an orange basketball on a dark rounded square) into an .iconset folder.
// Usage: swift make-icon.swift <out.iconset>   (then `iconutil -c icns`)
import AppKit

func draw(_ s: CGFloat) -> Data {
  let img = NSImage(size: NSSize(width: s, height: s))
  img.lockFocus()
  let ctx = NSGraphicsContext.current!.cgContext
  // macOS icon grid: the artwork sits in ~80% of the canvas.
  let inset = s * 0.1, box = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
  let tile = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
  NSGradient(colors: [NSColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1), NSColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)])!
    .draw(in: tile, angle: -90)
  let r = box.width * 0.36, c = CGPoint(x: box.midX, y: box.midY)
  let ball = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
  NSGradient(colors: [NSColor(red: 1, green: 0.62, blue: 0.25, alpha: 1), NSColor(red: 0.85, green: 0.38, blue: 0.1, alpha: 1)])!
    .draw(in: NSBezierPath(ovalIn: ball), relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))
  // Seams, clipped to the ball.
  ctx.saveGState()
  NSBezierPath(ovalIn: ball).addClip()
  NSColor(red: 0.22, green: 0.1, blue: 0.04, alpha: 1).setStroke()
  let w = max(1, r * 0.06)
  func line(_ p: NSBezierPath) { p.lineWidth = w; p.stroke() }
  let h = NSBezierPath(); h.move(to: CGPoint(x: c.x - r, y: c.y)); h.line(to: CGPoint(x: c.x + r, y: c.y)); line(h)
  let v = NSBezierPath(); v.move(to: CGPoint(x: c.x, y: c.y - r)); v.line(to: CGPoint(x: c.x, y: c.y + r)); line(v)
  for sx in [-1.0, 1.0] {
    let p = NSBezierPath()
    p.appendArc(withCenter: CGPoint(x: c.x + sx * r * 1.45, y: c.y), radius: r * 1.05, startAngle: 0, endAngle: 360)
    line(p)
  }
  ctx.restoreGState()
  img.unlockFocus()
  let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
  return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  try draw(CGFloat(base)).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
  try draw(CGFloat(base * 2)).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
