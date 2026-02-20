import AppKit
import Foundation
import SwiftUI

private let appTitle = "Serial Screen"
private let minimumWindowContentSize = NSSize(width: 940, height: 620)
private let defaultWindowContentSize = NSSize(width: 960, height: 620)

private func makeDescriptorCloseHandler(for descriptor: Int32) -> () -> Void {
    return {
        close(descriptor)
    }
}

private final class WeakSerialManagerBox: @unchecked Sendable {
    weak var manager: SerialManager?

    init(_ manager: SerialManager) {
        self.manager = manager
    }
}

private func makeReadSourceEventHandler(
    for descriptor: Int32,
    manager: SerialManager
) -> () -> Void {
    let managerBox = WeakSerialManagerBox(manager)

    return {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let text = String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
                Task { @MainActor [managerBox] in
                    guard let manager = managerBox.manager else { return }
                    manager.processIncomingChunk(text, from: descriptor)
                }
            } else if count == 0 {
                return
            } else {
                let readError = errno
                if readError == EAGAIN || readError == EWOULDBLOCK {
                    return
                }
                let errorMessage = String(cString: strerror(readError))
                Task { @MainActor [managerBox] in
                    guard let manager = managerBox.manager else { return }
                    manager.processReadError(errorMessage, from: descriptor)
                }
                return
            }
        }
    }
}

@MainActor
final class SerialManager: ObservableObject {
    @Published var ports: [String] = []
    @Published var selectedPort: String = ""
    @Published var selectedBaud: Int = 9600
    @Published var outgoingText: String = ""
    @Published var appendNewline: Bool = true

    @Published var isConnected: Bool = false
    @Published var statusText: String = "Disconnected"
    @Published var logText: String = ""
    @Published var logVersion: Int = 0
    @Published var showTimestamps: Bool = true
    @Published var autoScroll: Bool = true

    let baudRates: [Int] = [9600, 19200, 38400, 57600, 115200, 230400]

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private let ioQueue = DispatchQueue(label: "serialscreen.io")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var isRXLineStart: Bool = true
    private var commandHistory: [String] = []
    private var historyCursor: Int?
    private var draftBeforeHistory: String = ""

    func refreshPorts() {
        let fileManager = FileManager.default
        let devURL = URL(fileURLWithPath: "/dev", isDirectory: true)

        guard let items = try? fileManager.contentsOfDirectory(
            at: devURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            appendSystem("Failed to scan /dev")
            return
        }

        let allDeviceNames = items
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("cu.") || $0.hasPrefix("tty.") }

        // Deduplicate paired cu./tty. devices by physical port name, prefer cu.*.
        var deduplicatedByBase: [String: String] = [:]
        for name in allDeviceNames {
            let baseName: String
            let isCU: Bool
            if name.hasPrefix("cu.") {
                baseName = String(name.dropFirst(3))
                isCU = true
            } else {
                baseName = String(name.dropFirst(4))
                isCU = false
            }

            let fullPath = "/dev/\(name)"
            if let existing = deduplicatedByBase[baseName] {
                if !existing.hasPrefix("/dev/cu.") && isCU {
                    deduplicatedByBase[baseName] = fullPath
                }
            } else {
                deduplicatedByBase[baseName] = fullPath
            }
        }

        let scanned = deduplicatedByBase.keys
            .sorted()
            .compactMap { deduplicatedByBase[$0] }

        ports = scanned
        if !selectedPort.isEmpty, scanned.contains(selectedPort) {
            // keep selected
        } else {
            selectedPort = scanned.first ?? ""
        }

        appendSystem("Ports updated: \(scanned.isEmpty ? "none found" : scanned.joined(separator: ", "))")
    }

    func toggleConnection() {
        isConnected ? disconnect() : connect()
    }

    func connect() {
        guard !selectedPort.isEmpty else {
            appendSystem("Select a serial port first")
            return
        }

        do {
            try openSerialPort(path: selectedPort, baud: selectedBaud)
            isConnected = true
            statusText = "Connected"
            appendSystem("Connected to \(selectedPort) @ \(selectedBaud)")
        } catch {
            appendSystem("Connection error: \(error.localizedDescription)")
            disconnect()
        }
    }

    func disconnect() {
        let source = readSource
        let descriptor = fd
        readSource = nil
        fd = -1

        if let source {
            source.cancel()
        } else if descriptor >= 0 {
            close(descriptor)
        }

        if isConnected {
            appendSystem("Disconnected")
        }

        isConnected = false
        statusText = "Disconnected"
    }

    func clearLog() {
        logText = ""
        isRXLineStart = true
    }

    func saveLog() {
        let panel = NSSavePanel()
        panel.title = "Save Serial Log"
        panel.nameFieldStringValue = "serial_log.txt"
        panel.allowedContentTypes = [.plainText]

        if panel.runModal() == .OK, let url = panel.url {
            try? logText.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func send() {
        guard isConnected, fd >= 0 else {
            appendSystem("Connect to a serial port first")
            return
        }

        guard !outgoingText.isEmpty else { return }
        let command = outgoingText

        var payload = outgoingText
        if appendNewline {
            payload += "\n"
        }

        payload.utf8CString.withUnsafeBufferPointer { cString in
            _ = cString.baseAddress.map { ptr in
                write(fd, ptr, cString.count - 1)
            }
        }

        rememberCommand(command)
        appendLogEntry(payload.trimmingCharacters(in: .newlines))
        outgoingText = ""
    }

    func historyUp() {
        guard !commandHistory.isEmpty else { return }
        if historyCursor == nil {
            draftBeforeHistory = outgoingText
            historyCursor = commandHistory.count - 1
        } else if let cursor = historyCursor, cursor > 0 {
            historyCursor = cursor - 1
        }

        if let cursor = historyCursor {
            outgoingText = commandHistory[cursor]
        }
    }

    func historyDown() {
        guard !commandHistory.isEmpty else { return }
        guard let cursor = historyCursor else { return }

        if cursor < commandHistory.count - 1 {
            let next = cursor + 1
            historyCursor = next
            outgoingText = commandHistory[next]
        } else {
            historyCursor = nil
            outgoingText = draftBeforeHistory
        }
    }

    func setTimestampsEnabled(_ enabled: Bool) {
        guard showTimestamps != enabled else { return }
        showTimestamps = enabled
    }

    deinit {
        let source = readSource
        let descriptor = fd
        readSource = nil
        fd = -1

        if let source {
            source.cancel()
        } else if descriptor >= 0 {
            close(descriptor)
        }
    }

    private func openSerialPort(path: String, baud: Int) throws {
        disconnect()

        let flags = O_RDWR | O_NOCTTY | O_NONBLOCK
        let openedFD = open(path, flags)
        guard openedFD >= 0 else {
            throw NSError(domain: "Serial", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open \(path)"])
        }
        var shouldCloseOnFailure = true
        defer {
            if shouldCloseOnFailure {
                close(openedFD)
            }
        }

        var options = termios()
        guard tcgetattr(openedFD, &options) == 0 else {
            throw NSError(domain: "Serial", code: 2, userInfo: [NSLocalizedDescriptionKey: "tcgetattr failed"])
        }

        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)

        guard let speed = speedForBaud(baud) else {
            throw NSError(domain: "Serial", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported baud: \(baud)"])
        }

        guard cfsetispeed(&options, speed) == 0, cfsetospeed(&options, speed) == 0 else {
            throw NSError(domain: "Serial", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to set baud rate"])
        }

        guard tcsetattr(openedFD, TCSANOW, &options) == 0 else {
            throw NSError(domain: "Serial", code: 5, userInfo: [NSLocalizedDescriptionKey: "tcsetattr failed"])
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: openedFD, queue: ioQueue)
        source.setEventHandler(handler: makeReadSourceEventHandler(for: openedFD, manager: self))
        source.setCancelHandler(handler: makeDescriptorCloseHandler(for: openedFD))
        source.resume()

        fd = openedFD
        readSource = source
        shouldCloseOnFailure = false
    }

    fileprivate func processIncomingChunk(_ text: String, from descriptor: Int32) {
        guard fd == descriptor else { return }
        appendIncomingChunk(text)
    }

    fileprivate func processReadError(_ errorMessage: String, from descriptor: Int32) {
        guard fd == descriptor else { return }
        disconnect()
    }

    private func speedForBaud(_ baud: Int) -> speed_t? {
        switch baud {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default: return nil
        }
    }

    private func appendRaw(_ value: String) {
        logText += value
        logVersion &+= 1
    }

    private func appendLogEntry(_ text: String) {
        if !logText.isEmpty, !logText.hasSuffix("\n"), !logText.hasSuffix("\r") {
            appendRaw("\n")
        }
        appendRaw("\(timestampPrefix())\(text)\n")
        isRXLineStart = true
    }

    private func timestampPrefix() -> String {
        guard showTimestamps else { return "" }
        return "[\(Self.timestampFormatter.string(from: Date()))] "
    }

    private func appendIncomingChunk(_ value: String) {
        guard !value.isEmpty else { return }

        guard showTimestamps else {
            appendRaw(value)
            if let lastChar = value.last {
                isRXLineStart = lastChar == "\n" || lastChar == "\r"
            }
            return
        }

        var output = ""
        output.reserveCapacity(value.count + 16)
        for char in value {
            if isRXLineStart {
                output += timestampPrefix()
                isRXLineStart = false
            }
            output.append(char)
            if char == "\n" || char == "\r" {
                isRXLineStart = true
            }
        }
        appendRaw(output)
    }

    private func appendSystem(_ value: String) {}

    private func rememberCommand(_ command: String) {
        guard !command.isEmpty else { return }
        if commandHistory.last != command {
            commandHistory.append(command)
        }
        if commandHistory.count > 500 {
            commandHistory.removeFirst(commandHistory.count - 500)
        }
        historyCursor = nil
        draftBeforeHistory = ""
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            configure(window)
        }
    }

    private func configure(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.contentMinSize = minimumWindowContentSize
    }
}

struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 7)
    }
}

extension View {
    func glassCard() -> some View {
        modifier(GlassCard())
    }
}

private struct HistoryTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: HistoryTextField

        init(parent: HistoryTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrowUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrowDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .default
        textField.drawsBackground = true
        textField.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 0.8)
        textField.textColor = .white
        textField.font = NSFont.systemFont(ofSize: 15)
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }
}

struct ContentView: View {
    @StateObject private var serial = SerialManager()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(white: 0.20).opacity(0.76),
                    Color(white: 0.12).opacity(0.70)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Text(appTitle)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                }

                topControls
                    .glassCard()

                logBlock
                    .glassCard()

                sendBlock
                    .glassCard()
            }
            .padding(16)
        }
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
        .onAppear {
            serial.refreshPorts()
        }
    }

    private var topControls: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 10) {
                Text("Port")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 42, alignment: .leading)

                Picker("Port", selection: $serial.selectedPort) {
                    ForEach(serial.ports, id: \.self) { port in
                        Text(port).tag(port)
                    }
                }
                .labelsHidden()
                .disabled(serial.isConnected)

                Button("Refresh") {
                    serial.refreshPorts()
                }
                .buttonStyle(.bordered)
            }
            .frame(minWidth: 380, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Text("Baud")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 48, alignment: .leading)

                Picker("Baud", selection: $serial.selectedBaud) {
                    ForEach(serial.baudRates, id: \.self) { baud in
                        Text("\(baud)").tag(baud)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(serial.isConnected)
            }
            .frame(width: 188, alignment: .leading)
            .padding(.leading, 44)

            Button(serial.isConnected ? "Disconnect" : "Connect") {
                serial.toggleConnection()
            }
            .buttonStyle(.borderedProminent)
            .tint(serial.isConnected ? .orange : .green)
            .font(.system(size: 15, weight: .semibold))
            .frame(height: 34)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var logBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Monitor")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("Auto-scroll", isOn: $serial.autoScroll)
                    .toggleStyle(.checkbox)
                Toggle("Time", isOn: Binding(
                    get: { serial.showTimestamps },
                    set: { serial.setTimestampsEnabled($0) }
                ))
                .toggleStyle(.checkbox)

                Button("Clear Log") {
                    serial.clearLog()
                }
                .buttonStyle(.bordered)

                Button("Save Log") {
                    serial.saveLog()
                }
                .buttonStyle(.bordered)
            }

            ScrollViewReader { proxy in
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("log-top-marker")

                            Text(serial.logText)
                                .font(.system(size: 14, weight: .regular, design: .monospaced))
                                .lineSpacing(-2)
                                .foregroundStyle(Color.white.opacity(0.95))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                                .padding(10)

                            Spacer(minLength: 0)

                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("log-bottom-marker")
                        }
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo("log-top-marker", anchor: .topLeading)
                        }
                    }
                    .onChange(of: serial.logVersion) { _ in
                        guard serial.autoScroll else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo("log-bottom-marker", anchor: .bottomLeading)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sendBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send")
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                HistoryTextField(
                    text: $serial.outgoingText,
                    placeholder: "Type text to send",
                    onSubmit: { serial.send() },
                    onArrowUp: { serial.historyUp() },
                    onArrowDown: { serial.historyDown() }
                )
                .frame(height: 30)

                Toggle("Append newline", isOn: $serial.appendNewline)
                    .toggleStyle(.checkbox)

                Button("Send") {
                    serial.send()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
    }
}

@main
struct SerialScreenApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(
                    minWidth: minimumWindowContentSize.width,
                    idealWidth: defaultWindowContentSize.width,
                    minHeight: minimumWindowContentSize.height,
                    idealHeight: defaultWindowContentSize.height
                )
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
    }
}
