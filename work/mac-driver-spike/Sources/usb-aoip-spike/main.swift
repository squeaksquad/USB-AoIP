// usb-aoip-spike: the host-driver spike's user-space tool (SPIKE_PLAN.md).
//
//   usb-aoip-spike list            the gadget's IOKit services, no open (no root needed)
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
    guard geteuid() == 0 else { fail("probe captures the device: run with sudo") }
    let service = deviceService()
    let device: IOUSBHostDevice
    do {
        device = try IOUSBHostDevice(__ioService: service, options: [.deviceCapture], queue: nil, interestHandler: nil)
    } catch {
        fail("capture refused: \(error)")
    }
    print("captured the device (class driver's clients terminated)")
    defer {
        device.destroy()
        print("released the device: it is reset and the class driver matches it again")
    }
    // The interfaces come back as services once the device is captured; wait for them.
    var streaming: [(number: Int, alternate: Int, cls: Int, subclass: Int, service: io_service_t)] = []
    for _ in 0..<50 {
        streaming = interfaceServices().filter { $0.cls == 1 && $0.subclass == 2 }
        if streaming.count >= 2 { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard streaming.count >= 2 else { fail("found \(streaming.count) audio streaming interfaces, expected 2") }
    var interfaces: [IOUSBHostInterface] = []
    for entry in streaming {
        do {
            let interface = try IOUSBHostInterface(__ioService: entry.service, options: [], queue: nil, interestHandler: nil)
            try interface.selectAlternateSetting(1)
            print("  interface \(entry.number): opened, alt 1 selected")
            describeEndpoints(of: interface)
            interfaces.append(interface)
        } catch {
            print("  interface \(entry.number): \(error)")
        }
    }
    var now = UInt64(0)
    let frame = device.__frameNumber(withTime: &now)
    print("bus frame \(frame) at host time \(now)")
    for interface in interfaces {
        try? interface.selectAlternateSetting(0)
        interface.destroy()
    }

default:
    fail("unknown command \(command); use list or probe")
}
