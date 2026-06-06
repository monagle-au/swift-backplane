//
//  Plugin.swift
//  swift-backplane
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct BackplaneMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        ServiceKeyMacro.self,
    ]
}
