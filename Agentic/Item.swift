//
//  Item.swift
//  Agentic
//
//  Created by Ben Milford on 15/03/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
