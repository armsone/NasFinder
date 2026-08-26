import Darwin
import Foundation

/// 같은 Wi-Fi 페어링에 쓸 이 기기의 사설/링크로컬 IPv4 주소를 찾는다.
/// 공인 주소는 후보에서 제외해 QR에 노출되지 않게 한다.
enum PhotoTransferLocalIPv4 {
    struct Candidate: Equatable {
        let interfaceName: String
        let address: String
        /// RFC 1918 사설 대역 여부. false면 169.254.x.x 링크로컬.
        let isPrivateRange: Bool
    }

    static func preferredAddress() -> String? {
        preferred(from: candidates())
    }

    /// 사설 대역 우선, 그다음 Wi-Fi/유선 계열(en*) 우선으로 고른다.
    static func preferred(from candidates: [Candidate]) -> String? {
        candidates.sorted { lhs, rhs in
            if lhs.isPrivateRange != rhs.isPrivateRange { return lhs.isPrivateRange }
            let lhsEthernetLike = lhs.interfaceName.hasPrefix("en")
            let rhsEthernetLike = rhs.interfaceName.hasPrefix("en")
            if lhsEthernetLike != rhsEthernetLike { return lhsEthernetLike }
            return lhs.interfaceName < rhs.interfaceName
        }.first?.address
    }

    static func candidates() -> [Candidate] {
        var results: [Candidate] = []
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addressPointer = entry.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == sa_family_t(AF_INET)
            else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addressPointer,
                socklen_t(addressPointer.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }

            let addressLength = hostBuffer.firstIndex(of: 0) ?? hostBuffer.endIndex
            let address = String(
                decoding: hostBuffer[..<addressLength].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard PhotoTransferPairingPayload.isValidIPv4Host(address),
                  let isPrivateRange = privateRangeFlag(of: address)
            else {
                continue
            }
            results.append(
                Candidate(
                    interfaceName: decodeCString(entry.pointee.ifa_name),
                    address: address,
                    isPrivateRange: isPrivateRange
                )
            )
        }
        return results
    }

    private static func decodeCString(_ pointer: UnsafePointer<CChar>) -> String {
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(strlen(pointer)))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 사설 대역이면 true, 링크로컬이면 false, 그 외(공인 등)는 nil.
    private static func privateRangeFlag(of address: String) -> Bool? {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return nil }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168):
            return true
        case (172, 16...31):
            return true
        case (169, 254):
            return false
        default:
            return nil
        }
    }
}
