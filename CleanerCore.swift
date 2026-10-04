import Foundation
import Darwin
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import CoreServices

enum AgeUnit: String, CaseIterable, Codable, Identifiable {
    case day, month, year
    var id: String { rawValue }
    var label: String { switch self { case .day: return "天"; case .month: return "个月"; case .year: return "年" } }
    var component: Calendar.Component { switch self { case .day: return .day; case .month: return .month; case .year: return .year } }
    func cutoff(amount: Int, now: Date = Date(), calendar: Calendar = .current) throws -> Date {
        guard (1...9999).contains(amount), let date = calendar.date(byAdding: component, value: -amount, to: now) else {
            throw CleanerError.message("时间必须是 1 至 9999 的整数。")
        }
        return date
    }
}

enum CleanupMode: String, CaseIterable, Codable, Identifiable {
    case trash, permanent
    var id: String { rawValue }
    var label: String { self == .trash ? "移至废纸篓" : "彻底删除" }
}

enum CleanerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

struct FileIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    static func read(_ url: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CleanerError.message("无法读取文件：\(url.lastPathComponent)（\(String(cString: strerror(errno)))）") }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw CleanerError.message("跳过非普通文件：\(url.lastPathComponent)") }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }
    func sameFileAndSize(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode && size == other.size
    }
}

struct ScreenshotItem: Identifiable {
    var id: String { url.path }
    let url: URL
    let relativePath: String
    let capturedAt: Date
    let dateSource: String
    let identity: FileIdentity
    let digest: String
    var size: Int64 { identity.size }
}

struct ScanRequest {
    let root: URL
    let cutoff: Date
    let recursive: Bool
}

struct ScanResult {
    let request: ScanRequest
    let items: [ScreenshotItem]
    let screenshotCount: Int
    let issues: [String]
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

struct CleanupEntry: Codable {
    let source: String
    let destination: String?
    let bytes: Int64
    let success: Bool
    let error: String?
}

struct CleanupReport: Codable {
    let date: Date
    let mode: CleanupMode
    let folder: String
    let cutoff: Date
    let entries: [CleanupEntry]
    var successCount: Int { entries.filter(\.success).count }
    var failureCount: Int { entries.count - successCount }
    var successBytes: Int64 { entries.filter(\.success).reduce(0) { $0 + $1.bytes } }
}

enum ScreenshotScanner {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "webp", "bmp", "gif", "avif"]
    static let packageExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "photoslibrary", "photolibrary", "aplibrary", "pkg"]
    static let namePattern = try! NSRegularExpression(pattern: "^(?:截屏|截图|截圖|螢幕截圖|屏幕快照|Screenshot|Screen\\s+Shot)\\s*(\\d{4})-(\\d{2})-(\\d{2})\\s+(?:at\\s+)?(?:(上午|下午)\\s*)?(\\d{1,2})[.:](\\d{2})[.:](\\d{2})(?:\\s*(AM|PM))?(?:\\s+[0-9() -]+)?$", options: [.caseInsensitive])

    static func namedCaptureDate(_ url: URL, timeZone: TimeZone = .current) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent as NSString
        guard let match = namePattern.firstMatch(in: name as String, range: NSRange(location: 0, length: name.length)) else { return nil }
        func value(_ group: Int) -> String? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : name.substring(with: range)
        }
        guard let year = Int(value(1) ?? ""), let month = Int(value(2) ?? ""), let day = Int(value(3) ?? ""),
              var hour = Int(value(5) ?? ""), let minute = Int(value(6) ?? ""), let second = Int(value(7) ?? "") else { return nil }
        let period = value(4) ?? value(8)?.uppercased()
        if let period = period {
            guard (1...12).contains(hour) else { return nil }
            if hour == 12 { hour = 0 }
            if period == "PM" || period == "下午" { hour += 12 }
        }
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let components = DateComponents(timeZone: timeZone, year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              roundTrip.hour == hour, roundTrip.minute == minute, roundTrip.second == second else { return nil }
        return date
    }

    static func captureMarker(_ url: URL) -> Bool {
        let key = "com.apple.metadata:kMDItemIsScreenCapture"
        let length = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        if length > 0 && length <= 16_384 {
            var bytes = [UInt8](repeating: 0, count: length)
            let count = getxattr(url.path, key, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
            if count > 0, let property = try? PropertyListSerialization.propertyList(from: Data(bytes.prefix(count)), format: nil),
               let flag = property as? NSNumber, flag.boolValue { return true }
        }
        if let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString),
           let flag = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber { return flag.boolValue }
        return false
    }

    static func isImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source),
              let contentType = UTType(type as String) else { return false }
        return contentType.conforms(to: .image)
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hasher.update(data: bytes) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func scan(_ request: ScanRequest) throws -> ScanResult {
        let fm = FileManager.default
        let root = request.root.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey, .isPackageKey])
        guard values.isDirectory == true, values.isReadable != false else { throw CleanerError.message("此文件夹无法读取，请重新选择文件夹或允许访问。") }
        guard values.isPackage != true, !packageExtensions.contains(root.pathExtension.lowercased()) else {
            throw CleanerError.message("请选择普通文件夹；应用程序包和照片图库不能作为扫描目标。")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isPackageKey, .creationDateKey]
        var issues: [String] = []
        let candidates: [URL]
        if request.recursive {
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { url, error in
                issues.append("\(url.lastPathComponent)：\(error.localizedDescription)"); return true
            }) else { throw CleanerError.message("无法扫描此文件夹。") }
            var files: [URL] = []
            for case let url as URL in iterator {
                let properties = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey])
                if properties?.isSymbolicLink == true { continue }
                if properties?.isDirectory == true && (properties?.isPackage == true || packageExtensions.contains(url.pathExtension.lowercased())) {
                    iterator.skipDescendants(); continue
                }
                files.append(url)
            }
            candidates = files
        } else {
            candidates = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        }
        var items: [ScreenshotItem] = []; var screenshotCount = 0
        for url in candidates {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let namedDate = namedCaptureDate(url)
                guard namedDate != nil || captureMarker(url), isImage(url) else { continue }
                screenshotCount += 1
                guard let capturedAt = namedDate ?? values.creationDate else { issues.append("\(url.lastPathComponent)：没有可用的日期，已跳过。"); continue }
                guard capturedAt < request.cutoff else { continue }
                let identity = try FileIdentity.read(url)
                let contentDigest = try digest(url)
                guard identity.sameFileAndSize(as: try FileIdentity.read(url)) else { issues.append("\(url.lastPathComponent)：扫描期间发生变化，已跳过。"); continue }
                let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                let relative = String(url.path.dropFirst(rootPrefix.count))
                items.append(ScreenshotItem(url: url, relativePath: relative, capturedAt: capturedAt,
                                            dateSource: namedDate != nil ? "截屏文件名" : "文件创建日期", identity: identity, digest: contentDigest))
            } catch { issues.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        items.sort { $0.capturedAt == $1.capturedAt ? $0.relativePath < $1.relativePath : $0.capturedAt < $1.capturedAt }
        return ScanResult(request: ScanRequest(root: root, cutoff: request.cutoff, recursive: request.recursive), items: items, screenshotCount: screenshotCount, issues: issues)
    }
}

enum ScreenshotCleaner {
    static func validate(_ item: ScreenshotItem, root: URL) throws {
        let path = item.url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix), item.url.resolvingSymlinksInPath().path == path else { throw CleanerError.message("文件路径已变化，已跳过。") }
        let actual = try FileIdentity.read(item.url)
        guard actual.sameFileAndSize(as: item.identity), try ScreenshotScanner.digest(item.url) == item.digest else {
            throw CleanerError.message("文件自预览后发生变化，已跳过。请重新扫描。")
        }
        let namedDate = ScreenshotScanner.namedCaptureDate(item.url)
        var freshURL = item.url
        freshURL.removeAllCachedResourceValues()
        let fileCreationDate = try freshURL.resourceValues(forKeys: [.creationDateKey]).creationDate
        guard namedDate != nil || ScreenshotScanner.captureMarker(item.url),
              let currentDate = namedDate ?? fileCreationDate,
              abs(currentDate.timeIntervalSince(item.capturedAt)) < 0.001 else {
            throw CleanerError.message("截屏标记或日期自预览后发生变化，已跳过。请重新扫描。")
        }
    }

    static func clean(_ items: [ScreenshotItem], request: ScanRequest, mode: CleanupMode) -> CleanupReport {
        var entries: [CleanupEntry] = []
        var seen: Set<String> = []
        for item in items where seen.insert(item.id).inserted {
            var destination: String?
            do {
                guard item.capturedAt < request.cutoff else { throw CleanerError.message("文件不符合当前时间条件，已跳过。") }
                try validate(item, root: request.root)
                switch mode {
                case .trash:
                    var trashURL: NSURL?
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashURL)
                    destination = trashURL?.path
                    guard let trash = trashURL as URL?, !FileManager.default.fileExists(atPath: item.url.path),
                          try ScreenshotScanner.digest(trash) == item.digest else { throw CleanerError.message("已执行移动，但无法完整核验。请查看废纸篓。") }
                case .permanent:
                    guard unlink(item.url.path) == 0 else { throw CleanerError.message("删除失败：\(String(cString: strerror(errno)))") }
                    guard !FileManager.default.fileExists(atPath: item.url.path) else { throw CleanerError.message("路径再次出现文件，请重新扫描。") }
                }
                entries.append(CleanupEntry(source: item.url.path, destination: destination, bytes: item.size, success: true, error: nil))
            } catch { entries.append(CleanupEntry(source: item.url.path, destination: destination, bytes: item.size, success: false, error: error.localizedDescription)) }
        }
        return CleanupReport(date: Date(), mode: mode, folder: request.root.path, cutoff: request.cutoff, entries: entries)
    }
}
