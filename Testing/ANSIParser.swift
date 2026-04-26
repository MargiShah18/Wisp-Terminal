import Foundation

@MainActor
protocol ANSIParserDelegate: AnyObject {
    func parser(_ parser: ANSIParser, didReceiveText text: String)
    func parser(_ parser: ANSIParser, didReceiveControl byte: UInt8)
    func parser(_ parser: ANSIParser, didReceiveCSI params: [Int], intermediates: String, final: Character, isPrivate: Bool, privatePrefix: Character?)
    func parser(_ parser: ANSIParser, didReceiveOSC string: String)
    func parser(_ parser: ANSIParser, didReceiveESC final: Character, intermediates: String)
}

@MainActor
final class ANSIParser {
    weak var delegate: ANSIParserDelegate?

    private enum State {
        case ground
        case escape
        case csiEntry
        case csiParam
        case csiIntermediate
        case osc
        case oscEsc
        case escIntermediate
        case dcs
        case dcsEsc
    }

    private var state: State = .ground
    private var paramBuffer: [UInt8] = []
    private var intermediateBuffer: [UInt8] = []
    private var oscBuffer: [UInt8] = []
    private var dcsBuffer: [UInt8] = []
    private var utf8Acc: [UInt8] = []
    private var utf8Remaining: Int = 0
    private var textBuffer: String = ""

    func reset() {
        state = .ground
        paramBuffer.removeAll(keepingCapacity: true)
        intermediateBuffer.removeAll(keepingCapacity: true)
        oscBuffer.removeAll(keepingCapacity: true)
        dcsBuffer.removeAll(keepingCapacity: true)
        utf8Acc.removeAll(keepingCapacity: true)
        utf8Remaining = 0
        textBuffer.removeAll(keepingCapacity: true)
    }

    func feed(_ data: Data) {
        for byte in data { consume(byte) }
        flushText()
    }

    private func consume(_ b: UInt8) {
        switch state {
        case .ground:           handleGround(b)
        case .escape:           handleEscape(b)
        case .csiEntry:         handleCSIEntry(b)
        case .csiParam:         handleCSIParam(b)
        case .csiIntermediate:  handleCSIIntermediate(b)
        case .osc:              handleOSC(b)
        case .oscEsc:           handleOSCEsc(b)
        case .escIntermediate:  handleEscIntermediate(b)
        case .dcs:              handleDCS(b)
        case .dcsEsc:           handleDCSEsc(b)
        }
    }

    private func flushText() {
        if !textBuffer.isEmpty {
            delegate?.parser(self, didReceiveText: textBuffer)
            textBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func handleGround(_ b: UInt8) {
        if b == 0x1B {
            flushText()
            state = .escape
            return
        }
        if b < 0x20 || b == 0x7F {
            flushText()
            delegate?.parser(self, didReceiveControl: b)
            return
        }
        if utf8Remaining > 0 {
            utf8Acc.append(b)
            utf8Remaining -= 1
            if utf8Remaining == 0 {
                if let s = String(bytes: utf8Acc, encoding: .utf8) {
                    textBuffer.append(s)
                } else {
                    textBuffer.append("\u{FFFD}")
                }
                utf8Acc.removeAll(keepingCapacity: true)
            }
            return
        }
        if b < 0x80 {
            textBuffer.append(Character(Unicode.Scalar(b)))
            return
        }
        utf8Acc.append(b)
        if b & 0xE0 == 0xC0 {
            utf8Remaining = 1
        } else if b & 0xF0 == 0xE0 {
            utf8Remaining = 2
        } else if b & 0xF8 == 0xF0 {
            utf8Remaining = 3
        } else {
            utf8Acc.removeAll(keepingCapacity: true)
            textBuffer.append("\u{FFFD}")
        }
    }

    private func handleEscape(_ b: UInt8) {
        switch b {
        case 0x5B: // [
            state = .csiEntry
            paramBuffer.removeAll(keepingCapacity: true)
            intermediateBuffer.removeAll(keepingCapacity: true)
        case 0x5D: // ]
            state = .osc
            oscBuffer.removeAll(keepingCapacity: true)
        case 0x50: // P (DCS)
            state = .dcs
            dcsBuffer.removeAll(keepingCapacity: true)
        case 0x20...0x2F:
            intermediateBuffer.append(b)
            state = .escIntermediate
        case 0x30...0x7E:
            delegate?.parser(self, didReceiveESC: Character(Unicode.Scalar(b)), intermediates: stringFrom(intermediateBuffer))
            state = .ground
            intermediateBuffer.removeAll(keepingCapacity: true)
        case 0x1B:
            state = .escape
        default:
            state = .ground
        }
    }

    private func handleEscIntermediate(_ b: UInt8) {
        switch b {
        case 0x20...0x2F:
            intermediateBuffer.append(b)
        case 0x30...0x7E:
            delegate?.parser(self, didReceiveESC: Character(Unicode.Scalar(b)), intermediates: stringFrom(intermediateBuffer))
            state = .ground
            intermediateBuffer.removeAll(keepingCapacity: true)
        default:
            state = .ground
        }
    }

    private func handleCSIEntry(_ b: UInt8) {
        switch b {
        case 0x30...0x39, 0x3A, 0x3B, 0x3C...0x3F:
            paramBuffer.append(b)
            state = .csiParam
        case 0x20...0x2F:
            intermediateBuffer.append(b)
            state = .csiIntermediate
        case 0x40...0x7E:
            dispatchCSI(final: b)
            state = .ground
        default:
            state = .ground
        }
    }

    private func handleCSIParam(_ b: UInt8) {
        switch b {
        case 0x30...0x39, 0x3A, 0x3B, 0x3C...0x3F:
            paramBuffer.append(b)
        case 0x20...0x2F:
            intermediateBuffer.append(b)
            state = .csiIntermediate
        case 0x40...0x7E:
            dispatchCSI(final: b)
            state = .ground
        default:
            state = .ground
        }
    }

    private func handleCSIIntermediate(_ b: UInt8) {
        switch b {
        case 0x20...0x2F:
            intermediateBuffer.append(b)
        case 0x40...0x7E:
            dispatchCSI(final: b)
            state = .ground
        default:
            state = .ground
        }
    }

    private func dispatchCSI(final: UInt8) {
        var paramString = stringFrom(paramBuffer)
        var privatePrefix: Character?
        if let first = paramString.first, "<=>?".contains(first) {
            privatePrefix = first
            paramString.removeFirst()
        }
        let parts = paramString.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
        var params: [Int] = []
        for p in parts {
            if let n = Int(p) {
                params.append(n)
            } else {
                params.append(0)
            }
        }
        delegate?.parser(
            self,
            didReceiveCSI: params,
            intermediates: stringFrom(intermediateBuffer),
            final: Character(Unicode.Scalar(final)),
            isPrivate: privatePrefix != nil,
            privatePrefix: privatePrefix
        )
        paramBuffer.removeAll(keepingCapacity: true)
        intermediateBuffer.removeAll(keepingCapacity: true)
    }

    private func handleOSC(_ b: UInt8) {
        if b == 0x07 {
            let s = String(bytes: oscBuffer, encoding: .utf8) ?? ""
            delegate?.parser(self, didReceiveOSC: s)
            oscBuffer.removeAll(keepingCapacity: true)
            state = .ground
        } else if b == 0x1B {
            state = .oscEsc
        } else {
            oscBuffer.append(b)
            if oscBuffer.count > 8192 {
                oscBuffer.removeAll(keepingCapacity: true)
                state = .ground
            }
        }
    }

    private func handleOSCEsc(_ b: UInt8) {
        if b == 0x5C {
            let s = String(bytes: oscBuffer, encoding: .utf8) ?? ""
            delegate?.parser(self, didReceiveOSC: s)
            oscBuffer.removeAll(keepingCapacity: true)
            state = .ground
        } else {
            oscBuffer.append(0x1B)
            oscBuffer.append(b)
            state = .osc
        }
    }

    private func handleDCS(_ b: UInt8) {
        if b == 0x1B {
            state = .dcsEsc
        } else {
            dcsBuffer.append(b)
            if dcsBuffer.count > 8192 {
                dcsBuffer.removeAll(keepingCapacity: true)
                state = .ground
            }
        }
    }

    private func handleDCSEsc(_ b: UInt8) {
        if b == 0x5C {
            dcsBuffer.removeAll(keepingCapacity: true)
            state = .ground
        } else {
            dcsBuffer.append(0x1B)
            dcsBuffer.append(b)
            state = .dcs
        }
    }

    private func stringFrom(_ buf: [UInt8]) -> String {
        String(bytes: buf, encoding: .ascii) ?? ""
    }
}
