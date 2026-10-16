import Foundation

/// 从一手牌里枚举出所有合法的出牌组合。
/// 同时服务于：AI 决策、出牌提示、托管。
enum MoveFinder {

    /// 枚举 hand 中所有可出的牌型（去重）
    static func allMoves(_ hand: Hand) -> [Combo] {
        guard !hand.isEmpty else { return [] }
        let counts = hand.counts()
        var seen = Set<String>()
        var result: [Combo] = []

        func add(_ combo: Combo?) {
            guard let c = combo else { return }
            let key = c.cards.map { $0.id }.sorted().joined(separator: ",")
            if seen.insert(key).inserted { result.append(c) }
        }

        // 单张 / 对子 / 三张 / 三带一 / 三带二
        for (r, cs) in counts {
            let group = hand.cards(ofRank: r)
            add(Combo(kind: .single, mainRank: r, chain: 1, cards: Array(group.prefix(1))))
            if group.count >= 2 {
                add(Combo(kind: .pair, mainRank: r, chain: 1, cards: Array(group.prefix(2))))
            }
            if group.count >= 3 {
                let t = Array(group.prefix(3))
                add(Combo(kind: .triple, mainRank: r, chain: 1, cards: t))
                for (wr, _) in counts where wr != r {
                    let wing = hand.cards(ofRank: wr)
                    add(Combo(kind: .tripleOne, mainRank: r, chain: 1, cards: t + Array(wing.prefix(1))))
                    if wing.count >= 2 {
                        add(Combo(kind: .triplePair, mainRank: r, chain: 1, cards: t + Array(wing.prefix(2))))
                    }
                }
            }
        }
        // 炸弹
        for (r, cs) in counts where cs == 4 {
            add(Combo(kind: .bomb, mainRank: r, chain: 1, cards: hand.cards(ofRank: r)))
        }
        // 王炸
        if counts[16] != nil, counts[17] != nil {
            add(Combo(kind: .rocket, mainRank: 17, chain: 1,
                      cards: [Card(rank: 16, suit: .jokerSmall), Card(rank: 17, suit: .jokerBig)]))
        }
        // 四带二（4 + 2 单）
        for (r, cs) in counts where cs == 4 {
            let group = hand.cards(ofRank: r)
            let others = counts.filter { $0.key != r }.flatMap { $0.value }.flatMap { rank -> [Card] in
                hand.cards(ofRank: rank)
            }
            guard others.count >= 2 else { continue }
            add(Combo(kind: .fourTwoSingles, mainRank: r, chain: 1, cards: group + Array(others.prefix(2))))
            // 四带两对：需要 2 个不同点数的对子
            let pairRanks = counts.filter { $0.key != r && $0.value >= 2 }.keys.sorted()
            if pairRanks.count >= 2 {
                let w = Array(hand.cards(ofRank: pairRanks[0]).prefix(2))
                    + Array(hand.cards(ofRank: pairRanks[1]).prefix(2))
                add(Combo(kind: .fourTwoPairs, mainRank: r, chain: 1, cards: group + w))
            }
        }
        // 顺子 / 连对 / 飞机（连续型走收集器，见文件末尾 bridge）
        bridge(hand, add: add)

        return result.sorted { $0.cards.count < $1.cards.count }
    }

    /// 枚举所有能压过 prev 的出牌。prev 为 nil 时返回全部。
    static func movesBeating(_ hand: Hand, prev: Combo?) -> [Combo] {
        allMoves(hand).filter { $0.beats(prev) }
    }

    /// 能管住 prev 的最小出牌（用于 AI 跟牌）
    static func smallestBeating(_ hand: Hand, prev: Combo?) -> Combo? {
        let cands = movesBeating(hand, prev: prev)
        guard !cands.isEmpty else { return nil }
        // 非炸弹优先
        let nonBomb = cands.filter { !$0.isBomb }
        let pool = nonBomb.isEmpty ? cands : nonBomb
        return pool.min { a, b in
            if a.mainRank != b.mainRank { return a.mainRank < b.mainRank }
            return a.cards.count < b.cards.count
        }
    }

    // MARK: - 连牌型枚举

    private static func addStraight(_ counts: [Int: Int], _ hand: Hand) {
        // 顺子：3..A 连续，每点 1 张
        let maxRank = 14
        var start = 3
        while start <= maxRank {
            var chain: [Int] = []
            var r = start
            while r <= maxRank, counts[r] != nil {
                chain.append(r)
                r += 1
            }
            if chain.count >= 5 {
                // 枚举该段内所有长度 >=5 的子顺
                for len in 5...chain.count {
                    for i in 0...(chain.count - len) {
                        let sub = Array(chain[i..<(i + len)])
                        let cards = sub.flatMap { hand.cards(ofRank: $0).prefix(1) }
                        result(Combo(kind: .straight, mainRank: sub.last!, chain: len, cards: cards))
                    }
                }
            }
            start = chain.isEmpty ? start + 1 : chain.last! + 1
        }
    }

    private static func addDoubleStraight(_ counts: [Int: Int], _ hand: Hand) {
        var start = 3
        while start <= 14 {
            var chain: [Int] = []
            var r = start
            while r <= 14, (counts[r] ?? 0) >= 2 {
                chain.append(r)
                r += 1
            }
            if chain.count >= 3 {
                for len in 3...chain.count {
                    for i in 0...(chain.count - len) {
                        let sub = Array(chain[i..<(i + len)])
                        let cards = sub.flatMap { Array(hand.cards(ofRank: $0).prefix(2)) }
                        result(Combo(kind: .doubleStraight, mainRank: sub.last!, chain: len, cards: cards))
                    }
                }
            }
            start = chain.isEmpty ? start + 1 : chain.last! + 1
        }
    }

    private static func addAirplanes(_ counts: [Int: Int], _ hand: Hand) {
        var start = 3
        while start <= 14 {
            var chain: [Int] = []
            var r = start
            while r <= 14, (counts[r] ?? 0) >= 3 {
                chain.append(r)
                r += 1
            }
            if chain.count >= 2 {
                for len in 2...chain.count {
                    for i in 0...(chain.count - len) {
                        let sub = Array(chain[i..<(i + len)])
                        let body = sub.flatMap { Array(hand.cards(ofRank: $0).prefix(3)) }
                        result(Combo(kind: .tripleStraight, mainRank: sub.last!, chain: len, cards: body))

                        // 飞机带单：len 张单牌（点数不在 sub 里）
                        var wingPool: [Card] = []
                        for (wr, wc) in counts where !sub.contains(wr) {
                            wingPool.append(contentsOf: Array(hand.cards(ofRank: wr).prefix(wc)))
                        }
                        if wingPool.count >= len {
                            let wings = Array(wingPool.prefix(len))
                            // 翅膀不能与主体点数重复，已保证
                            result(Combo(kind: .airplaneSingles, mainRank: sub.last!, chain: len, cards: body + wings))
                        }
                        // 飞机带对：len 个对子
                        let pairRanks = counts.filter { !sub.contains($0.key) && $0.value >= 2 }.keys.sorted()
                        if pairRanks.count >= len {
                            var pairs: [Card] = []
                            for pr in pairRanks.prefix(len) {
                                pairs.append(contentsOf: Array(hand.cards(ofRank: pr).prefix(2)))
                            }
                            result(Combo(kind: .airplanePairs, mainRank: sub.last!, chain: len, cards: body + pairs))
                        }
                    }
                }
            }
            start = chain.isEmpty ? start + 1 : chain.last! + 1
        }
    }

    // 收集器（顺子 / 连对 / 飞机经由 bridge 汇入）
}

// MARK: - 手牌拆解

/// 把一手牌拆成若干「牌型单元」，用于 AI 评估手牌结构。
struct HandDecomposition {
    struct Unit {
        let combo: Combo
        /// 该单元对整体胜率的估值（0...1，越大越关键）
        var value: Double
    }
    var units: [Unit] = []
    var hand: Hand

    static func analyze(_ hand: Hand) -> HandDecomposition {
        var remaining = hand
        var units: [Unit] = []

        // 1. 王炸永远是一个强单元
        if remaining.contains(Card.bigJoker), remaining.contains(Card.smallJoker) {
            units.append(Unit(combo: Combo(kind: .rocket, mainRank: 17, chain: 1,
                                            cards: [Card.smallJoker, Card.bigJoker]), value: 0.95))
            remaining = remaining.removing([Card.smallJoker, Card.bigJoker])
        }

        // 2. 炸弹
        let counts0 = remaining.counts()
        for (r, cs) in counts0 where cs == 4 {
            let group = remaining.cards(ofRank: r)
            units.append(Unit(combo: Combo(kind: .bomb, mainRank: r, chain: 1, cards: group), value: 0.9))
            remaining = remaining.removing(group)
        }

        // 3. 贪心拆：顺子 -> 飞机 -> 连对 -> 三张 -> 对子 -> 单张
        // 循环拆，能拆就拆
        var guardLoop = 0
        while !remaining.isEmpty, guardLoop < 40 {
            guardLoop += 1
            let before = remaining.count
            if let c = MoveFinder.movesBeating(remaining, prev: nil).first(where: {
                $0.kind == .straight && $0.cards.count >= 5
            }), let longest = MoveFinder.movesBeating(remaining, prev: nil)
                .filter({ $0.kind == .straight }).max(by: { $0.chain < $1.chain }) {
                let pick = c.kind == .straight ? longest : c
                units.append(Unit(combo: pick, value: 0.75))
                remaining = remaining.removing(pick.cards)
                continue
            }
            if let c = MoveFinder.movesBeating(remaining, prev: nil).first(where: {
                $0.kind == .tripleStraight || $0.kind == .airplaneSingles || $0.kind == .airplanePairs
            }) {
                units.append(Unit(combo: c, value: 0.75))
                remaining = remaining.removing(c.cards)
                continue
            }
            if let c = MoveFinder.movesBeating(remaining, prev: nil).first(where: {
                $0.kind == .doubleStraight
            }) {
                units.append(Unit(combo: c, value: 0.7))
                remaining = remaining.removing(c.cards)
                continue
            }
            if let c = MoveFinder.movesBeating(remaining, prev: nil).first(where: {
                $0.kind == .triple || $0.kind == .tripleOne || $0.kind == .triplePair
            }) {
                units.append(Unit(combo: c, value: 0.6))
                remaining = remaining.removing(c.cards)
                continue
            }
            if let c = MoveFinder.movesBeating(remaining, prev: nil).first(where: {
                $0.kind == .pair
            }) {
                units.append(Unit(combo: c, value: 0.4))
                remaining = remaining.removing(c.cards)
                continue
            }
            // 兜底：最小的一张单牌
            if let minCard = remaining.cards.min() {
                units.append(Unit(combo: Combo(kind: .single, mainRank: minCard.rank, chain: 1, cards: [minCard]),
                                  value: 0.2))
                remaining = remaining.removing([minCard])
            }
            if remaining.count == before { break }
        }

        units.sort { $0.value > $1.value }
        return HandDecomposition(units: units, hand: hand)
    }

    /// 手牌「可控度」：拆得越整齐、炸弹越多，值越高
    var controlScore: Double {
        guard !units.isEmpty else { return 0 }
        return units.map { $0.value }.reduce(0, +) / Double(units.count)
    }
}

// MARK: - 连续型枚举的桥接
//
// 顺子/连对/飞机的枚举写在独立 static 函数里，但要把结果汇入 allMoves 的
// 局部数组。用一个文件级收集槽回调来桥接（类型取 (Combo?) -> Void，
// 与 allMoves 内部的 add 完全一致）。

private var collector: ((Combo?) -> Void)?

private func result(_ c: Combo) { collector?(c) }

extension MoveFinder {
    /// 把顺子 / 连对 / 飞机的枚举结果并入 allMoves 的收集器
    static func bridge(_ hand: Hand, add: @escaping (Combo?) -> Void) {
        let saved = collector
        collector = add
        let counts = hand.counts()
        addStraight(counts, hand)
        addDoubleStraight(counts, hand)
        addAirplanes(counts, hand)
        collector = saved
    }
}
