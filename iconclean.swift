// Limpa a logo: acha o quadrado arredondado, recorta com borda nítida e
// coloca no grid de ícone do macOS (824 px dentro de 1024, com sombra leve).
import AppKit
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
let W = src.pixelsWide, H = src.pixelsHigh
// limites do corpo: linhas/colunas com muitos pixels opacos
func opaque(_ x: Int, _ y: Int) -> Bool { (src.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.95 }
var minX = W, maxX = 0, minY = H, maxY = 0
for y in stride(from: 0, to: H, by: 2) {
    var c = 0; for x in stride(from: 0, to: W, by: 2) where opaque(x, y) { c += 1 }
    if c > W / 4 { minY = min(minY, y); maxY = max(maxY, y) }
}
for x in stride(from: 0, to: W, by: 2) {
    var c = 0; for y in stride(from: 0, to: H, by: 2) where opaque(x, y) { c += 1 }
    if c > H / 4 { minX = min(minX, x); maxX = max(maxX, x) }
}
let body = NSRect(x: minX, y: H - maxY, width: maxX - minX, height: maxY - minY)   // coordenadas de baixo p/ cima
print("corpo:", body)
let px = 1024
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
let dst = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: dst, xRadius: 232, yRadius: 232)
let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.28); sh.shadowOffset = NSSize(width: 0, height: -10); sh.shadowBlurRadius = 24
NSGraphicsContext.saveGraphicsState(); sh.set(); NSColor.white.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
path.addClip()
let img = NSImage(size: NSSize(width: W, height: H)); img.addRepresentation(src)
img.draw(in: dst, from: body, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
