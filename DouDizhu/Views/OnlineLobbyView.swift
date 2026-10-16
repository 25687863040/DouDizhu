import SwiftUI

/// 联机大厅：服务器设置 + 建房/加入 + 在线牌桌
struct OnlineLobbyContent: View {
    @StateObject private var client = RoomClient()
    @State private var joinCode: String = ""
    @State private var showSettings = false
    @State private var busy = false
    @StateObject private var vm = TableViewModel()
    @State private var inRoom = false

    var body: some View {
        Group {
            if inRoom, client.snapshot != nil {
                OnlineTable(client: client, vm: vm)
            } else {
                lobbyForm
            }
        }
        .onChange(of: client.snapshot) { _, snap in
            guard let snap = snap else { return }
            vm.isOnline = true
            vm.applyOnlineState(snap)
            // 联机模式下本地不自动跑 AI
            if !inRoom, snap.started {
                inRoom = true
                client.startPolling()
            }
        }
        .alert("出错了", isPresented: .constant(!client.lastError.isEmpty)) {
            Button("好") { client.lastError = "" }
        } message: {
            Text(client.lastError)
        }
    }

    private var lobbyForm: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 服务器地址
                VStack(alignment: .leading, spacing: 8) {
                    Text("服务器地址")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    TextField("http://你的域名/api.php 所在地址", text: $client.baseURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("把工程里的 server/api.php 传到任意 PHP 空间，填目录地址即可")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }

                // 昵称
                VStack(alignment: .leading, spacing: 8) {
                    Text("昵称")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    TextField("你的昵称", text: $client.nickname)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(11)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                        .foregroundStyle(.white)
                }

                // 状态
                if !client.statusText.isEmpty {
                    Text(client.statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(client.isConnected ? Color.green : Color.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }

                // 操作
                Button {
                    Task {
                        busy = true
                        client.saveSettings()
                        defer { busy = false }
                        do {
                            try await client.createRoom()
                            vm.isOnline = true
                            vm.game = GameState()
                            client.startPolling()
                        } catch {
                            client.lastError = error.localizedDescription
                        }
                    }
                } label: {
                    actionLabel("创建房间", emoji: "➕", color: .orange, busy: busy)
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    TextField("房间号", text: $joinCode)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)

                    Button {
                        Task {
                            busy = true
                            client.saveSettings()
                            defer { busy = false }
                            do {
                                try await client.joinRoom(joinCode.trimmingCharacters(in: .whitespaces))
                                vm.isOnline = true
                                client.startPolling()
                            } catch {
                                client.lastError = error.localizedDescription
                            }
                        }
                    } label: {
                        Text(busy ? "…" : "加入")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 88, height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.blue.opacity(0.85))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private func actionLabel(_ t: String, emoji: String, color: Color, busy: Bool) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView().tint(.white) } else { Text(emoji) }
            Text(busy ? "处理中…" : t)
                .font(.system(size: 16, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(color.opacity(0.85)))
    }
}

/// 联机牌桌
struct OnlineTable: View {
    @ObservedObject var client: RoomClient
    @ObservedObject var vm: TableViewModel
    @State private var actionBusy = false

    private var mySeatIndex: Int { client.mySeat }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.45, blue: 0.27),
                                    Color(red: 0.07, green: 0.30, blue: 0.18)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            GeometryReader { geo in
                VStack(spacing: 0) {
                    topBar
                    opponents
                    center
                    Spacer(minLength: 4)
                    handArea
                    bottomBar
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("房间 \(client.room.isEmpty ? "----" : client.room)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text(client.statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(client.isConnected ? Color.green : Color.orange)
            }
            Spacer()
            if client.mySeat >= 0 {
                Text("座位 \(client.mySeat + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.25)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var opponents: some View {
        HStack(alignment: .top, spacing: 0) {
            rivalColumn(seatOffset: 1, label: "下家")
            Spacer()
            rivalColumn(seatOffset: 2, label: "上家")
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    /// seatOffset: 相对我（1=下家，2=上家），对应本地 Seat.right / .left
    private func rivalColumn(seatOffset: Int, label: String) -> some View {
        let seat: Seat = seatOffset == 1 ? .right : .left
        let isLL = vm.game.landlord == seat
        let count = vm.handCount(seat)
        return VStack(spacing: 4) {
            AvatarView(name: label,
                       emoji: seatOffset == 1 ? "🧑" : "🧑",
                       count: count,
                       isLandlord: isLL,
                       isCurrent: vm.game.currentSeat == seat && !vm.game.isFinished,
                       role: isLL ? "地主" : nil)
            // 该家出过的牌
            let p = vm.playedCards(seat)
            if !p.isEmpty {
                Text(p.count > 1 ? "\(p.count)张" : (ComboParser.parse(Hand(p))?.name ?? ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.2)))
            }
        }
        .frame(width: 88)
    }

    private var center: some View {
        VStack(spacing: 8) {
            BottomCardsView(cards: vm.game.bottomCards, revealed: vm.game.landlord == .me)

            ZStack {
                if let combo = vm.game.tableCombo, !combo.cards.isEmpty {
                    VStack(spacing: 3) {
                        Text("\(vm.game.tableOwner?.name ?? "")·\(combo.name)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.28)))
                        CardRow(cards: combo.cards, size: .medium)
                    }
                    .id("\(vm.game.tableOwner?.rawValue ?? -1)-\(vm.animationToken)")
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else {
                    Text(vm.game.phase == .bidding ? "叫地主中…" : "")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(height: 96)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: vm.animationToken)
        }
    }

    private var handArea: some View {
        VStack(spacing: 3) {
            HStack {
                Text("你")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if vm.game.landlord == .me {
                    Text("地主")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.orange))
                }
                Spacer()
                Text("\(vm.myHand.count) 张")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                CardRow(cards: vm.myHand,
                        size: .large,
                        selected: vm.selected) { card in
                    vm.toggleSelect(card)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var bottomBar: some View {
        Group {
            if vm.game.isFinished {
                Button {
                    Task {
                        actionBusy = true
                        try? await client.ready()
                        actionBusy = false
                    }
                } label: {
                    barButton("再来一局", color: .orange)
                }
                .buttonStyle(.plain)
            } else if vm.game.phase == .bidding {
                if vm.game.currentSeat == .me {
                    HStack(spacing: 10) {
                        ForEach([1, 2, 3], id: \.self) { s in
                            Button {
                                Task {
                                    actionBusy = true
                                    try? await client.bid(s)
                                    actionBusy = false
                                }
                            } label: {
                                barButton(s == 3 ? "抢地主" : "\(s)分", color: s == 3 ? .orange : .blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    waitingText
                }
            } else {
                if vm.canAct {
                    HStack(spacing: 10) {
                        Button {
                            Task {
                                actionBusy = true
                                try? await client.pass()
                                actionBusy = false
                            }
                        } label: {
                            barButton("不出", color: .gray.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.game.tableCombo == nil)
                        .opacity(vm.game.tableCombo == nil ? 0.4 : 1)

                        Button {
                            let cards = vm.myHand.filter { vm.selected.contains($0.id) }
                            Task {
                                actionBusy = true
                                do {
                                    try await client.play(cards)
                                    vm.clearSelection()
                                } catch {
                                    client.lastError = error.localizedDescription
                                }
                                actionBusy = false
                            }
                        } label: {
                            barButton("出牌", color: vm.selected.isEmpty ? .gray.opacity(0.5) : .orange)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.selected.isEmpty)

                        Button { vm.showHint() } label: {
                            barButton("提示", color: .blue.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                } else if let snap = client.snapshot, !snap.started {
                    Button {
                        Task {
                            actionBusy = true
                            try? await client.ready()
                            actionBusy = false
                        }
                    } label: {
                        barButton("准 备", color: .green)
                    }
                    .buttonStyle(.plain)
                    .disabled(actionBusy)
                } else {
                    waitingText
                }
            }
        }
        .frame(height: 56)
        .padding(.bottom, 4)
    }

    private var waitingText: some View {
        Text(vm.game.currentSeat == .me ? "等待服务器确认…" : "等待其他玩家…")
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.85))
    }

    private func barButton(_ t: String, color: Color) -> some View {
        Text(t)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 92, height: 42)
            .background(RoundedRectangle(cornerRadius: 21, style: .continuous).fill(color))
    }
}
