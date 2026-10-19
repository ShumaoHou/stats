//
//  QuickActionItem.swift
//  Kit
//
//  Created by didi on 2026/10/18.
//  Using Swift 5.0
//  Running on macOS 10.15+
//

import Cocoa

public struct QuickActionItem {
    public let id: String
    public let title: String
    public let toolTip: String
    public let iconName: String
    public let isToggle: Bool
    public var isEnabled: () -> Bool
    public var isAvailable: () -> Bool
    public var action: (_ item: QuickActionItem, _ completion: @escaping (Bool) -> Void) -> Void
    
    public init(
        id: String,
        title: String,
        toolTip: String,
        iconName: String,
        isToggle: Bool = true,
        isEnabled: @escaping () -> Bool = { false },
        isAvailable: @escaping () -> Bool = { true },
        action: @escaping (_ item: QuickActionItem, _ completion: @escaping (Bool) -> Void) -> Void
    ) {
        self.id = id
        self.title = title
        self.toolTip = toolTip
        self.iconName = iconName
        self.isToggle = isToggle
        self.isEnabled = isEnabled
        self.isAvailable = isAvailable
        self.action = action
    }
}
