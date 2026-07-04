import SwiftUI

/// Standardized wrapper for native macOS tables in the results view: a
/// consistent title/subtitle header, an optional trailing accessory (e.g. a
/// Copy button), an optional footer line, and shared table styling.
///
/// Usage:
/// ```swift
/// TableCard(title: "…", subtitle: "…", footer: "…") {
///     Table(rows) { TableColumn(…) { … } }
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
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
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
    /// Shared styling for a results table: inset style with alternating row
    /// backgrounds, internal scrolling disabled (the results pane's outer
    /// ScrollView owns scrolling), sized to show exactly `rowCount` rows.
    ///
    /// macOS inset tables lay rows out on a 24 pt pitch with a ~28 pt header;
    /// oversizing the frame paints phantom striped rows below the content.
    func resultsTable(rowCount: Int) -> some View {
        self
            .tableStyle(.inset)
            .alternatingRowBackgrounds(.enabled)
            .scrollDisabled(true)
            .frame(height: CGFloat(rowCount) * 24 + 30)
    }

    /// A numeric table cell: right-aligned, monospaced digits.
    func numericCell() -> some View {
        self
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
