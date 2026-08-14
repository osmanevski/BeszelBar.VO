import SwiftUI

/// Settings pane for the machines reachable without the hub.
struct SSHTargetsView: View {
    var appState: AppState

    @State private var editingTarget: SSHTarget?
    @State private var showingSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: directModeBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SSH Direct Mode")
                            Text("Read these machines over SSH and do not contact the hub at all. Also on the menu, under Refresh Now.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(appState.sshTargets.isEmpty)

                    Toggle(isOn: fallbackBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fall back to SSH when the hub is unreachable")
                            Text("When the hub does not answer, these machines are read directly. No history and no alerts on this path — only what is happening right now.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    // Nothing to fall back from while the hub is already bypassed.
                    .disabled(appState.sshDirectModeEnabled)

                    Divider()

                    SectionHeader(title: "Targets")

                    if appState.sshTargets.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No targets")
                                .foregroundColor(.secondary)
                            Text("Each target needs a patched beszel-agent — one that supports the stats subcommand.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(appState.sshTargets) { target in
                            SSHTargetRow(
                                target: target,
                                failure: appState.sshFailures[target.recordID],
                                onEdit: {
                                    editingTarget = target
                                    showingSheet = true
                                },
                                onRemove: { appState.removeSSHTarget(target) }
                            )
                        }
                    }

                    Button("Add Target") {
                        editingTarget = nil
                        showingSheet = true
                    }
                    .buttonStyle(PillButtonStyle(isPrimary: true))
                    .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .sheet(isPresented: $showingSheet) {
            SSHTargetSheet(appState: appState, existing: editingTarget)
        }
    }

    private var fallbackBinding: Binding<Bool> {
        Binding(
            get: { appState.sshFallbackEnabled },
            set: { appState.sshFallbackEnabled = $0 }
        )
    }

    private var directModeBinding: Binding<Bool> {
        Binding(
            get: { appState.sshDirectModeEnabled },
            set: { appState.sshDirectModeEnabled = $0 }
        )
    }
}

struct SSHTargetRow: View {
    let target: SSHTarget
    let failure: String?
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: target.transport == .local ? "laptopcomputer" : "terminal")
                .foregroundColor(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                    .fontWeight(.medium)
                Text(target.displaySubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if let failure = failure {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Button("Edit", action: onEdit)
                .buttonStyle(PillButtonStyle())
            Button("Remove", action: onRemove)
                .buttonStyle(DestructivePillButtonStyle())
        }
        .padding(.vertical, 6)
    }
}

struct SSHTargetSheet: View {
    var appState: AppState
    let existing: SSHTarget?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var transport: SSHTarget.Transport = .ssh
    @State private var user = ""
    @State private var host = ""
    @State private var keyPath = "~/.ssh/nabiz_stats"
    @State private var command = "beszel-agent stats"
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Add Target" : "Edit Target")
                .font(.headline)

            Form {
                TextField("Name", text: $name)

                Picker("Transport", selection: $transport) {
                    ForEach(SSHTarget.Transport.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if transport == .ssh {
                    TextField("User", text: $user)
                    TextField("Address", text: $host)
                    TextField("Key", text: $keyPath)
                }

                TextField("Command", text: $command)
            }
            .formStyle(.grouped)

            Text(transport == .ssh
                 ? "Lock the key to a forced command on the target with `command=\"…stats\",restrict`. It can then do nothing but print stats, even if it leaks."
                 : "The command runs directly on this Mac — no SSH, no key.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let testResult = testResult {
                Text(testResult)
                    .font(.system(size: 11))
                    .foregroundColor(testResult.hasPrefix("OK") ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(isTesting ? "Testing…" : "Test Connection") { runTest() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(isTesting || !draft.isUsable)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyle())

                Button("Save") { save() }
                    .buttonStyle(PillButtonStyle(isPrimary: true))
                    .disabled(!draft.isUsable || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: loadExisting)
    }

    private var draft: SSHTarget {
        SSHTarget(
            id: existing?.id ?? UUID(),
            name: name,
            transport: transport,
            user: user,
            host: host,
            keyPath: keyPath,
            command: command
        )
    }

    private func loadExisting() {
        guard let existing = existing else { return }
        name = existing.name
        transport = existing.transport
        user = existing.user
        host = existing.host
        keyPath = existing.keyPath
        command = existing.command
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        let candidate = draft
        Task {
            let result = await appState.testSSHTarget(candidate)
            testResult = result
            isTesting = false
        }
    }

    private func save() {
        if existing == nil {
            appState.addSSHTarget(draft)
        } else {
            appState.updateSSHTarget(draft)
        }
        dismiss()
    }
}
