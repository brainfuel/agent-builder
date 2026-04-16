import SwiftUI

struct ConnectionLayer: View {
    let nodes: [OrgNode]
    let links: [NodeLink]
    let cardSize: CGSize
    let selectedLinkID: UUID?
    let draft: LinkDraft?

    var body: some View {
        Canvas { context, _ in
            let geometries = buildLinkGeometries(nodes: nodes, links: links, cardSize: cardSize)

            for geometry in geometries {
                var path = Path()
                guard let first = geometry.points.first else { continue }
                path.move(to: first)
                for point in geometry.points.dropFirst() {
                    path.addLine(to: point)
                }

                let isSelected = geometry.link.id == selectedLinkID
                let strokeStyle = StrokeStyle(
                    lineWidth: isSelected ? 3.8 : (geometry.isSecondary ? 1.8 : 2.2),
                    lineCap: .round,
                    lineJoin: .round,
                    dash: geometry.isSecondary ? [6, 4] : []
                )
                let strokeColor = geometry.link.color.opacity(geometry.isSecondary ? 0.9 : 1)
                context.stroke(path, with: .color(strokeColor), style: strokeStyle)

                if let arrow = arrowHeadPath(for: geometry.points, size: isSelected ? 12 : 10) {
                    context.fill(arrow, with: .color(strokeColor))
                    context.stroke(
                        arrow,
                        with: .color(Color.white.opacity(0.92)),
                        style: StrokeStyle(lineWidth: isSelected ? 1.2 : 1.0, lineJoin: .round)
                    )
                }
            }

            if
                let draft,
                let source = nodes.first(where: { $0.id == draft.sourceID })
            {
                let start = CGPoint(
                    x: source.position.x,
                    y: source.position.y + (cardSize.height / 2) - 4
                )

                var previewPath = Path()
                previewPath.move(to: start)
                previewPath.addLine(to: draft.currentPoint)

                context.stroke(
                    previewPath,
                    with: .color(AppTheme.brandTint),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round, dash: [5, 4])
                )
            }
        }
    }

    private func arrowHeadPath(for points: [CGPoint], size: CGFloat) -> Path? {
        guard points.count >= 2 else { return nil }

        var tip: CGPoint?
        var base: CGPoint?
        for index in stride(from: points.count - 1, through: 1, by: -1) {
            let candidateTip = points[index]
            let candidateBase = points[index - 1]
            if hypot(candidateTip.x - candidateBase.x, candidateTip.y - candidateBase.y) > 0.001 {
                tip = candidateTip
                base = candidateBase
                break
            }
        }
        guard let tip, let base else { return nil }

        let dx = tip.x - base.x
        let dy = tip.y - base.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return nil }

        let ux = dx / length
        let uy = dy / length
        let px = -uy
        let py = ux

        // Pull the arrow slightly back from the endpoint so node cards don't visually hide it.
        let visibleTip = CGPoint(
            x: tip.x - ux * (size * 0.75),
            y: tip.y - uy * (size * 0.75)
        )
        let stemBack = CGPoint(
            x: visibleTip.x - ux * size * 1.45,
            y: visibleTip.y - uy * size * 1.45
        )
        let left = CGPoint(
            x: stemBack.x + px * size * 0.82,
            y: stemBack.y + py * size * 0.82
        )
        let right = CGPoint(
            x: stemBack.x - px * size * 0.82,
            y: stemBack.y - py * size * 0.82
        )

        var path = Path()
        path.move(to: visibleTip)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        return path
    }
}

struct LinkHandle: View {
    let isActive: Bool

    var body: some View {
        Circle()
            .fill(isActive ? AppTheme.nodeHuman : AppTheme.brandTint)
            .overlay(
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: 24, height: 24)
            .shadow(color: AppTheme.cardShadow, radius: 6, y: 2)
    }
}

struct AddChildHandle: View {
    var body: some View {
        Circle()
            .fill(AppTheme.brandTint)
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: 26, height: 26)
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

struct LinkDraft {
    let sourceID: UUID
    let currentPoint: CGPoint
    let hoveredTargetID: UUID?
}

struct LinkGeometry {
    let link: NodeLink
    let points: [CGPoint]
    let isSecondary: Bool
}

func buildLinkGeometries(
    nodes: [OrgNode],
    links: [NodeLink],
    cardSize: CGSize
) -> [LinkGeometry] {
    let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let primaryLinks = links.filter { $0.edgeType == .primary }
    let secondaryLinks = links.filter { $0.edgeType == .tap }

    let parentIDs = Set(primaryLinks.map(\.fromID))
    let parentNodes = nodes.filter { parentIDs.contains($0.id) }
    var groupedParents: [Int: [OrgNode]] = [:]
    for parent in parentNodes {
        let levelKey = Int((parent.position.y / 10).rounded())
        groupedParents[levelKey, default: []].append(parent)
    }

    var laneOffsetByParentID: [UUID: CGFloat] = [:]
    let levelStep: CGFloat = 14
    for (_, parentsAtLevel) in groupedParents {
        let sorted = parentsAtLevel.sorted { $0.position.x < $1.position.x }
        let midpoint = CGFloat(sorted.count - 1) / 2
        for (index, parent) in sorted.enumerated() {
            laneOffsetByParentID[parent.id] = (CGFloat(index) - midpoint) * levelStep
        }
    }

    let groupedPrimary = Dictionary(grouping: primaryLinks, by: \.fromID)
    var laneYByParentID: [UUID: CGFloat] = [:]
    for (parentID, parentLinks) in groupedPrimary {
        guard let parent = nodeMap[parentID] else { continue }
        let children = parentLinks.compactMap { link in nodeMap[link.toID] }
        guard !children.isEmpty else { continue }

        let parentBottomY = parent.position.y + (cardSize.height / 2) - 4
        let childTopYs = children.map { $0.position.y - (cardSize.height / 2) + 4 }
        let childTopMinY = childTopYs.min() ?? parentBottomY + 40
        let baseLaneY = parentBottomY + 52 + (laneOffsetByParentID[parentID] ?? 0)
        laneYByParentID[parentID] = min(max(parentBottomY + 14, baseLaneY), childTopMinY - 16)
    }

    // For children with multiple incoming primary links, force a shared merge lane
    // so all incoming wires meet cleanly at the same Y.
    let incomingByChildID = Dictionary(grouping: primaryLinks, by: \.toID)
    var mergeLaneYByChildID: [UUID: CGFloat] = [:]
    for (childID, incoming) in incomingByChildID where incoming.count > 1 {
        guard let child = nodeMap[childID] else { continue }
        let childTopY = child.position.y - (cardSize.height / 2) + 4
        let parentBottomYs = incoming.compactMap { link -> CGFloat? in
            guard let parent = nodeMap[link.fromID] else { return nil }
            return parent.position.y + (cardSize.height / 2) - 4
        }
        guard let maxParentBottomY = parentBottomYs.max() else { continue }

        let upperBound = childTopY - 16
        let lowerBound = maxParentBottomY + 12
        let preferred = maxParentBottomY + 44
        let mergeY: CGFloat
        if lowerBound <= upperBound {
            mergeY = min(max(preferred, lowerBound), upperBound)
        } else {
            mergeY = (maxParentBottomY + childTopY) / 2
        }
        mergeLaneYByChildID[childID] = mergeY
    }

    var result: [LinkGeometry] = []

    for link in primaryLinks {
        guard
            let parent = nodeMap[link.fromID],
            let child = nodeMap[link.toID]
        else { continue }

        let start = CGPoint(
            x: parent.position.x,
            y: parent.position.y + (cardSize.height / 2) - 4
        )
        let end = CGPoint(
            x: child.position.x,
            y: child.position.y - (cardSize.height / 2) + 4
        )
        let laneY =
            mergeLaneYByChildID[link.toID]
            ?? laneYByParentID[link.fromID]
            ?? ((start.y + end.y) / 2)
        result.append(
            LinkGeometry(
                link: link,
                points: [start, CGPoint(x: start.x, y: laneY), CGPoint(x: end.x, y: laneY), end],
                isSecondary: false
            )
        )
    }

    let sortedSecondary = secondaryLinks.sorted { lhs, rhs in
        if lhs.fromID == rhs.fromID {
            return lhs.toID.uuidString < rhs.toID.uuidString
        }
        return lhs.fromID.uuidString < rhs.fromID.uuidString
    }
    for (index, link) in sortedSecondary.enumerated() {
        guard
            let from = nodeMap[link.fromID],
            let to = nodeMap[link.toID]
        else { continue }

        let start = CGPoint(
            x: from.position.x,
            y: from.position.y + (cardSize.height / 2) - 4
        )
        let end = CGPoint(
            x: to.position.x,
            y: to.position.y - (cardSize.height / 2) + 4
        )
        let detourY = max(start.y, end.y) + 70 + CGFloat(index % 4) * 14
        result.append(
            LinkGeometry(
                link: link,
                points: [start, CGPoint(x: start.x, y: detourY), CGPoint(x: end.x, y: detourY), end],
                isSecondary: true
            )
        )
    }

    return result
}

struct DotGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28
            let dotSize: CGFloat = 1.6
            let dotColor = Color.gray.opacity(0.28)

            for x in stride(from: CGFloat(0), through: size.width, by: spacing) {
                for y in stride(from: CGFloat(0), through: size.height, by: spacing) {
                    let dot = Path(
                        ellipseIn: CGRect(
                            x: x - dotSize / 2,
                            y: y - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                    )
                    context.fill(dot, with: .color(dotColor))
                }
            }
        }
    }
}

enum NodeExecutionState {
    case idle
    case running
    case succeeded
    case failed
}

struct NodeCard: View {
    let node: OrgNode
    let isSelected: Bool
    let isLinkTargeted: Bool
    let isOrphan: Bool
    var executionState: NodeExecutionState = .idle

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(node.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Circle()
                        .fill(Color(uiColor: .tertiaryLabel))
                        .frame(width: 4, height: 4)
                    Text(node.department)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.subheadline)
                HStack(spacing: 8) {
                    typeBadge
                    if node.type == .agent {
                        modelBadge
                    }
                }
            }
            Spacer(minLength: 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    executionBorderColor ?? (isSelected
                        ? AppTheme.brandTint
                        : (isLinkTargeted ? AppTheme.nodeHuman : defaultBorderColor)),
                    style: StrokeStyle(
                        lineWidth: isSelected || isLinkTargeted || executionState != .idle ? 2.5 : 1,
                        dash: isOrphan && !isSelected && !isLinkTargeted ? [6, 4] : []
                    )
                )
        )
        .opacity(isOrphan ? 0.55 : 1)
        .shadow(
            color: executionGlowColor ?? AppTheme.cardShadow,
            radius: executionState == .running ? 14 : 8,
            y: executionState == .running ? 0 : 3
        )
    }

    private var cardBackgroundColor: Color {
        switch node.type {
        case .input:
            return AppTheme.nodeInput.opacity(0.06)
        case .output:
            return AppTheme.nodeOutput.opacity(0.06)
        case .agent:
            return AppTheme.surfacePrimary
        case .human:
            return AppTheme.surfacePrimary
        }
    }

    private var executionBorderColor: Color? {
        switch executionState {
        case .idle: return nil
        case .running: return AppTheme.brandTint
        case .succeeded: return AppTheme.nodeHuman
        case .failed: return .red
        }
    }

    private var executionGlowColor: Color? {
        switch executionState {
        case .idle: return nil
        case .running: return AppTheme.brandTint.opacity(0.3)
        case .succeeded: return AppTheme.nodeHuman.opacity(0.2)
        case .failed: return Color.red.opacity(0.2)
        }
    }

    private var defaultBorderColor: Color {
        switch node.type {
        case .input:
            return AppTheme.nodeInput.opacity(0.4)
        case .output:
            return AppTheme.nodeOutput.opacity(0.4)
        case .agent:
            return AppTheme.cardBorder
        case .human:
            return AppTheme.nodeHuman.opacity(0.3)
        }
    }

    private var avatar: some View {
        Circle()
            .fill(LinearGradient(
                colors: avatarGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                Text(node.initials)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
            )
            .frame(width: 42, height: 42)
    }

    private var avatarGradientColors: [Color] {
        switch node.type {
        case .agent:
            return [AppTheme.nodeAgent, AppTheme.brandTint]
        case .human:
            return [AppTheme.nodeHuman, AppTheme.nodeHuman.opacity(0.7)]
        case .input:
            return [AppTheme.nodeInput, AppTheme.nodeInput.opacity(0.7)]
        case .output:
            return [AppTheme.nodeOutput, AppTheme.nodeOutput.opacity(0.7)]
        }
    }

    private var typeBadge: some View {
        Text(node.type.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(typeBadgeColor)
            )
    }

    private var typeBadgeColor: Color {
        switch node.type {
        case .agent:
            return AppTheme.nodeAgent.opacity(0.14)
        case .human:
            return AppTheme.nodeHuman.opacity(0.14)
        case .input:
            return AppTheme.nodeInput.opacity(0.14)
        case .output:
            return AppTheme.nodeOutput.opacity(0.14)
        }
    }

    private var modelBadge: some View {
        Text(node.provider.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.gray.opacity(0.15))
            )
    }
}

struct FlowLayout<Item: Hashable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let content: (Item) -> Content
    @State private var totalHeight: CGFloat = 44

    init(
        items: [Item],
        spacing: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            generateContent(in: proxy)
                .background(
                    GeometryReader { innerProxy in
                        Color.clear.preference(
                            key: FlowLayoutHeightPreferenceKey.self,
                            value: innerProxy.size.height
                        )
                    }
                )
        }
        .frame(height: totalHeight)
        .onPreferenceChange(FlowLayoutHeightPreferenceKey.self) { newHeight in
            let clamped = max(44, newHeight)
            if abs(clamped - totalHeight) > 0.5 {
                totalHeight = clamped
            }
        }
    }

    private func generateContent(in geo: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.self) { item in
                content(item)
                    .padding(.all, spacing / 2)
                    .alignmentGuide(.leading) { dimensions in
                        if abs(width - dimensions.width) > geo.size.width {
                            width = 0
                            height -= dimensions.height + spacing
                        }
                        let result = width
                        if item == items.last {
                            width = 0
                        } else {
                            width -= dimensions.width + spacing
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item == items.last {
                            height = 0
                        }
                        return result
                    }
            }
        }
    }
}

struct FlowLayoutHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 44

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

