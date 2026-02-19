import AppKit
import Foundation
import SwiftUI

private let appTitle = "Serial Screen"
private let minimumWindowContentSize = NSSize(width: 1040, height: 620)

@MainActor
final class SerialManager: ObservableObject {
    @Published var ports: [String] = []
    @Published var selectedPort: String = ""
    @Published var selectedBaud: Int = 115200
    @Published var outgoingText: String = ""
    @Published var appendNewline: Bool = true

    @Published var isConnected: Bool = false
    @Published var statusText: String = "Disconnected"
    @Published var logText: String = "[System] Ready. Select a serial port and press Connect.\n"
    @Published var logVersion: Int = 0

    let baudRates: [Int] = [9600, 19200, 38400, 57600, 115200, 230400]

    private let ioQueue = DispatchQueue(label: "serialscreen.io")
    private let sourceCancelGroup = DispatchGroup()
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?

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

        let scanned = items
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("cu.") || $0.hasPrefix("tty.") }
            .map { "/dev/\($0)" }
            .sorted()

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
            _ = sourceCancelGroup.wait(timeout: .now() + .milliseconds(300))
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
        appendSystem("Log cleared")
    }

    func saveLog() {
        let panel = NSSavePanel()
        panel.title = "Save Serial Log"
        panel.nameFieldStringValue = "serial_log.txt"
        panel.allowedContentTypes = [.plainText]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try logText.write(to: url, atomically: true, encoding: .utf8)
                appendSystem("Log saved: \(url.path)")
            } catch {
                appendSystem("Save error: \(error.localizedDescription)")
            }
        }
    }

    func send() {
        guard isConnected, fd >= 0 else {
            appendSystem("Connect to a serial port first")
            return
        }

        guard !outgoingText.isEmpty else { return }

        var payload = outgoingText
        if appendNewline {
            payload += "\n"
        }

        payload.utf8CString.withUnsafeBufferPointer { cString in
            _ = cString.baseAddress.map { ptr in
                write(fd, ptr, cString.count - 1)
            }
        }

        appendRaw("\n[TX] \(payload.trimmingCharacters(in: .newlines))\n")
        outgoingText = ""
    }

    deinit {
        let source = readSource
        let descriptor = fd
        readSource = nil
        fd = -1

        if let source {
            source.cancel()
            _ = sourceCancelGroup.wait(timeout: .now() + .milliseconds(300))
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
        source.setEventHandler { [weak self] in
            self?.readAvailableBytes(from: openedFD)
        }
        let cancelGroup = sourceCancelGroup
        cancelGroup.enter()
        source.setCancelHandler {
            close(openedFD)
            cancelGroup.leave()
        }
        source.resume()

        fd = openedFD
        readSource = source
        shouldCloseOnFailure = false
    }

    nonisolated private func readAvailableBytes(from descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let text = String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
                Task { @MainActor in
                    guard self.fd == descriptor else { return }
                    self.appendRaw(text)
                }
            } else if count == 0 {
                return
            } else {
                let readError = errno
                if readError == EAGAIN || readError == EWOULDBLOCK {
                    return
                }
                let errorMessage = String(cString: strerror(readError))
                Task { @MainActor in
                    guard self.fd == descriptor else { return }
                    self.appendSystem("Read error: \(errorMessage)")
                    self.disconnect()
                }
                return
            }
        }
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

    private func appendSystem(_ value: String) {
        appendRaw("\n[System] \(value)\n")
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
            }
            .frame(minWidth: 380, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
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
            }
            .frame(width: 210, alignment: .leading)

            Button("Refresh") {
                serial.refreshPorts()
            }
            .buttonStyle(.bordered)

            Button(serial.isConnected ? "Disconnect" : "Connect") {
                serial.toggleConnection()
            }
            .buttonStyle(.borderedProminent)
            .tint(serial.isConnected ? .orange : .green)

            Text(serial.statusText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(serial.isConnected ? .green : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06), in: Capsule())
                .frame(minWidth: 150, alignment: .leading)
        }
    }

    private var logBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Monitor")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
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
                ScrollView {
                    Text(serial.logText)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("log-bottom")
                }
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .onChange(of: serial.logVersion) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
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
                TextField("Type text to send", text: $serial.outgoingText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        serial.send()
                    }

                Toggle("Append newline (\\n)", isOn: $serial.appendNewline)
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
                .frame(minWidth: minimumWindowContentSize.width, minHeight: minimumWindowContentSize.height)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
    }
}
