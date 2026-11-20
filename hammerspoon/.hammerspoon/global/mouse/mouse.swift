import CoreGraphics
import Darwin
import Foundation
import IOKit.hid
import IOKit.hidsystem

struct ScrollError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// Resolve private APIs explicitly so an unavailable symbol produces an error.
final class HIDAccess {
    typealias CopyEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    typealias SenderID = @convention(c) (CFTypeRef) -> UInt64
    typealias SetFloat = @convention(c) (CFTypeRef, UInt32, Double) -> Void
    typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
    typealias ServiceBlock = @convention(block) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, IOHIDServiceClient?
    ) -> Void
    // IOKit retains these blocks. An optional block parameter imports as escaping.
    typealias RegisterServiceBlock = @convention(c) (
        IOHIDEventSystemClient, ServiceBlock?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void
    typealias UnregisterServiceBlock = @convention(c) (IOHIDEventSystemClient) -> Void
    typealias ScheduleClient = @convention(c) (IOHIDEventSystemClient, DispatchQueue) -> Void
    typealias RegisterRemovalBlock = @convention(c) (
        IOHIDServiceClient, ServiceBlock?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void

    let copyEvent: CopyEvent
    let senderID: SenderID
    let setFloat: SetFloat
    let createClient: CreateClient
    let registerService: RegisterServiceBlock
    let unregisterService: UnregisterServiceBlock
    let scheduleClient: ScheduleClient
    let unscheduleClient: ScheduleClient
    let registerRemoval: RegisterRemovalBlock
    private let symbols: UnsafeMutableRawPointer

    init() throws {
        guard let symbols = dlopen(nil, RTLD_LAZY) else {
            throw ScrollError("Could not load system symbols.")
        }
        func load<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(symbols, name) else {
                throw ScrollError("Required system API is unavailable: \(name)")
            }
            return unsafeBitCast(address, to: type)
        }
        do {
            copyEvent = try load("CGEventCopyIOHIDEvent", as: CopyEvent.self)
            senderID = try load("IOHIDEventGetSenderID", as: SenderID.self)
            setFloat = try load("IOHIDEventSetFloatValue", as: SetFloat.self)
            createClient = try load("IOHIDEventSystemClientCreate", as: CreateClient.self)
            registerService = try load("IOHIDEventSystemClientRegisterDeviceMatchingBlock", as: RegisterServiceBlock.self)
            unregisterService = try load("IOHIDEventSystemClientUnregisterDeviceMatchingBlock", as: UnregisterServiceBlock.self)
            scheduleClient = try load("IOHIDEventSystemClientScheduleWithDispatchQueue", as: ScheduleClient.self)
            unscheduleClient = try load("IOHIDEventSystemClientUnscheduleFromDispatchQueue", as: ScheduleClient.self)
            registerRemoval = try load("IOHIDServiceClientRegisterRemovalBlock", as: RegisterRemovalBlock.self)
        } catch {
            dlclose(symbols)
            throw error
        }
        self.symbols = symbols
    }

    deinit { dlclose(symbols) }
}

final class MouseScroll {
    private let amount: Double
    private let hid: HIDAccess
    private var deviceClient: IOHIDEventSystemClient?
    private var mice: [UInt64: IOHIDServiceClient] = [:]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var signals: [DispatchSourceSignal] = []
    private var parentMonitor: DispatchSourceProcess?

    init(amount: Double) throws {
        self.amount = amount
        hid = try HIDAccess()
    }

    private func startDeviceObservation() throws {
        guard let client = hid.createClient(kCFAllocatorDefault)?.takeRetainedValue() else {
            throw ScrollError("Could not create the HID device observer.")
        }
        deviceClient = client
        hid.registerService(client, { [weak self] _, _, service in
            if let service { self?.addService(service) }
        }, nil, nil)
        // Service callbacks and the scroll event tap both run on the main thread.
        hid.scheduleClient(client, .main)
        if let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] {
            for service in services { addService(service) }
        }
    }

    private func addService(_ service: IOHIDServiceClient) {
        guard deviceClient != nil,
              let senderID = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value,
              senderID != 0, mice[senderID] == nil, isMouse(service) else { return }

        mice[senderID] = service
        hid.registerRemoval(service, { [weak self] _, _, removedService in
            guard let self, let removedService, self.mice[senderID] === removedService else { return }
            self.mice.removeValue(forKey: senderID)
        }, nil, nil)
    }

    private func isMouse(_ service: IOHIDServiceClient) -> Bool {
        let vendor = (IOHIDServiceClientCopyProperty(service, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let product = (IOHIDServiceClientCopyProperty(service, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        // Magic Mouse can also expose touch usages; classify it before touchpads.
        if let vendor, let product, [0x004C, 0x05AC].contains(vendor),
           [0x0269, 0x030D].contains(product) {
            return true
        }
        if IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_Digitizer), UInt32(kHIDUsage_Dig_TouchPad)) != 0 {
            return false
        }
        return IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let delta = continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        guard delta.isFinite, delta != 0,
              let hidEvent = hid.copyEvent(event)?.takeRetainedValue(),
              mice[hid.senderID(hidEvent)] != nil else {
            return Unmanaged.passUnretained(event)
        }

        let direction: Double = delta > 0 ? 1 : -1
        // Clear accelerated HID data, then set the CG deltas as LinearMouse does.
        hid.setFloat(hidEvent, (6 << 16) | 1, 0) // IOHID scroll event, vertical field.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1,
                                   value: Int64(direction) * max(1, Int64(amount / 10)))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: direction * amount)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: direction * amount / 10)
        return Unmanaged.passUnretained(event)
    }

    func start() throws {
        let parentPID = getppid()
        guard parentPID > 1 else { throw ScrollError("The parent process is no longer running.") }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MouseScroll>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }, userInfo: context
        ) else {
            throw ScrollError("Could not create the scroll event tap. Allow Hammerspoon in System Settings > Privacy & Security > Accessibility.")
        }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            stop()
            throw ScrollError("Could not create the scroll event run loop source.")
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        for code in [SIGTERM, SIGINT, SIGHUP] {
            signal(code, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: code, queue: .main)
            signalSource.setEventHandler { [weak self] in self?.stop() }
            signalSource.resume()
            signals.append(signalSource)
        }
        let monitor = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
        monitor.setEventHandler { [weak self] in self?.stop() }
        monitor.resume()
        parentMonitor = monitor
        guard getppid() == parentPID else {
            stop()
            throw ScrollError("The parent process exited during startup.")
        }
        do {
            try startDeviceObservation()
        } catch {
            stop()
            throw error
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        parentMonitor?.cancel()
        parentMonitor = nil
        for signalSource in signals { signalSource.cancel() }
        signals.removeAll()
        if let client = deviceClient {
            deviceClient = nil
            hid.unregisterService(client)
            hid.unscheduleClient(client, .main)
        }
        mice.removeAll()
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

guard CommandLine.arguments.count == 2, let amount = Int(CommandLine.arguments[1]),
      (1...10000).contains(amount) else {
    FileHandle.standardError.write(Data("Usage: MouseScroll <scroll-amount: 1...10000>\n".utf8))
    exit(2)
}

do {
    let controller = try MouseScroll(amount: Double(amount))
    try controller.start()
    withExtendedLifetime(controller) { CFRunLoopRun() }
    controller.stop()
} catch {
    FileHandle.standardError.write(Data("Mouse scrolling failed: \(error)\n".utf8))
    exit(1)
}
