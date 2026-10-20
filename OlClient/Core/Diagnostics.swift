//
//  Diagnostics.swift
//  OpenList iOS
//
//  轻量诊断日志。用户在设置页能看到最近的事件，
//  不需要连 Xcode 也能判断「点了没反应」到底卡在哪一步。
//

import Foundation
import SwiftUI

@MainActor
final class Diagnostics: ObservableObject {

    static let shared = Diagnostics()

    struct Entry: Identifiable {
        let id = UUID()
        let time = Date()
        let kind: Kind
        let message: String

        enum Kind { case info, warn, error }

        var symbol: String {
            switch kind {
            case .info: return "info.circle"
            case .warn: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }

        var color: Color {
            switch kind {
            case .info: return .secondary
            case .warn: return .orange
            case .error: return .red
            }
        }
    }

    @Published private(set) var entries: [Entry] = []

    private let maxEntries = 200

    func info(_ message: String) { append(.info, message) }
    func warn(_ message: String) { append(.warn, message) }
    func error(_ message: String) { append(.error, message) }

    func clear() { entries = [] }

    private func append(_ kind: Entry.Kind, _ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(Entry(kind: kind, message: trimmed), at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        // 同时打到系统日志，连 Xcode / Console 时也看得到
        NSLog("[OpenList][\(kind)] %@", trimmed)
    }
}

// MARK: - 诊断页

struct DiagnosticsScreen: View {

    @ObservedObject private var diag = Diagnostics.shared
    @State private var showConfirm = false

    var body: some View {
        Group {
            if diag.entries.isEmpty {
                EmptyState(title: "暂无日志",
                           detail: "操作过程中发生的错误会记录在这里，\n方便定位「点了没反应」的原因。",
                           symbol: "text.alignleft")
            } else {
                List {
                    Section {
                        ForEach(diag.entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Image(systemName: entry.symbol)
                                        .font(.caption)
                                        .foregroundStyle(entry.color)
                                    Text(entry.time, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .padding(.vertical, 1)
                        }
                    } footer: {
                        Text("共 \(diag.entries.count) 条，最多保留 200 条。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = diag.entries
                            .map { "\($0.time.formatted(date: .omitted, time: .standard)) [\($0.kind)] \($0.message)" }
                            .joined(separator: "\n")
                        ToastCenter.shared.show("已复制全部日志")
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        showConfirm = true
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("清空日志？", isPresented: $showConfirm) {
            Button("清空", role: .destructive) { diag.clear() }
            Button("取消", role: .cancel) {}
        }
    }
}
