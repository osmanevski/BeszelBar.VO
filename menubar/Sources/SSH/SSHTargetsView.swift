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
                    Toggle(isOn: fallbackBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hub erişilemezse SSH'a düş")
                            Text("Hub cevap vermediğinde bu makineler doğrudan okunur. Geçmiş ve alarm gelmez — yalnız anlık durum.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    SectionHeader(title: "Hedefler")

                    if appState.sshTargets.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Hedef yok")
                                .foregroundColor(.secondary)
                            Text("Her hedefte yamalı beszel-agent gerekiyor; `stats` alt komutunu destekleyen sürüm.")
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

                    Button("Hedef Ekle") {
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

            Button("Düzenle", action: onEdit)
                .buttonStyle(PillButtonStyle())
            Button("Sil", action: onRemove)
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
            Text(existing == nil ? "Hedef Ekle" : "Hedefi Düzenle")
                .font(.headline)

            Form {
                TextField("Ad", text: $name)

                Picker("Bağlantı", selection: $transport) {
                    ForEach(SSHTarget.Transport.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if transport == .ssh {
                    TextField("Kullanıcı", text: $user)
                    TextField("Adres", text: $host)
                    TextField("Anahtar", text: $keyPath)
                }

                TextField("Komut", text: $command)
            }
            .formStyle(.grouped)

            Text(transport == .ssh
                 ? "Anahtarı hedefte `command=\"…stats\",restrict` ile kilitlemen önerilir; o zaman bu anahtar istatistik basmaktan başka bir şey yapamaz."
                 : "Bu Mac'te komut doğrudan çalıştırılır — SSH ve anahtar gerekmez.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let testResult = testResult {
                Text(testResult)
                    .font(.system(size: 11))
                    .foregroundColor(testResult.hasPrefix("Tamam") ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(isTesting ? "Deneniyor…" : "Bağlantıyı Dene") { runTest() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(isTesting || !draft.isUsable)

                Spacer()

                Button("Vazgeç") { dismiss() }
                    .buttonStyle(PillButtonStyle())

                Button("Kaydet") { save() }
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
