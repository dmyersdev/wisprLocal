import Foundation
import SwiftUI

struct TransformDiffOperation: Equatable {
    enum Kind: Equatable {
        case unchanged
        case added
        case removed
    }

    let kind: Kind
    let text: String
}

struct TransformDiff: Equatable {
    let operations: [TransformDiffOperation]
    let changeCount: Int

    init(original: String, transformed: String) {
        let originalTokens = Self.tokens(in: original)
        let transformedTokens = Self.tokens(in: transformed)
        let columnCount = transformedTokens.count + 1
        var lengths = [Int32](
            repeating: 0,
            count: (originalTokens.count + 1) * columnCount
        )

        if !originalTokens.isEmpty, !transformedTokens.isEmpty {
            for originalIndex in 1...originalTokens.count {
                for transformedIndex in 1...transformedTokens.count {
                    let offset = originalIndex * columnCount + transformedIndex
                    if originalTokens[originalIndex - 1] == transformedTokens[transformedIndex - 1] {
                        lengths[offset] = lengths[(originalIndex - 1) * columnCount + transformedIndex - 1] + 1
                    } else {
                        lengths[offset] = max(
                            lengths[(originalIndex - 1) * columnCount + transformedIndex],
                            lengths[originalIndex * columnCount + transformedIndex - 1]
                        )
                    }
                }
            }
        }

        var reversed: [TransformDiffOperation] = []
        var originalIndex = originalTokens.count
        var transformedIndex = transformedTokens.count
        while originalIndex > 0 || transformedIndex > 0 {
            if originalIndex > 0,
               transformedIndex > 0,
               originalTokens[originalIndex - 1] == transformedTokens[transformedIndex - 1] {
                reversed.append(.init(kind: .unchanged, text: originalTokens[originalIndex - 1]))
                originalIndex -= 1
                transformedIndex -= 1
            } else if transformedIndex > 0,
                      (originalIndex == 0
                        || lengths[originalIndex * columnCount + transformedIndex - 1]
                            >= lengths[(originalIndex - 1) * columnCount + transformedIndex]) {
                reversed.append(.init(kind: .added, text: transformedTokens[transformedIndex - 1]))
                transformedIndex -= 1
            } else {
                reversed.append(.init(kind: .removed, text: originalTokens[originalIndex - 1]))
                originalIndex -= 1
            }
        }

        operations = Self.mergeAdjacent(reversed.reversed())
        changeCount = operations.reduce(into: (count: 0, insideChange: false)) { result, operation in
            if operation.kind == .unchanged {
                result.insideChange = false
            } else if !result.insideChange {
                result.count += 1
                result.insideChange = true
            }
        }.count
    }

    var attributedText: AttributedString {
        operations.reduce(into: AttributedString()) { result, operation in
            var segment = AttributedString(operation.text)
            switch operation.kind {
            case .unchanged:
                break
            case .added:
                segment.foregroundColor = .green
                segment.backgroundColor = .green.opacity(0.14)
            case .removed:
                segment.foregroundColor = .red
                segment.backgroundColor = .red.opacity(0.10)
                segment.strikethroughStyle = .single
            }
            result.append(segment)
        }
    }

    private static func tokens(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var currentIsWhitespace: Bool?
        for character in text {
            let isWhitespace = character.isWhitespace
            if let currentIsWhitespace, currentIsWhitespace != isWhitespace {
                tokens.append(current)
                current = ""
            }
            current.append(character)
            currentIsWhitespace = isWhitespace
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func mergeAdjacent<S: Sequence>(
        _ operations: S
    ) -> [TransformDiffOperation] where S.Element == TransformDiffOperation {
        operations.reduce(into: []) { result, operation in
            if let last = result.last, last.kind == operation.kind {
                result[result.count - 1] = TransformDiffOperation(
                    kind: operation.kind,
                    text: last.text + operation.text
                )
            } else {
                result.append(operation)
            }
        }
    }
}
