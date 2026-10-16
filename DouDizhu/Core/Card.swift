import Foundation

// MARK: - 单张牌

/// 斗地主 54 张牌的建模。
/// 点数编码：3...10 -> 3...10，J=11 Q=12 K=13 A=14 2=15，小王=16 大王=17
struct Card: Hashable, Codable, Identifiable, Comparable {
    let rank: Int
    let suit: Suit

    enum Suit: Int, Codable, Hashable, CaseIterable {
        case spade = 0, heart = 1, club = 2, diamond = 3
        case jokerSmall = 4
        case jokerBig = 5

        var symbol: String {
            switch self {
            case .spade: return "♠"
            case .heart: return "♥"
            case .club: return "♣"
            case .diamond: return "♦"
            case .jokerSmall: return "小"
            case .jokerBig: return "大"
            }
        }

        /// 红花色用红色显示
        var isRed: Bool {
            self == .heart || self == .diamond
        }
    }

    var id: String { "\(rank)-\(suit.rawValue)" }

    var isJoker: Bool {
        suit == .jokerSmall || suit == .jokerBig
    }

    /// 排序用：先按点数，再按花色（大小王最大）
    var sortKey: Int {
        rank * 10 + suit.rawValue
    }

    static func < (lhs: Card, rhs: Card) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.suit.rawValue < rhs.suit.rawValue
    }

    /// 牌面文字，如 "A" "2" "小王"
    var label: String {
        if isJoker { return rank == 17 ? "大王" : "小王" }
        switch rank {
        case 11: return "J"
        case 12: return "Q"
        case 13: return "K"
        case 14: return "A"
        case 15: return "2"
        default: return "\(rank)"
        }
    }

    /// 牌面短文字（大王/小王用单字）
    var shortLabel: String {
        if isJoker { return rank == 17 ? "王" : "王" }
        return label
    }

    static let bigJoker = Card(rank: 17, suit: .jokerBig)
    static let smallJoker = Card(rank: 16, suit: .jokerSmall)

    /// 生成一副完整的 54 张牌
    static func fullDeck() -> [Card] {
        var deck: [Card] = []
        for rank in 3...15 {
            for suit in [Suit.spade, .heart, .club, .diamond] {
                deck.append(Card(rank: rank, suit: suit))
            }
        }
        deck.append(Card.bigJoker)
        deck.append(Card.smallJoker)
        return deck
    }
}

// MARK: - 手牌

/// 一手牌（玩家手上或桌面已出的牌）
struct Hand {
    private(set) var cards: [Card]

    init(_ cards: [Card] = []) {
        self.cards = cards.sorted()
    }

    var count: Int { cards.count }
    var isEmpty: Bool { cards.isEmpty }

    /// 点数 -> 该点数的所有牌
    func cards(ofRank rank: Int) -> [Card] {
        cards.filter { $0.rank == rank }
    }

    /// 按点数分组，点数升序
    func rankGroups() -> [Int: [Card]] {
        var g: [Int: [Card]] = [:]
        for c in cards { g[c.rank, default: []].append(c) }
        return g
    }

    /// 每种点数的张数
    func counts() -> [Int: Int] {
        var d: [Int: Int] = [:]
        for c in cards { d[c.rank, default: 0] += 1 }
        return d
    }

    func contains(_ card: Card) -> Bool { cards.contains(card) }

    func removing(_ cards: [Card]) -> Hand {
        Hand(self.cards.filter { !cards.contains($0) })
    }

    func adding(_ cards: [Card]) -> Hand {
        Hand(self.cards + cards)
    }

}

// MARK: - 牌型

/// 斗地主全部牌型
enum ComboKind: Int, Codable, CaseIterable {
    case single            // 单张
    case pair              // 对子
    case triple            // 三张
    case tripleOne         // 三带一
    case triplePair        // 三带二（带一对）
    case straight          // 顺子（5 张以上连张）
    case doubleStraight    // 连对（3 对以上）
    case tripleStraight    // 飞机不带（2 组以上连三张）
    case airplaneSingles   // 飞机带单（每组带一张）
    case airplanePairs     // 飞机带对（每组带一对）
    case fourTwoSingles    // 四带二（4 + 2 张单牌）
    case fourTwoPairs      // 四带两对（4 + 2 个对子）
    case bomb              // 炸弹
    case rocket            // 王炸

    var displayName: String {
        switch self {
        case .single: return "单张"
        case .pair: return "对子"
        case .triple: return "三张"
        case .tripleOne: return "三带一"
        case .triplePair: return "三带二"
        case .straight: return "顺子"
        case .doubleStraight: return "连对"
        case .tripleStraight: return "飞机"
        case .airplaneSingles: return "飞机带单"
        case .airplanePairs: return "飞机带对"
        case .fourTwoSingles: return "四带二"
        case .fourTwoPairs: return "四带两对"
        case .bomb: return "炸弹"
        case .rocket: return "王炸"
        }
    }
}

/// 一手已识别出牌型的牌
struct Combo: Equatable, Codable {
    let kind: ComboKind
    /// 主牌（决定大小的那张/那组牌的点数）
    let mainRank: Int
    /// 连续牌型的长度（顺子 5 表示 5 连，连对 3 表示 3 连，飞机 2 表示 2 连三张）
    let chain: Int
    /// 参与组成该牌型的全部牌
    let cards: [Card]

    init(kind: ComboKind, mainRank: Int, chain: Int = 1, cards: [Card]) {
        self.kind = kind
        self.mainRank = mainRank
        self.chain = chain
        self.cards = cards.sorted()
    }

    var isBomb: Bool { kind == .bomb || kind == .rocket }

    var name: String {
        if kind == .straight || kind == .doubleStraight || kind == .tripleStraight
            || kind == .airplaneSingles || kind == .airplanePairs {
            return "\(kind.displayName)\(chain)连"
        }
        return kind.displayName
    }

    /// 这手牌能否压过 prev（nil 表示自由出牌）
    func beats(_ prev: Combo?) -> Bool {
        guard let prev = prev else { return true }
        // 王炸最大
        if kind == .rocket { return prev.kind != .rocket }
        if prev.kind == .rocket { return false }
        // 炸弹压一切非炸弹非王炸
        if kind == .bomb {
            if prev.kind == .bomb { return mainRank > prev.mainRank }
            return true
        }
        if prev.kind == .bomb { return false }
        // 必须同型
        guard kind == prev.kind else { return false }
        // 连牌型：先比长度，长的压短的
        switch kind {
        case .straight, .doubleStraight, .tripleStraight, .airplaneSingles, .airplanePairs:
            if chain != prev.chain { return chain > prev.chain }
        default:
            if chain != prev.chain { return false }
        }
        return mainRank > prev.mainRank
    }

    /// 生成一个等型的、用于展示/文本描述的字符串
    var shortText: String {
        switch kind {
        case .single: return Card(rank: mainRank, suit: .spade).label
        case .pair, .triple, .bomb:
            return String(repeating: Card(rank: mainRank, suit: .spade).label, count: cards.count)
        case .rocket: return "王炸"
        default:
            return name
        }
    }
}

// MARK: - 牌型识别器

enum ComboParser {

    /// 尝试把手里的牌识别成一个合法牌型，失败返回 nil
    static func parse(_ hand: Hand) -> Combo? {
        let cards = hand.cards
        guard !cards.isEmpty, cards.count <= 20 else { return nil }
        let counts = hand.counts()
        let ranks = counts.keys.sorted()
        let n = cards.count

        // 王炸
        if n == 2 && cards.contains(Card.bigJoker) && cards.contains(Card.smallJoker) {
            return Combo(kind: .rocket, mainRank: 17, chain: 1, cards: cards)
        }
        // 炸弹
        if n == 4, ranks.count == 1, let r = ranks.first, counts[r] == 4 {
            return Combo(kind: .bomb, mainRank: r, chain: 1, cards: cards)
        }

        switch n {
        case 1:
            return Combo(kind: .single, mainRank: cards[0].rank, chain: 1, cards: cards)

        case 2:
            if ranks.count == 1 { return Combo(kind: .pair, mainRank: ranks[0], chain: 1, cards: cards) }
            return nil

        case 3:
            if ranks.count == 1 { return Combo(kind: .triple, mainRank: ranks[0], chain: 1, cards: cards) }
            return nil

        case 4:
            // 三带一：三张同点 + 一张杂牌
            if let t = tripleRank(counts) {
                return Combo(kind: .tripleOne, mainRank: t, chain: 1, cards: cards)
            }
            return nil

        case 5:
            // 三带二：三张 + 一对
            if let t = tripleRank(counts) {
                let wing = counts.filter { $0.key != t && $0.value == 2 }
                if wing.count == 1 { return Combo(kind: .triplePair, mainRank: t, chain: 1, cards: cards) }
            }
            // 5 张也可能是顺子 -> 落到下面
            return straight(counts, cards: cards)

        default:
            break
        }

        // 四带二：4 + 2 单
        if n == 6, let f = fourRank(counts) {
            let rest = counts.filter { $0.key != f }
            let restCards = rest.values.reduce(0, +)
            if restCards == 2 { return Combo(kind: .fourTwoSingles, mainRank: f, chain: 1, cards: cards) }
            return nil
        }
        // 四带两对：4 + 2 对
        if n == 8, let f = fourRank(counts) {
            let rest = counts.filter { $0.key != f }
            if rest.count == 2, rest.values.allSatisfy({ $0 == 2 }) {
                return Combo(kind: .fourTwoPairs, mainRank: f, chain: 1, cards: cards)
            }
            return nil
        }

        // 顺子：>=5 张连续单牌，不含 2 和王
        if let s = straight(counts, cards: cards) { return s }
        // 连对：>=3 组连续对子
        if n >= 6, n % 2 == 0, isAllPairs(counts), let r = consecutiveGroups(counts, groupSize: 2, minGroups: 3) {
            return Combo(kind: .doubleStraight, mainRank: r.last!, chain: r.count, cards: cards)
        }
        // 飞机：在「有 >=3 张」的点数里找连续 >=2 组的主体，其余牌作翅膀
        if let chainRanks = consecutiveGroupsAtLeast(counts, groupSize: 3, minGroups: 2) {
            let k = chainRanks.count
            let rest = counts.filter { !chainRanks.contains($0.key) }
            let restCount = rest.values.reduce(0, +)
            let main = chainRanks.last!
            // 纯飞机
            if restCount == 0, n == k * 3 {
                return Combo(kind: .tripleStraight, mainRank: main, chain: k, cards: cards)
            }
            // 带 k 张单牌
            if n == k * 4, restCount == k {
                return Combo(kind: .airplaneSingles, mainRank: main, chain: k, cards: cards)
            }
            // 带 k 个对子
            if n == k * 5, rest.count == k, rest.values.allSatisfy({ $0 == 2 }) {
                return Combo(kind: .airplanePairs, mainRank: main, chain: k, cards: cards)
            }
        }
        return nil
    }

    // MARK: 工具

    private static func tripleRank(_ counts: [Int: Int]) -> Int? {
        for (r, c) in counts where c == 3 { return r }
        return nil
    }

    private static func fourRank(_ counts: [Int: Int]) -> Int? {
        for (r, c) in counts where c == 4 { return r }
        return nil
    }

    private static func isAllSingle(_ counts: [Int: Int]) -> Bool {
        counts.values.allSatisfy { $0 == 1 }
    }

    private static func isAllPairs(_ counts: [Int: Int]) -> Bool {
        counts.values.allSatisfy { $0 == 2 }
    }

    private static func isAllTriples(_ counts: [Int: Int]) -> Bool {
        counts.values.allSatisfy { $0 == 3 }
    }

    /// 顺子判定：全部单张、>=5 连、不含 2 和王
    private static func straight(_ counts: [Int: Int], cards: [Card]) -> Combo? {
        guard cards.count >= 5, isAllSingle(counts),
              let r = straightRanks(counts, minLen: 5) else { return nil }
        return Combo(kind: .straight, mainRank: r.last!, chain: r.count, cards: cards)
    }

    /// 顺子校验：点数不含 2(15) 和王，返回全部点数（必须连续且至少 minLen 个）
    private static func straightRanks(_ counts: [Int: Int], minLen: Int) -> [Int]? {
        let rs = counts.keys.sorted()
        guard rs.count >= minLen else { return nil }
        // 顺子不含 2 和王
        if rs.contains(where: { $0 >= 15 }) { return nil }
        for i in 1..<rs.count where rs[i] != rs[i - 1] + 1 { return nil }
        return rs
    }

    /// 连续组校验：每组 groupSize 张，共 >= minGroups 组，组间点数连续（不含 2/王）
    private static func consecutiveGroups(_ counts: [Int: Int], groupSize: Int, minGroups: Int) -> [Int]? {
        let groups = counts.filter { $0.value == groupSize }.keys.sorted()
        guard groups.count >= minGroups else { return nil }
        if groups.contains(where: { $0 >= 15 }) { return nil }
        for i in 1..<groups.count where groups[i] != groups[i - 1] + 1 { return nil }
        return groups
    }

    /// 在「每组 >= groupSize 张」的点数里找最长的一段连续组（>= minGroups 组）。
    /// 翅膀点数不参与连续性判定。
    private static func consecutiveGroupsAtLeast(_ counts: [Int: Int], groupSize: Int, minGroups: Int) -> [Int]? {
        let cands = counts.filter { $0.value >= groupSize && $0.key < 15 }.keys.sorted()
        guard cands.count >= minGroups else { return nil }

        var best: [Int]?
        var cur: [Int] = [cands[0]]
        for i in 1..<cands.count {
            if cands[i] == cands[i - 1] + 1 {
                cur.append(cands[i])
            } else {
                if cur.count >= minGroups, best == nil || cur.count > best!.count { best = cur }
                cur = [cands[i]]
            }
        }
        if cur.count >= minGroups, best == nil || cur.count > best!.count { best = cur }
        return best
    }
}
