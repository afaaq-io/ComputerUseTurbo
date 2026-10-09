import TurboCore
import Foundation

/// JSON-RPC front end for one connection: `hello` gating, method routing, error mapping.
final class Dispatcher: ConnectionHandler {
    private let service: HelperService
    /// Set once this connection completed a matching `hello`.
    private var helloDone = false

    init(service: HelperService) {
        self.service = service
    }

    func connectionClosed(connectionId: Int) {}

    func handle(frame: Data, connectionId: Int) -> Data? {
        let response: JSONValue
        switch RPCMessage.parse(frame) {
        case .notification(let method):
            Log.info("conn \(connectionId): ignoring notification \(LogText.peer(method, limit: 60))")
            return nil
        case .failure(let id, let error):
            Log.warn("conn \(connectionId): bad request: \(error.message)")
            response = RPCMessage.failure(id: id, error: error)
        case .request(let request):
            response = handle(request, connectionId: connectionId)
        }
        return encode(response, connectionId: connectionId)
    }

    private func encode(_ response: JSONValue, connectionId: Int) -> Data? {
        do {
            let data = try response.encoded()
            if data.count <= Framing.maxFrameLength { return data }
            Log.error("conn \(connectionId): response of \(data.count) bytes exceeds the frame cap")
            let fallback = RPCMessage.failure(
                id: response["id"] ?? .null,
                error: RPCError(TurboError(.helperFault, "The response was too large to send.")))
            return try fallback.encoded()
        } catch {
            Log.error("conn \(connectionId): could not encode response: \(error)")
            return nil
        }
    }

    private func handle(_ request: RPCRequest, connectionId: Int) -> JSONValue {
        let id = JSONValue.int(request.id)
        switch request.method {
        case "hello":
            guard let params = request.params, case .object = params,
                let version = params["clientApiVersion"]?.stringValue
            else {
                return RPCMessage.failure(id: id, error: RPCError(.invalidParams, "hello requires params.clientApiVersion"))
            }
            guard version == TurboProtocol.apiVersion else {
                Log.warn("conn \(connectionId): version mismatch (client \"\(LogText.peer(version, limit: 40))\")")
                return RPCMessage.failure(
                    id: id,
                    error: RPCError(
                        TurboError(
                            .protocolMismatch,
                            "Client API version \"\(version)\" is not supported; this helper speaks \(TurboProtocol.apiVersion). Rebuild/reinstall so both sides match."
                        )))
            }
            helloDone = true
            Log.info(
                "conn \(connectionId): hello from \(params["clientName"]?.stringValue.map { LogText.peer($0, limit: 60) } ?? "unknown client")"
            )
            return RPCMessage.success(
                id: id,
                result: [
                    "serverApiVersion": .string(TurboProtocol.apiVersion),
                    "helperVersion": .string(TurboProtocol.helperVersion),
                    "pid": .int(Int(getpid())),
                    "permissions": Permissions.json,
                ])

        case "request":
            guard helloDone else {
                return RPCMessage.failure(
                    id: id, error: RPCError(TurboError(.callerRejected, "Call hello before sending requests.")))
            }
            let started = Date()
            var label = "request"
            do {
                let env = try RequestEnvelope.parse(request.params, nowMillis: currentUnixMillis())
                label = env.logLabel
                if currentUnixMillis() > env.deadlineUnixMillis {
                    throw TurboError(.timedOut, "The request deadline had already passed when it arrived.")
                }
                let result = try service.handle(env)
                Log.info("conn \(connectionId): \(label) → ok (\(Self.ms(since: started)) ms)")
                return RPCMessage.success(id: id, result: result)
            } catch let error as RPCError {
                Log.warn("conn \(connectionId): \(label) → \(error.code) \(error.message)")
                return RPCMessage.failure(id: id, error: error)
            } catch let error as TurboError {
                Log.info("conn \(connectionId): \(label) → \(error.code.name) (\(Self.ms(since: started)) ms)")
                return RPCMessage.failure(id: id, error: RPCError(error))
            } catch {
                Log.error("conn \(connectionId): \(label) → internal error \(error)")
                return RPCMessage.failure(
                    id: id, error: RPCError(TurboError(.helperFault, "Internal error: \(error.localizedDescription)")))
            }

        default:
            return RPCMessage.failure(
                id: id, error: RPCError(.methodNotFound, "Unknown method \"\(request.method)\""))
        }
    }

    private static func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }
}
