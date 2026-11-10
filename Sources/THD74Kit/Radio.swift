import Foundation

public enum RadioError: Error, CustomStringConvertible {
    case unexpectedReply(command: String, reply: String)
    case rejected(command: String)
    case wrongModel(String)

    public var description: String {
        switch self {
        case .unexpectedReply(let c, let r): "Unexpected reply to \"\(c)\": \"\(r)\""
        case .rejected(let c): "The radio rejected \"\(c)\""
        case .wrongModel(let m): "Connected device identifies as \"\(m)\", not a TH-D74"
        }
    }
}

/// Live (non-clone-mode) command interface to a TH-D74.
public final class Radio {
    public static let channelRange = 0...999

    let transport: RadioTransport
    private let timeout: TimeInterval

    public init(transport: RadioTransport, timeout: TimeInterval = 2.0) {
        self.transport = transport
        self.timeout = timeout
    }

    /// Opens the serial device and confirms a TH-D74 is answering.
    public static func connect(path: String) throws -> Radio {
        try connect(transport: try SerialPort(path: path))
    }

    /// Confirms a TH-D74 is answering on an already-open transport.
    public static func connect(transport: RadioTransport) throws -> Radio {
        let radio = Radio(transport: transport)
        try radio.synchronize()
        let model = try radio.model()
        guard model.hasPrefix("TH-D74") else { throw RadioError.wrongModel(model) }
        return radio
    }

    /// Sends an empty line so any half-received junk on the radio side is
    /// terminated, and discards whatever comes back.
    public func synchronize() throws {
        try transport.write([0x0D])
        _ = try? transport.readUntil(0x0D, timeout: 0.5)
    }

    /// Sends one command and returns the reply line, without the trailing CR.
    @discardableResult
    public func raw(_ command: String) throws -> String {
        try transport.write(Array(command.utf8) + [0x0D])
        let bytes = try transport.readUntil(0x0D, timeout: timeout)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Sends a query and returns the payload after the echoed command name.
    private func query(_ command: String) throws -> String {
        let reply = try raw(command)
        let name = command.split(separator: " ").first.map(String.init) ?? command
        if reply == "?" || reply == "N" { throw RadioError.rejected(command: command) }
        guard reply.hasPrefix(name + " ") else {
            throw RadioError.unexpectedReply(command: command, reply: reply)
        }
        return String(reply.dropFirst(name.count + 1))
    }

    public func model() throws -> String { try query("ID") }
    public func firmwareVersion() throws -> String { try query("FV") }

    /// Reads one memory channel. Returns nil if the channel is empty.
    public func readChannel(_ number: Int) throws -> Channel? {
        let command = String(format: "ME %03d", number)
        let reply = try raw(command)
        if reply == "N" { return nil }
        guard reply.hasPrefix("ME ") else {
            throw RadioError.unexpectedReply(command: command, reply: reply)
        }
        return try Channel(meReply: reply)
    }
}
