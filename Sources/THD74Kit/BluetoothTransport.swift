#if canImport(IOBluetooth)
import Foundation
@preconcurrency import IOBluetooth

public enum BluetoothError: Error, CustomStringConvertible {
    case noPairedRadio
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case closed

    public var description: String {
        switch self {
        case .noPairedRadio: "No paired TH-D74 found. Pair the radio in System Settings > Bluetooth first."
        case .openFailed(let r): String(format: "Could not open the Bluetooth serial channel (0x%08x). Is the radio on and in range?", r)
        case .writeFailed(let r): String(format: "Bluetooth write failed (0x%08x)", r)
        case .closed: "The radio closed the Bluetooth connection"
        }
    }
}

/// Talks to the radio's Serial Port service over an RFCOMM channel opened
/// directly with IOBluetooth. This is more reliable than the
/// `/dev/cu.TH-D74` device macOS creates, which often opens without
/// bringing up the link.
///
/// Must be created and used on a single thread that owns a run loop
/// (incoming data is delivered through that run loop).
public final class BluetoothTransport: NSObject, RadioTransport, IOBluetoothRFCOMMChannelDelegate {
    private var channel: IOBluetoothRFCOMMChannel?
    private var pending: [UInt8] = []
    private var isClosed = false
    private let device: IOBluetoothDevice
    public let deviceName: String

    /// Paired devices whose name looks like a TH-D74.
    public static func pairedRadios() -> [IOBluetoothDevice] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.filter { ($0.name ?? "").hasPrefix("TH-D74") }
    }

    /// Opens the first paired TH-D74.
    public static func openFirstPaired() throws -> BluetoothTransport {
        guard let device = pairedRadios().first else { throw BluetoothError.noPairedRadio }
        return try BluetoothTransport(opening: device)
    }

    public init(opening device: IOBluetoothDevice) throws {
        deviceName = device.name ?? "TH-D74"
        self.device = device
        super.init()

        // A baseband link left over from an earlier session (for example
        // after the radio rebooted out of programming mode) makes the radio
        // refuse the serial channel, so always start from a fresh link.
        var status: IOReturn = kIOReturnError
        for _ in 0..<3 {
            Self.dropLink(to: device)
            var opened: IOBluetoothRFCOMMChannel?
            status = device.openRFCOMMChannelSync(&opened, withChannelID: Self.serialChannelID(of: device), delegate: self)
            if status == kIOReturnSuccess, let opened {
                channel = opened
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        throw BluetoothError.openFailed(status)
    }

    deinit { close() }

    /// Closes the serial channel and the underlying link. Safe to call twice.
    public func close() {
        guard let channel else { return }
        self.channel = nil
        channel.setDelegate(nil)
        channel.close()
        Self.dropLink(to: device)
    }

    private static func dropLink(to device: IOBluetoothDevice) {
        guard device.isConnected() else { return }
        device.closeConnection()
        let deadline = Date().addingTimeInterval(5)
        while device.isConnected() && deadline.timeIntervalSinceNow > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        // The radio needs a moment before it will accept a new link.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    }

    /// The RFCOMM channel of the "Serial Port" service (channel 2 on the
    /// TH-D74; channel 1 is the headset service).
    private static func serialChannelID(of device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID {
        let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        for record in records where record.getServiceName() == "Serial Port" {
            var id: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&id) == kIOReturnSuccess { return id }
        }
        return 2
    }

    public func write(_ bytes: [UInt8]) throws {
        guard let channel, !isClosed else { throw BluetoothError.closed }
        // A single write may not exceed the channel's MTU.
        let mtu = max(1, Int(channel.getMTU()))
        var offset = 0
        while offset < bytes.count {
            var chunk = Array(bytes[offset..<min(offset + mtu, bytes.count)])
            let status = channel.writeSync(&chunk, length: UInt16(chunk.count))
            guard status == kIOReturnSuccess else { throw BluetoothError.writeFailed(status) }
            offset += chunk.count
        }
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

    private func fill(timeout: TimeInterval, take: (inout [UInt8]) -> [UInt8]?) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let result = take(&pending) { return result }
            if isClosed { throw BluetoothError.closed }
            guard deadline.timeIntervalSinceNow > 0 else {
                let partial = String(decoding: pending, as: UTF8.self)
                pending.removeAll()
                throw SerialError.timeout(partial: partial)
            }
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        pending.append(contentsOf: UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
    }

    public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        isClosed = true
    }
}
#endif
