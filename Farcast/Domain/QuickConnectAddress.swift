import Foundation

struct QuickConnectAddress {
    let kind: RemoteProtocol
    let host: String
    let port: Int
    let username: String?
    static func parse(_ input: String, defaultKind: RemoteProtocol) throws -> QuickConnectAddress {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = text.contains("://")
        let urlText = hasScheme ? text : "\(defaultKind.rawValue.lowercased())://\(text)"
        guard let url = URLComponents(string: urlText), let scheme = url.scheme,
            let kind = RemoteProtocol.allCases.first(where: { $0.rawValue.lowercased() == scheme.lowercased() }),
            let host = url.host, !host.isEmpty, url.password == nil, url.query == nil, url.fragment == nil,
            url.path.isEmpty || url.path == "/", !(url.user?.isEmpty ?? false),
            !text.contains(where: { $0.isWhitespace })
        else { throw QuickConnectAddressError.invalid }
        let port = url.port ?? kind.defaultPort
        guard (1...65535).contains(port) else { throw QuickConnectAddressError.invalid }
        let cleanHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return QuickConnectAddress(kind: kind, host: cleanHost, port: port, username: url.user)
    }
}
enum QuickConnectAddressError: LocalizedError {
    case invalid
    var errorDescription: String? {
        "Use user@host:port or an ssh://, rdp:// or vnc:// address. Enter passwords in the Password field."
    }
}
