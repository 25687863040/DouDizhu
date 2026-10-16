import Foundation

/// 对局阶段
enum GamePhase: String, Codable {
    case idle              // 未开始
    case bidding           // 叫地主阶段
    case landlordChosen    // 地主已定，等待出牌
    case playing           // 出牌中
    case finished          // 已结束
}

/// 玩家座位（0=自己/下家方向按屏幕：0 自己，1 右上，2 左上）
enum Seat: Int, Codable, CaseIterable {
    case me = 0, right = 1, left = 2

    var next: Seat { Seat(rawValue: (rawValue + 1) % 3)! }
    var name: String {
        switch self {
        case .me: return "你"
        case .right: return "右家"
        case .left: return "左家"
        }
    }
}

/// 出牌动作
enum PlayAction: Codable {
    case play(cards: [Card])
    case pass

    var cards: [Card] {
        if case .play(let c) = self { return c }
        return []
    }

    var isPass: Bool {
        if case .pass = self { return true }
        return false
    }
}

/// 叫分阶段的动作
enum BidAction: Codable {
    case bid(Int)      // 0=不叫 1=1分 2=2分 3=3分(即抢地主)
    case rob            // 抢地主

    var score: Int {
        if case .bid(let s) = self { return s }
        return 0
    }
}

// MARK: - 单局状态

/// 一局斗地主的完整状态。三种模式共用：
/// 人机模式全部本地驱动；联机模式由服务端快照填充。
struct GameState: Codable {
    var phase: GamePhase = .idle

    /// 三个座位的手牌
    var hands: [Seat: [Card]] = [:]
    /// 地主座位
    var landlord: Seat?
    /// 底牌（3 张）
    var bottomCards: [Card] = []
    /// 底分
    var baseScore: Int = 1
    /// 倍数
    var multiplier: Int = 1

    /// 当前该出牌的座位
    var currentSeat: Seat = .me
    /// 桌面当前的牌（需要压过的）
    var tableCombo: Combo?
    /// 桌面出牌者
    var tableOwner: Seat?
    /// 各座位已出的牌堆
    var playedCards: [Seat: [Card]] = [:]
    /// 各座位剩余手牌张数（用于展示）
    var handCounts: [Seat: Int] = [:]

    /// 叫地主记录
    var bids: [Seat: BidAction] = [:]
    var currentBid: Int = 0
    var highestBidder: Seat?
    var bidTurnsLeft: Int = 0

    /// 结果
    var winner: Seat?
    var scoreDelta: Int = 0        // 从「我」视角的分数变化
    var landlordWon: Bool?
    var isFinished: Bool { phase == .finished }

    /// 我的手牌
    var myHand: Hand {
        Hand(hands[.me] ?? [])
    }

    func hand(_ seat: Seat) -> Hand {
        Hand(hands[seat] ?? [])
    }

    var mySeat: Seat { .me }

    /// 底牌 + 全部已出牌（地主可见）
    var myTotalCards: [Card] {
        (hands[.me] ?? []) + (playedCards.values.flatMap { $0 })
    }

    // MARK: 初始化

    /// 发牌：随机洗牌分给三家，底牌 3 张
    static func newGame(skill: AutoPlayer.Skill = .normal, seed: UInt64? = nil) -> GameState {
        var rng = SeededRandom(seed: seed ?? UInt64.random(in: 0...UInt64.max))
        let deck = rng.shuffled(Card.fullDeck())
        var g = GameState()
        g.phase = .bidding
        g.hands[.me] = Array(deck[0..<17])
        g.hands[.right] = Array(deck[17..<34])
        g.hands[.left] = Array(deck[34..<51])
        g.bottomCards = Array(deck[51..<54])
        g.currentSeat = .me
        g.bidTurnsLeft = 3
        g.handCounts = [.me: 17, .right: 17, .left: 17]
        return g
    }

    // MARK: - 叫地主

    /// 处理一个叫分动作
    mutating func applyBid(_ action: BidAction, by seat: Seat) {
        guard phase == .bidding else { return }
        bids[seat] = action

        if action.score > currentBid {
            currentBid = action.score
            highestBidder = seat
        }

        bidTurnsLeft -= 1
        let allBid = bids.count >= 3
        let bidSaturated = currentBid >= 3

        if allBid || bidSaturated {
            // 有人叫 3 分立即成为地主
            settleLandlord()
        } else if bidTurnsLeft <= 0 {
            // 一圈没人叫
            if let hb = highestBidder {
                settleLandlord()
            } else {
                // 无人叫地主 -> 重新发牌
                let fresh = GameState.newGame()
                self = fresh
            }
        } else {
            currentSeat = currentSeat.next
        }
    }

    /// AI 的叫地主决策
    func aiBid(for seat: Seat, skill: AutoPlayer.Skill, seed: UInt64) -> BidAction {
        var ai = AutoPlayer(skill: skill, seed: seed)
        let h = hand(seat)
        if ai.wantLandlord(hand: h) {
            let s = max(currentBid + 1, 2)
            return .bid(min(3, s))
        }
        // 跟叫：已有较高分则放弃
        return .bid(0)
    }

    private mutating func settleLandlord() {
        guard let hb = highestBidder else {
            // 无人叫 -> 重开
            let fresh = GameState.newGame()
            self = fresh
            return
        }
        landlord = hb
        phase = .landlordChosen
        // 地主拿底牌
        hands[hb] = (hands[hb] ?? []) + bottomCards
        handCounts[hb] = (hands[hb] ?? []).count
        // 地主先出
        currentSeat = hb
        tableCombo = nil
        tableOwner = nil
        baseScore = max(baseScore, currentBid)
        multiplier = max(1, currentBid)
    }

    // MARK: - 出牌

    /// 校验并执行一次出牌。返回是否成功
    @discardableResult
    mutating func play(_ action: PlayAction, by seat: Seat) -> Bool {
        guard phase == .playing || phase == .landlordChosen else { return false }
        guard seat == currentSeat else { return false }

        if action.isPass {
            // 只有在有牌需要压时才能过
            guard tableCombo != nil else { return false }
            currentSeat = currentSeat.next
            if currentSeat == tableOwner {
                // 回到出牌者新一轮，重新自由出牌
                tableCombo = nil
                tableOwner = nil
            }
            return true
        }

        let cards = action.cards
        guard !cards.isEmpty else { return false }
        let mine = hands[seat] ?? []
        guard cards.allSatisfy({ mine.contains($0) }) else { return false }

        let combo = ComboParser.parse(Hand(cards))
        guard let c = combo else { return false }
        guard c.beats(tableCombo) else { return false }

        // 生效
        hands[seat] = mine.filter { !cards.contains($0) }
        playedCards[seat, default: []].append(contentsOf: cards)
        handCounts[seat] = hands[seat]?.count ?? 0
        tableCombo = c
        tableOwner = seat

        // 出完 -> 结束
        if handCounts[seat] == 0 {
            finish(winnerSeat: seat)
            return true
        }

        currentSeat = currentSeat.next
        return true
    }

    private mutating func finish(winnerSeat: Seat) {
        phase = .finished
        winner = winnerSeat
        guard let ld = landlord else { return }
        landlordWon = (winnerSeat == ld)
        // 计分：基础分 * 倍数 * 春天惩罚
        let base = max(baseScore, 1)
        var mult = multiplier
        let remainingCards = playedCards.values.flatMap { $0 }.count
        if landlordWon == true {
            // 地主走完，剩余牌 <= 2 -> 春天，翻倍
            if remainingCards <= 2 { mult *= 2 }
        } else {
            // 农民走完，地主只出过 <= 2 手 -> 反春
            if landlord == .me, (playedCards[.me]?.count ?? 0) <= 2 { mult *= 2 }
            if let l = playedCards[ld]?.count, l <= 2 { mult *= 2 }
        }
        let delta = base * mult
        // 地主赢：地主 +2delta，两个农民各 -delta
        // 农民赢：地主 -2delta，两个农民各 +delta
        let iAmLandlord = (ld == .me)
        let iWon = (winnerSeat == .me)
        if landlordWon! {
            // 地主赢
            if iAmLandlord { scoreDelta = delta * 2 }
            else { scoreDelta = iWon ? delta : -delta }
        } else {
            // 农民赢
            if iAmLandlord { scoreDelta = -delta * 2 }
            else { scoreDelta = iWon ? delta : -delta }
        }
    }

    // MARK: AI 推进

    /// 让某个 AI 座位行动，返回本轮动作
    mutating func stepAI(seat: Seat, skill: AutoPlayer.Skill, seed: UInt64) -> PlayAction? {
        guard phase == .bidding, currentSeat == seat else { return nil }
        let bid = aiBid(for: seat, skill: skill, seed: seed)
        applyBid(bid, by: seat)
        return nil
    }

    /// AI 出牌决策（不直接落子，供 UI 播放动画）
    func aiPlayDecision(seat: Seat, skill: AutoPlayer.Skill, seed: UInt64) -> PlayAction? {
        guard phase == .playing || phase == .landlordChosen else { return nil }
        guard currentSeat == seat else { return nil }
        var ai = AutoPlayer(skill: skill, seed: seed)
        let h = hand(seat)
        let sizes = [handCounts[.me] ?? 0, handCounts[.right] ?? 0, handCounts[.left] ?? 0]
        if let combo = ai.decide(hand: h, prevCombo: tableCombo, rivalHandSizes: sizes, seatIndex: seat.rawValue) {
            return .play(cards: combo.cards)
        }
        return .pass
    }

    // MARK: 查询

    var landlordBottomCards: [Card] {
        (landlord == nil) ? [] : bottomCards
    }

    /// 当前是否可以出这组牌
    func canPlay(_ cards: [Card]) -> Bool {
        guard let c = ComboParser.parse(Hand(cards)) else { return false }
        return c.beats(tableCombo)
    }

    /// 出牌提示：返回一组建议出牌
    func hint() -> [Card] {
        let moves = MoveFinder.movesBeating(myHand, prev: tableCombo)
        guard let m = MoveFinder.smallestBeating(myHand, prev: tableCombo) else { return [] }
        return m.cards
    }

    /// 所有可出的牌组（提示循环用）
    func hints() -> [[Card]] {
        MoveFinder.movesBeating(myHand, prev: tableCombo)
            .sorted { $0.mainRank < $1.mainRank }
            .map { $0.cards }
    }
}
