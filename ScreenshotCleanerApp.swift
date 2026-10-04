import SwiftUI
import AppKit

final class CleanerModel: ObservableObject {
    @Published var folder: URL
    @Published var amountText = "2"
    @Published var unit: AgeUnit = .month
    @Published var recursive = false
    @Published var mode: CleanupMode = .trash
    @Published var scan: ScanResult?
    @Published var selected: Set<String> = []
    @Published var busy = false
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var report: CleanupReport?
    @Published var showingConfirmation = false
    @Published var confirmationText = ""
    @Published var showingHistory = false
    @Published var history: [CleanupReport] = []
    private var pendingItems: [ScreenshotItem] = []
    private var pendingRequest: ScanRequest?
    private var pendingMode: CleanupMode = .trash

    static var historyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ScreenshotCleaner/history.json")
    }
    init() {
        if let argument = ProcessInfo.processInfo.arguments.firstIndex(of: "--folder"), ProcessInfo.processInfo.arguments.indices.contains(argument + 1) {
            folder = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[argument + 1]).resolvingSymlinksInPath()
        } else if let path = UserDefaults.standard.string(forKey: "folderPath"), FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        } else { folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").resolvingSymlinksInPath() }
        if let data = try? Data(contentsOf: Self.historyURL), let reports = try? JSONDecoder().decode([CleanupReport].self, from: data) { history = reports }
    }
    var amount: Int? { Int(amountText.trimmingCharacters(in: .whitespaces)) }
    var validAmount: Bool { amount.map { (1...9999).contains($0) } ?? false }
    var selectedItems: [ScreenshotItem] { scan?.items.filter { selected.contains($0.id) } ?? [] }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var allSelected: Bool { !(scan?.items.isEmpty ?? true) && selected.count == scan?.items.count }
    var folderName: String {
        folder.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").resolvingSymlinksInPath().path ? "桌面" : FileManager.default.displayName(atPath: folder.path)
    }
    var pendingCount: Int { pendingItems.count }
    var pendingBytes: Int64 { pendingItems.reduce(0) { $0 + $1.size } }
    var confirmationMode: CleanupMode { pendingMode }

    func invalidate() {
        guard !busy else { return }
        scan = nil; selected = []; report = nil; status = "条件已更改，点击“扫描截屏”更新清单。"
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = folder; panel.prompt = "选择文件夹"
        panel.message = "选择保存截屏的文件夹。"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.standardizedFileURL.resolvingSymlinksInPath()
            UserDefaults.standard.set(folder.path, forKey: "folderPath")
            invalidate(); scanNow()
        }
    }
    func useDesktop() {
        folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").resolvingSymlinksInPath()
        UserDefaults.standard.set(folder.path, forKey: "folderPath"); invalidate(); scanNow()
    }
    func scanNow(keepingReport: Bool = false) {
        guard !busy, let amount = amount, validAmount else { return }
        do {
            let cutoff = try unit.cutoff(amount: amount)
            let request = ScanRequest(root: folder, cutoff: cutoff, recursive: recursive)
            busy = true; selected = []; scan = nil; status = "正在识别截屏并检查文件…"
            if !keepingReport { report = nil }
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try ScreenshotScanner.scan(request) }
                DispatchQueue.main.async {
                    self.busy = false
                    switch outcome {
                    case .success(let result):
                        self.scan = result; self.selected = Set(result.items.map(\.id))
                        self.status = result.items.isEmpty ? "扫描完成，没有符合时间条件的截屏。" : "扫描完成，可取消勾选需要保留的图片。"
                    case .failure(let error): self.status = "扫描失败"; self.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func toggleAll() {
        selected = allSelected ? [] : Set(scan?.items.map(\.id) ?? [])
    }
    func prepareCleanup() {
        guard let request = scan?.request, !selectedItems.isEmpty, !busy else { return }
        pendingItems = selectedItems; pendingRequest = request; pendingMode = mode
        confirmationText = ""; showingConfirmation = true
    }
    func performCleanup() {
        guard let request = pendingRequest, !pendingItems.isEmpty,
              pendingMode != .permanent || confirmationText == "彻底删除" else { return }
        let items = pendingItems, mode = pendingMode
        showingConfirmation = false; busy = true; status = "正在\(mode.label)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ScreenshotCleaner.clean(items, request: request, mode: mode)
            DispatchQueue.main.async {
                self.busy = false; self.report = result; self.history.insert(result, at: 0)
                self.history = Array(self.history.prefix(100))
                do {
                    try FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(self.history).write(to: Self.historyURL, options: .atomic)
                } catch { self.errorMessage = "操作已完成，但清理记录保存失败：\(error.localizedDescription)" }
                self.scanNow(keepingReport: true)
            }
        }
    }
    func showTrash() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) }
}

private let accent = Color(red: 0.12, green: 0.45, blue: 0.41)
private func bytes(_ value: Int64) -> String { value == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
private func dateText(_ date: Date) -> String { date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second()) }

struct CleanerView: View {
    @StateObject private var model = CleanerModel()
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "viewfinder").font(.system(size: 29, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 54, height: 54).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("截屏清理").font(.system(size: 25, weight: .semibold))
                    Text("按时间整理截图，先看清单再处理").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showingHistory = true } label: { Label("清理记录", systemImage: "clock.arrow.circlepath") }.disabled(model.busy)
            }
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").foregroundStyle(accent).font(.title2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.folderName).font(.headline)
                        Text(model.folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(model.folder.path)
                    }
                    Spacer()
                    Button("桌面") { model.useDesktop() }.disabled(model.busy)
                    Button("选择文件夹…") { model.chooseFolder() }.disabled(model.busy)
                }
                Divider()
                HStack(spacing: 10) {
                    Text("查找超过")
                    TextField("2", text: $model.amountText).textFieldStyle(.roundedBorder).frame(width: 65).disabled(model.busy)
                        .accessibilityLabel("时间数量")
                    Picker("时间单位", selection: $model.unit) { ForEach(AgeUnit.allCases) { Text($0.label).tag($0) } }
                        .labelsHidden().frame(width: 95).disabled(model.busy)
                    Text("的截屏")
                    Spacer()
                    Toggle("包括子文件夹", isOn: $model.recursive).toggleStyle(.checkbox).disabled(model.busy)
                    Button { model.scanNow() } label: { Label("扫描截屏", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(model.busy || !model.validAmount)
                        .keyboardShortcut("r", modifiers: .command)
                }
                if !model.validAmount { Text("请输入 1 至 9999 的整数。").font(.caption).foregroundStyle(.red) }
                if let scan = model.scan {
                    Text("早于 \(dateText(scan.request.cutoff)) · 识别到 \(scan.screenshotCount) 张截屏 · 普通照片不纳入清单")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("按日历计算天、月、年；文件名中的截屏时间优先，没有时采用文件创建日期。")
                        .font(.caption).foregroundStyle(.secondary) }
            }
            .padding(17).background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 12) {
                metric("符合条件", value: "\(model.scan?.items.count ?? 0) 张", symbol: "photo.on.rectangle")
                metric("已选图片", value: "\(model.selected.count) 张", symbol: "checkmark.circle")
                metric("已选大小", value: bytes(model.selectedBytes), symbol: "internaldrive")
            }

            VStack(spacing: 0) {
                HStack {
                    Button(model.allSelected ? "取消全选" : "全选") { model.toggleAll() }.disabled(model.busy || (model.scan?.items.isEmpty ?? true))
                    Text("截屏清单").font(.headline)
                    Spacer()
                    Text("双击文件名查看图片").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).padding(.vertical, 10)
                Divider()
                Table(model.scan?.items ?? []) {
                    TableColumn("选择") { item in
                        Toggle("选择 \(item.url.lastPathComponent)", isOn: Binding(get: { model.selected.contains(item.id) }, set: { flag in
                            if flag { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
                        })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                    }.width(42)
                    TableColumn("文件") { item in
                        HStack(spacing: 7) {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                            Text(item.relativePath).lineLimit(1).truncationMode(.middle).help(item.url.path)
                        }.onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                            .contextMenu { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
                    }.width(min: 240, ideal: 400)
                    TableColumn("截屏时间") { item in
                        Text(dateText(item.capturedAt)).font(.caption).help("日期依据：\(item.dateSource)")
                    }.width(185)
                    TableColumn("大小") { item in Text(bytes(item.size)).font(.caption).monospacedDigit() }.width(85)
                }
                .frame(minHeight: 180)
                .overlay {
                    if model.busy { VStack(spacing: 10) { ProgressView(); Text(model.status).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(NSColor.controlBackgroundColor).opacity(0.93)) }
                    else if model.scan == nil { emptyState("准备扫描", detail: "选择时间范围，点击“扫描截屏”。", symbol: "viewfinder") }
                    else if model.scan?.items.isEmpty == true { emptyState("没有需要清理的截屏", detail: "可以缩短时间范围或选择其他文件夹。", symbol: "checkmark.circle") }
                }
            }
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let report = model.report {
                HStack(spacing: 9) {
                    Image(systemName: report.failureCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.failureCount == 0 ? accent : .orange)
                    Text("已\(report.mode.label) \(report.successCount) 张（\(bytes(report.successBytes))）\(report.failureCount > 0 ? "，\(report.failureCount) 张未完成" : "")")
                    Spacer()
                    if report.mode == .trash { Button("查看废纸篓") { model.showTrash() } }
                    if report.failureCount > 0 { Button("查看详情") { model.showingHistory = true } }
                }.font(.callout).padding(11).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            if let scan = model.scan, !scan.issues.isEmpty {
                HStack {
                    Label("\(scan.issues.count) 项无法完整读取，已跳过。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    Button("查看原因") { model.errorMessage = scan.issues.joined(separator: "\n") }.font(.caption)
                    Spacer()
                }
            }
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Picker("处理方式", selection: $model.mode) { ForEach(CleanupMode.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 280).disabled(model.busy)
                    Text(model.mode == .trash ? "移至废纸篓后可恢复；不会清空废纸篓。" : "彻底删除无法通过废纸篓恢复。")
                        .font(.caption).foregroundStyle(model.mode == .permanent ? Color.red : Color.secondary)
                }
                Spacer()
                Button("\(model.mode.label)（\(model.selected.count) 张）") { model.prepareCleanup() }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(model.mode == .trash ? accent : .red)
                    .disabled(model.busy || model.selected.isEmpty || model.scan == nil)
            }
        }
        .padding(24).frame(minWidth: 880, minHeight: 730)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { model.scanNow() }
        .onChange(of: model.amountText) { _ in model.invalidate() }
        .onChange(of: model.unit) { _ in model.invalidate() }
        .onChange(of: model.recursive) { _ in model.invalidate() }
        .sheet(isPresented: $model.showingConfirmation) { confirmation }
        .sheet(isPresented: $model.showingHistory) { historyView }
        .alert("提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private func metric(_ title: String, value: String, symbol: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 24, weight: .medium)).monospacedDigit() }
            Spacer(); Image(systemName: symbol).font(.title2).foregroundStyle(accent.opacity(0.75))
        }.padding(15).frame(maxWidth: .infinity).background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    private func emptyState(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 9) { Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(accent); Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(NSColor.controlBackgroundColor))
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.confirmationMode == .permanent ? "确认彻底删除" : "确认移至废纸篓", systemImage: model.confirmationMode == .permanent ? "exclamationmark.triangle.fill" : "trash")
                .font(.title2.weight(.semibold)).foregroundStyle(model.confirmationMode == .permanent ? Color.red : accent)
            Text("将处理你勾选的 \(model.pendingCount) 张截屏，共 \(bytes(model.pendingBytes))。")
            Text(model.folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if model.confirmationMode == .permanent {
                Text("这些文件将直接删除，不进入废纸篓。请输入“彻底删除”确认。")
                TextField("彻底删除", text: $model.confirmationText).textFieldStyle(.roundedBorder).accessibilityLabel("彻底删除确认文字")
            } else { Text("文件会保留在废纸篓中，可由你恢复。").foregroundStyle(.secondary) }
            HStack { Spacer(); Button("取消") { model.showingConfirmation = false }.keyboardShortcut(.cancelAction)
                Button(model.confirmationMode.label) { model.performCleanup() }.buttonStyle(.borderedProminent)
                    .tint(model.confirmationMode == .permanent ? .red : accent)
                    .disabled(model.confirmationMode == .permanent && model.confirmationText != "彻底删除")
            }
        }.padding(26).frame(width: 450)
    }
    private var historyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("清理记录").font(.title2.weight(.semibold)); Spacer(); Button("完成") { model.showingHistory = false }.keyboardShortcut(.cancelAction) }
            Text("最近 100 次操作；记录保存在这台 Mac 上。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                if model.history.isEmpty { Text("还没有清理记录。").foregroundStyle(.secondary).padding(40) }
                ForEach(Array(model.history.enumerated()), id: \.offset) { _, report in
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(dateText(report.date)) · \(report.mode.label)").font(.headline)
                        Text("成功 \(report.successCount) 张 · 未完成 \(report.failureCount) 张 · \(bytes(report.successBytes))")
                        Text(report.folder).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        DisclosureGroup("查看文件清单") {
                            ForEach(Array(report.entries.enumerated()), id: \.offset) { _, entry in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(entry.success ? "✓" : "!") \(entry.source)").font(.caption).textSelection(.enabled)
                                    if let error = entry.error { Text(error).font(.caption).foregroundStyle(.orange) }
                                    if let destination = entry.destination { Text("废纸篓位置：\(destination)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                            }
                        }.font(.callout)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }.padding(24).frame(width: 650, height: 500)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ScreenshotCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("截屏清理") { CleanerView() }
            .defaultSize(width: 960, height: 780)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .appInfo) {
                    Button("关于截屏清理") { NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "截屏清理", .applicationVersion: "1.0", .credits: NSAttributedString(string: "按天、月、年整理截屏。默认移至废纸篓。")]) }
                }
            }
    }
}
