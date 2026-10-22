// The short tag on a file's card, "PDF" or "DOCX": from the file's name when it has a
// plain extension, else from its type when that is short, else just "FILE".

import Foundation

enum FileTypeLabel {
    static func label(name: String?, mime: String) -> String {
        if let name, let dot = name.lastIndex(of: "."), dot > name.startIndex {
            let fileExtension = name[name.index(after: dot)...]
            if isPlain(fileExtension, longest: 5) {
                return fileExtension.uppercased()
            }
        }
        let subtype = mime.split(separator: "/").last ?? ""
        return isPlain(subtype, longest: 4) ? subtype.uppercased() : "FILE"
    }

    private static func isPlain(_ text: Substring, longest: Int) -> Bool {
        (1...longest).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
