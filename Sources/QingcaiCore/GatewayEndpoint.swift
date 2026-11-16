import Foundation

public enum GatewayEndpoint {
    public static func validate(_ raw: String, environment: GatewayEnvironment) throws -> URL {
        guard let components = URLComponents(string: raw), let host = components.host?.lowercased(),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw FinanceError.invalid("网关地址只填写协议、主机和端口，不包含账号、路径或查询参数。") }
        if environment == .sandbox {
            guard ["127.0.0.1", "localhost"].contains(host), components.scheme == "http", let port = components.port, (1...65535).contains(port) else { throw FinanceError.invalid("本机测试网关必须使用 http://127.0.0.1:端口 或 localhost。") }
        } else {
            guard components.scheme == "https", !host.isEmpty else { throw FinanceError.invalid("正式网关必须使用 HTTPS。") }
        }
        guard let url = components.url else { throw FinanceError.invalid("网关网址无效。") }; return url
    }
}
