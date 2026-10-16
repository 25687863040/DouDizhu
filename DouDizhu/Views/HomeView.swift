import SwiftUI

/// 首页：选择人机 / 联机
struct HomeView: View {
    @State private var showAI = false
    @State private var showOnline = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.45, blue: 0.27),
                                    Color(red: 0.05, green: 0.22, blue: 0.14)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // 标题区
                VStack(spacing: 10) {
                    Text("🃏")
                        .font(.system(size: 64))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
                    Text("斗地主")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 3)
                    Text("经典三人斗地主 · 支持人机与联机对战")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.bottom, 44)

                // 装饰牌
                HStack(spacing: -12) {
                    ForEach(Array(decorCards.enumerated()), id: \.offset) { idx, c in
                        CardView(card: c, size: .large)
                            .rotationEffect(.degrees(Double(idx - 1) * 13))
                            .offset(y: abs(Double(idx - 1)) * 9)
                            .shadow(color: .black.opacity(0.3), radius: 5, y: 4)
                    }
                }
                .padding(.bottom, 46)

                VStack(spacing: 16) {
                    bigButton("人机对战", subtitle: "与两个 AI 对局", emoji: "🤖", color: .orange) {
                        showAI = true
                    }
                    bigButton("联机对战", subtitle: "三人联网，房间号匹配", emoji: "🌐", color: .blue) {
                        showOnline = true
                    }
                }
                .padding(.horizontal, 40)

                Spacer()

                Text("支持牌型：单张 / 对子 / 三张 / 三带一 / 三带二 / 顺子 / 连对 / 飞机 / 飞机带牌 / 四带二 / 炸弹 / 王炸")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 16)
            }
        }
        .fullScreenCover(isPresented: $showAI) {
            AIPickerView()
        }
        .fullScreenCover(isPresented: $showOnline) {
            OnlineLobbyView()
        }
    }

    private var decorCards: [Card] {
        [Card(rank: 14, suit: .heart), Card(rank: 17, suit: .jokerBig), Card(rank: 15, suit: .spade)]
    }

    private func bigButton(_ title: String, subtitle: String, emoji: String,
                           color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(emoji).font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 18)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(color.opacity(0.85))
            )
            .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
    }
}

/// 人机难度选择
struct AIPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var skill: AutoPlayer.Skill = .normal

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.10, green: 0.34, blue: 0.22).ignoresSafeArea()

                VStack(spacing: 18) {
                    Text("选择对手难度")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 30)

                    ForEach(AutoPlayer.Skill.allCases, id: \.self) { s in
                        skillCard(s)
                    }

                    Spacer()

                    Button {
                        vm.skill = skill
                        vm.startNewGame()
                        showTable = true
                    } label: {
                        Text("开始游戏")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: 25, style: .continuous).fill(Color.orange))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
                }
            }
            .navigationDestination(isPresented: $showTable) {
                TableView(vm: vm)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }

    @StateObject private var vm = TableViewModel()
    @State private var showTable = false

    private func skillCard(_ s: AutoPlayer.Skill) -> some View {
        Button {
            skill = s
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(desc(s))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Image(systemName: skill == s ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(skill == s ? Color.orange : .white.opacity(0.5))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(skill == s ? 0.18 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(skill == s ? Color.orange : Color.clear, lineWidth: 2)
            )
            .padding(.horizontal, 24)
        }
        .buttonStyle(.plain)
    }

    private func desc(_ s: AutoPlayer.Skill) -> String {
        switch s {
        case .easy: return "随手打牌，新手练手"
        case .normal: return "会拆牌会跟牌，日常对战"
        case .hard: return "算牌控场，炸弹不轻易出"
        }
    }
}

/// 联机大厅（占位，后续由 RoomClient 填充）
struct OnlineLobbyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.10, green: 0.28, blue: 0.45).ignoresSafeArea()
                OnlineLobbyContent()
            }
            .navigationTitle("联机对战")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回") { dismiss() }
                }
            }
        }
    }
}
