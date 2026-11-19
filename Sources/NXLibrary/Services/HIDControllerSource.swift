import Foundation
import GameController
import IOKit.hid
import IOKit.hidsystem
import OSLog
import NXLibraryCore

// HID discovery follows NX2Apple's GamepadHID.swift (MIT; see NOTICE).
final class HIDControllerSource: ControllerSource {
    var onEvent: ((ControllerSourceEvent) -> Void)?
    private var manager: IOHIDManager?
    private var devices: [ObjectIdentifier: IOHIDDevice] = [:]
    private var reader: Reader?
    private static let options = IOOptionBits(kIOHIDOptionsTypeNone)
    private static let mode = CFRunLoopMode.commonModes.rawValue
    private static let log = Logger(subsystem: "local.nxlibrary", category: "controllers")

    func start() {
        guard manager == nil else { return }
        // Discover without opening every matching device; only the selected pad is read.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        let matches = [kHIDUsage_GD_GamePad, kHIDUsage_GD_Joystick].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HIDControllerSource>.fromOpaque(context).takeUnretainedValue().found(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDControllerSource>.fromOpaque(context).takeUnretainedValue().removed(device)
        }, context)
        self.manager = manager
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), Self.mode)
        let result = IOHIDManagerOpen(manager, Self.options)
        if result != kIOReturnSuccess {
            Self.log.error("Cannot open HID controller manager (\(result))")
            stop()
        }
    }

    func stop() {
        let ids = Array(devices.keys)
        tearDown()
        for id in ids { onEvent?(.disconnected(id)) }
    }

    deinit { tearDown() }

    private func tearDown() {
        closeReader()
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), Self.mode)
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerClose(manager, Self.options)
        }
        manager = nil
        devices.removeAll()
    }

    private func found(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        guard manager != nil, devices[id] == nil else { return }
        func property(_ key: String) -> CFTypeRef? { IOHIDDeviceGetProperty(device, key as CFString) }
        guard (property(kIOHIDGCSyntheticDeviceKey) as? NSNumber)?.boolValue != true,
              (property(kIOHIDVirtualHIDevice) as? NSNumber)?.boolValue != true,
              (property(kIOHIDTransportKey) as? String)?.caseInsensitiveCompare("Virtual") != .orderedSame,
              let elements = IOHIDDeviceCopyMatchingElements(device, nil, Self.options) as? [IOHIDElement],
              elements.contains(where: {
                  IOHIDElementGetUsagePage($0) == UInt32(kHIDPage_Button) && IOHIDElementGetReportID($0) == 0x3f
              }) else { return }
        // Matching both usages can return two references to the same registry device.
        if let entry = Self.registryID(device),
           devices.values.contains(where: { Self.registryID($0) == entry }) { return }
        devices[id] = device
        let identity = ControllerIdentity(id: id, name: property(kIOHIDProductKey) as? String, brand: .nintendoSwitch)
        onEvent?(.connected(identity, claimedByGC: GCController.supportsHIDDevice(device)))
    }

    private func removed(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        guard devices.removeValue(forKey: id) != nil else { return }
        if reader?.device === device { closeReader() }
        onEvent?(.disconnected(id))
    }

    @discardableResult
    func select(_ id: ObjectIdentifier?) -> Bool {
        if id == reader.map({ ObjectIdentifier($0.device) }) { return true }
        closeReader()
        guard let id else { return true }
        guard let device = devices[id] else { return false }
        let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
        guard (11...65_536).contains(size) else {
            Self.log.error("Invalid HID controller report buffer size (\(size))")
            return false
        }
        let result = IOHIDDeviceOpen(device, Self.options) // Shared with the game engine; never seize.
        guard result == kIOReturnSuccess else {
            Self.log.error("Cannot open HID controller (\(result))")
            return false
        }
        let reader = Reader(device: device, capacity: size)
        self.reader = reader
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reader.buffer, size, { context, result, _, _, reportID, bytes, count in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HIDControllerSource>.fromOpaque(context).takeUnretainedValue().read(reportID, bytes, count)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), Self.mode)
        return true
    }

    private func closeReader() {
        guard let reader else { return }
        self.reader = nil
        IOHIDDeviceRegisterInputReportCallback(reader.device, reader.buffer, reader.capacity, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(reader.device, CFRunLoopGetMain(), Self.mode)
        IOHIDDeviceClose(reader.device, Self.options)
    }

    private func read(_ reportID: UInt32, _ bytes: UnsafePointer<UInt8>, _ count: Int) {
        guard let reader, (0...reader.capacity).contains(count),
              let state = reader.decoder.decode(reportID: reportID,
                                                bytes: UnsafeBufferPointer(start: bytes, count: count)) else { return }
        let changes = state.changes(from: reader.state)
        reader.state = state
        let id = ObjectIdentifier(reader.device)
        for change in changes { onEvent?(.input(id, change)) }
    }

    private static func registryID(_ device: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        let result = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return result == kIOReturnSuccess ? id : nil
    }

    private final class Reader {
        let device: IOHIDDevice
        let capacity: Int
        let buffer: UnsafeMutablePointer<UInt8>
        var decoder = NintendoHIDInput()
        var state = ControllerInputState()

        init(device: IOHIDDevice, capacity: Int) {
            self.device = device
            self.capacity = capacity
            buffer = .allocate(capacity: capacity)
        }

        deinit { buffer.deallocate() }
    }
}
