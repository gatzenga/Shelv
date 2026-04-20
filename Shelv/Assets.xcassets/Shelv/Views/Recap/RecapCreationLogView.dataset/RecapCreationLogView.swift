import SwiftUI

struct RecapCreationLogView: View {
    @EnvironmentObject var ckStatus: CloudKitSyncStatus
    @AppStorage("themeColor") private var themeColorName = "violet"

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        Group {
            if ckStatus.recapCreationLog.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(tr("No recap activity yet.", "Noch keine Recap-Aktivität."))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle(tr("Recap log", "Recap-Protokoll"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var blocks: [LogBlock] {
        groupLogs(ckStatus.recapCreationLog)
    }

    @ViewBuilder
    private func blockView(_ block: LogBlock) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(block.lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let style = classify(line)
        Text(display(line))
            .font(.system(.caption2, design: .monospaced).weight(style.weight))
            .foregroundStyle(style.color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, style.topPad)
    }

    private func classify(_ line: String) -> (weight: Font.Weight, color: Color, topPad: CGFloat) {
        if line.contains("══") {
            return (.bold, accentColor, 0)
        }
        if line.contains("── Trigger:") {
            return (.bold, .primary, 0)
        }
        if line.contains("Result: CREATED") || line.contains("Result: ADOPTED") || line.contains("Result: CONFLICT_RESOLVED") {
            return (.semibold, .green, 4)
        }
        if line.contains("Result: SKIPPED") || line.contains("Result: ABORTED") {
            return (.semibold, .secondary, 4)
        }
        if line.contains("Result: FAILED") || line.contains(": FAILED") {
            return (.semibold, .red, 4)
        }
        if line.contains(" Period:") || line.contains(" periodKey:") || line.contains(" recordName:") {
            return (.medium, .primary, 0)
        }
        return (.regular, .secondary, 0)
    }

    private func display(_ line: String) -> String {
        line.replacingOccurrences(of: "[RecapGen] ", with: "")
    }
}

// MARK: - Grouping

private struct LogBlock {
    let lines: [String]
}

private func groupLogs(_ entries: [String]) -> [LogBlock] {
    // entries are newest-first. We group chronologically (reverse), then un-reverse blocks.
    var groupsChrono: [[String]] = []
    var current: [String] = []
    for entry in entries.reversed() {
        let isBoundary = entry.contains("── Trigger:") || entry.contains("══")
        if isBoundary && !current.isEmpty {
            groupsChrono.append(current)
            current = []
        }
        current.append(entry)
    }
    if !current.isEmpty { groupsChrono.append(current) }
    return groupsChrono.reversed().map { LogBlock(lines: $0) }
}
