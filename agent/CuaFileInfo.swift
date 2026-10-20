import Foundation
import ImageIO
import PDFKit
import CryptoKit
import Darwin

func reply(_ value: [String: Any], code: Int32) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: value) { FileHandle.standardOutput.write(data) }
    exit(code)
}
func reject(_ message: String) -> Never { reply(["ok": false, "error": message], code: 1) }

// This process reads one inherited descriptor. It has no desktop or input commands.
var cpuLimit = rlimit(rlim_cur: 3, rlim_max: 4)
guard setrlimit(RLIMIT_CPU, &cpuLimit) == 0 else { reject("File resource limits are unavailable. Rebuild the app.") }
let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
let started = ProcessInfo.processInfo.systemUptime
watchdog.schedule(deadline: .now(), repeating: .milliseconds(50))
watchdog.setEventHandler {
    var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    if result != KERN_SUCCESS || info.resident_size > 384 * 1024 * 1024 || ProcessInfo.processInfo.systemUptime - started > 4 {
        reject("This file exceeds the check's resource limit. Use a smaller or simpler file.")
    }
}
watchdog.resume()
guard CommandLine.arguments.count == 3 else { reject("Pass a supported file type and SHA-256.") }
let type = CommandLine.arguments[1], expected = CommandLine.arguments[2]
var st = stat()
guard fstat(3, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
      st.st_mode & 0o777 == 0o600, st.st_size > 0, st.st_size <= 8 * 1024 * 1024 else { reject("Use a private file up to 8 MiB.") }
guard let bytes = try? FileHandle(fileDescriptor: 3, closeOnDealloc: false).read(upToCount: 8 * 1024 * 1024 + 1), bytes.count == st.st_size else { reject("The file could not be read. Add it again.") }
let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
guard digest == expected else { reject("The file changed during the check. Add it again.") }
var result: [String: Any] = ["ok": true, "type": type, "sha256": digest]
if type == "application/pdf" {
    guard bytes.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: bytes) else { reject("The PDF could not be read. Export a new PDF and add it again.") }
    guard !pdf.isEncrypted, !pdf.isLocked else { reject("Encrypted PDFs are not supported. Export an unencrypted copy and add it again.") }
    guard pdf.pageCount > 0, pdf.pageCount <= 100 else { reject("Use a PDF with 1 to 100 pages.") }
    for index in 0..<pdf.pageCount {
        guard let page = pdf.page(at: index) else { reject("A PDF page could not be read. Export a new copy.") }
        let bounds = page.bounds(for: .mediaBox)
        guard [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height].allSatisfy({ $0.isFinite }), bounds.width > 0, bounds.height > 0, bounds.width <= 14400, bounds.height <= 14400 else { reject("The PDF has unsupported page dimensions. Export a normal-size copy.") }
    }
    result["pages"] = pdf.pageCount
} else if type == "image/png" || type == "image/jpeg" {
    guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetType(source) as String? == (type == "image/png" ? "public.png" : "public.jpeg"),
          CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 40000000 else { reject("Use one readable PNG or JPEG image up to 40 megapixels and 16,384 pixels per side.") }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
          image.width == width, image.height == height, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { reject("The image could not be read completely. Export a new PNG or JPEG.") }
    result["width"] = width; result["height"] = height
} else { reject("Choose a PNG, JPEG, or PDF.") }
reply(result, code: 0)
