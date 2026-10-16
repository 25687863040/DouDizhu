import Foundation

// MARK: - 服务端快照

/// 服务端下发的房间状态快照（扁平结构，便于 PHP 直接生成）
struct OnlineRoomSnapshot: Codable {
    var v: Int = 0                    // 版本号，用于长轮询比对
    var started: Bool = false         // 三人是否到齐
    var seatsFilled: [Bool] = [false, false, false]
    var phase: String = "idle"        // idle / bidding / playing / finished
    var hands: [[Card]] = [[], [], []]
    var counts: [Int] = [0, 0, 0]
    var landlord: Int? = nil
    var bottom: [Card] = []
    var current: Int = 0
    var base: Int = 1
    var mult: Int = 1
    var table: Combo? = nil
    var tableOwner: Int? = nil
    var played: [[Card]] = [[], [], []]
    var bids: [Int] = [-1, -1, -1]    // -1 未叫
    var bidsLeft: Int = 3
    var highest: Int? = nil
    var winner: Int? = nil
    var scoreDelta: Int = 0
    var landlordWon: Bool? = nil
    var message: String = ""
    /// 只有 meSeat 对应的手牌才下发完整内容，其余座位只给张数
    var mySeat: Int = 0

    /// 把快照转成本地 GameState；把「我」重映射到 .me
    func decodeGameState() -> GameState? {
        guard ["bidding", "playing", "finished", "landlordChosen"].contains(phase) else {
            return nil
        }
        var g = GameState()
        g.phase = GamePhase(rawValue: phase) ?? .idle
        if g.phase == .landlordChosen { g.phase = .playing }

        // 服务端座位 -> 本地座位（我 = .me，其余按相对顺序）
        func localSeat(_ s: Int) -> Seat {
            if s == mySeat { return .me }
            let diff = ((s - mySeat) % 3 + 3) % 3   // 1 = 下家, 2 = 上家
            return diff == 1 ? .right : .left
        }

        for s in 0..<3 {
            let ls = localSeat(s)
            // 服务端只给「我」的完整手牌；其他家给空数组 + counts
            if s == mySeat {
                g.hands[ls] = hands[s] ?? []
            } else {
                g.hands[ls] = []
            }
            g.handCounts[ls] = counts[s] ?? (hands[s]?.count ?? 0)
            g.playedCards[ls] = played[s] ?? []
        }

        g.baseScore = base
        g.multiplier = mult
        g.bottomCards = bottom
        if let l = landlord { g.landlord = localSeat(l) }
        g.currentSeat = localSeat(current)
        g.tableCombo = table
        if let to = tableOwner { g.tableOwner = localSeat(to) }
        g.winner = winner.map { localSeat($0) }
        g.scoreDelta = scoreDelta
        g.landlordWon = landlordWon

        // 叫分记录
        for s in 0..<3 where (bids[s] ?? -1) >= 0 {
            let ls = localSeat(s)
            g.bids[ls] = .bid(bids[s] ?? 0)
        }
        g.currentBid = max(0, bids.max() ?? 0)
        if let h = highest { g.highestBidder = localSeat(h) }
        g.bidTurnsLeft = bidsLeft

        return g
    }
}

// MARK: - 错误

enum RoomError: LocalizedError {
    case badURL
    case network(String)
    case server(String)
    case roomFull
    case roomNotFound
    case notYourTurn
    case illegalPlay(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址不正确"
        case .network(let m): return "网络错误：\(m)"
        case .server(let m): return m
        case .roomFull: return "房间已满"
        case .roomNotFound: return "房间不存在"
        case .notYourTurn: return "还没轮到你"
        case .illegalPlay(let m): return m
        }
    }
}

// MARK: - 联机客户端

/// 极简长轮询房间客户端。无 WebSocket 依赖，任意 PHP 环境可跑。
@MainActor
final class RoomClient: ObservableObject {

    @Published var baseURL: String = UserDefaults.standard.string(forKey: "ddz_server") ?? ""
    @Published var snapshot: OnlineRoomSnapshot?
    @Published var isConnected = false
    @Published var statusText = ""
    @Published var lastError: String = ""
    @Published var mySeat: Int = -1
    @Published var nickname: String = UserDefaults.standard.string(forKey: "ddz_nick") ?? "玩家"

    private var room: String = ""
    private var token: String = ""
    private var version: Int = -1
    private var pollTask: Task<Void, Never>?

    private var session: URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 40
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }

    private func endpoint() -> URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "http://" + s }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return URL(string: s + "/api.php")
    }

    // MARK: 请求

    private func post(_ params: [String: String]) async throws -> [String: Any] {
        guard let url = endpoint() else { throw RoomError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        var body = URLComponents()
        body.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw RoomError.network(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse, http.statusCode >= 500 {
            throw RoomError.server("服务器错误 \(http.statusCode)")
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else { throw RoomError.server("返回格式错误") }
        if let ok = dict["ok"] as? Bool, !ok {
            throw RoomError.server((dict["msg"] as? String) ?? "未知错误")
        }
        return dict
    }

    private func decode(_ dict: [String: Any]) -> OnlineRoomSnapshot? {
        guard let snapDict = dict["state"] as? [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: snapDict),
              let snap = try? JSONDecoder().decode(OnlineRoomSnapshot.self, from: data) else { return nil }
        return snap
    }

    // MARK: 对外操作

    func saveSettings() {
        UserDefaults.standard.set(baseURL, forKey: "ddz_server")
        UserDefaults.standard.set(nickname, forKey: "ddz_nick")
    }

    func createRoom() async throws -> String {
        let r = try await post(["action": "create", "nick": nickname])
        room = (r["room"] as? String) ?? ""
        token = (r["token"] as? String) ?? ""
        mySeat = (r["seat"] as? Int) ?? 0
        UserDefaults.standard.set(room, forKey: "ddz_room")
        UserDefaults.standard.set(token, forKey: "ddz_token")
        statusText = "房间 \(room) 已创建，等待玩家加入（座位 \(mySeat + 1)）"
        return room
    }

    func joinRoom(_ code: String) async throws {
        let r = try await post(["action": "join", "room": code, "nick": nickname])
        room = code
        token = (r["token"] as? String) ?? ""
        mySeat = (r["seat"] as? Int) ?? 0
        UserDefaults.standard.set(room, forKey: "ddz_room")
        UserDefaults.standard.set(token, forKey: "ddz_token")
        statusText = "已加入房间 \(code)（座位 \(mySeat + 1)）"
    }

    func ready() async throws {
        _ = try await post(["action": "ready", "room": room, "token": token, "seat": "\(mySeat)"])
        statusText = "已准备，等待开局"
    }

    func bid(_ value: Int) async throws {
        _ = try await post(["action": "bid", "room": room, "token": token,
                            "seat": "\(mySeat)", "value": "\(value)"])
    }

    func play(_ cards: [Card]) async throws {
        var parts: [String] = []
        for c in cards { parts.append("\(c.rank)-\(c.suit.rawValue)") }
        _ = try await post(["action": "play", "room": room, "token": token,
                            "seat": "\(mySeat)", "cards": parts.joined(separator: ",")])
    }

    func pass() async throws {
        _ = try await post(["action": "pass", "room": room, "token": token, "seat": "\(mySeat)"])
    }

    func leave() {
        pollTask?.cancel()
        pollTask = nil
        isConnected = false
    }

    func resumeIfPossible() -> Bool {
        room = UserDefaults.standard.string(forKey: "ddz_room") ?? ""
        token = UserDefaults.standard.string(forKey: "ddz_token") ?? ""
        return !room.isEmpty && !token.isEmpty
    }

    // MARK: 轮询

    /// 启动长轮询循环
    func startPolling() {
        pollTask?.cancel()
        version = -1
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                do {
                    let r = try await self.post([
                        "action": "poll", "room": self.room, "token": self.token,
                        "seat": "\(self.mySeat)", "since": "\(self.version)"
                    ])
                    if let snap = self.decode(r) {
                        self.version = snap.v
                        self.snapshot = snap
                        self.isConnected = true
                        self.lastError = ""
                        if !snap.message.isEmpty { self.statusText = snap.message }
                        else if snap.started { self.statusText = "对局进行中" }
                        else { self.statusText = "等待其他玩家…（\(snap.seatsFilled.filter { $0 }.count)/3）" }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.isConnected = false
                    self.lastError = error.localizedDescription
                    self.statusText = "连接中断，3 秒后重试"
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }
}
