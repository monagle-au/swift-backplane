//
//  ServiceKeyMacro.swift
//  swift-backplane
//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - ServiceKeyMacro

/// Implementation of the `#service` freestanding declaration macro.
///
/// Expands `#service(SomeType.self, name:?, id:?)` to a `public var`
/// computed property on the enclosing type returning a typed
/// `ServiceKey<SomeType>`. See the `service` macro declaration in the
/// `Backplane` module for the consumer-facing contract.
public struct ServiceKeyMacro: DeclarationMacro {

    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let arguments = node.arguments

        // First (unlabelled) argument: the `SomeType.self` metatype.
        guard let typeArgument = arguments.first, typeArgument.label == nil else {
            context.diagnose(
                Diagnostic(node: node, message: Message.missingType)
            )
            return []
        }

        // Recover the written type from `<Type>.self`, stripping any
        // enclosing single-element parentheses (`(any P).self`).
        guard let valueTypeExpr = metatypeBase(of: typeArgument.expression) else {
            context.diagnose(
                Diagnostic(node: typeArgument.expression, message: Message.malformedType)
            )
            return []
        }
        let valueTypeText = valueTypeExpr.trimmedDescription

        // Optional `name:` / `id:` — string literals only.
        var explicitName: String?
        var explicitID: String?
        for argument in arguments.dropFirst() {
            guard let label = argument.label?.text else { continue }
            guard let literal = stringLiteralValue(argument.expression) else {
                context.diagnose(
                    Diagnostic(node: argument.expression, message: Message.nonLiteralArgument(label))
                )
                return []
            }
            switch label {
            case "name": explicitName = literal
            case "id": explicitID = literal
            default: break
            }
        }

        // Resolve the property name: explicit wins, else derive from the
        // type's trailing identifier.
        let name: String
        if let explicitName {
            name = explicitName
        } else if let derived = derivedName(from: valueTypeText) {
            name = derived
        } else {
            context.diagnose(
                Diagnostic(node: typeArgument.expression, message: Message.underivableName(valueTypeText))
            )
            return []
        }

        let id = explicitID ?? name

        let decl: DeclSyntax =
            """
            public var \(raw: name): ServiceKey<\(raw: valueTypeText)> {
                ServiceKey(id: \(literal: id))
            }
            """
        return [decl]
    }
}

// MARK: - Syntax helpers

extension ServiceKeyMacro {

    /// Return the base expression of a `<expr>.self` member access,
    /// unwrapping a single enclosing parenthesis group so that
    /// `(any P).self` yields the `any P` type expression. Returns nil if
    /// the argument is not a `.self` metatype reference.
    private static func metatypeBase(of expression: ExprSyntax) -> ExprSyntax? {
        guard
            let memberAccess = expression.as(MemberAccessExprSyntax.self),
            memberAccess.declName.baseName.text == "self",
            let base = memberAccess.base
        else {
            return nil
        }
        return stripParentheses(base)
    }

    /// Unwrap a single-element, unlabelled tuple expression — the shape
    /// `(any P)` parses as — returning the inner expression. Non-tuples
    /// pass through unchanged.
    private static func stripParentheses(_ expression: ExprSyntax) -> ExprSyntax {
        guard
            let tuple = expression.as(TupleExprSyntax.self),
            tuple.elements.count == 1,
            let only = tuple.elements.first,
            only.label == nil
        else {
            return expression
        }
        // Recurse to collapse redundant nesting like `((any P))`.
        return stripParentheses(only.expression)
    }

    /// Extract the literal contents of a string-literal expression with no
    /// interpolation. Returns nil for anything else (interpolations,
    /// computed values, etc.).
    private static func stringLiteralValue(_ expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
        var result = ""
        for segment in literal.segments {
            guard let stringSegment = segment.as(StringSegmentSyntax.self) else {
                return nil  // an \(interpolation) segment — not a plain literal
            }
            result += stringSegment.content.text
        }
        return result
    }

    /// Derive a property name from the written type text: strip a leading
    /// `any `/`some `, take the last dot-separated component, and — if what
    /// remains is a plain identifier — lower-case its first letter.
    /// Returns nil for anything the macro can't reduce to a bare
    /// identifier (generics, tuples, function types, …).
    ///
    /// Internal (not private) so it can be unit-tested directly.
    static func derivedName(from typeText: String) -> String? {
        // Pure-stdlib trimming — no Foundation in the plugin.
        var text = Substring(typeText)
        text = trimmingASCIIWhitespace(text)

        for prefix in ["any ", "some "] where text.hasPrefix(prefix) {
            text = trimmingASCIIWhitespace(text.dropFirst(prefix.count))
        }

        if let lastDot = text.lastIndex(of: ".") {
            text = text[text.index(after: lastDot)...]
        }

        let identifier = String(text)
        guard isPlainIdentifier(identifier) else { return nil }
        return lowercaseFirst(identifier)
    }

    private static func trimmingASCIIWhitespace(_ text: Substring) -> Substring {
        let whitespace: Set<Character> = [" ", "\t", "\n", "\r"]
        var slice = text
        while let first = slice.first, whitespace.contains(first) { slice = slice.dropFirst() }
        while let last = slice.last, whitespace.contains(last) { slice = slice.dropLast() }
        return slice
    }

    private static func isPlainIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func lowercaseFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

// MARK: - Diagnostics

extension ServiceKeyMacro {

    private enum Message: DiagnosticMessage {
        case missingType
        case malformedType
        case nonLiteralArgument(String)
        case underivableName(String)

        var message: String {
            switch self {
            case .missingType:
                return "#service requires a type argument, e.g. #service(MyService.self)"
            case .malformedType:
                return "#service expects a metatype literal, e.g. MyService.self or (any MyProtocol).self"
            case .nonLiteralArgument(let label):
                return "#service '\(label):' must be a string literal"
            case .underivableName(let type):
                return "#service can't derive a property name from '\(type)'; pass an explicit name:, e.g. #service(\(type).self, name: \"myService\")"
            }
        }

        var diagnosticID: MessageID {
            let id: String
            switch self {
            case .missingType: id = "missingType"
            case .malformedType: id = "malformedType"
            case .nonLiteralArgument: id = "nonLiteralArgument"
            case .underivableName: id = "underivableName"
            }
            return MessageID(domain: "BackplaneMacros.ServiceKeyMacro", id: id)
        }

        var severity: DiagnosticSeverity { .error }
    }
}
