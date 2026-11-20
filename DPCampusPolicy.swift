import Foundation

struct DPCampusPolicy: Sendable {
    private struct Rule: Sendable {
        let network: UInt32
        let mask: UInt32
        let restricted: Bool
        let tcp: [ClosedRange<UInt16>]
        let udp: [ClosedRange<UInt16>]

        func matches(_ address: UInt32) -> Bool { address & mask == network & mask }
    }

    private let rules: [Rule]
    static let portalDestinations = ["202.203.208.5", "113.55.14.8"]
    let routeMask: UInt8
    private let portalAddresses: Set<UInt32>
    let advertisedNetworks: [String]
    let extraHosts: [String]
    private let extraAddresses: Set<UInt32>
    static let campusNetworks = ["10.111.176.0/20", "10.141.176.0/20"]
    private static let campusBases: [UInt32] = [0x0a6f_b000, 0x0a8d_b000]
    private static let campusMask: UInt32 = 0xffff_f000
    private let broad: Bool
    private let assignedAddress: UInt32

    init(data: Data, virtualAddress: String, broad: Bool = false, extraHosts: [String] = [], includePortal: Bool = false) throws {
        let response = try JSONSerialization.jsonObject(with: data)
        guard let root = response as? [String: Any], let groups = root["ResourceGroups"] else {
            throw DPControlError.invalidHTTPResponse
        }
        assignedAddress = try Self.address(virtualAddress)
        var collected: [Rule] = []
        func visit(_ object: Any) {
            if let entries = object as? [Any] {
                entries.forEach(visit)
            } else if let entry = object as? [String: Any] {
                if let net = entry["Net"] as? String, let mask = entry["Mask"] as? String,
                   let address = try? Self.address(net, allowZero: true),
                   let netmask = try? Self.address(mask, allowZero: true),
                   let control = (entry["access_contrl"] as? NSNumber)?.intValue,
                   control == 0 || control == 1 {
                    collected.append(Rule(network: address, mask: netmask, restricted: control == 1,
                                          tcp: Self.ranges(entry["TCP"]), udp: Self.ranges(entry["UDP"])))
                } else {
                    entry.values.forEach(visit)
                }
            }
        }
        visit(groups)
        rules = collected
        advertisedNetworks = Set(collected.map { rule in
            let network = rule.network & rule.mask
            let octets = [24, 16, 8, 0].map { String((network >> $0) & 255) }
            return octets.joined(separator: ".") + "/" + String(rule.mask.nonzeroBitCount)
        }).sorted()
        let campusAllowed = Self.campusBases.allSatisfy { base in
            collected.contains { rule in
                (rule.mask & Self.campusMask) == rule.mask && rule.matches(base)
            }
        }
        let useBroadRoutes = broad && campusAllowed
        self.broad = useBroadRoutes
        let portals = try Self.portalDestinations.map { try Self.address($0) }
        let portalAllowed = includePortal && portals.allSatisfy { address in
            collected.contains { $0.matches(address) }
        }
        portalAddresses = portalAllowed ? Set(portals) : []
        let primaryRoutes: UInt8 = self.broad ? 4 : 0
        routeMask = primaryRoutes | (portalAllowed ? 8 : 0)
        let parsed = try extraHosts.map { name -> (String, UInt32) in
            let address = try Self.address(name)
            guard address >> 24 == 10, collected.contains(where: { $0.matches(address) }) else {
                throw DPControlError.unauthorizedHost(name)
            }
            return (name, address)
        }
        let extra = parsed.filter { _, address in
            !(useBroadRoutes && Self.campusBases.contains(address & Self.campusMask))
        }
        self.extraHosts = extra.map(\.0)
        extraAddresses = Set(extra.map(\.1))
    }

    func allows(_ packet: Data, inbound: Bool) -> Bool {
        let bytes = [UInt8](packet)
        guard bytes.count >= 20, bytes[0] >> 4 == 4,
              Int(bytes[2]) * 256 + Int(bytes[3]) == bytes.count,
              bytes[6] & 0x3f == 0, bytes[7] == 0 else { return false }
        let headerLength = Int(bytes[0] & 15) * 4
        guard headerLength >= 20, headerLength <= bytes.count else { return false }
        let source = Self.number(bytes[12..<16])
        let destination = Self.number(bytes[16..<20])
        let campus = inbound ? source : destination
        let local = inbound ? destination : source
        guard local == assignedAddress else { return false }
        let withinCampus = broad && Self.campusBases.contains(campus & Self.campusMask)
        guard withinCampus || extraAddresses.contains(campus) || portalAddresses.contains(campus) else { return false }
        let protocolNumber = bytes[9]
        if portalAddresses.contains(campus) {
            guard protocolNumber == 6, bytes.count >= headerLength + 4 else { return false }
            let offset = headerLength + (inbound ? 0 : 2)
            let port = UInt16(bytes[offset]) * 256 + UInt16(bytes[offset + 1])
            guard port == 80 || port == 443 else { return false }
        }
        guard protocolNumber == 1 || protocolNumber == 6 || protocolNumber == 17 else { return false }
        let matching = rules.filter { $0.matches(campus) }
        if matching.contains(where: { !$0.restricted }) { return true }
        guard (protocolNumber == 6 || protocolNumber == 17), bytes.count >= headerLength + 4 else { return false }
        let offset = headerLength + (inbound ? 0 : 2)
        let port = UInt16(bytes[offset]) * 256 + UInt16(bytes[offset + 1])
        return matching.contains { rule in
            (protocolNumber == 6 ? rule.tcp : rule.udp).contains { $0.contains(port) }
        }
    }

    private static func ranges(_ entry: Any?) -> [ClosedRange<UInt16>] {
        let container = entry as? [String: Any]
        let collection = container?["Range"] as? [[String: Any]] ?? []
        return collection.compactMap {
            guard let min = ($0["Min"] as? NSNumber).flatMap({ UInt16(exactly: $0.doubleValue) }),
                  let max = ($0["Max"] as? NSNumber).flatMap({ UInt16(exactly: $0.doubleValue) }),
                  min <= max else { return nil }
            return min...max
        }
    }

    private static func address(_ value: String, allowZero: Bool = false) throws -> UInt32 {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { UInt8($0) }
        guard parts.count == 4, bytes.count == 4 else { throw DPControlError.invalidHTTPResponse }
        let result = number(bytes)
        guard result != 0 || allowZero else { throw DPControlError.invalidHTTPResponse }
        return result
    }

    private static func number<T: Sequence>(_ bytes: T) -> UInt32 where T.Element == UInt8 {
        bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
