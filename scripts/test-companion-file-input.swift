import AppKit

@main struct FileInputChecks {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("file-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lesson.txt"), data = Data("日本語 and coffee ☕".utf8)
        try data.write(to: file)
        let result = try CompanionFileInput.urls([file]).read()
        precondition(result.count == 1 && result[0]["name"] == "lesson.txt" && result[0]["data"] == data.base64EncodedString(), "native selection reads exact bytes, not a path payload")
        for input in [CompanionFileInput.urls(Array(repeating: file, count: 5)), .urls([root]), .image(Data(count: 8388609), "Pasted image.png")] {
            do { _ = try input.read(); preconditionFailure("invalid native file input was accepted") } catch {}
        }
        let link = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do { _ = try CompanionFileInput.urls([link]).read(); preconditionFailure("symbolic link was read") } catch {}
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(file.path, forType: .string)
        precondition(CompanionFileInput.pasted(pasteboard) == nil, "plain text is never treated as a file path")
        pasteboard.clearContents(); pasteboard.writeObjects([file as NSURL])
        let pasted = try CompanionFileInput.pasted(pasteboard)!.read()
        precondition(pasted == result, "native file paste uses the same bounded reader")
        pasteboard.clearContents(); pasteboard.setData(Data([1, 2, 3]), forType: .png)
        let pastedImage = try CompanionFileInput.pasted(pasteboard)!.read()
        precondition(pastedImage[0]["data"] == "AQID", "explicit PNG paste stays data until the server checks its format")
        let editor = CompanionTextView(); var accepted = false
        editor.isEditable = true; editor.onFiles = { _ in accepted = true }; editor.string = "Keep draft"
        precondition(editor.acceptFiles(pasteboard) && accepted && editor.string == "Keep draft", "file paste never replaces native text")
        print("Native picker, file and image paste, bounds, link, and draft checks passed")
    }
}
