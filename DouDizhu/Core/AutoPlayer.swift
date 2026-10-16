import Foundation

/// 斗地主 AI。
/// 策略：出牌用「候选打分 + 剩余手牌结构评估」，跟牌优先最小压制牌，
/// 保留大牌与炸弹到关键时刻。
struct AutoPlayer {

    /// AI 难度
    enum Skill: Int, Codable, CaseIterable {
        case easy = 0, normal = 1, hard = 2

        var displayName: String {
            switch self {
            case .easy: return "初级"
            case .normal: return "普通"
            case .hard: return "高手"
            }
        }

        /// 跟牌时的「贪婪度」：越低越保守
        var greed: Double {
            switch self {
            case .easy: return 0.35
            case .normal: return 0.7
            case .hard: return 0.95
            }
        }
    }

    var skill: Skill = .normal
    /// 随机源（注入以便复现）
    var rng: SeededRandom

    init(skill: Skill = .normal, seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.skill = skill
        self.rng = SeededRandom(seed: seed)
    }

    // MARK: - 叫地主决策

    /// 叫地主：返回 true 表示抢地主
    func wantLandlord(hand: Hand) -> Bool {
        let counts = hand.counts()
        var score = 0.0
        // 大王
        if hand.contains(Card.bigJoker) { score += 3 }
        // 小王
        if hand.contains(Card.smallJoker) { score += 2 }
        // 2 的数量
        score += Double(counts[15] ?? 0) * 1.2
        // 炸弹
        score += Double(counts.values.filter { $0 == 4 }.count) * 4
        // 火箭
        if hand.contains(Card.bigJoker), hand.contains(Card.smallJoker) { score += 3 }
        // 手牌整齐度
        let decomp = HandDecomposition.analyze(hand)
        score += decomp.controlScore * 4

        let threshold: Double = {
            switch skill {
            case .easy: return 9.5
            case .normal: return 7.5
            case .hard: return 6.0
            }
        }()
        // 加一点随机，避免每局行为一致
        score += rng.nextDouble() * 1.5
        return score >= threshold
    }

    // MARK: - 出牌决策

    /// 决策：返回要出的牌，nil 表示「不出」（要不起）
    /// - Parameters:
    ///   - hand: 当前手牌
    ///   - prevCombo: 需要压过的牌，nil 表示我先手自由出
    ///   - rivalHandSizes: 三家剩余张数（自己 index 0）
    ///   - seatIndex: 自己座位
    func decide(hand: Hand,
                prevCombo: Combo?,
                rivalHandSizes: [Int],
                seatIndex: Int) -> Combo? {
        if hand.isEmpty { return nil }

        // 1) 能一把走完，直接出
        if let finish = MoveFinder.allMoves(hand).first(where: { $0.cards.count == hand.count }) {
            return finish
        }

        // 2) 自由出牌：打出当前拆解里估值最低的单元，优先出小牌型
        if prevCombo == nil {
            return leadMove(hand: hand, rivalHandSizes: rivalHandSizes, seatIndex: seatIndex)
        }

        // 3) 跟牌：判断要不要压
        return followMove(hand: hand, prev: prevCombo!, rivalHandSizes: rivalHandSizes, seatIndex: seatIndex)
    }

    // MARK: 自由出牌

    private func leadMove(hand: Hand, rivalHandSizes: [Int], seatIndex: Int) -> Combo? {
        let decomp = HandDecomposition.analyze(hand)
        let units = decomp.units

        // 单测：手牌很少 -> 直接一把梭
        if hand.count <= 2 {
            if let m = MoveFinder.allMoves(hand).first(where: { $0.cards.count == hand.count }) { return m }
        }

        // 局势判断：有人快出完了要压着打
        let minRival = rivalHandSizes.enumerated()
            .filter { $0.offset != seatIndex }
            .map { $0.element }.min() ?? 99
        let urgent = minRival <= 3

        var candidates: [Combo] = []
        for u in units {
            candidates.append(u.combo)
            // 三张可以带一张或带一对，扩大可选面
            if u.combo.kind == .triple {
                let rest = hand.removing(u.combo.cards)
                for extra in MoveFinder.allMoves(rest) where extra.kind == .single || extra.kind == .pair {
                    let merged = buildTripleWith(u.combo, extra, from: hand)
                    if let m = merged { candidates.append(m) }
                }
            }
            // 对子可拆出单张（当人手少时）
            if u.combo.kind == .pair, urgent, skill != .easy {
                if let first = u.combo.cards.first {
                    candidates.append(Combo(kind: .single, mainRank: first.rank, chain: 1, cards: [first]))
                }
            }
        }

        guard !candidates.isEmpty else {
            // 兜底：出最小单张
            if let c = hand.cards.min() { return Combo(kind: .single, mainRank: c.rank, chain: 1, cards: [c]) }
            return nil
        }

        // 打分：越小越优先出（除非是炸弹且对手快出完了要留着）
        let scored = candidates.map { combo -> (Combo, Double) in
            var score = 0.0
            score -= Double(combo.mainRank) * 1.0
            score += Double(combo.cards.count) * 0.35
            if combo.isBomb { score -= 12 }   // 强效牌型留着
            if urgent && !combo.isBomb { score -= 4 }

            // 出牌后的剩余结构评估（越整齐越好 -> 加分）
            let rest = hand.removing(combo.cards)
            let after = HandDecomposition.analyze(rest)
            score += after.controlScore * 8
            // 剩余张数越少越好
            score -= Double(rest.count) * 0.15

            return (combo, score)
        }

        let pool = skill == .easy ? Array(scored.prefix(1)) : scored
        let best = pool.min { $0.1 < $1.1 }
        return best?.0
    }

    // MARK: 跟牌

    private func followMove(hand: Hand, prev: Combo, rivalHandSizes: [Int], seatIndex: Int) -> Combo? {
        let options = MoveFinder.movesBeating(hand, prev: prev)
        guard !options.isEmpty else { return nil }   // 要不起

        let myCount = rivalHandSizes.count > seatIndex ? rivalHandSizes[seatIndex] : hand.count
        let minRival = rivalHandSizes.enumerated()
            .filter { $0.offset != seatIndex }
            .map { $0.element }.min() ?? 99

        // 只剩最后几手且能一把走 -> 必须出
        if myCount <= 3, let win = options.first(where: { $0.cards.count == myCount }) {
            return win
        }

        // 炸弹：平时留着，别人快出完了或者对方是地主时才考虑
        let bombs = options.filter { $0.isBomb }
        let normal = options.filter { !$0.isBomb }
        let landlordSeat = 0   // 简化：座位 0 视为地主候选
        let threatHigh = minRival <= 4 || (skill == .hard && minRival <= 6)
        if normal.isEmpty {
            if let bomb = bestBomb(bombs, hand: hand) { return bomb }
            return nil
        }
        // 对方快出完了 -> 用炸弹
        if threatHigh, !bombs.isEmpty, skill != .easy {
            if let bomb = bestBomb(bombs, hand: hand) { return bomb }
        }

        // 普通跟牌：选最小压制 + 出牌后结构最好的
        let scored = normal.map { combo -> (Combo, Double) in
            var score = 0.0
            score -= Double(combo.mainRank) * 1.4        // 越小越好
            score += Double(combo.cards.count) * 0.4
            let rest = hand.removing(combo.cards)
            let after = HandDecomposition.analyze(rest)
            score += after.controlScore * (4 + skill.greed * 6)
            score -= Double(rest.count) * 0.1
            return (combo, score)
        }
        let best = scored.min { $0.1 < $1.1 }
        return best?.0 ?? MoveFinder.smallestBeating(hand, prev: prev)
    }

    private func bestBomb(_ bombs: [Combo], hand: Hand) -> Combo? {
        bombs.min { $0.mainRank < $1.mainRank }
    }

    private func buildTripleWith(_ triple: Combo, _ extra: Combo, from hand: Hand) -> Combo? {
        let cards = triple.cards + extra.cards
        return ComboParser.parse(Hand(cards))
    }
}

// MARK: - 可复现随机数

/// 线性同余伪随机，保证同种子同序列
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() % 1_000_000) / 1_000_000.0
    }

    mutating func nextInt(_ upper: Int) -> Int {
        guard upper > 0 else { return 0 }
        return Int(next() % UInt64(upper))
    }

    mutating func shuffled<T>(_ arr: [T]) -> [T] {
        var a = arr
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) {
            let j = nextInt(i + 1)
            a.swapAt(i, j)
        }
        return a
    }
}
