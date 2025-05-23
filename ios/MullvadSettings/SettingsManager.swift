//
//  SettingsManager.swift
//  MullvadVPN
//
//  Created by pronebird on 29/04/2022.
//  Copyright © 2025 Mullvad VPN AB. All rights reserved.
//

import Foundation
import MullvadLogging
import MullvadTypes

private let keychainServiceName = "Mullvad VPN"
private let accountTokenKey = "accountToken"
private let accountExpiryKey = "accountExpiry"

public enum SettingsManager {
    nonisolated(unsafe) private static let logger = Logger(label: "SettingsManager")

    #if DEBUG
    nonisolated(unsafe) private static var _store = KeychainSettingsStore(
        serviceName: keychainServiceName,
        accessGroup: ApplicationConfiguration.securityGroupIdentifier
    )

    /// Alternative store used for tests.
    nonisolated(unsafe) internal static var unitTestStore: SettingsStore?

    public static var store: SettingsStore {
        if let unitTestStore { return unitTestStore }
        return _store
    }

    #else
    public static let store: SettingsStore = KeychainSettingsStore(
        serviceName: keychainServiceName,
        accessGroup: ApplicationConfiguration.securityGroupIdentifier
    )

    #endif

    private static func makeParser() -> SettingsParser {
        SettingsParser(decoder: JSONDecoder(), encoder: JSONEncoder())
    }

    // MARK: - Last used account

    public static func getLastUsedAccount() throws -> String {
        let data = try store.read(key: .lastUsedAccount)
        guard let result = String(bytes: data, encoding: .utf8) else {
            throw StringDecodingError(data: data)
        }
        return result
    }

    public static func setLastUsedAccount(_ string: String?) throws {
        if let string {
            guard let data = string.data(using: .utf8) else {
                throw StringEncodingError(string: string)
            }

            try store.write(data, for: .lastUsedAccount)
        } else {
            do {
                try store.delete(key: .lastUsedAccount)
            } catch let error as KeychainError where error == .itemNotFound {
                return
            } catch {
                throw error
            }
        }
    }

    // MARK: - Should wipe settings

    public static func getShouldWipeSettings() -> Bool {
        (try? store.read(key: .shouldWipeSettings)) != nil
    }

    public static func setShouldWipeSettings() {
        do {
            try store.write(Data(), for: .shouldWipeSettings)
        } catch {
            logger.error(
                error: error,
                message: "Failed to set should wipe settings."
            )
        }
    }

    // MARK: - Settings

    public static func readSettings() throws -> LatestTunnelSettings {
        let storedVersion: Int
        let data: Data
        let parser = makeParser()

        do {
            data = try store.read(key: .settings)
            storedVersion = try parser.parseVersion(data: data)
        } catch {
            throw ReadSettingsVersionError(underlyingError: error)
        }

        let currentVersion = SchemaVersion.current

        if storedVersion == currentVersion.rawValue {
            return try parser.parsePayload(as: LatestTunnelSettings.self, from: data)
        } else {
            throw UnsupportedSettingsVersionError(
                storedVersion: storedVersion,
                currentVersion: currentVersion
            )
        }
    }

    public static func writeSettings(_ settings: LatestTunnelSettings) throws {
        let parser = makeParser()
        let data = try parser.producePayload(settings, version: SchemaVersion.current.rawValue)

        try store.write(data, for: .settings)
    }

    // MARK: - Device state

    public static func readDeviceState() throws -> DeviceState {
        let data = try store.read(key: .deviceState)
        let parser = makeParser()

        return try parser.parseUnversionedPayload(as: DeviceState.self, from: data)
    }

    public static func writeDeviceState(_ deviceState: DeviceState) throws {
        let parser = makeParser()
        let data = try parser.produceUnversionedPayload(deviceState)

        try store.write(data, for: .deviceState)
    }

    /// Removes all legacy settings, device state, tunnel settings and API access methods but keeps
    /// the last used account number stored.
    public static func resetStore(completely: Bool = false) {
        logger.debug("Reset store.")

        let keys = completely
            ? SettingsKey.allCases
            : [
                .settings,
                .deviceState,
                .apiAccessMethods,
                .ipOverrides,
                .customRelayLists,
            ]

        keys.forEach { key in
            do {
                try store.delete(key: key)
            } catch {
                if (error as? KeychainError) != .itemNotFound {
                    logger.error(error: error, message: "Failed to delete \(key.rawValue).")
                }
            }
        }
    }

    // MARK: - Private

    private static func checkLatestSettingsVersion() throws {
        let settingsVersion: Int
        do {
            let parser = makeParser()
            let settingsData = try store.read(key: .settings)
            settingsVersion = try parser.parseVersion(data: settingsData)
        } catch .itemNotFound as KeychainError {
            return
        } catch {
            throw ReadSettingsVersionError(underlyingError: error)
        }

        guard settingsVersion != SchemaVersion.current.rawValue else {
            return
        }

        let error = UnsupportedSettingsVersionError(
            storedVersion: settingsVersion,
            currentVersion: SchemaVersion.current
        )

        logger.error(error: error, message: "Encountered an unknown version.")

        throw error
    }
}

// MARK: - Supporting types

/// An error type describing a failure to read or parse settings version.
public struct ReadSettingsVersionError: LocalizedError, WrappingError {
    private let inner: Error

    public var underlyingError: Error? {
        inner
    }

    public var errorDescription: String? {
        "Failed to read settings version."
    }

    public init(underlyingError: Error) {
        inner = underlyingError
    }
}

/// An error returned when stored settings version is unknown to the currently running app.
public struct UnsupportedSettingsVersionError: LocalizedError {
    public let storedVersion: Int
    public let currentVersion: SchemaVersion

    public var errorDescription: String? {
        """
        Stored settings version was not the same as current version, \
        stored version: \(storedVersion), current version: \(currentVersion)
        """
    }
}
