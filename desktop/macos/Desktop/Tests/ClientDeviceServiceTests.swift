import CryptoKit
import XCTest

@testable import Omi_Computer

final class ClientDeviceServiceTests: XCTestCase {
  func testDeviceIdHashIsStableEightHexChars() {
    let hash = ClientDeviceService.shared.deviceIdHash
    XCTAssertEqual(hash.count, 8)
    XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
    XCTAssertEqual(hash, ClientDeviceService.shared.deviceIdHash)
  }

  func testClientDeviceIdUsesMacosPrefix() {
    let id = ClientDeviceService.shared.clientDeviceId
    XCTAssertTrue(id.hasPrefix("macos_"))
    XCTAssertEqual(id, "macos_\(ClientDeviceService.shared.deviceIdHash)")
  }

  func testUnknownAndTestBundlesNeverAccessKeychain() throws {
    for bundleID in [nil, "com.apple.dt.xctest", "example.test-runner"] as [String?] {
      let defaults = try makeIsolatedDefaults()
      let service = ClientDeviceService(
        bundleIdentifier: bundleID,
        userDefaults: defaults,
        keychainReader: {
          XCTFail("A non-production bundle must not read the login keychain")
          return .missing
        },
        keychainWriter: { _ in
          XCTFail("A non-production bundle must not write the login keychain")
        }
      )
      let hash = service.deviceIdHash
      let identity = try XCTUnwrap(defaults.string(forKey: DefaultsKey.devClientDeviceInstallId.rawValue))
      XCTAssertFalse(identity.isEmpty)
      let expectedHash = SHA256.hash(data: Data(identity.utf8))
        .map { String(format: "%02x", $0) }.joined().prefix(8).description
      XCTAssertEqual(hash, expectedHash)
      XCTAssertEqual(hash, service.deviceIdHash)
    }
  }

  func testProductionFamilyRetainsKeychainIdentity() throws {
    for bundleID in AppBuild.productionFamilyBundleIdentifiers {
      let defaults = try makeIsolatedDefaults()
      var reads = 0
      let service = ClientDeviceService(
        bundleIdentifier: bundleID,
        userDefaults: defaults,
        keychainReader: {
          reads += 1
          return .found("existing-production-install")
        },
        keychainWriter: { _ in XCTFail("An existing identity must not be replaced") }
      )
      let expectedHash = SHA256.hash(data: Data("existing-production-install".utf8))
        .map { String(format: "%02x", $0) }.joined().prefix(8).description
      XCTAssertEqual(service.deviceIdHash, expectedHash)
      XCTAssertEqual(service.deviceIdHash, expectedHash)
      XCTAssertEqual(reads, 1)
      XCTAssertNil(defaults.string(forKey: DefaultsKey.devClientDeviceInstallId.rawValue))
    }
  }

  func testNamedDevelopmentBundleUsesBundleScopedInstallId() {
    let suiteName = "ClientDeviceServiceTests.named.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let service = ClientDeviceService(
      bundleIdentifier: "com.omi.omi-menubar-logo",
      userDefaults: defaults
    )
    let hash = service.deviceIdHash

    XCTAssertEqual(hash.count, 8)
    XCTAssertEqual(
      hash,
      ClientDeviceService(
        bundleIdentifier: "com.omi.omi-menubar-logo",
        userDefaults: defaults
      ).deviceIdHash
    )
  }

  func testDesktopDevBundleAlsoUsesUserDefaultsInstallId() {
    // Omi Dev must not touch the shared login-keychain device-id item either.
    let suiteName = "ClientDeviceServiceTests.dev.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let service = ClientDeviceService(
      bundleIdentifier: AppBuild.desktopDevBundleIdentifier,
      userDefaults: defaults
    )
    _ = service.deviceIdHash
    XCTAssertNotNil(defaults.string(forKey: "dev-client-device-install-uuid"))
  }

  func testNamedDevelopmentBundlesDoNotShareInstallIds() {
    let firstSuiteName = "ClientDeviceServiceTests.first.\(UUID().uuidString)"
    let secondSuiteName = "ClientDeviceServiceTests.second.\(UUID().uuidString)"
    let firstDefaults = UserDefaults(suiteName: firstSuiteName)!
    let secondDefaults = UserDefaults(suiteName: secondSuiteName)!
    defer {
      firstDefaults.removePersistentDomain(forName: firstSuiteName)
      secondDefaults.removePersistentDomain(forName: secondSuiteName)
    }

    let first = ClientDeviceService(
      bundleIdentifier: "com.omi.omi-first-feature",
      userDefaults: firstDefaults
    )
    let second = ClientDeviceService(
      bundleIdentifier: "com.omi.omi-second-feature",
      userDefaults: secondDefaults
    )

    _ = first.deviceIdHash
    _ = second.deviceIdHash

    XCTAssertNotEqual(
      firstDefaults.string(forKey: "dev-client-device-install-uuid"),
      secondDefaults.string(forKey: "dev-client-device-install-uuid")
    )
  }

  func testProductionMigratesMirroredInstallIdWhenScopedKeychainIsMissing() {
    let suiteName = "ClientDeviceServiceTests.production-mirror.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let mirror = "stable-install-id-before-scoped-keychain"
    defaults.set(mirror, forKey: "client-device-install-uuid-mirror")
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    var persistedInstallIds: [String] = []
    let service = ClientDeviceService(
      bundleIdentifier: AppBuild.productionBundleIdentifier,
      userDefaults: defaults,
      keychainReader: { .missing },
      keychainWriter: { persistedInstallIds.append($0) }
    )

    let expectedHash = SHA256.hash(data: Data(mirror.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
      .prefix(8)
      .description

    XCTAssertEqual(service.deviceIdHash, expectedHash)
    XCTAssertEqual(persistedInstallIds, [mirror])
    XCTAssertEqual(defaults.string(forKey: "client-device-install-uuid-mirror"), mirror)
  }
}
