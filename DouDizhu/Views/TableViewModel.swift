import SwiftUI
import Combine

/// 牌桌 ViewModel：驱动人机对局，同时兼容联机模式下的外部状态注入。
@MainActor
final class TableViewModel: ObservableObject {

    @Published var game: GameState = GameState()
    @Published var selected: Set<String> = []
    @Published var skill: AutoPlayer.Skill = .normal
    @Published var message: String = ""
    @Published var showResult = false
    @Published var hintIndex: Int = 0
    @Published var lastPlayedBy: Seat?
    @Published var lastPlayedCards: [Card] = []
    @Published var animationToken: Int = 0
    @Published var baseScore: Int = 1
    @Published var totalScore: Int = 0

    /// 联机模式：为 true 时不自动推进 AI
    var isOnline = false

    private var hintCycle: [[Card]] = []      // 提示候选：每项是一组可出的牌
    private var aiTask: Task<Void, Never>?

    var myHand: [Card] { game.hands[.me] ?? [] }
    var landlord: Seat? { game.landlord }
    var isMyTurn: Bool { game.currentSeat == .me && !game.isFinished }
    var canAct: Bool { isMyTurn && (game.phase == .playing || game.phase == .landlordChosen) }
    var isBidding: Bool { game.phase == .bidding }

    // MARK: - 开局

    func startNewGame() {
        aiTask?.cancel()
        game = GameState.newGame(skill: skill)
        game.baseScore = baseScore
        selected.removeAll()
        hintIndex = 0
        hintCycle = []
        message = ""
        showResult = false
        lastPlayedBy = nil
        lastPlayedCards = []
        baseScore = 1

        if !isOnline {
            scheduleAIIfNeeded()
        }
    }

    // MARK: - 叫地主

    func bid(_ action: BidAction) {
        guard isBidding else { return }
        game.applyBid(action, by: .me)
        if case .rob = action {
            message = "你抢到了地主"
        }
        if !game.isFinished && !isOnline {
            scheduleAIIfNeeded()
        }
    }

    // MARK: - 出牌

    func toggleSelect(_ card: Card) {
        guard canAct else { return }
        if selected.contains(card.id) {
            selected.remove(card.id)
        } else {
            selected.insert(card.id)
        }
        // 选满就尝试提示合法性（selected 存的是牌 id，要映射回 Card）
        let picked = myHand.filter { selected.contains($0.id) }
        if let combo = ComboParser.parse(Hand(picked)) {
            message = combo.name
        } else {
            message = ""
        }
    }

    func clearSelection() {
        selected.removeAll()
        message = ""
    }

    func selectAll() {
        guard canAct else { return }
        selected = Set(myHand.map { $0.id })
    }

    func playSelected() {
        guard canAct, !selected.isEmpty else { return }
        let cards = myHand.filter { selected.contains($0.id) }
        guard let combo = ComboParser.parse(Hand(cards)), combo.beats(game.tableCombo) else {
            message = game.tableCombo == nil ? "不是合法牌型" : "管不过上家"
            return
        }
        let cardsToPlay = combo.cards
        // 只打选中的牌（若选中了翅膀之外的部分，交给 combo.cards）
        selected.removeAll()
        message = ""
        doPlay(.play(cards: cardsToPlay))
    }

    func playPass() {
        guard canAct, game.tableCombo != nil else { return }
        selected.removeAll()
        message = ""
        doPlay(.pass)
    }

    private func doPlay(_ action: PlayAction) {
        let ok = game.play(action, by: .me)
        guard ok else { return }
        if !action.isPass {
            lastPlayedBy = .me
            lastPlayedCards = action.cards
            animationToken += 1
        }
        if game.isFinished {
            handleFinish()
            return
        }
        if !isOnline {
            scheduleAIIfNeeded()
        }
    }

    // MARK: - 提示

    func showHint() {
        guard canAct else { return }
        if hintCycle.isEmpty {
            hintCycle = game.hints()
        }
        guard !hintCycle.isEmpty else {
            message = "没有能管上的牌"
            return
        }
        let cards = hintCycle[hintIndex % hintCycle.count]
        hintIndex += 1
        selected = Set(cards.map { $0.id })
        if let combo = ComboParser.parse(Hand(cards)) {
            message = "提示：\(combo.name)"
        }
    }

    // MARK: - AI 驱动

    private func scheduleAIIfNeeded() {
        aiTask?.cancel()
        guard !isOnline else { return }
        aiTask = Task { [weak self] in
            await self?.advanceAIs()
        }
    }

    /// 依次推进所有 AI 座位的行动
    private func advanceAIs() async {
        var step = 0
        while !Task.isCancelled {
            step += 1
            if step > 200 { return }   // 保险丝

            let seat = game.currentSeat
            if seat == .me { return }   // 等玩家
            if game.isFinished { return }

            // 叫地主阶段
            if game.phase == .bidding {
                try? await Task.sleep(nanoseconds: 420_000_000)
                if Task.isCancelled { return }
                let seed = UInt64.random(in: 0...UInt64.max)
                let bid = game.aiBid(for: seat, skill: skill, seed: seed)
                game.applyBid(bid, by: seat)
                if game.isFinished { return }
                continue
            }

            // 出牌阶段
            if game.phase == .playing || game.phase == .landlordChosen {
                // 确保已进入 playing
                if game.phase == .landlordChosen {
                    game.phase = .playing
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }
                guard let action = game.aiPlayDecision(seat: seat, skill: skill,
                                                      seed: UInt64.random(in: 0...UInt64.max)) else { return }
                let before = game.currentSeat
                let ok = game.play(action, by: seat)
                if ok && !action.isPass {
                    lastPlayedBy = seat
                    lastPlayedCards = action.cards
                    animationToken += 1
                }
                if game.isFinished {
                    handleFinish()
                    return
                }
                if before == seat { return }  // 无进展，防死循环
                continue
            }
            return
        }
    }

    private func handleFinish() {
        showResult = true
        totalScore += game.scoreDelta
    }

    // MARK: - 联机模式：外部注入状态

    func applyOnlineState(_ snapshot: OnlineRoomSnapshot) {
        guard let g = snapshot.decodeGameState() else { return }
        // 保留本地已选中的牌（服务器不感知 UI 选中态）
        let keepSelection = selected
        game = g
        selected = keepSelection.filter { id in myHand.contains { $0.id == id } }
        if game.isFinished { showResult = true }
    }

    // MARK: - 便捷

    func handCount(_ seat: Seat) -> Int {
        game.handCounts[seat] ?? 0
    }

    func playedCards(_ seat: Seat) -> [Card] {
        game.playedCards[seat] ?? []
    }
}
