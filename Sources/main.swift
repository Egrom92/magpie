// Magpie — история буфера обмена в строке меню.
// Щелчок по значку открывает боковую панель справа на всю высоту экрана: всё, что копировали
// (текст, картинки, файлы), по дням; фильтр сверху; кнопка копирования у каждой записи — после неё панель закрывается.
// История хранится 7 дней (~/Library/Application Support/Magpie), старое удаляется само.
// Пароли из менеджеров паролей (org.nspasteboard.ConcealedType и т. п.) не сохраняются.
import AppKit
import SwiftUI
import CryptoKit
import ImageIO
import ServiceManagement

// MARK: - Настройки

let keepDays = 7            // сколько дней хранить
let maxItems = 1000         // не больше стольких записей
let maxImageBytes = 40_000_000
let panelWidth: CGFloat = 380

let supportDir: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Magpie", isDirectory: true)
    try? FileManager.default.createDirectory(at: u.appendingPathComponent("images"), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
    return u
}()
let historyURL = supportDir.appendingPathComponent("history.json")
let imagesDir = supportDir.appendingPathComponent("images", isDirectory: true)

func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

// MARK: - Модель

enum ClipKind: String, Codable { case text, image, files }

struct Clip: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ClipKind
    var date: Date
    var hash: String
    var text: String? = nil
    var image: String? = nil        // имя PNG в imagesDir
    var width: Int? = nil
    var height: Int? = nil
    var paths: [String]? = nil
}

final class Store: ObservableObject {
    @Published private(set) var clips: [Clip] = []   // новые сверху

    init() {
        if let d = try? Data(contentsOf: historyURL), let c = try? JSONDecoder().decode([Clip].self, from: d) {
            clips = c.sorted { $0.date > $1.date }
        }
        prune()
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(clips) else { return }
        try? d.write(to: historyURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }

    private func removeFiles<S: Sequence>(_ items: S) where S.Element == Clip {
        for c in items { if let n = c.image { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(n)) } }
    }

    /// Новая запись. То же самое, скопированное повторно, не дублируется, а поднимается наверх.
    func add(_ clip: Clip, imageData: Data? = nil) {
        if let i = clips.firstIndex(where: { $0.kind == clip.kind && $0.hash == clip.hash }) {
            var old = clips.remove(at: i)
            old.date = clip.date
            clips.insert(old, at: 0)
            save(); return
        }
        var c = clip
        if let data = imageData {
            let name = c.id.uuidString + ".png"
            guard (try? data.write(to: imagesDir.appendingPathComponent(name))) != nil else { return }
            c.image = name
        }
        clips.insert(c, at: 0)
        if clips.count > maxItems {
            removeFiles(clips[maxItems...])
            clips.removeLast(clips.count - maxItems)
        }
        save()
    }

    /// Запись снова скопировали из истории — она поднимается в «Сегодня».
    func touch(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        var c = clips.remove(at: i)
        c.date = Date()
        clips.insert(c, at: 0)
        save()
    }

    func delete(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        removeFiles([clips.remove(at: i)])
        save()
    }

    func clear() {
        removeFiles(clips)
        clips = []
        save()
    }

    /// Удаляет всё старше keepDays дней и картинки, на которые никто не ссылается.
    func prune() {
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        let old = clips.filter { $0.date < cutoff }
        if !old.isEmpty { removeFiles(old); clips.removeAll { $0.date < cutoff } }
        let used = Set(clips.compactMap(\.image))
        for f in (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path)) ?? [] where !used.contains(f) {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(f))
        }
        save()
    }
}

// MARK: - Слежение за буфером

final class Watcher {
    private let pb = NSPasteboard.general
    private let store: Store
    private var last: Int
    private var own = -1            // changeCount нашей собственной записи в буфер — её не ловим
    private var timer: Timer?

    /// Пароли и служебные копии (стандарт nspasteboard.org, 1Password и др.) в историю не попадают.
    private let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "com.typeit4me.clipping", "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type", "net.antelle.keeweb",
    ]

    init(store: Store) {
        self.store = store
        last = pb.changeCount
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let n = pb.changeCount
        guard n != last else { return }
        last = n
        if n != own { capture() }
    }

    private func capture() {
        let types = pb.types ?? []
        if types.contains(where: { skipTypes.contains($0.rawValue) }) { return }
        let now = Date()

        // Файлы из Finder (вместе с ними в буфере лежат имя и значок — их не берём).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            store.add(Clip(kind: .files, date: now, hash: sha(Data(paths.joined(separator: "\n").utf8)), paths: paths))
            return
        }
        // Текст (у Word, Excel, Pages вместе с текстом бывает и картинка-превью — важнее текст).
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = String(s.prefix(200_000))
            store.add(Clip(kind: .text, date: now, hash: sha(Data(text.utf8)), text: text))
            return
        }
        // Картинка.
        if let data = pngData(), data.count <= maxImageBytes, let rep = NSBitmapImageRep(data: data) {
            store.add(Clip(kind: .image, date: now, hash: sha(data), width: rep.pixelsWide, height: rep.pixelsHigh), imageData: data)
        }
    }

    private func pngData() -> Data? {
        if let d = pb.data(forType: .png) { return d }
        guard let tiff = pb.data(forType: .tiff) ?? NSImage(pasteboard: pb)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Положить запись обратно в буфер.
    func copy(_ c: Clip) {
        pb.clearContents()
        switch c.kind {
        case .text:
            pb.setString(c.text ?? "", forType: .string)
        case .image:
            if let n = c.image, let data = try? Data(contentsOf: imagesDir.appendingPathComponent(n)) {
                pb.setData(data, forType: .png)
                if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        case .files:
            pb.writeObjects((c.paths ?? []).map { URL(fileURLWithPath: $0) as NSURL })
        }
        own = pb.changeCount
        last = own
        store.touch(c.id)
    }
}

// MARK: - Миниатюры

final class Thumbs {
    static let shared = Thumbs()
    private let cache = NSCache<NSString, NSImage>()

    func image(_ name: String) -> NSImage? {
        if let i = cache.object(forKey: name as NSString) { return i }
        let url = imagesDir.appendingPathComponent(name)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 720,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: name as NSString)
        return img
    }
}

// MARK: - Интерфейс панели

enum Filter: String, CaseIterable, Identifiable {
    case all = "Все", text = "Текст", image = "Картинки", files = "Файлы"
    var id: String { rawValue }
    func matches(_ c: Clip) -> Bool {
        switch self {
        case .all: return true
        case .text: return c.kind == .text
        case .image: return c.kind == .image
        case .files: return c.kind == .files
        }
    }
}

final class UIState: ObservableObject {
    @Published var opened = 0       // растёт при каждом открытии — список прокручивается к началу
}

struct DayGroup: Identifiable {
    let day: Date
    let items: [Clip]
    var id: Date { day }
    var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Сегодня" }
        if cal.isDateInYesterday(day) { return "Вчера" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let s = f.string(from: day)
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    let onCopy: (Clip) -> Void
    let onClear: () -> Void
    let onClose: () -> Void
    @State private var filter: Filter = .all

    private var groups: [DayGroup] {
        let cal = Calendar.current
        var out: [DayGroup] = []
        var cur: (Date, [Clip])? = nil
        for c in store.clips where filter.matches(c) {
            let d = cal.startOfDay(for: c.date)
            if cur?.0 == d { cur!.1.append(c) } else {
                if let x = cur { out.append(DayGroup(day: x.0, items: x.1)) }
                cur = (d, [c])
            }
        }
        if let x = cur { out.append(DayGroup(day: x.0, items: x.1)) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Буфер обмена")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Menu {
                    Button("Очистить историю…", role: .destructive, action: onClear)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Ещё")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Закрыть (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            let g = groups
            if g.isEmpty {
                EmptyState(filter: filter)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Color.clear.frame(height: 0).id("top")
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(g) { group in
                                Section {
                                    ForEach(group.items) { clip in
                                        ClipRow(clip: clip, onCopy: onCopy, onDelete: { store.delete($0.id) })
                                    }
                                } header: {
                                    DayHeader(title: group.title, count: group.items.count)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: ui.opened) { _, _ in proxy.scrollTo("top", anchor: .top) }
                    .onChange(of: filter) { _, _ in proxy.scrollTo("top", anchor: .top) }
                }
            }

            Divider().opacity(0.5)
            Text("История хранится \(keepDays) дней")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct DayHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

struct EmptyState: View {
    let filter: Filter
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: filter == .image ? "photo" : filter == .files ? "doc" : "doc.on.clipboard")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(filter == .all ? "Пока пусто" : "Здесь пока ничего нет")
                .font(.system(size: 14, weight: .semibold))
            Text("Скопируйте что-нибудь — оно появится здесь")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(24)
    }
}

struct ClipRow: View {
    let clip: Clip
    let onCopy: (Clip) -> Void
    let onDelete: (Clip) -> Void
    @State private var hover = false
    @State private var hoverButton = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                content
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { onCopy(clip) } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(hoverButton ? Color.accentColor : Color.secondary)
                    .background(Circle().fill(Color.primary.opacity(hoverButton ? 0.14 : (hover ? 0.08 : 0))))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoverButton = $0 }
            .help("Скопировать")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover = $0 }
        .onTapGesture { onCopy(clip) }
        .contextMenu {
            Button("Скопировать") { onCopy(clip) }
            if clip.kind == .files, let p = clip.paths {
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(p.map { URL(fileURLWithPath: $0) })
                }
            }
            Divider()
            Button("Удалить из истории", role: .destructive) { onDelete(clip) }
        }
    }

    private var time: String { timeFormatter.string(from: clip.date) }

    private var meta: String {
        switch clip.kind {
        case .text:
            let n = clip.text?.count ?? 0
            return n > 300 ? "\(time) · \(n) символов" : time
        case .image:
            if let w = clip.width, let h = clip.height { return "\(time) · \(w)×\(h)" }
            return time
        case .files:
            return time
        }
    }

    @ViewBuilder private var leading: some View {
        switch clip.kind {
        case .text:
            badge("text.alignleft")
        case .image:
            EmptyView()
        case .files:
            let path = clip.paths?.first ?? ""
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 30, height: 30)
        }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    @ViewBuilder private var content: some View {
        switch clip.kind {
        case .text:
            Text(preview(clip.text ?? ""))
                .font(.system(size: 12.5))
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image:
            if let n = clip.image, let img = Thumbs.shared.image(n) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .frame(maxHeight: 130)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Картинка недоступна").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        case .files:
            let paths = clip.paths ?? []
            let first = URL(fileURLWithPath: paths.first ?? "")
            let exists = FileManager.default.fileExists(atPath: first.path)
            VStack(alignment: .leading, spacing: 2) {
                Text(paths.count > 1 ? "\(first.lastPathComponent) и ещё \(paths.count - 1)" : first.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(exists ? (first.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath : "файл перемещён или удалён")
                    .font(.system(size: 11))
                    .foregroundStyle(exists ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func preview(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(600))
    }
}

// MARK: - Панель и значок

final class SidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let ui = UIState()
    lazy var watcher = Watcher(store: store)
    var statusItem: NSStatusItem!
    var panel: SidePanel!
    var monitors: [Any] = []
    let menu = NSMenu()
    var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = watcher
        setupEditMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "История буфера")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = "История буфера обмена"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panel = SidePanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 600),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let root = PanelView(store: store, ui: ui,
                             onCopy: { [weak self] in self?.copy($0) },
                             onClear: { [weak self] in self?.confirmClear() },
                             onClose: { [weak self] in self?.hidePanel() })
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        loginItem = NSMenuItem(title: "Запускать при входе в систему", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        let clearItem = NSMenuItem(title: "Очистить историю…", action: #selector(clearFromMenu), keyEquivalent: "")
        clearItem.target = self
        menu.items = [clearItem, .separator(), loginItem, .separator(),
                      NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")]

        enableLoginItemOnce()

        // Раз в час — удалить записи старше недели.
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.store.prune() } }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Без Dock у приложения нет меню «Правка» — добавляем скрыто, чтобы работали ⌘C/⌘V в меню.
    private func setupEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    @objc private func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            hidePanel()
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func targetFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = statusItem.button?.window?.screen
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let m: CGFloat = 8
        return NSRect(x: vf.maxX - panelWidth - m, y: vf.minY + m, width: panelWidth, height: vf.height - m * 2)
    }

    func showPanel() {
        let target = targetFrame()
        ui.opened += 1
        panel.setFrame(target.offsetBy(dx: 24, dy: 0), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    func hidePanel() {
        guard panel.isVisible else { return }
        removeMonitors()
        let to = panel.frame.offsetBy(dx: 24, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(to, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel.orderOut(nil)
                self?.panel.alphaValue = 1
            }
        })
    }

    /// Щелчок мимо панели (в другом приложении) или Esc — закрыть.
    private func installMonitors() {
        removeMonitors()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.hidePanel() }; return nil }
            return e
        }) { monitors.append(l) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func copy(_ clip: Clip) {
        watcher.copy(clip)
        hidePanel()
    }

    @objc private func clearFromMenu() { confirmClear() }

    private func confirmClear() {
        let a = NSAlert()
        a.messageText = "Очистить всю историю?"
        a.informativeText = "Все записи и картинки из истории буфера будут удалены. Это нельзя отменить."
        a.addButton(withTitle: "Очистить")
        a.addButton(withTitle: "Отмена")
        a.buttons[0].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { store.clear() }
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }

    private func enableLoginItemOnce() {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"),
              !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { return }
        if (try? SMAppService.mainApp.register()) != nil { UserDefaults.standard.set(true, forKey: "loginItemConfigured") }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
