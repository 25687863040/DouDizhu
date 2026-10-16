import SwiftUI

/// 单张扑克牌的绘制。
/// 支持大（手牌）、中（出牌）、小（背面）三种尺寸。
struct CardView: View {
    let card: Card
    var size: CardSize = .medium
    var isSelected: Bool = false
    var isDimmed: Bool = false
    var showSuit: Bool = true

    enum CardSize {
        case small, medium, large

        var width: CGFloat {
            switch self {
            case .small: return 38
            case .medium: return 52
            case .large: return 64
            }
        }
        var height: CGFloat {
            switch self {
            case .small: return 54
            case .medium: return 74
            case .large: return 90
            }
        }
        var fontSize: CGFloat {
            switch self {
            case .small: return 15
            case .medium: return 20
            case .large: return 25
            }
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size == .small ? 5 : 7, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: size == .small ? 1.5 : 3, y: 1.5)

            RoundedRectangle(cornerRadius: size == .small ? 5 : 7, style: .continuous)
                .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.8)

            if card.isJoker {
                jokerFace(size: size)
            } else {
                normalFace(size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            if isSelected {
                RoundedRectangle(cornerRadius: size == .small ? 5 : 7, style: .continuous)
                    .strokeBorder(Color.blue, lineWidth: 2.5)
            }
        }
        .opacity(isDimmed ? 0.45 : 1)
        .scaleEffect(isSelected ? 1.04 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isSelected)
    }

    private func normalFace(size s: CardSize) -> some View {
        let isRed = card.suit.isRed
        return VStack(alignment: .leading, spacing: -s.fontSize * 0.15) {
            Text(card.label)
                .font(.system(size: s.fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(isRed ? Color.red : Color.black)
            if showSuit {
                Text(card.suit.symbol)
                    .font(.system(size: s.fontSize * 0.85))
                    .foregroundStyle(isRed ? Color.red : Color.black)
            }
        }
        .padding(.leading, s.width * 0.09)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func jokerFace(size s: CardSize) -> some View {
        let isBig = card.rank == 17
        return VStack(spacing: -s.fontSize * 0.2) {
            Text(isBig ? "大" : "小")
                .font(.system(size: s.fontSize * 0.95, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
            Text("王")
                .font(.system(size: s.fontSize * 0.95, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
            if showSuit {
                Text(isBig ? "★" : "☆")
                    .font(.system(size: s.fontSize * 0.6))
                    .foregroundStyle(isBig ? Color.red : Color.blue)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 牌背
struct CardBackView: View {
    var width: CGFloat = 38
    var height: CGFloat = 54

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(red: 0.20, green: 0.42, blue: 0.78),
                                            Color(red: 0.11, green: 0.26, blue: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1.5)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                .padding(3)
        }
        .frame(width: width, height: height)
    }
}

/// 一组牌的展示（重叠排列）
struct CardRow: View {
    let cards: [Card]
    var size: CardSize = .medium
    var selected: Set<String> = []
    var onTap: ((Card) -> Void)? = nil

    /// 重叠间距：越小越紧凑
    private var overlap: CGFloat {
        switch size {
        case .small: return size.width * 0.42
        case .medium: return size.width * 0.40
        case .large: return size.width * 0.38
        }
    }

    var body: some View {
        let sorted = cards.sorted()
        let totalWidth = overlap * CGFloat(max(0, sorted.count - 1)) + size.width
        HStack(spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, c in
                let isSel = selected.contains(c.id)
                CardView(card: c, size: size, isSelected: isSel)
                    .offset(y: isSel ? -14 : 0)
                    .zIndex(Double(idx))
                    .onTapGesture {
                        if let onTap = onTap { onTap(c) }
                    }
                    .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isSel)
            }
        }
        .frame(width: totalWidth, height: size.height + 16, alignment: .bottom)
    }
}

/// 头像
struct AvatarView: View {
    var name: String
    var emoji: String
    var count: Int
    var isLandlord: Bool
    var isCurrent: Bool
    var role: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(colors: isLandlord
                                       ? [Color(red: 0.98, green: 0.72, blue: 0.20),
                                          Color(red: 0.92, green: 0.45, blue: 0.10)],
                                       startPoint: .top, endPoint: .bottom)
                        : [Color(red: 0.72, green: 0.80, blue: 0.90),
                           Color(red: 0.48, green: 0.58, blue: 0.72)],
                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)

                if isLandlord {
                    // 地主帽
                    VStack(spacing: -2) {
                        Text("👑")
                            .font(.system(size: 17))
                        Image(systemName: "crown.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(red: 0.85, green: 0.62, blue: 0.08))
                    }
                    .offset(y: -24)
                }

                Text(emoji)
                    .font(.system(size: 26))

                if isCurrent {
                    Circle()
                        .strokeBorder(Color.green, lineWidth: 3)
                        .frame(width: 58, height: 58)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // 剩余张数
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .offset(x: 6, y: 6)
            }

            HStack(spacing: 3) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                if let role = role {
                    Text(role)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(role == "地主" ? Color.orange : Color.blue.opacity(0.85)))
                }
            }
        }
    }
}

/// 底牌展示（地主视角 3 张）
struct BottomCardsView: View {
    let cards: [Card]
    var revealed: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text("底牌")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(cards) { c in
                    if revealed {
                        CardView(card: c, size: .small, showSuit: true)
                    } else {
                        CardBackView(width: 34, height: 48)
                    }
                }
            }
        }
    }
}
