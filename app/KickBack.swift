// KickBack — interface do kb (Contents/Resources/kb + runtime).
// Compilar: ver package.sh (swiftc, sem projeto Xcode).
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Backend: String, CaseIterable, Identifiable {
    case auto, d3dmetal, dxmt, dxvk, wined3d
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automático"
        case .d3dmetal: return "D3DMetal (D3D11/12, Apple)"
        case .dxmt: return "DXMT (D3D11 → Metal)"
        case .dxvk: return "DXVK (D3D9–11 → Vulkan)"
        case .wined3d: return "WineD3D (OpenGL)"
        }
    }
}

struct Program: Identifiable, Hashable {
    let id: URL                 // atalho .lnk, ou o appmanifest de um jogo da Steam
    var title: String? = nil
    var steamApp: String? = nil // abre com Steam.exe -applaunch <appid>
    var size: Int64? = nil
    var cover: URL? = nil       // capa vertical (Steam)
    var name: String { title ?? id.deletingPathExtension().lastPathComponent }
}

/// Programas de um drive_c: atalhos .lnk do Menu Iniciar e jogos instalados pela Steam (appmanifest_*.acf).
/// A Steam cria atalhos .url steam://, que não abrem sem ela; o appmanifest tem nome, tamanho e estado.
func installedPrograms(_ c: URL) -> [Program] {
    let fm = FileManager.default
    var roots = [c.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")]
    for u in (try? fm.contentsOfDirectory(atPath: c.appendingPathComponent("users").path)) ?? [] {
        roots.append(c.appendingPathComponent("users/\(u)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
    }
    var found: [Program] = []
    for r in roots {
        let e = fm.enumerator(at: r, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            let n = u.lastPathComponent.lowercased()
            if u.pathExtension.lowercased() == "lnk", !n.contains("uninstall"), !n.contains("desinstal") {
                found.append(Program(id: u))
            }
        }
    }
    // bibliotecas da Steam: a padrão e as do libraryfolders.vdf que ficam no C:
    let steamapps = c.appendingPathComponent("Program Files (x86)/Steam/steamapps")
    var libs = [steamapps]
    let vdf = (try? String(contentsOf: steamapps.appendingPathComponent("libraryfolders.vdf"), encoding: .utf8)) ?? ""
    for line in vdf.components(separatedBy: "\n") {
        let f = line.components(separatedBy: "\"")
        guard f.count >= 4, f[1] == "path", f[3].lowercased().hasPrefix("c:\\\\") else { continue }
        let rel = f[3].dropFirst(4).replacingOccurrences(of: "\\\\", with: "/")
        let l = c.appendingPathComponent(rel).appendingPathComponent("steamapps")
        if !libs.contains(where: { $0.standardizedFileURL.path.lowercased() == l.standardizedFileURL.path.lowercased() }) { libs.append(l) }
    }
    for l in libs {
        for f in (try? fm.contentsOfDirectory(atPath: l.path)) ?? [] where f.hasPrefix("appmanifest_") && f.hasSuffix(".acf") {
            let u = l.appendingPathComponent(f)
            var kv: [String: String] = [:]
            for line in ((try? String(contentsOf: u, encoding: .utf8)) ?? "").components(separatedBy: "\n") {
                let q = line.components(separatedBy: "\"")
                if q.count >= 4, kv[q[1]] == nil { kv[q[1]] = q[3] }
            }
            // StateFlags 4 = totalmente instalado; o 228980 são os redistribuíveis que a Steam instala sozinha
            guard let id = kv["appid"], let name = kv["name"], id != "228980",
                  let st = Int(kv["StateFlags"] ?? ""), st & 4 != 0 else { continue }
            found.append(Program(id: u, title: name, steamApp: id, size: Int64(kv["SizeOnDisk"] ?? ""),
                                 cover: steamCover(l, appid: id)))
        }
    }
    // o mesmo atalho costuma existir no menu de todos os usuários e no do usuário
    var seen = Set<String>()
    return found.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        .filter { seen.insert($0.name.lowercased()).inserted }
}

@MainActor
final class Model: ObservableObject {
    @Published var bottles: [String] = []
    @Published var selected: String? { didSet { loadBottle() } }
    @Published var backend: Backend = .auto
    @Published var msync = false
    @Published var programs: [Program] = []
    @Published var status = ""
    @Published var busy = false
    @Published var showImport = false

    let fm = FileManager.default
    let res = Bundle.main.resourceURL!
    // mesmo padrão do kb (que herda o ambiente)
    let home = ProcessInfo.processInfo.environment["KB_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KickBack")
    var bottlesDir: URL { home.appendingPathComponent("bottles") }
    var logURL: URL { home.appendingPathComponent("kickback.log") }
    func dir(_ b: String) -> URL { bottlesDir.appendingPathComponent(b) }
    func envFile(_ b: String) -> URL { dir(b).appendingPathComponent("bottle.env") }

    var hasGPTK: Bool {
        fm.fileExists(atPath: home.appendingPathComponent("apple_gptk/external/D3DMetal.framework").path)
            || fm.fileExists(atPath: res.appendingPathComponent("runtime/lib64/apple_gptk/external/D3DMetal.framework").path)
    }

    init() {
        try? fm.createDirectory(at: bottlesDir, withIntermediateDirectories: true)
        // o .dmg baixado marca tudo com quarentena; os binários do runtime são executados por nós
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", res.appendingPathComponent("runtime").path]
        try? x.run()
        refresh()
    }

    func refresh() {
        bottles = ((try? fm.contentsOfDirectory(atPath: bottlesDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && fm.fileExists(atPath: envFile($0).path) }
            .sorted()
        if selected == nil || !bottles.contains(selected!) { selected = bottles.first } else { loadBottle() }
    }

    // MARK: kb

    /// Roda o kb com saída anexada ao log e devolve o código de saída.
    @discardableResult
    func kb(_ args: [String]) async -> Int32 {
        if let size = try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 20_000_000 {
            try? fm.removeItem(at: logURL)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()
        log?.write("\n=== \(Date()) kb \(args.joined(separator: " "))\n".data(using: .utf8)!)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [res.appendingPathComponent("kb").path] + args
        p.standardOutput = log
        p.standardError = log
        return await withCheckedContinuation { c in
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { c.resume(returning: -1) }
        }
    }

    func work(_ msg: String, _ body: @escaping () async -> Void) {
        busy = true
        status = msg
        Task {
            await body()
            busy = false
        }
    }

    // MARK: garrafas

    func create(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.hasPrefix("."), !n.contains("/") else { status = "Nome inválido."; return }
        work("Criando a garrafa “\(n)”… (leva cerca de 1 minuto)") {
            let rc = await self.kb(["create", n])
            self.status = rc == 0 ? "Garrafa “\(n)” pronta. Arraste um instalador ou jogo para começar."
                                  : "Falha ao criar a garrafa (veja o log)."
            self.refresh()
            if rc == 0 { self.selected = n }
        }
    }

    // garrafas do CrossOver (mesmo padrão do kb import-crossover)
    var crossoverDir: URL {
        ProcessInfo.processInfo.environment["KB_CROSSOVER_BOTTLES"].map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
    }
    var crossoverBottles: [String] {
        ((try? fm.contentsOfDirectory(atPath: crossoverDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") && fm.fileExists(atPath: crossoverDir.appendingPathComponent("\($0)/drive_c").path) }
            .sorted()
    }

    func importCrossOver(_ cx: String) {
        var n = cx
        if fm.fileExists(atPath: dir(n).path) { n = "\(cx) (CrossOver)" }
        var i = 2
        while fm.fileExists(atPath: dir(n).path) { n = "\(cx) (CrossOver \(i))"; i += 1 }
        work("Importando “\(cx)” do CrossOver… (é uma cópia por clonagem: rápida e sem ocupar espaço extra)") {
            let rc = await self.kb(["import-crossover", cx, n])
            self.status = rc == 0 ? "Garrafa “\(n)” importada do CrossOver. A do CrossOver continua intacta."
                                  : "Falha ao importar “\(cx)” (está aberta no CrossOver? veja o log)."
            self.refresh()
            if rc == 0 { self.selected = n }
        }
    }

    func delete(_ b: String) {
        let a = NSAlert()
        a.messageText = "Mover a garrafa “\(b)” para a Lixeira?"
        a.informativeText = "Todos os programas e jogos instalados nela vão junto. Dá para recuperar pela Lixeira."
        a.addButton(withTitle: "Mover para a Lixeira")
        a.addButton(withTitle: "Cancelar")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        work("Encerrando “\(b)”…") {
            await self.kb(["kill", b])
            NSWorkspace.shared.recycle([self.dir(b)]) { _, err in
                Task { @MainActor in
                    self.status = err == nil ? "Garrafa movida para a Lixeira." : "Não foi possível excluir: \(err!.localizedDescription)"
                    self.refresh()
                }
            }
        }
    }

    // MARK: bottle.env

    func envLines(_ b: String) -> [String] {
        ((try? String(contentsOf: envFile(b), encoding: .utf8)) ?? "").components(separatedBy: "\n")
    }

    func setEnv(_ key: String, _ value: String?) {
        guard let b = selected else { return }
        var lines = envLines(b).filter { !$0.hasPrefix("\(key)=") && !$0.hasPrefix("#\(key)=") && !$0.isEmpty }
        if let value { lines.append("\(key)=\(value)") }
        try? (lines.joined(separator: "\n") + "\n").write(to: envFile(b), atomically: true, encoding: .utf8)
    }

    func loadBottle() {
        guard let b = selected else { programs = []; return }
        let env = envLines(b)
        let v = env.last { $0.hasPrefix("BACKEND=") }?.dropFirst(8) ?? "auto"
        backend = Backend(rawValue: String(v)) ?? .auto
        msync = env.contains("WINEMSYNC=1")
        loadPrograms(b)
    }

    func saveBackend(_ v: Backend) {
        setEnv("BACKEND", v.rawValue)
        status = "Gráficos: \(v.label). Vale para os próximos programas abertos."
    }

    func saveMsync(_ on: Bool) {
        setEnv("WINEMSYNC", on ? "1" : nil)
        guard let b = selected else { return }
        work("Reiniciando a garrafa para aplicar o MSync…") {
            await self.kb(["kill", b])
            self.status = on ? "MSync ligado (menos uso de CPU em jogos; alguns apps não gostam)." : "MSync desligado."
        }
    }

    func loadPrograms(_ b: String) {
        programs = installedPrograms(dir(b).appendingPathComponent("prefix/drive_c"))
    }

    // MARK: executar

    func open(_ url: URL) {
        if url.pathExtension.lowercased() == "app" {
            if !openCrossOverLauncher(url) { status = "Isso é um app do Mac, não um programa do Windows." }
            return
        }
        Task {
            if selected == nil {
                await kb(["create", "Padrão"])
                refresh()
                selected = "Padrão"
            }
            guard let b = selected else { return }
            let path = url.path
            let args: [String]
            switch url.pathExtension.lowercased() {
            case "msi": args = ["run", b, "msiexec", "/i", path]
            case "lnk": args = ["run", b, "start", "/unix", path]
            case "bat", "cmd": args = ["run", b, "cmd", "/c", path]
            default: args = ["run", b, path]
            }
            status = "Abrindo \(url.deletingPathExtension().lastPathComponent) em “\(b)”…"
            let rc = await kb(args)
            status = rc == 0 ? "\(url.deletingPathExtension().lastPathComponent) foi fechado."
                             : "\(url.deletingPathExtension().lastPathComponent) terminou com erro \(rc) (veja o log)."
            if selected == b { loadPrograms(b) }
        }
    }

    func open(_ p: Program) {
        guard let b = selected else { open(p.id); return }
        // o atalho “Steam” do Menu Iniciar abre pelo Steam.exe, que o kb lança com as opções certas
        if p.steamApp == nil, p.name.lowercased() == "steam", hasSteam(b) { open(steamExe(b)); return }
        guard let app = p.steamApp else { open(p.id); return }
        launchSteamGame(app, name: p.name, in: b)
    }

    func launchSteamGame(_ app: String, name: String, in b: String) {
        status = "Abrindo \(name) pela Steam em “\(b)”… Se a Steam pedir, entre na sua conta."
        Task {
            let rc = await kb(["run", b, steamExe(b).path, "-applaunch", app])
            status = rc == 0 ? "\(name): pedido enviado à Steam." : "A Steam terminou com erro \(rc) (veja o log)."
        }
    }

    /// Atalho .app que o CrossOver cria em ~/Applications/CrossOver: abre o mesmo jogo da Steam numa garrafa importada.
    func openCrossOverLauncher(_ url: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let cxBottle = info["CXHelperAppBottleName"] as? String else { return false }
        let name = info["CXOriginalMenuName"] as? String ?? url.deletingPathExtension().lastPathComponent
        let cmd = (info["CrossOverHelperCommand"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let text = (try? String(contentsOfFile: cmd, encoding: .utf8)) ?? ""
        guard let r = text.range(of: #"rungameid/(\d+)"#, options: .regularExpression) else {
            status = "“\(name)” é um atalho do CrossOver. Importe a garrafa “\(cxBottle)” e abra o programa pela biblioteca."
            return true
        }
        let app = String(text[r].dropFirst("rungameid/".count))
        // garrafa importada daquela do CrossOver (mesmo nome ou “nome (CrossOver)”) que tenha a Steam
        let candidates = bottles.filter { ($0 == cxBottle || $0.hasPrefix("\(cxBottle) (CrossOver")) && hasSteam($0) }
        guard let b = candidates.first else {
            status = "“\(name)” está na garrafa “\(cxBottle)” do CrossOver. Importe essa garrafa primeiro (Arquivo → Importar do CrossOver…)."
            showImport = true
            return true
        }
        selected = b
        launchSteamGame(app, name: name, in: b)
        return true
    }

    func runBuiltin(_ exe: String) {
        guard let b = selected else { return }
        Task { await kb(["run", b, exe]) }
    }

    func killAll() {
        guard let b = selected else { return }
        work("Encerrando os programas de “\(b)”…") {
            await self.kb(["kill", b])
            self.status = "Programas de “\(b)” encerrados."
        }
    }

    func chooseFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.message = "Escolha um instalador ou jogo do Windows (.exe, .msi)"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    // MARK: Steam

    func steamExe(_ b: String) -> URL {
        dir(b).appendingPathComponent("prefix/drive_c/Program Files (x86)/Steam/Steam.exe")
    }

    func hasSteam(_ b: String) -> Bool { fm.fileExists(atPath: steamExe(b).path) }

    /// Baixa o instalador oficial e instala na garrafa selecionada (ou cria a garrafa “Steam”), depois abre.
    func installSteam() {
        let b = selected ?? "Steam"
        if hasSteam(b) { open(steamExe(b)); return }
        work("Baixando e instalando a Steam em “\(b)”… (alguns minutos)") {
            if !self.bottles.contains(b) {
                self.status = "Criando a garrafa “\(b)”… (leva cerca de 1 minuto)"
                guard await self.kb(["create", b]) == 0 else {
                    self.status = "Falha ao criar a garrafa (veja o log)."; return
                }
                self.refresh()
                self.selected = b
                self.status = "Baixando e instalando a Steam em “\(b)”… (alguns minutos)"
            }
            let rc = await self.kb(["install-steam", b])
            self.loadBottle()
            guard rc == 0 else { self.status = "Falha ao instalar a Steam (veja o log)."; return }
            self.status = "Steam instalada. Abrindo…"
            self.open(self.steamExe(b))
        }
    }

    func importGPTK() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "Selecione o volume montado do Game Porting Toolkit da Apple (developer.apple.com/games)"
        p.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard p.runModal() == .OK, let u = p.url else { return }
        work("Importando o D3DMetal…") {
            let rc = await self.kb(["import-gptk", u.path])
            self.status = rc == 0 ? "D3DMetal importado. Jogos D3D12 já podem usar."
                                  : "Não encontrei o D3DMetal nessa pasta (veja o log)."
            self.objectWillChange.send()
        }
    }
}

// MARK: - Interface

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        NavigationSplitView {
            List(m.bottles, id: \.self, selection: $m.selected) { b in
                Label(b, systemImage: "shippingbox.fill")
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
            .toolbar {
                Button { newName = ""; showNew = true } label: { Label("Nova garrafa", systemImage: "plus") }
                    .help("Nova garrafa")
            }
            .safeAreaInset(edge: .bottom) {
                if !m.crossoverBottles.isEmpty {
                    Button { m.showImport = true } label: { Label("Importar do CrossOver…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.borderless).padding(10).disabled(m.busy)
                }
            }
        } detail: {
            if let b = m.selected {
                BottleView(bottle: b)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 52)).foregroundStyle(.secondary)
                    Text("Bem-vindo ao KickBack").font(.title.bold())
                    Text("Jogos e programas do Windows no seu Mac.").foregroundStyle(.secondary)
                    Button { m.installSteam() } label: { Label("Instalar a Steam", systemImage: "arrow.down.circle.fill") }
                        .controlSize(.large).buttonStyle(.borderedProminent).disabled(m.busy)
                        .help("Cria a garrafa “Steam”, baixa o instalador oficial da Valve e instala")
                    HStack(spacing: 16) {
                        Button("Criar garrafa vazia") { m.create("Padrão") }
                        if !m.crossoverBottles.isEmpty {
                            Button("Importar do CrossOver…") { m.showImport = true }
                        }
                    }
                    .buttonStyle(.link).disabled(m.busy)
                }
                .padding(40)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !m.status.isEmpty {
                HStack(spacing: 8) {
                    if m.busy { ProgressView().controlSize(.small) }
                    Text(m.status).lineLimit(2).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.bar)
            }
        }
        .sheet(isPresented: $showNew) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nova garrafa").font(.headline)
                TextField("Nome (ex.: Steam, Jogos antigos)", text: $newName).frame(width: 300)
                    .onSubmit { showNew = false; m.create(newName) }
                HStack {
                    Spacer()
                    Button("Cancelar") { showNew = false }.keyboardShortcut(.cancelAction)
                    Button("Criar") { showNew = false; m.create(newName) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $m.showImport) { ImportCrossOverView() }
    }
}

struct ImportCrossOverView: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importar do CrossOver").font(.headline)
            Text("A garrafa é clonada para o KickBack com os jogos instalados. A do CrossOver não é alterada, e a cópia não ocupa espaço extra no disco.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let list = m.crossoverBottles
            if list.isEmpty {
                Text("Nenhuma garrafa encontrada em \(m.crossoverDir.path).").foregroundStyle(.secondary)
            } else {
                ForEach(list, id: \.self) { b in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(b, systemImage: "shippingbox").font(.headline)
                            Spacer()
                            Button("Importar") { dismiss(); m.importCrossOver(b) }
                        }
                        let ps = installedPrograms(m.crossoverDir.appendingPathComponent("\(b)/drive_c"))
                        if ps.isEmpty {
                            Text("Nenhum programa encontrado no Menu Iniciar.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(ps) { p in
                            HStack {
                                Image(systemName: p.steamApp == nil ? "app" : "gamecontroller").foregroundStyle(.secondary)
                                Text(p.name)
                                Spacer()
                                if let n = p.size, n > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)).foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
            }
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .disabled(m.busy)
    }
}

struct BottleView: View {
    @EnvironmentObject var m: Model
    let bottle: String
    @State private var dropping = false
    @State private var showSettings = false

    var driveC: URL { m.dir(bottle).appendingPathComponent("prefix/drive_c") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bottle).font(.largeTitle.bold())
                    Text(m.programs.isEmpty ? "Nenhum programa instalado"
                         : m.programs.count == 1 ? "1 programa" : "\(m.programs.count) programas")
                        .foregroundStyle(.secondary)
                }

                if m.programs.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 160), spacing: 20, alignment: .top)],
                              alignment: .leading, spacing: 26) {
                        ForEach(m.programs) { p in ProgramTile(program: p, driveC: driveC) }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // soltar um instalador/jogo em qualquer lugar da tela
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.08)))
                    .overlay(Label("Solte para abrir em “\(bottle)”", systemImage: "arrow.down.app.fill")
                        .font(.title3.weight(.semibold)).padding(14).background(.regularMaterial, in: Capsule()))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { items in
            for item in items {
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in m.open(url) } }
                }
            }
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if m.hasSteam(bottle) {
                    Button { m.open(m.steamExe(bottle)) } label: { Label("Abrir Steam", systemImage: "gamecontroller") }
                        .help("Abrir a Steam")
                } else {
                    Button { m.installSteam() } label: { Label("Instalar Steam", systemImage: "arrow.down.circle") }
                        .help("Baixar o instalador oficial da Valve e instalar nesta garrafa")
                }
                Button { m.chooseFile() } label: { Label("Instalar programa", systemImage: "plus.app") }
                    .help("Abrir um instalador ou jogo do Windows (.exe, .msi)")
                Button { showSettings = true } label: { Label("Ajustes", systemImage: "slider.horizontal.3") }
                    .help("Gráficos e desempenho desta garrafa")
                Menu {
                    Button { NSWorkspace.shared.open(driveC) } label: { Label("Abrir disco C: no Finder", systemImage: "internaldrive") }
                    Button { m.runBuiltin("winecfg") } label: { Label("Configurações do Wine", systemImage: "gearshape") }
                    Button { NSWorkspace.shared.open(m.logURL) } label: { Label("Ver log", systemImage: "doc.text") }
                    Divider()
                    Button { m.killAll() } label: { Label("Encerrar programas", systemImage: "stop.circle") }
                    Button(role: .destructive) { m.delete(bottle) } label: { Label("Excluir garrafa…", systemImage: "trash") }
                } label: { Label("Mais", systemImage: "ellipsis.circle") }
                .help("Mais opções")
            }
        }
        .sheet(isPresented: $showSettings) { BottleSettings(bottle: bottle) }
        .disabled(m.busy)
        .onAppear { m.loadBottle() }
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.app").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("Arraste um instalador ou jogo do Windows para cá").font(.headline)
            HStack(spacing: 10) {
                Button("Escolher arquivo…") { m.chooseFile() }
                if !m.hasSteam(bottle) {
                    Button { m.installSteam() } label: { Label("Instalar Steam", systemImage: "arrow.down.circle.fill") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6])))
    }
}

/// Um programa na biblioteca: capa da Steam ou o ícone do .exe, nome embaixo.
struct ProgramTile: View {
    @EnvironmentObject var m: Model
    let program: Program
    let driveC: URL
    @State private var icon: NSImage?
    @State private var cover: NSImage?
    @State private var hover = false

    var body: some View {
        Button { m.open(program) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if let cover {
                        Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.06)],
                                       startPoint: .top, endPoint: .bottom)
                        Group {
                            if let icon {
                                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit)
                                    .fontWeight(.ultraLight).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 76, height: 76)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    }
                    if hover {
                        Color.black.opacity(0.35)
                        Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(.white)
                    }
                }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(hover ? 0.35 : 0.15), radius: hover ? 12 : 5, y: hover ? 6 : 2)
                .scaleEffect(hover ? 1.03 : 1)

                Text(program.name).font(.callout.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help(program.size.map { "\(program.name) — \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? program.name)
        .contextMenu {
            Button("Abrir") { m.open(program) }
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([program.id]) }
        }
        .task(id: program.id) {
            let p = program, c = driveC
            let (ic, cv) = await Task.detached(priority: .utility) { () -> (NSImage?, NSImage?) in
                if let u = p.cover, let img = NSImage(contentsOf: u) { return (nil, img) }
                // jogo da Steam sem capa: tenta o ícone do .exe na pasta do jogo
                if p.steamApp != nil { return (nil, nil) }
                return (IconCache.icon(for: p.id, driveC: c), nil)
            }.value
            icon = ic; cover = cv
        }
    }
}

struct BottleSettings: View {
    @EnvironmentObject var m: Model
    @Environment(\.dismiss) private var dismiss
    let bottle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ajustes de “\(bottle)”").font(.headline)
            Form {
                Picker("Tradução DirectX", selection: Binding(get: { m.backend }, set: { m.backend = $0; m.saveBackend($0) })) {
                    ForEach(Backend.allCases) { b in Text(b.label).tag(b) }
                }
                Toggle("MSync (menos uso de CPU)", isOn: Binding(get: { m.msync }, set: { m.msync = $0; m.saveMsync($0) }))
            }
            if !m.hasGPTK {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Jogos DirectX 12 precisam do D3DMetal, que vem no Game Porting Toolkit da Apple.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Importar…") { m.importGPTK() }
                }
            }
            HStack { Spacer(); Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 440)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: Model?
    var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { urls.forEach(model.open) } else { pending += urls }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // teste: KICKBACK_SNAPSHOT=arquivo.png salva a janela e sai (não precisa de permissão de gravação de tela)
        if let out = ProcessInfo.processInfo.environment["KICKBACK_SNAPSHOT"] {
            NSApp.activate(ignoringOtherApps: true)   // com o Stage Manager, janela inativa vira miniatura
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                // CGWindowListCreateImage some do SDK em Swift; para a própria janela ainda funciona
                typealias Grab = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                let w = NSApp.windows.first { $0.isVisible && $0.frame.width > 300 }
                if let w, let sym = dlsym(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW), "CGWindowListCreateImage"),
                   let img = unsafeBitCast(sym, to: Grab.self)(.null, 1 << 3, UInt32(w.windowNumber), 1)?.takeRetainedValue() {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                NSApp.terminate(nil)
            }
            return
        }
        #if arch(arm64)
        if !FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta") {
            let a = NSAlert()
            a.messageText = "O KickBack precisa do Rosetta 2"
            a.informativeText = "Os jogos do Windows rodam em x86_64. Instale o Rosetta abrindo o Terminal e rodando:\n\nsoftwareupdate --install-rosetta --agree-to-license"
            a.addButton(withTitle: "Copiar comando")
            a.addButton(withTitle: "OK")
            if a.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("softwareupdate --install-rosetta --agree-to-license", forType: .string)
            }
        }
        #endif
    }
}

@main
struct KickBackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    delegate.model = model
                    delegate.pending.forEach(model.open)
                    delegate.pending = []
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Abrir programa do Windows…") { model.chooseFile() }.keyboardShortcut("o")
                Button("Importar D3DMetal (Game Porting Toolkit)…") { model.importGPTK() }
                Button("Importar do CrossOver…") { model.showImport = true }
                Button("Instalar Steam") { model.installSteam() }.disabled(model.busy)
            }
        }
    }
}
