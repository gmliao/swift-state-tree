// Sources/SwiftStateTreeBenchmarks/TextTable.swift

import Foundation

/// Simple text table for benchmark output
struct TextTable {
    private var columns: [TextTableColumn]
    
    /// The `String` used to separate columns in the table. Defaults to "│".
    var columnFence = "│"
    
    /// The `String` used to separate rows in the table. Defaults to "─".
    var rowFence = "─"
    
    /// The `String` used to mark the intersections. Defaults to "┼".
    var cornerFence = "┼"
    
    /// The `String` used for top border. Defaults to "┌".
    var topLeftCorner = "┌"
    
    /// The `String` used for top border. Defaults to "┐".
    var topRightCorner = "┐"
    
    /// The `String` used for bottom border. Defaults to "└".
    var bottomLeftCorner = "└"
    
    /// The `String` used for bottom border. Defaults to "┘".
    var bottomRightCorner = "┘"
    
    /// The `String` used for header separator left. Defaults to "├".
    var headerLeftCorner = "├"
    
    /// The `String` used for header separator right. Defaults to "┤".
    var headerRightCorner = "┤"
    
    /// The table's header text. If set to `nil`, no header will be rendered.
    var header: String?
    
    init(columns: [TextTableColumn], header: String? = nil) {
        self.columns = columns
        self.header = header
    }
    
    mutating func addRow(values: [CustomStringConvertible]) {
        let values = values.count >= columns.count ? values :
            values + [CustomStringConvertible](repeating: "", count: columns.count - values.count)
        columns = zip(columns, values).map {
            (column, value) in
            var column = column
            column.values.append(value.description)
            return column
        }
    }
    
    func render() -> String {
        let separator = createSeparator()
        let topBorder = createTopBorder()
        let bottomBorder = createBottomBorder()
        
        let columnHeaders = createRow(
            strings: columns.map { " \($0.header.withPadding(count: $0.width())) " }
        )
        
        let values = columns.isEmpty ? "" : (0..<columns.first!.values.count).map { rowIndex in
            createRow(strings: columns.map { " \($0.values[rowIndex].withPadding(count: $0.width())) " })
        }.joined(separator: "\n")
        
        var result: [String] = []
        
        if let header = header {
            let headerTop = createHeaderTopBorder()
            let headerBottom = createHeaderBottomBorder()
            let headerRow = createRow(strings: [" \(header.withPadding(count: totalWidth() - 2)) "])
            result.append(headerTop)
            result.append(headerRow)
            result.append(headerBottom)
        } else {
            result.append(topBorder)
        }
        
        result.append(columnHeaders)
        result.append(separator)
        
        if !values.isEmpty {
            result.append(values)
        }
        
        result.append(bottomBorder)
        
        return result.joined(separator: "\n")
    }
    
    private func totalWidth() -> Int {
        return columns.reduce(0) { $0 + $1.width() + 2 } + columns.count - 1
    }
    
    private func createSeparator() -> String {
        let parts = columns.map { column in
            String(repeating: rowFence, count: column.width() + 2)
        }
        return headerLeftCorner + parts.joined(separator: cornerFence) + headerRightCorner
    }
    
    private func createTopBorder() -> String {
        let parts = columns.map { column in
            String(repeating: rowFence, count: column.width() + 2)
        }
        return topLeftCorner + parts.joined(separator: String(repeating: rowFence, count: 1)) + topRightCorner
    }
    
    private func createBottomBorder() -> String {
        let parts = columns.map { column in
            String(repeating: rowFence, count: column.width() + 2)
        }
        return bottomLeftCorner + parts.joined(separator: String(repeating: rowFence, count: 1)) + bottomRightCorner
    }
    
    private func createHeaderSeparator() -> String {
        let parts = columns.map { column in
            String(repeating: rowFence, count: column.width() + 2)
        }
        return headerLeftCorner + parts.joined(separator: cornerFence) + headerRightCorner
    }
    
    private func createHeaderTopBorder() -> String {
        // For header, we need a single continuous border
        let totalWidth = totalWidth()
        return topLeftCorner + String(repeating: rowFence, count: totalWidth) + topRightCorner
    }
    
    private func createHeaderBottomBorder() -> String {
        // For header separator, use the column-based separator
        let parts = columns.map { column in
            String(repeating: rowFence, count: column.width() + 2)
        }
        return headerLeftCorner + parts.joined(separator: cornerFence) + headerRightCorner
    }
    
    private func createRow(strings: [String]) -> String {
        return columnFence + strings.joined(separator: columnFence) + columnFence
    }
}

/// Represents a column in a `TextTable`.
struct TextTableColumn {
    var header: String {
        didSet {
            computeWidth()
        }
    }
    
    fileprivate var values: [String] = [] {
        didSet {
            computeWidth()
        }
    }
    
    init(header: String) {
        self.header = header
        computeWidth()
    }
    
    func width() -> Int {
        return precomputedWidth
    }
    
    private var precomputedWidth: Int = 0
    
    private mutating func computeWidth() {
        let valueLengths = [header.count] + values.map { $0.count }
        if let max = valueLengths.max() {
            precomputedWidth = max
        }
    }
}

private extension String {
    func withPadding(count: Int) -> String {
        let length = self.count
        
        if length < count {
            return self + String(repeating: " ", count: count - length)
        }
        return self
    }
}

