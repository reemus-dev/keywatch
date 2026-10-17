// keywatch: a live view of every key event at the HID level, with hold times.
//
// The tap is listen-only at the head of the HID tap point, so it sees events before any app or
// session-level tap (remappers, hotkey apps) can swallow or change them. A listen-only tap
// cannot alter events.
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

let usage = """
Usage: keywatch [--out <file>]

Shows every key down, key up, first autorepeat and modifier change, with hold
times, as macOS receives them from the keyboard. Ctrl-C stops it.

  --out <file>   Also save the lines, as plain text, to <file>.
                 Everything you type while it runs is saved.
  -h, --help     Show this help.
  -V, --version  Show the version.

Needs Input Monitoring for the terminal app it runs in.
"""

// MARK: Keys

struct ModifierKey {
    let label: String
    let flag: CGEventFlags
    /// The device bit for this physical key, and the one for the other side.
    let deviceBit: Int32
    let otherDeviceBit: Int32
}

let modifierKeys: [Int64: ModifierKey] = [
    Int64(kVK_Command): ModifierKey(
        label: "left ⌘", flag: .maskCommand,
        deviceBit: NX_DEVICELCMDKEYMASK, otherDeviceBit: NX_DEVICERCMDKEYMASK
    ),
    Int64(kVK_RightCommand): ModifierKey(
        label: "right ⌘", flag: .maskCommand,
        deviceBit: NX_DEVICERCMDKEYMASK, otherDeviceBit: NX_DEVICELCMDKEYMASK
    ),
    Int64(kVK_Shift): ModifierKey(
        label: "left ⇧", flag: .maskShift,
        deviceBit: NX_DEVICELSHIFTKEYMASK, otherDeviceBit: NX_DEVICERSHIFTKEYMASK
    ),
    Int64(kVK_RightShift): ModifierKey(
        label: "right ⇧", flag: .maskShift,
        deviceBit: NX_DEVICERSHIFTKEYMASK, otherDeviceBit: NX_DEVICELSHIFTKEYMASK
    ),
    Int64(kVK_Option): ModifierKey(
        label: "left ⌥", flag: .maskAlternate,
        deviceBit: NX_DEVICELALTKEYMASK, otherDeviceBit: NX_DEVICERALTKEYMASK
    ),
    Int64(kVK_RightOption): ModifierKey(
        label: "right ⌥", flag: .maskAlternate,
        deviceBit: NX_DEVICERALTKEYMASK, otherDeviceBit: NX_DEVICELALTKEYMASK
    ),
    Int64(kVK_Control): ModifierKey(
        label: "left ⌃", flag: .maskControl,
        deviceBit: NX_DEVICELCTLKEYMASK, otherDeviceBit: NX_DEVICERCTLKEYMASK
    ),
    Int64(kVK_RightControl): ModifierKey(
        label: "right ⌃", flag: .maskControl,
        deviceBit: NX_DEVICERCTLKEYMASK, otherDeviceBit: NX_DEVICELCTLKEYMASK
    ),
]

let specialKeyNames: [Int64: String] = [
    Int64(kVK_Function): "fn",
    Int64(kVK_CapsLock): "caps lock",
    Int64(kVK_Return): "Return",
    Int64(kVK_ANSI_KeypadEnter): "Enter",
    Int64(kVK_Tab): "Tab",
    Int64(kVK_Space): "Space",
    Int64(kVK_Delete): "Delete",
    Int64(kVK_ForwardDelete): "Fwd Delete",
    Int64(kVK_Escape): "Escape",
    Int64(kVK_ANSI_KeypadClear): "Clear",
    Int64(kVK_Help): "Help",
    Int64(kVK_Home): "Home",
    Int64(kVK_End): "End",
    Int64(kVK_PageUp): "Page Up",
    Int64(kVK_PageDown): "Page Down",
    Int64(kVK_LeftArrow): "←",
    Int64(kVK_RightArrow): "→",
    Int64(kVK_UpArrow): "↑",
    Int64(kVK_DownArrow): "↓",
    Int64(kVK_VolumeUp): "Volume Up",
    Int64(kVK_VolumeDown): "Volume Down",
    Int64(kVK_Mute): "Mute",
    Int64(kVK_F1): "F1", Int64(kVK_F2): "F2", Int64(kVK_F3): "F3", Int64(kVK_F4): "F4",
    Int64(kVK_F5): "F5", Int64(kVK_F6): "F6", Int64(kVK_F7): "F7", Int64(kVK_F8): "F8",
    Int64(kVK_F9): "F9", Int64(kVK_F10): "F10", Int64(kVK_F11): "F11", Int64(kVK_F12): "F12",
    Int64(kVK_F13): "F13", Int64(kVK_F14): "F14", Int64(kVK_F15): "F15", Int64(kVK_F16): "F16",
    Int64(kVK_F17): "F17", Int64(kVK_F18): "F18", Int64(kVK_F19): "F19", Int64(kVK_F20): "F20",
]

/// The character the current layout types for the key with no modifiers.
func layoutCharacter(_ keyCode: Int64) -> String? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else {
        return nil
    }

    let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
    var deadKeyState: UInt32 = 0
    var characters = [UniChar](repeating: 0, count: 4)
    var length = 0
    let status = layoutData.withUnsafeBytes { bytes in
        UCKeyTranslate(
            bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )
    }
    guard status == noErr, length > 0 else {
        return nil
    }

    let text = String(utf16CodeUnits: characters, count: length)
    let isPrintable = text.unicodeScalars.allSatisfy { scalar in
        !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.whitespaces.contains(scalar)
    }
    return isPrintable ? text : nil
}

func keyName(_ keyCode: Int64) -> String {
    modifierKeys[keyCode]?.label ?? specialKeyNames[keyCode] ?? layoutCharacter(keyCode) ?? "key"
}

/// Whether a modifier's flags-changed event pressed or released it. The side-specific device bit
/// decides when the event carries any for that modifier. Posted events often carry none, so the
/// generic flag decides then.
func isModifierDown(_ modifier: ModifierKey, flags: CGEventFlags) -> Bool {
    let ownBit = UInt64(modifier.deviceBit)
    let otherBit = UInt64(modifier.otherDeviceBit)
    if flags.rawValue & (ownBit | otherBit) != 0 {
        return flags.rawValue & ownBit != 0
    }
    return flags.contains(modifier.flag)
}

var processNames: [pid_t: String] = [:]

/// The process that posted the event, or nil when it came from a keyboard.
func poster(_ event: CGEvent) -> String? {
    let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
    if pid == 0 {
        return nil
    }
    if processNames[pid] == nil {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        processNames[pid] = length > 0 ? String(cString: buffer) : "?"
    }
    return "\(processNames[pid] ?? "?") (\(pid))"
}

// MARK: Rendering

/// Colors and live status only on a terminal. Pipes and --out get plain text.
let isTerminal = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

enum Style: String {
    case plain = ""
    case bold = "1"
    case dim = "2"
    case green = "32"
    case red = "31"
    case yellow = "33"
    case blue = "34"
    case cyan = "1;36"
    case boldGreen = "1;32"
}

struct Segment {
    let text: String
    let style: Style
}

func seg(_ text: String, _ style: Style = .plain) -> Segment {
    Segment(text: text, style: style)
}

/// Pads a column to `width` characters.
func column(_ segments: [Segment], _ width: Int) -> [Segment] {
    let used = segments.reduce(0) { $0 + $1.text.count }
    return segments + [seg(String(repeating: " ", count: max(0, width - used)))]
}

func render(_ segments: [Segment], styled: Bool, maxWidth: Int = .max) -> String {
    var result = ""
    var used = 0
    for segment in segments {
        let text = String(segment.text.prefix(max(0, maxWidth - used)))
        used += text.count
        if styled, segment.style != .plain, !text.isEmpty {
            result += "\u{1B}[\(segment.style.rawValue)m\(text)\u{1B}[0m"
        } else {
            result += text
        }
    }
    return result
}

func terminalWidth() -> Int {
    var size = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
        return Int(size.ws_col)
    }
    return 120
}

var outputFile: FileHandle?

func writeOut(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

/// Prints a log line above the live status line, and saves it.
func emit(_ segments: [Segment]) {
    let plain = render(segments, styled: false)
    outputFile?.write(Data((plain + "\n").utf8))
    if isTerminal {
        writeOut("\r\u{1B}[2K" + render(segments, styled: true) + "\n")
        drawStatus()
    } else {
        writeOut(plain + "\n")
    }
}

// MARK: Events

/// One press in progress, from its down to its up.
struct Press {
    let name: String
    let downAt: TimeInterval
    var repeats = 0
}

enum Kind: String {
    case down, up, `repeat`, on, off, flags

    var segment: Segment {
        switch self {
        case .down: seg("▼ down", .green)
        case .up: seg("▲ up", .red)
        case .repeat: seg("↻ repeat", .yellow)
        case .on: seg("● on", .green)
        case .off: seg("○ off", .red)
        case .flags: seg("· flags", .dim)
        }
    }
}

var presses: [Int64: Press] = [:]
var lastEventAt: TimeInterval?
var eventCount = 0

let clockFormatter = DateFormatter()
clockFormatter.dateFormat = "HH:mm:ss.SSS"

/// Times come from the tap callback, not CGEvent timestamps. Keyboard events stamp mach ticks
/// (125/3 ns on Apple silicon) and posted events stamp nanoseconds, so no one unit reads both.
/// A listen-only tap runs within a millisecond of the event.
func now() -> TimeInterval {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

func milliseconds(_ seconds: TimeInterval) -> Int {
    Int((seconds * 1000).rounded())
}

func formatGap(_ seconds: TimeInterval) -> String {
    seconds < 10 ? "+\(milliseconds(seconds))" : String(format: "+%.0fs", seconds)
}

func modifierSegments(_ flags: CGEventFlags) -> [Segment] {
    let symbols: [(String, CGEventFlags)] = [
        ("⌃", .maskControl), ("⌥", .maskAlternate), ("⇧", .maskShift), ("⌘", .maskCommand),
    ]
    var segments = symbols.map { flags.contains($0.1) ? seg($0.0, .cyan) : seg("·", .dim) }
    segments.append(flags.contains(.maskSecondaryFn) ? seg("fn", .cyan) : seg("  "))
    return segments
}

/// "1693 ms ████████████████ 48 repeats": one bar block per 100 ms, up to 2 s.
func heldSegments(_ press: Press, at time: TimeInterval) -> [Segment] {
    let held = milliseconds(time - press.downAt)
    var segments = [
        seg(String(format: "%5d ms ", held), .bold),
        seg(String(repeating: "█", count: max(1, min(20, held / 100))), .blue),
    ]
    if held > 2000 {
        segments.append(seg("▸", .blue))
    }
    if press.repeats > 0 {
        segments.append(seg(" \(press.repeats) repeat\(press.repeats == 1 ? "" : "s")", .yellow))
    }
    return segments
}

func logEvent(_ event: CGEvent, at time: TimeInterval, kind: Kind, detail: [Segment] = []) {
    if let lastEventAt, time - lastEventAt >= 2 {
        emit([seg(String(format: "┄┄ %.1f s idle ┄┄", time - lastEventAt), .dim)])
    }
    var gap = ""
    if let lastEventAt {
        gap = formatGap(time - lastEventAt)
    }
    lastEventAt = time
    eventCount += 1

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    var segments = [seg(clockFormatter.string(from: Date()), .dim), seg("  ")]
    segments += column([seg(String(repeating: " ", count: max(0, 6 - gap.count)) + gap, .dim)], 8)
    segments += column([seg(keyName(keyCode), .bold), seg(" \(keyCode)", .dim)], 16)
    segments += column([kind.segment], 10)
    segments += column(modifierSegments(event.flags), 8)
    segments += detail
    if let poster = poster(event) {
        segments += [seg("  "), seg("⚠ posted by \(poster)", .yellow)]
    }
    emit(segments)
}

func logUp(_ event: CGEvent, at time: TimeInterval) {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    var detail: [Segment] = []
    if let press = presses.removeValue(forKey: keyCode) {
        detail = heldSegments(press, at: time)
    }
    logEvent(event, at: time, kind: .up, detail: detail)
}

func logDown(_ event: CGEvent, at time: TimeInterval) {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    presses[keyCode] = Press(name: keyName(keyCode), downAt: time)
    logEvent(event, at: time, kind: .down)
}

func handle(_ type: CGEventType, _ event: CGEvent) {
    let time = now()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    switch type {
    case .keyDown:
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            logDown(event, at: time)
            return
        }
        // Only the first autorepeat of a press is logged. The up line counts them all.
        var press = presses[keyCode] ?? Press(name: keyName(keyCode), downAt: time)
        press.repeats += 1
        presses[keyCode] = press
        if press.repeats == 1 {
            logEvent(event, at: time, kind: .repeat)
        } else {
            drawStatus()
        }
    case .keyUp:
        logUp(event, at: time)
    case .flagsChanged:
        if keyCode == Int64(kVK_CapsLock) {
            logEvent(event, at: time, kind: flags.contains(.maskAlphaShift) ? .on : .off)
        } else if let modifier = modifierKeys[keyCode] {
            isModifierDown(modifier, flags: flags) ? logDown(event, at: time) : logUp(event, at: time)
        } else if keyCode == Int64(kVK_Function) {
            flags.contains(.maskSecondaryFn) ? logDown(event, at: time) : logUp(event, at: time)
        } else {
            logEvent(event, at: time, kind: .flags)
        }
    default:
        break
    }
}

// MARK: Live status

var isStopping = false

/// The bottom line: every key held right now, with its live hold time.
func drawStatus() {
    guard isTerminal, !isStopping else {
        return
    }
    var segments: [Segment]
    if presses.isEmpty {
        segments = [seg("○ nothing held", .dim)]
    } else {
        segments = [seg("● holding", .boldGreen)]
        let time = now()
        for press in presses.values.sorted(by: { $0.downAt < $1.downAt }) {
            segments += [
                seg("   "),
                seg(press.name, .bold),
                seg(String(format: " %.1fs", time - press.downAt)),
            ]
            if press.repeats > 0 {
                segments.append(seg(" ↻\(press.repeats)", .yellow))
            }
        }
    }
    writeOut("\r\u{1B}[2K" + render(segments, styled: true, maxWidth: terminalWidth() - 1))
}

// MARK: Main

var outputPath: String?
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument == "--out", !arguments.isEmpty {
        outputPath = arguments.removeFirst()
    } else if argument == "-h" || argument == "--help" {
        print(usage)
        exit(0)
    } else if argument == "-V" || argument == "--version" {
        print("keywatch \(version)")
        exit(0)
    } else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let permissionMessage = """
keywatch needs Input Monitoring for the app it runs in, such as your terminal.
Turn it on in System Settings › Privacy & Security › Input Monitoring, then run keywatch again.
"""
if !CGPreflightListenEventAccess() {
    CGRequestListenEventAccess()
    fail(permissionMessage)
}

var eventTap: CFMachPort?
let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        emit([seg("⚠ macOS disabled the tap and keywatch re-enabled it. Events in between are missing.", .yellow)])
        return Unmanaged.passUnretained(event)
    }
    handle(type, event)
    return Unmanaged.passUnretained(event)
}

let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    | CGEventMask(1 << CGEventType.keyUp.rawValue)
    | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
eventTap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: eventMask,
    callback: callback,
    userInfo: nil
)
guard let eventTap else {
    fail(permissionMessage)
}

if let outputPath {
    let outputURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: outputPath, contents: nil)
    guard let file = FileHandle(forWritingAtPath: outputPath) else {
        fail("keywatch cannot write \(outputPath)")
    }
    outputFile = file
}

// Keys typed into this terminal would echo between the lines, so echo is off while it runs.
var savedTerminal = termios()
let ownsTerminalInput = isatty(STDIN_FILENO) == 1 && tcgetattr(STDIN_FILENO, &savedTerminal) == 0
if ownsTerminalInput {
    var quiet = savedTerminal
    quiet.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
}

// Ctrl-C restores the terminal, drops what was typed into it, prints a summary and exits 0.
let stopSources = [SIGINT, SIGTERM].map { signalNumber in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        isStopping = true
        if isTerminal {
            writeOut("\r\u{1B}[2K\u{1B}[?25h")
        }
        if ownsTerminalInput {
            tcflush(STDIN_FILENO, TCIFLUSH)
            tcsetattr(STDIN_FILENO, TCSANOW, &savedTerminal)
        }
        emit([])
        emit([seg("Stopped after \(eventCount) events.", .dim)])
        exit(0)
    }
    source.resume()
    return source
}

// Redraws the live hold times while keys are down.
let statusTimer = DispatchSource.makeTimerSource(queue: .main)
statusTimer.schedule(deadline: .now(), repeating: .milliseconds(100))
statusTimer.setEventHandler {
    if !presses.isEmpty {
        drawStatus()
    }
}
statusTimer.resume()

if isTerminal {
    writeOut("\u{1B}[?25l")
}
emit([seg("keywatch", .cyan), seg("  key events at the HID level, before any app sees them", .dim)])
var saving = "not saving, pass --out <file> to save"
if let outputPath {
    saving = "saving to \(outputPath)"
}
emit([seg("Ctrl-C to stop · \(saving)", .dim)])
emit([])
var header = [seg("time", .dim), seg(String(repeating: " ", count: 10))]
header += column([seg("   gap", .dim)], 8)
header += column([seg("key", .dim)], 16)
header += column([seg("event", .dim)], 10)
header += column([seg("⌃⌥⇧⌘", .dim)], 8)
header.append(seg("held", .dim))
emit(header)

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)
CFRunLoopRun()
