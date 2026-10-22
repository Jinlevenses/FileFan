import Foundation

/// CEA-608 CC1 pop-on captions at 30000/1001 fps, with an explicit representability boundary.
enum SCCWriter {
    struct Cue { let startMilliseconds: Int, endMilliseconds: Int, lines: [String] }
    static func write(srt: Data) throws -> Data {
        guard srt.count <= 16 * 1024 * 1024, let text = String(data: srt, encoding: .utf8) else {
            throw ConversionBackendError.invalidInput("SCC 변환은 16MB 이하 UTF-8 자막을 처리합니다.")
        }
        let cues = try parseSRT(text)
        var events: [Int: String] = [:]
        var previousEnd = -1
        func put(_ words: [String], at frame: Int) throws {
            guard frame >= 0 else { throw ConversionBackendError.invalidInput("SCC는 자막 표시 전 로딩 시간이 필요합니다. 첫 자막 앞의 여유 시간을 늘리세요.") }
            for (offset, word) in words.enumerated() {
                guard events.updateValue(word, forKey: frame + offset) == nil else {
                    throw ConversionBackendError.invalidInput("SCC 전송 대역폭보다 자막 간격이 짧습니다. 자막 사이 간격을 늘리세요.")
                }
            }
        }
        for (cueIndex, cue) in cues.enumerated() {
            guard cue.lines.count <= 15, cue.lines.allSatisfy({ $0.count <= 32 }), cue.endMilliseconds > cue.startMilliseconds,
                  cue.startMilliseconds >= previousEnd, cue.endMilliseconds < 24 * 60 * 60 * 1000 else {
                throw ConversionBackendError.invalidInput("SCC는 겹치지 않는 24시간 이내 자막, 한 줄 32자와 최대 15줄을 지원합니다.")
            }
            previousEnd = cue.endMilliseconds
            var words = [pair(0x14, 0x20), pair(0x14, 0x20), pair(0x14, 0x2E), pair(0x14, 0x2E)]
            for (index, line) in cue.lines.enumerated() {
                let row = 16 - cue.lines.count + index
                let preamble = rowPreamble(row)
                words += [pair(preamble.0, preamble.1), pair(preamble.0, preamble.1)]
                words += try encode(line)
            }
            words += [pair(0x14, 0x2F), pair(0x14, 0x2F)]
            let start = frame(cue.startMilliseconds), end = frame(cue.endMilliseconds)
            guard end > start + 1 else { throw ConversionBackendError.invalidInput("SCC 자막 표시 시간은 두 프레임 이상이어야 합니다.") }
            try put(words, at: start - (words.count - 2))
            let continuous = cueIndex + 1 < cues.count && frame(cues[cueIndex + 1].startMilliseconds) == end
            if !continuous { try put([pair(0x14, 0x2C), pair(0x14, 0x2C)], at: end) }
        }
        var output = "Scenarist_SCC V1.0\n\n"
        let sorted = events.keys.sorted()
        var index = 0
        while index < sorted.count {
            let first = sorted[index]
            var words = [events[first]!]
            index += 1
            while index < sorted.count, sorted[index] == first + words.count {
                words.append(events[sorted[index]]!); index += 1
            }
            output += timecode(first) + "\t" + words.joined(separator: " ") + "\n\n"
        }
        return Data(output.utf8)
    }

    private static func parseSRT(_ text: String) throws -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let timing = try NSRegularExpression(pattern: "^(\\d{2}):([0-5]\\d):([0-5]\\d)[,.](\\d{3}) --> (\\d{2}):([0-5]\\d):([0-5]\\d)[,.](\\d{3})$")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") where !block.isEmpty {
            let lines = block.components(separatedBy: "\n")
            guard let position = lines.firstIndex(where: { $0.contains(" --> ") }), position <= 1,
                  let match = timing.firstMatch(in: lines[position], range: NSRange(lines[position].startIndex..., in: lines[position])), position + 1 < lines.count else {
                throw ConversionBackendError.invalidInput("SCC 변환용 SRT 자막의 시간 또는 본문을 읽을 수 없습니다.")
            }
            func milliseconds(_ start: Int) -> Int {
                let values = (start..<(start + 4)).map { Int((lines[position] as NSString).substring(with: match.range(at: $0)))! }
                return ((values[0] * 60 + values[1]) * 60 + values[2]) * 1000 + values[3]
            }
            let body = Array(lines[(position + 1)...])
            guard body.allSatisfy({ !$0.contains("<") && !$0.contains(">") && !$0.contains("{\\") }) else {
                throw ConversionBackendError.invalidInput("SCC 쓰기는 일반 텍스트를 지원합니다. 자막 스타일 태그를 제거한 후 변환하세요.")
            }
            cues.append(Cue(startMilliseconds: milliseconds(1), endMilliseconds: milliseconds(5), lines: body))
        }
        guard !cues.isEmpty else { throw ConversionBackendError.invalidInput("자막이 비어 있습니다.") }
        return cues
    }

    private static func encode(_ text: String) throws -> [String] {
        let substituted: [UInt8: Character] = [0x2A: "á", 0x5C: "é", 0x5E: "í", 0x5F: "ó", 0x60: "ú", 0x7B: "ç", 0x7C: "÷", 0x7D: "Ñ", 0x7E: "ñ", 0x7F: "█"]
        let special = Array("®°½¿™¢£♪à èâêîôû")
        let extended1 = Array("ÁÉÓÚÜü‘¡*’—©℠•“”ÀÂÇÈÊËëÎÏïÔÙùÛ«»")
        let extended2 = Array("ÃãÍÌìÒòÕõ{}\\^_|~ÄäÖöß¥¤│ÅåØø┌┐└┘")
        var words: [String] = [], pending: UInt8?
        func flush() { if let byte = pending { words.append(pair(byte, 0)); pending = nil } }
        for character in text {
            let basic = substituted.first { $0.value == character }?.key ?? character.asciiValue.flatMap { (0x20...0x7F).contains($0) && substituted[$0] == nil ? $0 : nil }
            if let basic {
                if let first = pending { words.append(pair(first, basic)); pending = nil } else { pending = basic }
            } else if let index = special.firstIndex(of: character) {
                flush(); words += [pair(0x11, UInt8(0x30 + index)), pair(0, 0)]
            } else if let index = extended1.firstIndex(of: character) {
                flush(); words += [pair(0x20, 0), pair(0x12, UInt8(0x20 + index))]
            } else if let index = extended2.firstIndex(of: character) {
                flush(); words += [pair(0x20, 0), pair(0x13, UInt8(0x20 + index))]
            } else {
                throw ConversionBackendError.invalidInput("SCC/CEA-608로 표현할 수 없는 문자가 있습니다: \(character). 한글 등은 SRT/VTT/ASS를 사용하세요.")
            }
        }
        flush()
        return words
    }

    static func parity(_ byte: UInt8) -> UInt8 { byte.nonzeroBitCount.isMultiple(of: 2) ? byte | 0x80 : byte }
    private static func pair(_ a: UInt8, _ b: UInt8) -> String { String(format: "%02x%02x", parity(a), parity(b)) }
    static func frame(_ milliseconds: Int) -> Int { Int((Double(milliseconds) * 30_000 / 1_001_000).rounded()) }
    static func timecode(_ frame: Int) -> String { String(format: "%02d:%02d:%02d:%02d", frame / 108_000, frame / 1800 % 60, frame / 30 % 60, frame % 30) }
    private static func rowPreamble(_ row: Int) -> (UInt8, UInt8) {
        let rows: [(UInt8, UInt8)] = [(0x11, 0x40), (0x11, 0x60), (0x12, 0x40), (0x12, 0x60), (0x15, 0x40), (0x15, 0x60), (0x16, 0x40), (0x16, 0x60), (0x17, 0x40), (0x17, 0x60), (0x10, 0x40), (0x13, 0x40), (0x13, 0x60), (0x14, 0x40), (0x14, 0x60)]
        return rows[row - 1]
    }
}
