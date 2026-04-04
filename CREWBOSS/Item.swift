//
//  Item.swift
//  CREWBOSS
//
//  Created by alew on 4/4/26.
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
