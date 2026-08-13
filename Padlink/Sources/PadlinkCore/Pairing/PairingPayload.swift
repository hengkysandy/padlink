import Foundation

/// What the QR code carries. The secret travels optically, never over the
/// network, which is what makes a person-in-the-middle attack impossible.
public struct PairingPayload: Sendable, Equatable {
    public static let version = 1
    public static let scheme = "padlink"

    public let pairingID: PairingID
    public let secret: PairingSecret
    /// Shown in the iPad's UI.
    public let macName: String
    /// Bonjour service instance name, so the iPad picks the right Mac when
    /// several are advertising.
    public let serviceName: String

    public init(
        pairingID: PairingID,
        secret: PairingSecret,
        macName: String,
        serviceName: String
    ) {
        self.pairingID = pairingID
        self.secret = secret
        self.macName = macName
        self.serviceName = serviceName
    }

    public var urlString: String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "id", value: pairingID.hexString),
            URLQueryItem(name: "k", value: Self.base64URL(secret.bytes)),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "s", value: serviceName)
        ]
        return components.string ?? ""
    }

    public static func parse(_ text: String) throws -> PairingPayload {
        guard let components = URLComponents(string: text) else {
            throw PairingError.notAURL
        }
        guard components.scheme == scheme else { throw PairingError.wrongScheme }

        let items = components.queryItems ?? []
        func value(_ name: String) throws -> String {
            guard let found = items.first(where: { $0.name == name })?.value,
                  !found.isEmpty
            else { throw PairingError.missingField(name) }
            return found
        }

        guard let rawVersion = Int(try value("v")) else {
            throw PairingError.malformedField("v")
        }
        guard rawVersion == version else {
            throw PairingError.unsupportedVersion(rawVersion)
        }

        guard let pairingID = PairingID(hexString: try value("id")) else {
            throw PairingError.malformedField("id")
        }
        guard let keyBytes = decodeBase64URL(try value("k")),
              let secret = PairingSecret(bytes: keyBytes)
        else {
            throw PairingError.malformedField("k")
        }

        return PairingPayload(
            pairingID: pairingID,
            secret: secret,
            macName: try value("n"),
            serviceName: try value("s")
        )
    }

    // Base64url, unpadded. Padding and the plus and slash characters would
    // need percent-encoding inside a URL, which makes the QR code denser.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ text: String) -> Data? {
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder > 0 {
            standard.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: standard)
    }
}
