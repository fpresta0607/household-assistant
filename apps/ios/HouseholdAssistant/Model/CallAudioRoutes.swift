// Where a call's sound can go and where it goes now, as iOS reports it (CallAudio): the
// iPhone at the ear, its speaker, and any AirPods, headset or car the call could use, and
// which of those is connected, since that takes the sound (CallRouting).
//
// A headset or a car is read from the inputs a call can use, since a call chooses one by
// its microphone, and the output in use says where the sound is now. Somewhere the sound
// goes that cannot be chosen that way, a Bluetooth speaker or AirPlay, still counts while
// it is in use. Pure, so every rule is a plain test.

import Foundation

struct CallAudioRoutes: Equatable, Sendable {
    /// What iOS says a port is.
    enum Kind: Equatable, Hashable, Sendable {
        /// The iPhone's own microphone.
        case phoneMicrophone
        /// The iPhone's earpiece.
        case receiver
        case speaker
        case wired
        case bluetooth
        case car
        /// Anything else, such as AirPlay or a USB interface.
        case other
    }

    /// One port, as iOS reports it.
    struct Port: Equatable, Sendable {
        let id: String
        let name: String
        let kind: Kind
    }

    /// AirPods, a headset or the car, by the port a call chooses it with.
    struct Device: Equatable, Hashable, Sendable {
        let id: String
        let name: String
        let kind: Kind
    }

    enum Route: Equatable, Hashable, Sendable {
        case receiver
        case speaker
        case device(Device)
    }

    /// Every way the sound can go: the iPhone's own first, then whatever is connected.
    let available: [Route]
    /// Where it goes now.
    let current: Route

    /// `hasReceiver` is false on an iPad, which has no earpiece.
    init(inputs: [Port], outputs: [Port], hasReceiver: Bool) {
        var devices = inputs.compactMap(Self.device(for:))
        let current: Route
        if let output = outputs.first, let device = Self.device(for: output) {
            // A headset's microphone and its earphones are two ports, named apart when wired.
            if let known = devices.first(where: { $0.id == device.id || $0.name == device.name || ($0.kind == .wired && device.kind == .wired) }) {
                current = .device(known)
            } else {
                devices.append(device)
                current = .device(device)
            }
        } else if outputs.first?.kind == .speaker || !hasReceiver {
            current = .speaker
        } else {
            current = .receiver
        }
        available = (hasReceiver ? [Route.receiver, .speaker] : [.speaker]) + devices.map(Route.device)
        self.current = current
    }

    /// AirPods, a headset or the car while one is connected: the one the sound is on, or
    /// else the first iOS lists.
    var device: Device? {
        if case .device(let device) = current {
            return device
        }
        for route in available {
            if case .device(let device) = route {
                return device
            }
        }
        return nil
    }

    private static func device(for port: Port) -> Device? {
        switch port.kind {
        case .phoneMicrophone, .receiver, .speaker:
            return nil
        case .wired, .bluetooth, .car, .other:
            return Device(id: port.id, name: port.name, kind: port.kind)
        }
    }
}

extension CallAudioRoutes.Device {
    /// How it is named. A wired headset's ports are named for their halves, "Headset
    /// Microphone", so it is named for what it is.
    var title: String {
        kind == .wired ? "Headphones" : name
    }

    /// The SF Symbol it is drawn with.
    var symbol: String {
        switch kind {
        case .bluetooth:
            return name.lowercased().contains("airpods") ? "airpods" : "headphones"
        case .wired:
            return "headphones"
        case .car:
            return "car.fill"
        case .phoneMicrophone, .receiver, .speaker, .other:
            return "hifispeaker.fill"
        }
    }
}
