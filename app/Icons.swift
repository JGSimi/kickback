// Ícones e capas dos programas: capa da Steam (librarycache) ou o ícone de dentro do .exe (recurso RT_GROUP_ICON).
import AppKit

private extension Data {
    func u16(_ o: Int) -> Int { o >= 0 && o + 2 <= count ? Int(self[startIndex + o]) | Int(self[startIndex + o + 1]) << 8 : 0 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
}

/// Converte "C:\Program Files\X.exe" num caminho dentro do drive_c (só o C:, o resto não aponta para a garrafa).
func windowsPath(_ p: String, driveC: URL) -> URL? {
    var s = p.trimmingCharacters(in: CharacterSet(charactersIn: "\" \0"))
    guard s.count > 3, s.lowercased().hasPrefix("c:\\"), !s.contains("%") else { return nil }
    s = String(s.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")
    return driveC.appendingPathComponent(s)
}

/// Lê um atalho .lnk (MS-SHLLINK) e devolve o arquivo de onde tirar o ícone: IconLocation ou o alvo.
func lnkIconSource(_ lnk: URL, driveC: URL) -> URL? {
    guard let d = try? Data(contentsOf: lnk), d.count > 0x4C, d.u32(0) == 0x4C else { return nil }
    let flags = d.u32(0x14)
    var o = 0x4C
    if flags & 0x01 != 0 { o += 2 + d.u16(o) }                 // LinkTargetIDList
    var target: String?
    if flags & 0x02 != 0 {                                      // LinkInfo
        let base = o, size = d.u32(o), local = d.u32(o + 16)
        if local > 0, base + local < d.count {
            let bytes = d[(d.startIndex + base + local)...].prefix { $0 != 0 }
            target = String(decoding: bytes, as: UTF8.self)
        }
        o += size
    }
    let unicode = flags & 0x80 != 0
    func str() -> String {
        let n = d.u16(o); o += 2
        let len = unicode ? n * 2 : n
        guard o + len <= d.count else { o = d.count; return "" }
        let sub = d.subdata(in: (d.startIndex + o)..<(d.startIndex + o + len)); o += len
        return (unicode ? String(data: sub, encoding: .utf16LittleEndian) : String(data: sub, encoding: .windowsCP1252)) ?? ""
    }
    var icon: String?
    for (bit, keep) in [(0x04, false), (0x08, false), (0x10, false), (0x20, false), (0x40, true)] where flags & bit != 0 {
        let s = str(); if keep { icon = s }
    }
    let fm = FileManager.default
    for c in [icon, target].compactMap({ $0 }) {
        if let u = windowsPath(c, driveC: driveC), fm.fileExists(atPath: u.path) { return u }
    }
    return nil
}

/// Maior ícone do primeiro grupo de ícones de um .exe/.dll do Windows.
func peIcon(_ url: URL) -> NSImage? {
    if url.pathExtension.lowercased() == "ico" { return NSImage(contentsOf: url) }
    guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.u16(0) == 0x5A4D else { return nil }
    let pe = d.u32(0x3C)
    guard d.u32(pe) == 0x4550 else { return nil }
    let nsec = d.u16(pe + 6), optSize = d.u16(pe + 20), opt = pe + 24
    let dirs = opt + (d.u16(opt) == 0x20B ? 112 : 96)
    let resRVA = d.u32(dirs + 2 * 8)
    guard resRVA != 0 else { return nil }
    let secs = (0..<nsec).map { opt + optSize + $0 * 40 }
    func off(_ rva: Int) -> Int? {
        for s in secs {
            let va = d.u32(s + 12), sz = max(d.u32(s + 8), d.u32(s + 16))
            if rva >= va && rva < va + sz { return rva - va + d.u32(s + 20) }
        }
        return nil
    }
    guard let res = off(resRVA) else { return nil }
    // entradas de um diretório de recursos: (id, offset relativo, é subdiretório)
    func entries(_ dir: Int) -> [(id: Int, off: Int, sub: Bool)] {
        let n = d.u16(dir + 12) + d.u16(dir + 14)
        return (0..<min(n, 4096)).map { i in
            let e = dir + 16 + i * 8, v = d.u32(e + 4)
            return (d.u32(e), v & 0x7FFF_FFFF, v & 0x8000_0000 != 0)
        }
    }
    // tipo -> nome/id -> idioma -> dados
    func leaf(_ entry: (id: Int, off: Int, sub: Bool)) -> Data? {
        var e = entry
        while e.sub { guard let f = entries(res + e.off).first else { return nil }; e = f }
        let rva = d.u32(res + e.off), size = d.u32(res + e.off + 4)
        guard let o = off(rva), size > 0, o + size <= d.count else { return nil }
        return d.subdata(in: (d.startIndex + o)..<(d.startIndex + o + size))
    }
    let types = entries(res)
    guard let group = types.first(where: { $0.id == 14 }), group.sub,
          let firstGroup = entries(res + group.off).first, let grp = leaf(firstGroup),
          let icons = types.first(where: { $0.id == 3 }), icons.sub else { return nil }
    let iconEntries = entries(res + icons.off)
    // GRPICONDIR: 6 bytes + entradas de 14 bytes; escolhe a maior (largura 0 = 256)
    var best: (w: Int, bits: Int, id: Int, hdr: Data)?
    for i in 0..<min(grp.u16(4), 64) {
        let e = 6 + i * 14
        guard e + 14 <= grp.count else { break }
        let w = grp[grp.startIndex + e] == 0 ? 256 : Int(grp[grp.startIndex + e]), bits = grp.u16(e + 6)
        if best == nil || (w, bits) > (best!.w, best!.bits) {
            best = (w, bits, grp.u16(e + 12), grp.subdata(in: (grp.startIndex + e)..<(grp.startIndex + e + 12)))
        }
    }
    guard let b = best, let ie = iconEntries.first(where: { $0.id == b.id }), let img = leaf(ie) else { return nil }
    if img.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return NSImage(data: img) }
    // monta um .ico de uma imagem só para o NSImage ler o bitmap
    var ico = Data([0, 0, 1, 0, 1, 0])
    ico.append(b.hdr.prefix(8))
    var size = UInt32(img.count), offset = UInt32(22)
    ico.append(Data(bytes: &size, count: 4)); ico.append(Data(bytes: &offset, count: 4))
    ico.append(img)
    return NSImage(data: ico)
}

/// Capa vertical do jogo que a Steam já baixou (appcache/librarycache/<appid>/…).
func steamCover(_ steamapps: URL, appid: String) -> URL? {
    let cache = steamapps.deletingLastPathComponent().appendingPathComponent("appcache/librarycache/\(appid)")
    var found: [String: URL] = [:]
    let e = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)
    while let u = e?.nextObject() as? URL { found[u.lastPathComponent] = found[u.lastPathComponent] ?? u }
    // antigo: librarycache/<appid>_library_600x900.jpg
    let old = steamapps.deletingLastPathComponent().appendingPathComponent("appcache/librarycache/\(appid)_library_600x900.jpg")
    return found["library_600x900.jpg"] ?? found["library_capsule.jpg"]
        ?? (FileManager.default.fileExists(atPath: old.path) ? old : nil)
}

/// Ícone de um programa, com cache em memória (ler um .exe grande custa).
enum IconCache {
    nonisolated(unsafe) private static let cache = NSCache<NSURL, NSImage>()
    static func icon(for program: URL, driveC: URL) -> NSImage? {
        if let i = cache.object(forKey: program as NSURL) { return i }
        let src = program.pathExtension.lowercased() == "lnk" ? lnkIconSource(program, driveC: driveC) : program
        guard let s = src, let img = peIcon(s) else { return nil }
        cache.setObject(img, forKey: program as NSURL)
        return img
    }
}
