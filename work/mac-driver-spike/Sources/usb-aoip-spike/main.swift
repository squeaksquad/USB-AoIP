// usb-aoip-spike: the host-driver spike's user-space tool (SPIKE_PLAN.md).
//
//   usb-aoip-spike list            the gadget's IOKit services, no open (no root needed)
//   sudo usb-aoip-spike stream [S]  capture, stream both directions for S seconds (10) from one
//                                  bus frame, impulses on channel 1, and report the round trip
//   sudo usb-aoip-spike probe      capture the device from the class driver, open both
//                                  streaming interfaces at alt 1, print their endpoints
//                                  and the bus frame number, then let the device go
//
// Capture (IOUSBHostObjectInitOptionsDeviceCapture) terminates the class driver's
// clients; as root it needs no entitlement (IOUSBHostDefinitions.h). On destroy the
// device is reset and the class driver matches it again, so USB-AoIP comes back.
// The device is found by VID/PID (0x1d6b:0x0104 until pid.codes assigns one) and
// checked by its product string, USB-AoIP.

import Foundation
import IOKit
import IOUSBHost

let vendorID = 0x1d6b
let productID = 0x0104
let productName = "USB-AoIP"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("usb-aoip-spike: \(message)\n".utf8))
    exit(1)
}

func registryString(_ service: io_service_t, _ key: String) -> String? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
}

func registryInt(_ service: io_service_t, _ key: String) -> Int? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Int
}

func services(matching dictionary: CFMutableDictionary) -> [io_service_t] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var found: [io_service_t] = []
    while case let service = IOIteratorNext(iterator), service != 0 { found.append(service) }
    return found
}

func deviceService() -> io_service_t {
    let matching = IOUSBHostDevice.__createMatchingDictionary(
        withVendorID: NSNumber(value: vendorID), productID: NSNumber(value: productID), bcdDevice: nil,
        deviceClass: nil, deviceSubclass: nil, deviceProtocol: nil, speed: nil, productIDArray: nil)
        .takeRetainedValue()
    let found = services(matching: matching)
    guard let service = found.first else { fail(String(format: "no USB device %04x:%04x", vendorID, productID)) }
    let name = registryString(service, "USB Product Name") ?? registryString(service, "kUSBProductString") ?? "?"
    guard name == productName else { fail("device %04x:%04x is \"\(name)\", not \(productName)") }
    return service
}

// Interface services of the device, its IOUSBHostInterface children: (number, alternate, class, subclass, service).
func interfaceServices() -> [(number: Int, alternate: Int, cls: Int, subclass: Int, service: io_service_t)] {
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(deviceService(), kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var children: [io_service_t] = []
    while case let child = IOIteratorNext(iterator), child != 0 {
        if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 { children.append(child) } else { IOObjectRelease(child) }
    }
    return children.map { service in
        (registryInt(service, "bInterfaceNumber") ?? -1, registryInt(service, "bAlternateSetting") ?? 0,
         registryInt(service, "bInterfaceClass") ?? -1, registryInt(service, "bInterfaceSubClass") ?? -1, service)
    }.sorted { $0.number < $1.number }
}

func describeEndpoints(of interface: IOUSBHostInterface) {
    guard let descriptor = Optional(interface.interfaceDescriptor) else { print("    no current descriptor"); return }
    let configuration = interface.configurationDescriptor
    var endpoint = IOUSBGetNextEndpointDescriptor(configuration, descriptor, nil)
    while let current = endpoint {
        let address = current.pointee.bEndpointAddress
        let attributes = current.pointee.bmAttributes
        let maxPacket = UInt16(littleEndian: current.pointee.wMaxPacketSize)
        let kinds = ["control", "isochronous", "bulk", "interrupt"]
        let syncs = ["none", "async", "adaptive", "sync"]
        let usages = ["data", "feedback", "implicit", "reserved"]
        print(String(format: "    endpoint 0x%02x %@ %@ sync=%@ usage=%@ maxPacket=%d bInterval=%d",
                     address, address & 0x80 != 0 ? "IN" : "OUT", kinds[Int(attributes & 3)],
                     syncs[Int((attributes >> 2) & 3)], usages[Int((attributes >> 4) & 3)],
                     Int(maxPacket & 0x7ff), Int(current.pointee.bInterval)))
        endpoint = IOUSBGetNextEndpointDescriptor(configuration, descriptor, UnsafePointer(OpaquePointer(current)))
    }
}

// Capture the device from the class driver and open both streaming interfaces at alt 1.
func captureAndOpen() -> (IOUSBHostDevice, [(Int, IOUSBHostInterface)]) {
    guard geteuid() == 0 else { fail("capturing the device needs root: run with sudo") }
    let service = deviceService()
    let device: IOUSBHostDevice
    do {
        device = try IOUSBHostDevice(__ioService: service, options: [.deviceCapture], queue: nil, interestHandler: nil)
    } catch {
        fail("capture refused: \(error)")
    }
    print("captured the device (class driver's clients terminated)")
    // The interfaces come back as services once the device is captured; wait for them.
    var streaming: [(number: Int, alternate: Int, cls: Int, subclass: Int, service: io_service_t)] = []
    for _ in 0..<50 {
        streaming = interfaceServices().filter { $0.cls == 1 && $0.subclass == 2 }
        if streaming.count >= 2 { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard streaming.count >= 2 else {
        device.destroy()
        fail("found \(streaming.count) audio streaming interfaces, expected 2")
    }
    var interfaces: [(Int, IOUSBHostInterface)] = []
    for entry in streaming {
        do {
            let interface = try IOUSBHostInterface(__ioService: entry.service, options: [], queue: nil, interestHandler: nil)
            try interface.selectAlternateSetting(1)
            interfaces.append((entry.number, interface))
        } catch {
            print("  interface \(entry.number): \(error)")
        }
    }
    return (device, interfaces)
}

// Close the interfaces and let the device go: it is reset and the class driver matches it again.
func release(_ device: IOUSBHostDevice, _ interfaces: [(Int, IOUSBHostInterface)]) {
    for (_, interface) in interfaces {
        try? interface.selectAlternateSetting(0)
        interface.destroy()
    }
    device.destroy()
    print("released the device: it is reset and the class driver matches it again")
}

// The UAC2 clock source's ID, from the configuration descriptor (CS_INTERFACE, CLOCK_SOURCE).
func clockSourceID(_ device: IOUSBHostDevice) -> UInt8? {
    guard let configuration = device.configurationDescriptor else { return nil }
    let total = Int(UInt16(littleEndian: configuration.pointee.wTotalLength))
    let bytes = UnsafeRawPointer(configuration).assumingMemoryBound(to: UInt8.self)
    var at = 0
    while at + 2 < total {
        let length = Int(bytes[at])
        if length == 0 { break }
        if bytes[at + 1] == 0x24 && bytes[at + 2] == 0x0a && length >= 4 { return bytes[at + 3] }
        at += length
    }
    return nil
}

// SET_CUR on the clock's sampling-frequency control, as the class driver does before streaming.
func setClock(_ device: IOUSBHostDevice, rate: UInt32) {
    guard let clock = clockSourceID(device) else { print("no clock source in the descriptors; rate not set"); return }
    var request = IOUSBDeviceRequest()
    request.bmRequestType = 0x21            // class, interface, host to device
    request.bRequest = 0x01                 // CUR
    request.wValue = 0x0100                 // CS_SAM_FREQ_CONTROL
    request.wIndex = UInt16(clock) << 8     // clock entity, interface 0
    request.wLength = 4
    var value = rate.littleEndian
    let data = NSMutableData(bytes: &value, length: 4)
    do {
        try device.__send(request, data: data, bytesTransferred: nil, completionTimeout: 1.0)
        print("clock \(clock) set to \(rate) Hz")
    } catch {
        print("clock \(clock): SET_CUR \(rate) failed: \(error)")
    }
}

func printReport(_ r: StreamReport) {
    print(String(format: "ran %.2f s: OUT %d frames in %d transactions (%d failed), IN %d frames in %d transactions (%d failed)",
                 r.seconds, r.outFrames, r.outTransactions, r.outFailed, r.inFrames, r.inTransactions, r.inFailed))
    print(String(format: "feedback: %d transactions (%d failed), %.4f..%.4f frames a microframe, last %.4f",
                 r.feedbackTransactions, r.feedbackFailed, r.feedbackMin.isFinite ? r.feedbackMin : 0, r.feedbackMax, r.feedbackLast))
    for failure in r.enqueueFailures { print("enqueue failed: \(failure)") }
    var counts: [Int: Int] = [:]
    for lag in r.lags { counts[lag, default: 0] += 1 }
    let spread = (r.lags.max() ?? 0) - (r.lags.min() ?? 0)
    print("impulses: \(r.impulsesSent) sent, \(r.lags.count) found, \(r.unmatched) unmatched onsets; lag (samples): "
          + counts.keys.sorted().map { "\($0) x\(counts[$0]!)" }.joined(separator: ", ")
          + (r.lags.isEmpty ? "none" : ", spread \(spread)"))
    print(r.broken ? "BROKEN: a failed transaction or enqueue breaks the sample numbering; this run's lag is not valid"
                   : "numbering intact: no failed transaction")
}

let command = CommandLine.arguments.dropFirst().first ?? "list"
switch command {
case "list":
    let device = deviceService()
    print(String(format: "device %04x:%04x \"%@\" serial %@", vendorID, productID, productName,
                 registryString(device, "USB Serial Number") ?? "?"))
    for entry in interfaceServices() {
        print("  interface \(entry.number) alt \(entry.alternate) class \(entry.cls) subclass \(entry.subclass)")
    }

case "probe":
    let (device, interfaces) = captureAndOpen()
    defer { release(device, interfaces) }
    for (number, interface) in interfaces {
        print("  interface \(number): opened, alt 1 selected")
        describeEndpoints(of: interface)
    }
    var now = UInt64(0)
    let frame = device.__frameNumber(withTime: &now)
    print("bus frame \(frame) at host time \(now)")

case "stream":
    let seconds = CommandLine.arguments.dropFirst(2).first.flatMap(Double.init) ?? 10
    let (device, interfaces) = captureAndOpen()
    defer { release(device, interfaces) }
    setClock(device, rate: 48000)
    func pipe(_ address: Int) -> IOUSBHostPipe {
        for (_, interface) in interfaces {
            if let pipe = try? interface.copyPipe(withAddress: address) { return pipe }
        }
        fail(String(format: "no endpoint 0x%02x on the streaming interfaces", address))
    }
    let engine = StreamEngine(outPipe: pipe(0x01), feedbackPipe: pipe(0x82), inPipe: pipe(0x83))
    var now = UInt64(0)
    let anchor = device.__frameNumber(withTime: &now) + kStartMargin
    print("streaming \(seconds) s from bus frame \(anchor), both directions anchored there")
    printReport(engine.run(anchor: anchor, seconds: seconds))

default:
    fail("unknown command \(command); use list, probe or stream [SECONDS]")
}
