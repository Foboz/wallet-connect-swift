// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation
import Starscream
import Combine

public typealias SessionRequestClosure = (_ id: Int64, _ peerParam: WCSessionRequestParam) -> Void
public typealias DisconnectClosure = (Error?) -> Void
public typealias CustomRequestClosure = (_ id: Int64, _ request: [String: Any]) -> Void
public typealias ErrorClosure = (Error) -> Void

public enum WCInteractorState {
    case connected
    case connecting
    case paused
    case disconnected
}

open class WCInteractor {
    public let session: WCSession

    public private(set) var state: WCInteractorState

    public let clientId: String
    public let clientMeta: WCPeerMeta

    public var eth: WCEthereumInteractor
    public var bnb: WCBinanceInteractor
    public var trust: WCTrustInteractor
    public var okt: WCOKExChainInteractor

    // incoming event handlers
    public var onSessionRequest: SessionRequestClosure?
    public var onDisconnect: DisconnectClosure?
    public var onError: ErrorClosure?
    public var onCustomRequest: CustomRequestClosure?

    // outgoing promise resolvers
    private var connectResolver: Future<Bool, Error>.Promise?

    private let socket: WebSocket
    private var handshakeId: Int64 = -1
    private weak var pingTimer: Timer?
    private weak var sessionTimer: Timer?
    private let sessionRequestTimeout: TimeInterval

    private var peerId: String?
    private var peerMeta: WCPeerMeta?

    public init(session: WCSession, meta: WCPeerMeta, uuid: UUID, sessionRequestTimeout: TimeInterval = 20) {
        self.session = session
        self.clientId = uuid.description.lowercased()
        self.clientMeta = meta
        self.sessionRequestTimeout = sessionRequestTimeout
        self.state = .disconnected

        var request = URLRequest(url: session.bridge)
        request.timeoutInterval = sessionRequestTimeout
        self.socket = WebSocket(request: request)

        self.eth = WCEthereumInteractor()
        self.bnb = WCBinanceInteractor()
        self.trust = WCTrustInteractor()
        self.okt = WCOKExChainInteractor()
      
        socket.onEvent = { [weak self] event in
            switch event {
            case .connected: self?.onConnect()
            case .disconnected: self?.onDisconnect(error: nil)
            case let .error(error): self?.onDisconnect(error: error)
            case .cancelled: self?.onDisconnect(error: nil)
            case let .text(text): self?.onReceiveMessage(text: text)
            case .pong: WCLog("<== pong")
            case let .binary(data): WCLog("<== websocketDidReceiveData: \(data.toHexString())")
            default: break
            }
        }
    }

    deinit {
        disconnect()
    }
  
    open func connect() -> Future<Bool, Error> {
        guard state != .connected else {
            return Future { promise in
                promise(.success(true))
            }
        }
        socket.connect()
        state = .connecting
        return Future { [weak self] seal in
            self?.connectResolver = seal
        }
    }

    open func pause() {
        state = .paused
        socket.disconnect(closeCode: CloseCode.goingAway.rawValue)
    }

    open func resume() {
        socket.connect()
        state = .connecting
    }

    open func disconnect() {
        stopTimers()

        socket.disconnect()
        state = .disconnected

        connectResolver = nil
        handshakeId = -1

        WCSessionStore.clear(session.topic)
    }

    open func approveSession(accounts: [String], chainId: Int) -> Future<Void, Error> {
        guard handshakeId > 0 else {
            return Future { promise in
                promise(.failure(WCError.sessionInvalid))
            }
        }
        let result = WCApproveSessionResponse(
            approved: true,
            chainId: chainId,
            accounts: accounts,
            peerId: clientId,
            peerMeta: clientMeta
        )
        let response = JSONRPCResponse(id: handshakeId, result: result)
        return encryptAndSend(data: response.encoded)
    }

    open func rejectSession(_ message: String = "Session Rejected") -> Future<Void, Error> {
        guard handshakeId > 0 else {
            return Future { promise in
                promise(.failure(WCError.sessionInvalid))
            }
        }
        let response = JSONRPCErrorResponse(id: handshakeId, error: JSONRPCError(code: -32000, message: message))
        return encryptAndSend(data: response.encoded)
    }

    open func killSession() -> Future<Void, Error> {
        let result = WCSessionUpdateParam(approved: false, chainId: nil, accounts: nil)
        let response = JSONRPCRequest(id: generateId(), method: WCEvent.sessionUpdate.rawValue, params: [result])
      
        return Future { seal in
            var dispose: AnyCancellable?
            dispose = self.encryptAndSend(data: response.encoded)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
              if case .finished = completion {
                self?.disconnect()
                seal(.success(()))

                dispose?.cancel()
                dispose = nil
              }
            }, receiveValue: { })
        }
    }

    open func approveBnbOrder(id: Int64, signed: WCBinanceOrderSignature) -> Future<WCBinanceTxConfirmParam, Error> {
        let result = signed.encodedString
      
        return Future { seal in
            var dispose: AnyCancellable?
            dispose = self.approveRequest(id: id, result: result)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                if case .finished = completion {
                    dispose?.cancel()
                    dispose = nil
                }
            }, receiveValue: { [weak self] in
                self?.bnb.confirmResolvers[id] = seal
            })
        }
    }

    open func approveRequest<T: Codable>(id: Int64, result: T) -> Future<Void, Error> {
        let response = JSONRPCResponse(id: id, result: result)
        return encryptAndSend(data: response.encoded)
    }

    open func rejectRequest(id: Int64, message: String) -> Future<Void, Error> {
        let response = JSONRPCErrorResponse(id: id, error: JSONRPCError(code: -32000, message: message))
        return encryptAndSend(data: response.encoded)
    }
}

// MARK: internal funcs
extension WCInteractor {
    private func subscribe(topic: String) {
        let message = WCSocketMessage(topic: topic, type: .sub, payload: "")
        let data = try! JSONEncoder().encode(message)
        socket.write(data: data)
        WCLog("==> subscribe: \(String(data: data, encoding: .utf8)!)")
    }

    private func encryptAndSend(data: Data) -> Future<Void, Error> {
        WCLog("==> encrypt: \(String(data: data, encoding: .utf8)!) ")
        let encoder = JSONEncoder()
        let payload = try! WCEncryptor.encrypt(data: data, with: session.key)
        let payloadString = encoder.encodeAsUTF8(payload)
        let message = WCSocketMessage(topic: peerId ?? session.topic, type: .pub, payload: payloadString)
        let data = message.encoded
        return Future { seal in
            self.socket.write(data: data) {
                WCLog("==> sent \(String(data: data, encoding: .utf8)!) ")
                seal(.success(()))
            }
        }
    }

    private func handleEvent(_ event: WCEvent, topic: String, decrypted: Data) throws {
        switch event {
        case .sessionRequest:
            // topic == session.topic
            let request: JSONRPCRequest<[WCSessionRequestParam]> = try event.decode(decrypted)
            guard let params = request.params.first else { throw WCError.badJSONRPCRequest }
            handshakeId = request.id
            peerId = params.peerId
            peerMeta = params.peerMeta
            sessionTimer?.invalidate()
            onSessionRequest?(request.id, params)
        case .sessionUpdate:
            // topic == clientId
            let request: JSONRPCRequest<[WCSessionUpdateParam]> = try event.decode(decrypted)
            guard let param = request.params.first else { throw WCError.badJSONRPCRequest }
            if param.approved == false {
                disconnect()
            }
        default:
            if WCEvent.eth.contains(event) {
                try eth.handleEvent(event, topic: topic, decrypted: decrypted)
            } else if WCEvent.bnb.contains(event) {
                try bnb.handleEvent(event, topic: topic, decrypted: decrypted)
            } else if WCEvent.trust.contains(event) {
                try trust.handleEvent(event, topic: topic, decrypted: decrypted)
            } else if WCEvent.okt.contains(event) {
                try okt.handleEvent(event, topic: topic, decrypted: decrypted)
            }
        }
    }

    private func setupPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak socket] _ in
            WCLog("==> ping")
            socket?.write(ping: Data())
        }
    }

    private func checkExistingSession() {
        // check if it's an existing session
        if let existing = WCSessionStore.load(session.topic), existing.session == session {
            peerId = existing.peerId
            peerMeta = existing.peerMeta
            return
        }

        // we only setup timer for new sessions
        sessionTimer = Timer.scheduledTimer(withTimeInterval: sessionRequestTimeout, repeats: false) { [weak self] _ in
            self?.onSessionRequestTimeout()
        }
    }

    private func stopTimers() {
        pingTimer?.invalidate()
        sessionTimer?.invalidate()
    }

    private func onSessionRequestTimeout() {
        onDisconnect(error: WCError.sessionRequestTimeout)
    }
}

// MARK: WebSocket event handler
extension WCInteractor {
    private func onConnect() {
        WCLog("<== websocketDidConnect")

        setupPingTimer()
        checkExistingSession()

        subscribe(topic: session.topic)
        subscribe(topic: clientId)

        connectResolver?(.success(true))
        connectResolver = nil

        state = .connected
    }

    private func onDisconnect(error: Error?) {
        WCLog("<== websocketDidDisconnect, error: \(error.debugDescription)")

        stopTimers()

        if let error = error {
          connectResolver?(.failure(error))
        } else {
          connectResolver?(.success(false))
        }

        connectResolver = nil
        onDisconnect?(error)

        state = .disconnected
    }

    private func onReceiveMessage(text: String) {
        WCLog("<== receive: \(text)")
        // handle ping in text format :(
        if text == "ping" { return socket.write(pong: Data()) }
        guard let (topic, payload) = WCEncryptionPayload.extract(text) else { return }
        do {
            let decrypted = try WCEncryptor.decrypt(payload: payload, with: session.key)
            guard let json = try JSONSerialization.jsonObject(with: decrypted, options: [])
                as? [String: Any] else {
                throw WCError.badJSONRPCRequest
            }
            WCLog("<== decrypted: \(String(data: decrypted, encoding: .utf8)!)")
            if let method = json["method"] as? String {
                if let event = WCEvent(rawValue: method) {
                    try handleEvent(event, topic: topic, decrypted: decrypted)
                } else if let id = json["id"] as? Int64 {
                    onCustomRequest?(id, json)
                }
            }
        } catch let error {
            onError?(error)
            WCLog("==> onReceiveMessage error: \(error.localizedDescription)")
        }
    }
}
