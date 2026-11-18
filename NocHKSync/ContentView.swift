import SwiftUI

struct ContentView: View {
    @Environment(SyncEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var engine = engine
        NavigationStack {
            Form {
                Section {
                    TextField("your-site.example.com", text: $engine.serverURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API token (noc_…)", text: $engine.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Test Connection") { Task { await engine.testConnection() } }
                        .disabled(!engine.isConfigured || engine.isSyncing)
                } header: {
                    Text("Nocturne")
                } footer: {
                    Text("Create a direct grant token in Nocturne with the heartrate.readwrite and stepcount.readwrite scopes.")
                }

                Section("Apple Health") {
                    if !engine.healthAvailable {
                        Text("Health data is not available on this device.")
                            .foregroundStyle(.secondary)
                    } else if engine.needsHealthPrompt {
                        Button("Allow Access to Steps and Heart Rate") {
                            Task { await engine.requestHealthAccess() }
                        }
                    } else {
                        Label("Permission requested", systemImage: "checkmark.circle")
                        Text("To change access, open Settings › Health › Data Access & Devices.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Stepper("Sync window: \(engine.days) days", value: $engine.days, in: 1 ... SyncEngine.maxDays)
                    Button("Sync Now") { Task { await engine.sync(full: false) } }
                        .disabled(!canSync)
                    Button("Full Resync") { Task { await engine.sync(full: true) } }
                        .disabled(!canSync)
                    if engine.isSyncing {
                        HStack {
                            ProgressView()
                            Text(engine.status).foregroundStyle(.secondary)
                        }
                    } else if !engine.status.isEmpty {
                        Text(engine.status).foregroundStyle(.secondary)
                    }
                    if let last = engine.lastSyncAt {
                        LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Sync Now sends new data since the last sync. Full Resync re-sends the whole window; Nocturne updates matching records instead of duplicating them.")
                }

                Section {
                    Toggle("Daily background sync", isOn: Binding(
                        get: { engine.backgroundSyncEnabled },
                        set: { on in Task { await engine.setBackgroundSync(enabled: on) } }
                    ))
                    .disabled(!canSync && !engine.backgroundSyncEnabled)
                    if engine.consecutiveFailures > 0 {
                        LabeledContent("Failed attempts in a row", value: "\(engine.consecutiveFailures)")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("Syncs about once a day when new Health data arrives. Failed attempts retry with increasing delays, and you get a notification after \(BackgroundSync.alertAfterFailures) failures in a row. Requires Background App Refresh to be on for this app.")
                }

                if !engine.log.isEmpty {
                    Section("Log") {
                        ForEach(engine.log, id: \.self) { line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("NocHKSync")
        }
        .task { await engine.refreshHealthStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await engine.autoSyncIfDue() } }
        }
    }

    private var canSync: Bool {
        engine.isConfigured && engine.healthAvailable && !engine.needsHealthPrompt && !engine.isSyncing
    }
}
