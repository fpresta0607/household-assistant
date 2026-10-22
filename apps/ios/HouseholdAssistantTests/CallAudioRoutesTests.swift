// Where a call's sound can go, as iOS reports it: the iPhone's own earpiece and speaker,
// AirPods, a headset or the car, where the sound is now, and which device is connected.

import XCTest
@testable import HouseholdAssistant

final class CallAudioRoutesTests: XCTestCase {
    private let microphone = CallAudioRoutes.Port(id: "Built-In Microphone", name: "iPhone Microphone", kind: .phoneMicrophone)
    private let receiver = CallAudioRoutes.Port(id: "Built-In Receiver", name: "Receiver", kind: .receiver)
    private let speaker = CallAudioRoutes.Port(id: "Speaker", name: "Speaker", kind: .speaker)
    private let airPods = CallAudioRoutes.Port(id: "F0:5C:77:12:34:56-tsco", name: "Leo\u{2019}s AirPods Pro", kind: .bluetooth)
    private let car = CallAudioRoutes.Port(id: "CarPlay-0001", name: "Rosa\u{2019}s Highlander", kind: .car)

    private func device(_ port: CallAudioRoutes.Port) -> CallAudioRoutes.Device {
        CallAudioRoutes.Device(id: port.id, name: port.name, kind: port.kind)
    }

    // MARK: - The iPhone on its own

    func testWithNothingConnectedTheSoundIsOnTheIPhonesOwnTwo() {
        let cases: [(outputs: [CallAudioRoutes.Port], current: CallAudioRoutes.Route)] = [
            ([receiver], .receiver),
            ([speaker], .speaker),
            ([], .receiver),
        ]
        for (outputs, current) in cases {
            let routes = CallAudioRoutes(inputs: [microphone], outputs: outputs, hasReceiver: true)
            XCTAssertEqual(routes.available, [.receiver, .speaker], "\(outputs.map(\.name))")
            XCTAssertEqual(routes.current, current, "\(outputs.map(\.name))")
            XCTAssertNil(routes.device, "\(outputs.map(\.name))")
        }
    }

    func testAnIPadHasNoEarpiece() {
        let routes = CallAudioRoutes(inputs: [microphone], outputs: [], hasReceiver: false)
        XCTAssertEqual(routes.available, [.speaker])
        XCTAssertEqual(routes.current, .speaker)
    }

    // MARK: - Something connected

    func testAirPodsInUseAreTheDeviceConnected() {
        let routes = CallAudioRoutes(inputs: [microphone, airPods], outputs: [airPods], hasReceiver: true)
        XCTAssertEqual(routes.available, [.receiver, .speaker, .device(device(airPods))])
        XCTAssertEqual(routes.current, .device(device(airPods)))
        XCTAssertEqual(routes.device, device(airPods))
    }

    /// Just connected, before the call's sound has moved to them.
    func testAirPodsConnectedButNotYetInUseAreStillTheDeviceConnected() {
        let routes = CallAudioRoutes(inputs: [microphone, airPods], outputs: [speaker], hasReceiver: true)
        XCTAssertEqual(routes.current, .speaker)
        XCTAssertEqual(routes.device, device(airPods))
    }

    func testTheDeviceInUseComesBeforeOthersConnected() {
        let routes = CallAudioRoutes(inputs: [microphone, airPods, car], outputs: [car], hasReceiver: true)
        XCTAssertEqual(routes.available, [.receiver, .speaker, .device(device(airPods)), .device(device(car))])
        XCTAssertEqual(routes.device, device(car))
    }

    /// A Bluetooth speaker or AirPlay has no microphone for a call to choose it by, but while
    /// the sound is on it, it counts.
    func testWhereTheSoundIsCountsEvenWhenItCannotBeChosen() {
        let homePod = CallAudioRoutes.Port(id: "AirPlay-1", name: "Kitchen", kind: .other)
        let routes = CallAudioRoutes(inputs: [microphone], outputs: [homePod], hasReceiver: true)
        XCTAssertEqual(routes.available, [.receiver, .speaker, .device(device(homePod))])
        XCTAssertEqual(routes.device, device(homePod))
    }

    func testAWiredHeadsetShowsOnceWhateverItsTwoPortsAreCalled() {
        let headsetMicrophone = CallAudioRoutes.Port(id: "Wired Microphone", name: "Headset Microphone", kind: .wired)
        let headphones = CallAudioRoutes.Port(id: "Wired Headphones", name: "Headphones", kind: .wired)
        let routes = CallAudioRoutes(inputs: [microphone, headsetMicrophone], outputs: [headphones], hasReceiver: true)
        XCTAssertEqual(routes.available, [.receiver, .speaker, .device(device(headsetMicrophone))])
        XCTAssertEqual(routes.device, device(headsetMicrophone))
        XCTAssertEqual(routes.device?.title, "Headphones")
    }

    // MARK: - Names and glyphs

    func testEachDeviceIsNamedAndDrawn() {
        let headset = CallAudioRoutes.Port(id: "B", name: "Jabra Evolve", kind: .bluetooth)
        let homePod = CallAudioRoutes.Port(id: "AirPlay-1", name: "Kitchen", kind: .other)
        let cases: [(port: CallAudioRoutes.Port, title: String, symbol: String)] = [
            (airPods, "Leo\u{2019}s AirPods Pro", "airpods"),
            (headset, "Jabra Evolve", "headphones"),
            (car, "Rosa\u{2019}s Highlander", "car.fill"),
            (homePod, "Kitchen", "hifispeaker.fill"),
        ]
        for (port, title, symbol) in cases {
            XCTAssertEqual(device(port).title, title)
            XCTAssertEqual(device(port).symbol, symbol, title)
        }
    }
}
