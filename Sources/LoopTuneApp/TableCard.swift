import SwiftUI
import AppKit

/// Standardized wrapper for native macOS tables in the results view: a
/// consistent title/subtitle header, an optional trailing accessory (e.g. a
/// Copy button), an optional footer line, and shared table styling.
///
/// Usage:
/// ```swift
/// TableCard(title: "…", subtitle: "…", footer: "…") {
///     Table(rows, selection: $selection) { TableColumn(…) { … } }
///         .resultsTable(rowCount: rows.count)
/// } accessory: {
///     Button("Copy") { … }
/// }
/// ```
struct TableCard<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    var footer: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory

    init(
        title: String,
        subtitle: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                accessory()
            }

            content()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )

            if let footer {
                Text(footer)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// Shared styling for a results table: inset style, alternating row
    /// backgrounds, internal scrolling disabled (the results pane's outer
    /// ScrollView owns scrolling), and a frame that hugs the content exactly.
    ///
    /// Rather than guessing at row metrics, this reaches into the backing
    /// `NSTableView`, applies `rowHeight`, and computes the frame from the
    /// table's real header/row/spacing values — so no phantom striped rows
    /// appear below the content and the last row is never clipped.
    func resultsTable(rowCount: Int, rowHeight: CGFloat = 26) -> some View {
        modifier(ResultsTableStyle(rowCount: rowCount, rowHeight: rowHeight))
    }

    /// A numeric table cell: right-aligned, monospaced digits.
    func numericCell() -> some View {
        self
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct ResultsTableStyle: ViewModifier {
    var rowCount: Int
    var rowHeight: CGFloat
    @State private var measuredHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .tableStyle(.inset)
            .alternatingRowBackgrounds(.enabled)
            .scrollDisabled(true)
            // Request the row height through SwiftUI's own API — never by
            // mutating the NSTableView, which AppKit flags as a reentrant
            // delegate operation when it happens inside a table update.
            .environment(\.defaultMinListRowHeight, rowHeight)
            .frame(height: measuredHeight ?? fallbackHeight)
            .background(TableMetricsSync(rowCount: rowCount, height: $measuredHeight))
    }

    /// Used only until the real metrics are measured (first layout pass).
    private var fallbackHeight: CGFloat {
        CGFloat(rowCount) * (rowHeight + 2) + 30
    }
}

/// Locates the `NSTableView` backing the adjacent SwiftUI `Table` and reports
/// the exact content height (header + rows + intercell spacing + scroll-view
/// insets) back to SwiftUI.
///
/// Strictly READ-ONLY: it never mutates the table. SwiftUI owns that
/// `NSTableView`, and writing to it (e.g. `rowHeight`) from inside an update
/// cycle triggers AppKit's "reentrant operation in its NSTableView delegate"
/// warning — a future assert. Row height is requested via
/// `defaultMinListRowHeight` instead, and whatever height the table actually
/// uses is measured here.
private struct TableMetricsSync: NSViewRepresentable {
    var rowCount: Int
    @Binding var height: CGFloat?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let rowCount = rowCount
        DispatchQueue.main.async {
            guard let tableView = Self.findTableView(near: nsView, expectedRows: rowCount) else { return }
            let header = tableView.headerView?.frame.height ?? 0
            let spacing = tableView.intercellSpacing.height
            var total = header + CGFloat(rowCount) * (tableView.rowHeight + spacing)
            if let scrollView = tableView.enclosingScrollView {
                total += scrollView.contentInsets.top + scrollView.contentInsets.bottom
            }
            total = ceil(total)
            if height != total {
                height = total
            }
        }
    }

    /// Walk up from the background view and search each ancestor's subtree for
    /// the nearest table. Two results tables can share an ancestor, so prefer a
    /// row-count match to disambiguate before falling back to the nearest.
    static func findTableView(near view: NSView, expectedRows: Int) -> NSTableView? {
        var ancestor: NSView? = view.superview
        var nearest: NSTableView?
        for _ in 0..<6 {
            guard let current = ancestor else { break }
            let tables = descendantTableViews(in: current)
            if let exact = tables.first(where: { $0.numberOfRows == expectedRows }) {
                return exact
            }
            if nearest == nil {
                nearest = tables.first
            }
            ancestor = current.superview
        }
        return nearest
    }

    static func descendantTableViews(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { descendantTableViews(in: $0) }
    }
}
