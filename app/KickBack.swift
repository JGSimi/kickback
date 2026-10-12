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
    let id: URL
    var name: String { id.deletingPathExtension().lastPathComponent }
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

    let fm = FileManager.default
    let res = Bundle.main.resourceURL!
    let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/KickBack")
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

    // atalhos .lnk do Menu Iniciar criados pelos instaladores
    func loadPrograms(_ b: String) {
        let c = dir(b).appendingPathComponent("prefix/drive_c")
        var roots = [c.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")]
        for u in (try? fm.contentsOfDirectory(atPath: c.appendingPathComponent("users").path)) ?? [] {
            roots.append(c.appendingPathComponent("users/\(u)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
        }
        var found = Set<URL>()
        for r in roots {
            let e = fm.enumerator(at: r, includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL {
                let n = u.lastPathComponent.lowercased()
                if u.pathExtension.lowercased() == "lnk", !n.contains("uninstall"), !n.contains("desinstal") {
                    found.insert(u)
                }
            }
        }
        programs = found.map(Program.init).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: executar

    func open(_ url: URL) {
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
        } detail: {
            if let b = m.selected {
                BottleView(bottle: b)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 54)).foregroundStyle(.secondary)
                    Text("Bem-vindo ao KickBack").font(.title.bold())
                    Text("Uma garrafa é um “PC Windows” isolado onde seus jogos e programas são instalados.")
                        .foregroundStyle(.secondary)
                    Button("Criar minha primeira garrafa") { m.create("Padrão") }
                        .controlSize(.large).buttonStyle(.borderedProminent).disabled(m.busy)
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
    }
}

struct BottleView: View {
    @EnvironmentObject var m: Model
    let bottle: String
    @State private var dropping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(bottle).font(.largeTitle.bold())

                // área de soltar
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.app.fill").font(.system(size: 34))
                    Text("Arraste um instalador ou jogo do Windows aqui").font(.headline)
                    Text(".exe, .msi ou atalhos .lnk").font(.caption).foregroundStyle(.secondary)
                    Button("Escolher arquivo…") { m.chooseFile() }
                }
                .frame(maxWidth: .infinity).padding(28)
                .background(RoundedRectangle(cornerRadius: 14).fill(dropping ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.4)))
                .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { items in
                    for item in items {
                        _ = item.loadObject(ofClass: URL.self) { url, _ in
                            if let url { Task { @MainActor in m.open(url) } }
                        }
                    }
                    return true
                }

                if !m.programs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Programas instalados").font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                            ForEach(m.programs) { p in
                                Button { m.open(p.id) } label: {
                                    HStack {
                                        Image(systemName: "play.circle.fill").font(.title2)
                                        Text(p.name).lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Gráficos").font(.title3.bold())
                    Picker("Tradução DirectX", selection: Binding(get: { m.backend }, set: { m.backend = $0; m.saveBackend($0) })) {
                        ForEach(Backend.allCases) { b in
                            Text(b.label).tag(b)
                        }
                    }
                    .frame(maxWidth: 420)
                    Toggle("MSync (sincronização rápida, menos CPU)", isOn: Binding(get: { m.msync }, set: { m.msync = $0; m.saveMsync($0) }))
                    if !m.hasGPTK {
                        HStack {
                            Image(systemName: "info.circle")
                            Text("D3DMetal (jogos DirectX 12) precisa do Game Porting Toolkit da Apple, que não pode vir junto.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Importar…") { m.importGPTK() }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Garrafa").font(.title3.bold())
                    HStack(spacing: 10) {
                        Button { NSWorkspace.shared.open(m.dir(bottle).appendingPathComponent("prefix/drive_c")) } label: {
                            Label("Abrir disco C:", systemImage: "internaldrive")
                        }
                        Button { m.runBuiltin("winecfg") } label: { Label("Configurações do Wine", systemImage: "gearshape") }
                        Button { m.killAll() } label: { Label("Encerrar programas", systemImage: "stop.circle") }
                        Button { NSWorkspace.shared.open(m.logURL) } label: { Label("Ver log", systemImage: "doc.text") }
                    }
                    Button(role: .destructive) { m.delete(bottle) } label: { Label("Excluir garrafa…", systemImage: "trash") }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .disabled(m.busy)
        .onAppear { m.loadBottle() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: Model?
    var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { urls.forEach(model.open) } else { pending += urls }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            }
        }
    }
}
