import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct KindleCastApp: App {
    @StateObject private var model = CastModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Kindle 投放", id: "desk") {
            DeskView(model: model)
        }
        .defaultSize(width: 880, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件…", action: model.chooseFile).keyboardShortcut("o")
                Button("粘贴到预览", action: model.paste).keyboardShortcut("v")
                Divider()
                Button("框选并投放", action: model.capture).keyboardShortcut("k", modifiers: [.command, .shift])
                Button("投放当前页", action: model.send).keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.preview == nil || model.busy)
            }
        }

        MenuBarExtra("Kindle 投放", systemImage: "rectangle.portrait.on.rectangle.portrait") {
            Button("打开投放窗口") {
                openWindow(id: "desk")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("框选并投放", action: model.capture).disabled(model.busy)
            Button("投放当前页", action: model.send).disabled(model.preview == nil || model.busy)
            Button("返回 Kindle 阅读界面", action: model.returnToReader).disabled(model.busy)
            Divider()
            Button("退出 Kindle 投放") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class CastModel: ObservableObject {
    @Published private(set) var preview: CGImage?
    @Published private(set) var title: String?
    @Published private(set) var page = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var landscape = false
    @Published private(set) var busy = false
    @Published private(set) var status = "拖入文件后预览，确认满意再投放。"
    @Published private(set) var failed = false
    private var renderer: PageRenderer?

    func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        guard !busy, url.isFileURL else { return }
        do {
            try show(CastDocument(url: url))
        } catch {
            report(error)
        }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let bytes = item as? Data {
                url = URL(dataRepresentation: bytes, relativeTo: nil)
            } else {
                url = item as? URL
            }
            DispatchQueue.main.async {
                if let url {
                    self.load(url)
                } else {
                    self.report(CastError.message("无法读取拖入的文件。请点击选择文件。"))
                }
            }
        }
        return true
    }

    func paste() {
        guard !busy else { return }
        let board = NSPasteboard.general
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if let url = urls?.first as? URL {
            load(url)
            return
        }
        do {
            if let image = NSImage(pasteboard: board),
               let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                try show(CastDocument(name: "剪贴板图片", body: .image(bitmap)))
            } else if let text = board.string(forType: .string), !text.isEmpty {
                try show(CastDocument(name: "剪贴板文字", body: .text(text)))
            } else {
                throw CastError.message("剪贴板中没有可投放的图片、文字或文件。")
            }
        } catch {
            report(error)
        }
    }

    func changePage(_ offset: Int) {
        guard !busy, let renderer, (0..<renderer.count).contains(page + offset) else { return }
        do {
            let newPage = page + offset
            preview = try renderer.render(page: newPage)
            page = newPage
            report("预览已更新。点「投放当前页」更新 Kindle。")
        } catch {
            report(error)
        }
    }

    func setLandscape(_ value: Bool) {
        guard !busy, value != landscape else { return }
        do {
            if let renderer {
                try show(renderer.document, landscape: value, requestedPage: page)
            } else {
                landscape = value
            }
        } catch {
            report(error)
        }
    }

    func send() {
        guard !busy, let preview else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await transmit(preview)
            } catch {
                report(error)
            }
        }
    }

    func capture() {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            report(CastError.message("请在「系统设置 → 隐私与安全性 → 屏幕录制」允许 Kindle 投放，然后重开 App。"))
            return
        }
        busy = true
        report("拖出截图范围。按 Esc 可取消。")
        let window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        window?.orderOut(nil)
        Task {
            defer { busy = false }
            do {
                let captured = try await Task.detached(priority: .userInitiated) {
                    try USBTransport.captureRegion()
                }.value
                window?.makeKeyAndOrderFront(nil)
                guard let captured,
                      let source = CGImageSourceCreateWithData(captured as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    report("已取消截图。")
                    return
                }
                try show(CastDocument(name: "屏幕截图", body: .image(image)))
                if let preview { try await transmit(preview) }
            } catch {
                window?.makeKeyAndOrderFront(nil)
                report(error)
            }
        }
    }

    func returnToReader() {
        guard !busy else { return }
        busy = true
        report("正在返回阅读界面…")
        Task {
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) { try USBTransport.returnToReader() }.value
                report("Kindle 已返回阅读界面。")
            } catch {
                report(error)
            }
        }
    }

    private func show(_ document: CastDocument, landscape orientation: Bool? = nil,
                      requestedPage: Int = 0) throws {
        let prepared = try PageRenderer(document: document, landscape: orientation ?? landscape)
        let current = min(requestedPage, prepared.count - 1)
        let frame = try prepared.render(page: current)
        renderer = prepared
        title = document.name
        page = current
        pageCount = prepared.count
        landscape = prepared.landscape
        preview = frame
        report("预览已就绪。点「投放当前页」更新 Kindle。")
    }

    private func transmit(_ image: CGImage) async throws {
        report("正在经 USB 投放…")
        let png = try PageRenderer.png(image)
        try await Task.detached(priority: .userInitiated) { try USBTransport.send(png) }.value
        report("已投放。Kindle 会保留这幅画面，直到下一次投放或返回阅读。")
    }

    private func report(_ text: String) {
        failed = false
        status = text
    }

    private func report(_ error: Error) {
        failed = true
        status = error.localizedDescription
    }
}

struct DeskView: View {
    @ObservedObject var model: CastModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Kindle 投放").font(.system(size: 23, weight: .semibold))
                    Text("给 DX Graphite 留一页你正在看的内容").foregroundStyle(.secondary)
                }
                Spacer()
                Label("USB · 192.168.2.2", systemImage: "cable.connector")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(.quaternary, in: Capsule())
            }
            .padding(22)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                controls.frame(width: 288).padding(22)
                Divider()
                preview
            }
            Divider()
            HStack(alignment: .top, spacing: 9) {
                if model.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.failed ? "exclamationmark.circle" : "info.circle")
                        .foregroundStyle(model.failed ? Color.orange : Color.secondary)
                }
                Text(model.status).font(.callout)
                    .foregroundStyle(model.failed ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
            .frame(minHeight: 46, alignment: .leading)
        }
        .frame(minWidth: 770, minHeight: 585)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: model.acceptDrop)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: model.chooseFile) {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 22, weight: .medium))
                    Text(isDropTarget ? "松手预览文件" : "拖入文件，或点击选择")
                        .font(.system(.body, weight: .semibold))
                    Text("图片 · PDF · TXT · Markdown").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 119)
                .background(isDropTarget ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isDropTarget ? Color.accentColor : Color.secondary.opacity(0.45),
                                      style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
            .buttonStyle(.plain)

            HStack {
                Button(action: model.capture) { Label("框选并投放", systemImage: "viewfinder") }
                Spacer(minLength: 0)
                Button(action: model.paste) { Label("粘贴", systemImage: "clipboard") }
            }
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 8) {
                Text("显示方向").font(.subheadline.weight(.medium))
                Picker("显示方向", selection: Binding(get: { model.landscape }, set: model.setLandscape)) {
                    Text("竖向").tag(false)
                    Text("横向").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(model.landscape ? "发送后，将 Kindle 向右旋转 90° 阅读。" : "竖向适合文档，横向适合宽截图。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.pageCount > 1 {
                HStack {
                    Button { model.changePage(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(model.page == 0).accessibilityLabel("上一页")
                    Spacer()
                    Text("第 \(model.page + 1) / \(model.pageCount) 页")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.changePage(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(model.page + 1 == model.pageCount).accessibilityLabel("下一页")
                }
            }

            Spacer(minLength: 8)
            Button(action: model.send) {
                Label("投放当前页", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.preview == nil)
            Button("返回 Kindle 阅读界面", action: model.returnToReader)
                .buttonStyle(.link).frame(maxWidth: .infinity)
        }
        .disabled(model.busy)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.title ?? "投放预览").font(.headline).lineLimit(1)
                Spacer()
                Text("824 × 1200").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let ratio = 824.0 / 1200.0
                let width = min(geometry.size.width, geometry.size.height * ratio)
                let height = width / ratio
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.97))
                    if let preview = model.preview {
                        Image(decorative: preview, scale: 1, orientation: .up)
                            .resizable().interpolation(.high)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.text.image").font(.system(size: 31, weight: .light))
                            Text("下一幅画面").font(.headline)
                            Text("拖入一份文件开始").font(.caption)
                        }
                        .foregroundStyle(Color(white: 0.39))
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.12)) }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
