//
//  ContentView.swift
//  WATCH-CREWBOSS Watch App
//
//  Created by alew on 4/5/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = WatchDataStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Your Assignments") {
                    if store.assignments.isEmpty {
                        Text("Open the iPhone app to sync")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    } else {
                        ForEach(store.assignments) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.title).font(.headline)
                                Text(a.location).font(.caption).foregroundStyle(.secondary)
                                Text(a.date).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section("Job Posts") {
                    ForEach(store.jobs) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title).font(.headline)
                            Text(job.location).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("CREWBOSS")
        }
    }
}
