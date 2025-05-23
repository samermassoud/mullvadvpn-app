//
//  WgAdapter.swift
//  PacketTunnel
//
//  Created by pronebird on 29/08/2023.
//  Copyright © 2025 Mullvad VPN AB. All rights reserved.
//

import Foundation
@preconcurrency import MullvadLogging
import MullvadTypes
import NetworkExtension
import PacketTunnelCore
@preconcurrency import WireGuardKit

class WgAdapter: TunnelAdapterProtocol, @unchecked Sendable {
    let logger = Logger(label: "WgAdapter")
    let adapter: WireGuardAdapter

    init(packetTunnelProvider: NEPacketTunnelProvider) {
        let wgGoLogger = Logger(label: "WireGuard")

        adapter = WireGuardAdapter(
            with: packetTunnelProvider,
            shouldHandleReasserting: false,
            logHandler: { logLevel, string in
                wgGoLogger.log(level: logLevel.loggerLevel, "\(string)")
            }
        )
    }

    func start(configuration: TunnelAdapterConfiguration, daita: DaitaConfiguration?) async throws {
        let wgConfig = configuration.asWgConfig
        do {
            try await adapter.stop()
            try await adapter.start(tunnelConfiguration: wgConfig, daita: daita)
        } catch WireGuardAdapterError.invalidState {
            try await adapter.start(tunnelConfiguration: wgConfig, daita: daita)
        }
    }

    func startMultihop(
        entryConfiguration: TunnelAdapterConfiguration? = nil,
        exitConfiguration: TunnelAdapterConfiguration,
        daita: DaitaConfiguration?
    ) async throws {
        let exitConfiguration = exitConfiguration.asWgConfig
        let entryConfiguration = entryConfiguration?.asWgConfig

        logger.info("\(exitConfiguration.peers)")

        if let entryConfiguration {
            logger.info("\(entryConfiguration.peers)")
        }

        do {
            try await adapter.stop()
            try await adapter.startMultihop(
                entryConfiguration: entryConfiguration,
                exitConfiguration: exitConfiguration,
                daita: daita
            )
        } catch WireGuardAdapterError.invalidState {
            try await adapter.startMultihop(
                entryConfiguration: entryConfiguration,
                exitConfiguration: exitConfiguration,
                daita: daita
            )
        }
    }

    func stop() async throws {
        try await adapter.stop()
    }

    public var icmpPingProvider: ICMPPingProvider {
        adapter
    }
}

extension WgAdapter: TunnelDeviceInfoProtocol {
    var interfaceName: String? {
        return adapter.interfaceName
    }

    func getStats() throws -> WgStats {
        var result: String?

        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        adapter.getRuntimeConfiguration { string in
            result = string
            dispatchGroup.leave()
        }

        guard case .success = dispatchGroup.wait(wallTimeout: .now() + 1) else { throw StatsError.timeout }
        guard let result else { throw StatsError.nilValue }
        guard let newStats = WgStats(from: result) else { throw StatsError.parse }

        return newStats
    }

    enum StatsError: LocalizedError {
        case timeout, nilValue, parse

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "adapter.getRuntimeConfiguration() timeout."
            case .nilValue:
                return "Received nil string for stats."
            case .parse:
                return "Couldn't parse stats."
            }
        }
    }
}

private extension TunnelAdapterConfiguration {
    var asWgConfig: TunnelConfiguration {
        var interfaceConfig = InterfaceConfiguration(privateKey: privateKey)
        interfaceConfig.addresses = interfaceAddresses
        interfaceConfig.dns = dns.map { DNSServer(address: $0) }
        interfaceConfig.listenPort = 0

        var peers: [PeerConfiguration] = []
        if let peer {
            var peerConfig = PeerConfiguration(publicKey: peer.publicKey)
            peerConfig.endpoint = peer.endpoint.wgEndpoint
            peerConfig.allowedIPs = allowedIPs
            peerConfig.preSharedKey = peer.preSharedKey
            peers.append(peerConfig)
        }

        return TunnelConfiguration(
            name: nil,
            interface: interfaceConfig,
            peers: peers,
            pingableGateway: pingableGateway
        )
    }
}

private extension AnyIPEndpoint {
    var wgEndpoint: Endpoint {
        switch self {
        case let .ipv4(endpoint):
            return Endpoint(host: .ipv4(endpoint.ip), port: .init(integerLiteral: endpoint.port))
        case let .ipv6(endpoint):
            return Endpoint(host: .ipv6(endpoint.ip), port: .init(integerLiteral: endpoint.port))
        }
    }
}

private extension WgStats {
    init?(from string: String) {
        var bytesReceived: UInt64?
        var bytesSent: UInt64?

        string.enumerateLines { line, stop in
            if bytesReceived == nil, let value = parseValue("rx_bytes=", in: line) {
                bytesReceived = value
            } else if bytesSent == nil, let value = parseValue("tx_bytes=", in: line) {
                bytesSent = value
            }

            if bytesReceived != nil, bytesSent != nil {
                stop = true
            }
        }

        guard let bytesReceived, let bytesSent else {
            return nil
        }

        self.init(bytesReceived: bytesReceived, bytesSent: bytesSent)
    }
}

@inline(__always) private func parseValue(_ prefixKey: String, in line: String) -> UInt64? {
    guard line.hasPrefix(prefixKey) else { return nil }

    let value = line.dropFirst(prefixKey.count)

    return UInt64(value)
}

extension WgAdapter: TunnelProvider {
    public func tunnelHandle() throws -> Int32 {
        return try self.adapter.tunnelHandle()
    }

    public func wgFunctions() -> WgFunctionPointers {
        WgFunctionPointers(
            open: adapter.inTunnelTcpOpen,
            close: adapter.inTunnelTcpClose,
            receive: adapter.inTunnelTcpRecv,
            send: adapter.inTunnelTcpSend
        )
    }
}
