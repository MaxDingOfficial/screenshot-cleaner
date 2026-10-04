import Foundation
import Darwin

@main
struct CoreTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ text: String) throws {
        checks += 1
        if try !condition() { throw CleanerError.message("FAIL: " + text) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("core-fixtures-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=")!
        func write(_ name: String, data: Data? = nil) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data ?? png).write(to: url); return url
        }
        func marker(_ url: URL, enabled: Bool = true) throws {
            let bytes = try PropertyListSerialization.data(fromPropertyList: enabled, format: .binary, options: 0)
            let result = bytes.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
            guard result == 0 else { throw CleanerError.message("Cannot set fixture metadata") }
        }
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = tz
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))! }
        try expect(try AgeUnit.month.cutoff(amount: 1, now: date(2024, 3, 31), calendar: calendar) == date(2024, 2, 29), "calendar month clamps to leap day")
        try expect(try AgeUnit.year.cutoff(amount: 1, now: date(2024, 2, 29), calendar: calendar) == date(2023, 2, 28), "year clamps leap day")
        try expect(try AgeUnit.day.cutoff(amount: 3, now: date(2026, 10, 4), calendar: calendar) == date(2026, 10, 1), "day subtraction")
        do { _ = try AgeUnit.month.cutoff(amount: 0); throw CleanerError.message("Accepted invalid age") } catch CleanerError.message(let text) { try expect(text != "Accepted invalid age", "zero rejected") }
        try expect(ScreenshotScanner.namedCaptureDate(URL(fileURLWithPath: "Screenshot 2026-04-21 at 9.29.02 PM.png"), timeZone: tz) == calendar.date(from: DateComponents(year: 2026, month: 4, day: 21, hour: 21, minute: 29, second: 2)), "English PM parsing")
        try expect(ScreenshotScanner.namedCaptureDate(URL(fileURLWithPath: "截屏2026-02-30 12.00.00.png"), timeZone: tz) == nil, "invalid filename date rejected")
        try expect(ScreenshotScanner.namedCaptureDate(URL(fileURLWithPath: "截图设计.png"), timeZone: tz) == nil, "generic screenshot-like name rejected")
        let old = try write("截屏2020-01-01 12.00.00.png")
        let boundary = try write("截屏2026-08-04 12.00.00.png")
        let recent = try write("截屏2026-09-01 12.00.00.png")
        let ordinary = try write("photo.png")
        let corrupt = try write("截屏2020-02-01 12.00.00.png", data: Data("not an image".utf8))
        _ = try write("录屏2020-01-01 12.00.00.mov", data: Data("video".utf8))
        let tagged = try write("renamed.png"); try marker(tagged)
        try fm.setAttributes([.creationDate: date(2020, 1, 2)], ofItemAtPath: tagged.path)
        let nested = try write("nested/截屏2020-01-01 12.00.00.png")
        _ = try write("bundle.app/截屏2020-01-01 12.00.00.png")
        _ = try write(".hidden/截屏2020-01-01 12.00.00.png")
        try fm.createSymbolicLink(at: root.appendingPathComponent("截屏2020-01-03 12.00.00.png"), withDestinationURL: ordinary)
        let request = ScanRequest(root: root, cutoff: date(2026, 8, 4), recursive: false)
        let scan = try ScreenshotScanner.scan(request)
        try expect(Set(scan.items.map(\.url)) == Set([old, tagged]), "only old screenshots and tagged renamed screenshot qualify")
        try expect(scan.screenshotCount == 4, "counts recent and exact boundary separately")
        let recursive = try ScreenshotScanner.scan(ScanRequest(root: root, cutoff: request.cutoff, recursive: true))
        if Set(recursive.items.map(\.url)) != Set([old, tagged, nested]) {
            print("Recursive diagnostic: \(recursive.items.map { $0.relativePath }); issues: \(recursive.issues)")
            if let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in iterator {
                    let props = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                    print("Enumerator: \(url.path) dir=\(String(describing: props.isDirectory)) link=\(String(describing: props.isSymbolicLink)) package=\(String(describing: props.isPackage))")
                }
            }
            fflush(stdout)
        }
        try expect(Set(recursive.items.map(\.url)) == Set([old, tagged, nested]), "recursive scan skips packages, hidden files and symlinks")
        let selected = recursive.items.filter { $0.url == old || $0.url == nested }
        let trashReport = ScreenshotCleaner.clean(selected, request: recursive.request, mode: .trash)
        try expect(trashReport.successCount == 2 && trashReport.failureCount == 0, "same-name screenshots move to Trash")
        try expect(Set(trashReport.entries.compactMap(\.destination)).count == 2, "same-name trash destinations remain distinct")
        try expect(!fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: nested.path), "trashed sources removed")
        for entry in trashReport.entries {
            guard let destination = entry.destination else { throw CleanerError.message("Missing fixture trash destination") }
            let url = URL(fileURLWithPath: destination)
            try expect(try Data(contentsOf: url) == png, "Trash content preserved")
            try fm.moveItem(at: url, to: URL(fileURLWithPath: entry.source))
        }
        try expect(fm.fileExists(atPath: ordinary.path) && fm.fileExists(atPath: boundary.path) && fm.fileExists(atPath: recent.path) && fm.fileExists(atPath: corrupt.path), "ordinary, recent, exact cutoff and corrupt images preserved")
        let changedScan = try ScreenshotScanner.scan(request)
        let changedItem = changedScan.items.first { $0.url == old }!
        var changedData = png; changedData[changedData.count - 1] ^= 1
        try changedData.write(to: old)
        let changeReport = ScreenshotCleaner.clean([changedItem], request: request, mode: .permanent)
        try expect(changeReport.successCount == 0 && changeReport.failureCount == 1 && fm.fileExists(atPath: old.path), "same-size content change blocked")
        try png.write(to: old)
        let directoryScan = try ScreenshotScanner.scan(request)
        let directoryItem = directoryScan.items.first { $0.url == old }!
        try fm.removeItem(at: old); try fm.createDirectory(at: old, withIntermediateDirectories: false)
        let directoryReport = ScreenshotCleaner.clean([directoryItem], request: request, mode: .permanent)
        try expect(directoryReport.failureCount == 1 && (try old.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true, "replacement directory never removed")
        try fm.removeItem(at: old); try png.write(to: old)
        let markerScan = try ScreenshotScanner.scan(request)
        let markerItem = markerScan.items.first { $0.url == tagged }!
        try marker(tagged, enabled: false)
        let markerReport = ScreenshotCleaner.clean([markerItem], request: request, mode: .permanent)
        try expect(markerReport.failureCount == 1 && fm.fileExists(atPath: tagged.path), "removed screenshot marker blocked")
        try marker(tagged)
        let cleanScan = try ScreenshotScanner.scan(request)
        let permanentItems = cleanScan.items.filter { $0.url == old }
        let permanentReport = ScreenshotCleaner.clean(permanentItems, request: request, mode: .permanent)
        try expect(permanentReport.successCount == 1 && permanentReport.failureCount == 0 && !fm.fileExists(atPath: old.path), "permanent deletion works on selected fixture")
        try expect(fm.fileExists(atPath: tagged.path) && fm.fileExists(atPath: nested.path), "unselected screenshots preserved")
        let changedDateItem = try ScreenshotScanner.scan(request).items.first { $0.url == tagged }!
        try fm.setAttributes([.creationDate: date(2026, 9, 1)], ofItemAtPath: tagged.path)
        let changedDateReport = ScreenshotCleaner.clean([changedDateItem], request: request, mode: .trash)
        try expect(changedDateReport.failureCount == 1 && fm.fileExists(atPath: tagged.path), "changed date blocked")
        print("PASS: \(checks) checks; only isolated test fixtures were moved or deleted.")
    }
}
