//
//  CREWBOSSApp.swift
//  CREWBOSS
//
//  Created by alew on 4/4/26.
//

import SwiftUI
import SwiftData

// CREWBOSSApp.swift
@main
struct CREWBOSSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate  // ← ADD THIS

    // remove the SwiftData block unless you have an Item model defined
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
