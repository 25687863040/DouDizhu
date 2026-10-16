import SwiftUI

/// 牌桌主界面
struct TableView: View {
    @ObservedObject var vm: TableViewModel

    var body: some View {
        ZStack {
            // 绿色绒布桌
            LinearGradient(colors: [Color(red: 0.13, green: 0.45, blue: 0.27),
                                    Color(red: 0.07, green: 0.30, blue: 0.18)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            GeometryReader { geo in
                VStack(spacing: 0) {
                    topBar
                    opponentArea
                    centerArea
                    myHandArea
                    actionBar
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            if vm.showResult {
                ResultOverlay(vm: vm)
            }
        }
        .statusBarHidden(true)
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack {
            Button {
                vm.startNewGame()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.25)))
            }

            Spacer()

            VStack(spacing: 1) {
                Text("斗地主")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text("底分 \(vm.game.baseScore) · 倍数 \(vm.game.multiplier) · 总分 \(vm.totalScore)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            // 难度/模式标识
            Text(vm.isOnline ? "联机" : vm.skill.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(vm.isOnline ? Color.blue.opacity(0.7)
                                                          : Color.black.opacity(0.25)))
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: 对手区

    private var opponentArea: some View {
        HStack(alignment: .top, spacing: 0) {
            opponentColumn(.left, name: "左家", emoji: "🤖")
            Spacer()
            opponentColumn(.right, name: "右家", emoji: "🤖")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func opponentColumn(_ seat: Seat, name: String, emoji: String) -> some View {
        let isLL = vm.game.landlord == seat
        let role: String? = isLL ? "地主" : nil
        let isCur = vm.game.currentSeat == seat && !vm.game.isFinished

        return VStack(spacing: 5) {
            AvatarView(name: name,
                       emoji: emoji,
                       count: vm.handCount(seat),
                       isLandlord: isLL,
                       isCurrent: isCur,
                       role: role)

            // 该家打出的牌
            let cards = vm.playedCards(seat)
            if !cards.isEmpty {
                Text(cardsLabel(cards))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.22)))
            }
        }
        .frame(width: 92)
    }

    private func cardsLabel(_ cards: [Card]) -> String {
        guard let c = ComboParser.parse(Hand(cards)) else { return "\(cards.count)张" }
        return c.name
    }

    // MARK: 中央区域（底牌 + 桌面出牌）

    private var centerArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                BottomCardsView(cards: vm.game.bottomCards, revealed: vm.game.landlord == .me)
            }

            // 桌面出牌
            ZStack {
                if let combo = vm.game.tableCombo,
                   let owner = vm.game.tableOwner,
                   !combo.cards.isEmpty {
                    VStack(spacing: 3) {
                        Text("\(owner.name)·\(combo.name)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.28)))
                        CardRow(cards: combo.cards, size: .medium)
                    }
                    .id("\(owner.rawValue)-\(vm.animationToken)")
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                } else {
                    Text(vm.game.phase == .bidding ? "叫地主中…" : "")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(height: 100)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: vm.animationToken)

            if !vm.message.isEmpty {
                Text(vm.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.28)))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: 我的手牌

    private var myHandArea: some View {
        VStack(spacing: 4) {
            // 座次行
            HStack(spacing: 8) {
                AvatarView(name: "你",
                           emoji: "😀",
                           count: vm.myHand.count,
                           isLandlord: vm.game.landlord == .me,
                           isCurrent: vm.isMyTurn && !vm.game.isFinished,
                           role: vm.game.landlord == .me ? "地主" : nil)
                Spacer()
                if vm.game.isFinished {
                    Text("本局 \(vm.game.scoreDelta >= 0 ? "+" : "")\(vm.game.scoreDelta)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(vm.game.scoreDelta >= 0 ? Color.yellow : Color.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 20)

            // 手牌（扇形微弧）
            handFan
                .frame(height: CardView.CardSize.large.height + 22)
        }
        .padding(.top, 4)
    }

    private var handFan: some View {
        GeometryReader { geo in
            let cards = vm.myHand
            let n = cards.count
            let cardW = CGFloat(64)
            let overlap = n > 0 ? min(cardW * 0.42, (geo.size.width - cardW - 8) / CGFloat(max(1, n - 1))) : 0
            let totalW = overlap * CGFloat(max(0, n - 1)) + cardW

            HStack(spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { idx, c in
                    let isSel = vm.selected.contains(c.id)
                    // 弧形：中间高两边低
                    let t = n > 1 ? Double(idx) / Double(n - 1) - 0.5 : 0
                    let arc = -abs(t) * 2 * 26
                    CardView(card: c, size: .large, isSelected: isSel)
                        .offset(x: idx == 0 ? 0 : 0)
                        .rotationEffect(.degrees(t * 5))
                        .offset(y: arc + (isSel ? -16 : 0))
                        .onTapGesture { vm.toggleSelect(c) }
                        .zIndex(Double(idx))
                        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isSel)
                }
            }
            .frame(width: max(totalW, geo.size.width), alignment: .center)
            .position(x: geo.size.width / 2, y: geo.size.height / 2 + 6)
        }
    }

    // MARK: 操作栏

    private var actionBar: some View {
        HStack(spacing: 12) {
            if vm.isBidding {
                biddingButtons
            } else {
                playButtons
            }
        }
        .frame(height: 62)
        .padding(.bottom, 4)
    }

    private var biddingButtons: some View {
        HStack(spacing: 14) {
            if vm.game.currentSeat == .me {
                ForEach([1, 2, 3], id: \.self) { s in
                    Button {
                        vm.bid(.bid(s))
                    } label: {
                        Text(s == 3 ? "抢地主" : "\(s)分")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(s == 3 ? Color.orange : Color.blue.opacity(0.75))
                            )
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("\(vm.game.currentSeat.name)正在叫分…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var playButtons: some View {
        HStack(spacing: 14) {
            if vm.canAct {
                Button { vm.playPass() } label: {
                    Text("不出")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 21, style: .continuous)
                                .fill(Color.gray.opacity(0.55))
                        )
                }
                .buttonStyle(.plain)
                .disabled(vm.game.tableCombo == nil)
                .opacity(vm.game.tableCombo == nil ? 0.4 : 1)

                Button { vm.playSelected() } label: {
                    Text("出牌")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 92, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 21, style: .continuous)
                                .fill(vm.selected.isEmpty ? Color.gray.opacity(0.4) : Color.orange)
                        )
                }
                .buttonStyle(.plain)
                .disabled(vm.selected.isEmpty)

                Button { vm.showHint() } label: {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.yellow)
                        .frame(width: 46, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 21, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                        )
                }
                .buttonStyle(.plain)
            } else if vm.game.isFinished {
                Button { vm.startNewGame() } label: {
                    Text("再来一局")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 140, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.orange)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Text("\(vm.game.currentSeat.name)思考中…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

/// 结算弹窗
struct ResultOverlay: View {
    @ObservedObject var vm: TableViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 16) {
                Text(vm.game.scoreDelta >= 0 ? "🎉 赢了！" : "😢 输了")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(vm.game.scoreDelta >= 0 ? Color.yellow : Color.white)

                VStack(spacing: 6) {
                    resultRow("地主", vm.game.landlord?.name ?? "-",
                              highlight: vm.game.landlordWon == true)
                    Divider()
                    resultRow("赢家", vm.game.winner?.name ?? "-", highlight: false)
                    Divider()
                    HStack {
                        Text("本局得分")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Text("\(vm.game.scoreDelta >= 0 ? "+" : "")\(vm.game.scoreDelta)")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(vm.game.scoreDelta >= 0 ? Color.yellow : Color.white.opacity(0.9))
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 22)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(red: 0.15, green: 0.42, blue: 0.26))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                )

                HStack(spacing: 14) {
                    Button {
                        vm.showResult = false
                        vm.startNewGame()
                    } label: {
                        Text("再来一局")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 130, height: 44)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.orange))
                    }
                    .buttonStyle(.plain)

                    Button {
                        vm.showResult = false
                    } label: {
                        Text("看看牌局")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 110, height: 44)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(28)
        }
        .transition(.opacity)
    }

    private func resultRow(_ k: String, _ v: String, highlight: Bool) -> some View {
        HStack {
            Text(k).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(v).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(highlight ? Color.orange : Color.white)
        }
    }
}
