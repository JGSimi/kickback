// Gera o ícone do app (PNG 1024x1024): gradiente + controle de videogame.
// Uso: swift tools/make-icon.swift saida.png
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// formato padrão de ícone do macOS: quadrado arredondado com margem
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 1.0, green: 0.36, blue: 0.22, alpha: 1),
                    NSColor(red: 0.62, green: 0.12, blue: 0.55, alpha: 1)])!.draw(in: shape, angle: -60)

let cfg = NSImage.SymbolConfiguration(pointSize: 400, weight: .bold)
    .applying(.init(paletteColors: [.white]))
let sym = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let s = sym.size
sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 10, width: s.width, height: s.height))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
