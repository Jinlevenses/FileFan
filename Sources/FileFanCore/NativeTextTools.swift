import CoreFoundation
import Foundation

public enum NativeTextTools {
    public static let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
    public static func exportUTF8(_ source: URL, directory: URL, encoding: String.Encoding) throws -> URL {
        let input = try LocalFileTools.validated([source])[0]
        guard (try input.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 16_000_000 else { throw ConversionBackendError.invalidInput("Text tools accept files up to 16 MB.") }
        let text = try String(contentsOf: input, encoding: encoding)
        return try LocalFileTools.write(Data(text.utf8), source: input, directory: directory, suffix: "utf8", extension: source.pathExtension)
    }
}
