import Foundation

public enum SerialError: Error, CustomStringConvertible {
    case openFailed(path: String, errno: Int32)
    case configureFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case timeout(partial: String)

    public var description: String {
        switch self {
        case .openFailed(let path, let e): "Could not open \(path): \(String(cString: strerror(e)))"
        case .configureFailed(let e): "Could not configure serial port: \(String(cString: strerror(e)))"
        case .writeFailed(let e): "Write failed: \(String(cString: strerror(e)))"
        case .readFailed(let e): "Read failed: \(String(cString: strerror(e)))"
        case .timeout(let partial):
            partial.isEmpty ? "Timed out waiting for the radio" : "Timed out waiting for the radio (got \"\(partial)\")"
        }
    }
}

/// A byte transport to the radio. The serial port is one implementation;
/// tests use a scripted fake.
public protocol RadioTransport: AnyObject {
    func write(_ bytes: [UInt8]) throws
    /// Reads until `terminator` is seen (terminator not included in the result).
    func readUntil(_ terminator: UInt8, timeout: TimeInterval) throws -> [UInt8]
    /// Reads exactly `count` bytes.
    func read(count: Int, timeout: TimeInterval) throws -> [UInt8]
    /// Changes the line speed. Only meaningful on a real serial port.
    func setBaudRate(_ baud: Int) throws
}

extension RadioTransport {
    public func setBaudRate(_ baud: Int) throws {}

    /// Discards anything that arrives within `duration`.
    public func drain(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while deadline.timeIntervalSinceNow > 0 {
            _ = try? read(count: 1, timeout: deadline.timeIntervalSinceNow)
        }
    }
}

/// A POSIX serial port. Works for both the USB virtual COM port and the
/// Bluetooth serial device macOS creates for a paired radio.
public final class SerialPort: RadioTransport {
    private let fd: Int32
    private var pending: [UInt8] = []

    public init(path: String, baud: speed_t = 9600) throws {
        // O_NONBLOCK so open() doesn't wait for carrier detect.
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialError.openFailed(path: path, errno: errno) }
        self.fd = fd

        var tio = termios()
        guard tcgetattr(fd, &tio) == 0 else {
            let e = errno; close(fd); throw SerialError.configureFailed(errno: e)
        }
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CS8 | CREAD | CLOCAL)
        cfsetspeed(&tio, baud)
        guard tcsetattr(fd, TCSANOW, &tio) == 0 else {
            let e = errno; close(fd); throw SerialError.configureFailed(errno: e)
        }
    }

    deinit { close(fd) }

    public func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { usleep(1000); continue }
                throw SerialError.writeFailed(errno: errno)
            }
            offset += n
        }
    }

    public func setBaudRate(_ baud: Int) throws {
        var tio = termios()
        guard tcgetattr(fd, &tio) == 0 else { throw SerialError.configureFailed(errno: errno) }
        cfsetspeed(&tio, speed_t(baud))
        guard tcsetattr(fd, TCSADRAIN, &tio) == 0 else { throw SerialError.configureFailed(errno: errno) }
    }

    public func readUntil(_ terminator: UInt8, timeout: TimeInterval) throws -> [UInt8] {
        try fill(timeout: timeout) { pending in
            guard let i = pending.firstIndex(of: terminator) else { return nil }
            let line = Array(pending[..<i])
            pending.removeFirst(i + 1)
            return line
        }
    }

    public func read(count: Int, timeout: TimeInterval) throws -> [UInt8] {
        try fill(timeout: timeout) { pending in
            guard pending.count >= count else { return nil }
            let bytes = Array(pending[..<count])
            pending.removeFirst(count)
            return bytes
        }
    }

    /// Reads from the port until `take` can satisfy itself from the buffer.
    private func fill(timeout: TimeInterval, take: (inout [UInt8]) -> [UInt8]?) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            if let result = take(&pending) { return result }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                let partial = String(decoding: pending, as: UTF8.self)
                pending.removeAll()
                throw SerialError.timeout(partial: partial)
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 0.25) * 1000))
            if ready < 0 && errno != EINTR { throw SerialError.readFailed(errno: errno) }
            if ready > 0 {
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n > 0 {
                    pending.append(contentsOf: chunk[..<n])
                } else if n < 0 && errno != EAGAIN && errno != EINTR {
                    throw SerialError.readFailed(errno: errno)
                }
            }
        }
    }

    /// USB serial devices that could be a TH-D74 (it enumerates as a USB modem).
    public static func usbCandidatePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }
}
