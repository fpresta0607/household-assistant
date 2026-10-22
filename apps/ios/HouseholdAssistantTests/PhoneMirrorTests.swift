#if canImport(UIKit)
// Every Settings row that mirrors the iPhone says what iOS says: each answer iOS can give
// for notifications, the microphone and speech, Contacts, adding to Photos and the camera,
// in the app's words; what App Lock asks for on each kind of iPhone and whether it can;
// and the iPhone's own text size while text size is Like iPhone.

import AVFoundation
import Contacts
import LocalAuthentication
import Photos
import Speech
import SwiftUI
import UserNotifications
import XCTest
@testable import HouseholdAssistant

@MainActor
final class PhoneMirrorTests: XCTestCase {
    func testNotificationsDeliveredQuietlyOrForAWhileAreStillOn() {
        // Arrange
        let expected: [(UNAuthorizationStatus, PermissionStatus)] = [
            (.notDetermined, .notAsked),
            (.authorized, .allowed),
            (.provisional, .allowed),
            (.ephemeral, .allowed),
            (.denied, .denied),
        ]

        for (status, mirrored) in expected {
            // Act, Assert
            XCTAssertEqual(Permissions.status(of: status), mirrored, "notifications \(status.rawValue)")
        }
    }

    func testTheMicrophoneAndSpeechReadAsIOSHasThem() {
        // Arrange
        let microphone: [(AVAudioApplication.recordPermission, PermissionStatus)] = [
            (.undetermined, .notAsked),
            (.granted, .allowed),
            (.denied, .denied),
        ]
        let speech: [(SFSpeechRecognizerAuthorizationStatus, PermissionStatus)] = [
            (.notDetermined, .notAsked),
            (.authorized, .allowed),
            (.denied, .denied),
            (.restricted, .denied),
        ]

        // Act, Assert
        for (status, mirrored) in microphone {
            XCTAssertEqual(Permissions.status(of: status), mirrored, "microphone \(status.rawValue)")
        }
        for (status, mirrored) in speech {
            XCTAssertEqual(Permissions.status(of: status), mirrored, "speech \(status.rawValue)")
        }
    }

    func testContactsPhotosAndTheCameraReadAsIOSHasThem() {
        // Arrange
        let contacts: [(CNAuthorizationStatus, PhoneAccessState)] = [
            (.notDetermined, .notAsked),
            (.authorized, .allowed),
            (.limited, .limited),
            (.denied, .denied),
            (.restricted, .denied),
        ]
        let photos: [(PHAuthorizationStatus, PhoneAccessState)] = [
            (.notDetermined, .notAsked),
            (.authorized, .allowed),
            (.limited, .limited),
            (.denied, .denied),
            (.restricted, .denied),
        ]
        let camera: [(AVAuthorizationStatus, PhoneAccessState)] = [
            (.notDetermined, .notAsked),
            (.authorized, .allowed),
            (.denied, .denied),
            (.restricted, .denied),
        ]

        // Act, Assert
        for (status, mirrored) in contacts {
            XCTAssertEqual(Permissions.state(of: status), mirrored, "contacts \(status.rawValue)")
        }
        for (status, mirrored) in photos {
            XCTAssertEqual(Permissions.state(of: status), mirrored, "photos \(status.rawValue)")
        }
        for (status, mirrored) in camera {
            XCTAssertEqual(Permissions.state(of: status), mirrored, "camera \(status.rawValue)")
        }
    }

    func testAppLockAsksForWhatThisIPhoneOpensWithAndIsOffOnlyWhereIOSSaysSo() {
        // Arrange
        let expected: [(biometry: LABiometryType, error: LAError.Code?, hasPasscode: Bool, state: PhoneAccessState, name: String)] = [
            (.faceID, nil, true, .allowed, "Face ID"),
            (.touchID, nil, true, .allowed, "Touch ID"),
            (.opticID, nil, true, .allowed, "Optic ID"),
            (.none, nil, true, .allowed, "Passcode"),
            // No face set up: App Lock still opens with the passcode.
            (.faceID, .biometryNotEnrolled, true, .allowed, "Passcode"),
            (.faceID, .biometryLockout, true, .allowed, "Face ID"),
            // The person said no to Face ID for Steward AI: only iOS can turn it back on.
            (.faceID, .biometryNotAvailable, true, .denied, "Face ID"),
            (.faceID, .passcodeNotSet, false, .unavailable, "Face ID"),
        ]

        for (biometry, error, hasPasscode, state, name) in expected {
            // Act
            let mirrored = Permissions.lockState(biometryType: biometry, biometricsError: error, hasPasscode: hasPasscode)
            let named = Permissions.lockName(of: biometry, biometricsError: error)

            // Assert
            let label = "\(biometry.rawValue) \(error.map { "\($0.rawValue)" } ?? "none") passcode \(hasPasscode)"
            XCTAssertEqual(mirrored, state, label)
            XCTAssertEqual(named, name, label)
        }
    }

    func testLikeIPhoneNamesTheIPhonesTextSizeAndTurningItOffStartsAtTheNearestSize() {
        // Arrange
        let expected: [(onIPhone: DynamicTypeSize, nearest: TextSizeChoice, label: String)] = [
            (.xSmall, .xSmall, "Smallest"),
            (.small, .small, "Smaller"),
            (.medium, .medium, "Small"),
            (.large, .large, "Standard"),
            (.xLarge, .xLarge, "Large"),
            (.xxLarge, .xxLarge, "Larger"),
            (.xxxLarge, .xxxLarge, "Largest"),
            (.accessibility1, .xxxLarge, "Accessibility size"),
            (.accessibility5, .xxxLarge, "Accessibility size"),
        ]

        for (onIPhone, nearest, label) in expected {
            // Act, Assert
            XCTAssertEqual(TextSizeChoice(nearest: onIPhone), nearest, "\(onIPhone)")
            XCTAssertEqual(TextSizeChoice.label(ofIPhone: onIPhone), label, "\(onIPhone)")
        }
    }
}
#endif
