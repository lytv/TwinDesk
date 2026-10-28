// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject var core: Core
    @State private var page: Page = .general
    @State private var showPair = false
    @State private var showViewer = false
    @State private var showRemote = false

    enum Page: String, CaseIterable, Identifiable, Hashable {
        case general = "General"
        case clipboard = "Clipboard"
        case files = "Files"
        case notifications = "Notifications"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DeviceStatusCard()
                }
                Section("Pages") {
                    ForEach(Page.allCases) { p in
                        NavigationLink(value: p) {
                            Label(p.rawValue, systemImage: icon(for: p))
                        }
                    }
                }
                if core.host != nil {
                    Section("This session") {
                        Button { showViewer = true } label: {
                            Label("Screen", systemImage: "display")
                        }
                        Button { showRemote = true } label: {
                            Label("Remote", systemImage: "hand.tap")
                        }
                    }
                }
            }
            .navigationTitle("TwinDesk")
            .navigationDestination(for: Page.self) { p in
                switch p {
                case .general: GeneralView(showPair: $showPair)
                case .clipboard: ClipboardView()
                case .files: FilesView()
                case .notifications: NotificationsView()
                }
            }
        }
        .sheet(isPresented: $showPair) { PairSheet() }
        .fullScreenCover(isPresented: $showViewer) { ViewerView() }
        .fullScreenCover(isPresented: $showRemote) { RemoteView() }
        .onAppear { core.start() }
        .overlay(alignment: .top) {
            if let invite = core.invite {
                InviteBanner(invite: invite)
                    .padding()
            }
        }
    }

    private func icon(for p: Page) -> String {
        switch p {
        case .general: return "gearshape"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "folder"
        case .notifications: return "bell"
        }
    }
}

struct DeviceStatusCard: View {
    @EnvironmentObject var core: Core

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(status)
                    .font(.headline)
                Spacer()
                if core.link.connected {
                    Button("Disconnect") { core.disconnect() }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                }
            }
            if let host = core.host {
                Text("Connected to \(host.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !core.link.message.isEmpty {
                Text(core.link.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if core.discovery.error.isEmpty {
                Text("\(core.discovery.list().count) computer(s) nearby")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(core.discovery.error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        switch core.link.state {
        case "connected": return "Connected"
        case "connecting": return "Connecting…"
        case "failed": return "Failed"
        default: return "Not connected"
        }
    }

    private var color: Color {
        switch core.link.state {
        case "connected": return .green
        case "connecting": return .yellow
        case "failed": return .red
        default: return .gray
        }
    }
}

struct InviteBanner: View {
    @EnvironmentObject var core: Core
    let invite: Found

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(invite.name) wants to pair")
                .font(.headline)
            HStack {
                Button("Pair") { core.pair(invite) }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { core.dismissInvite() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
    }
}

struct GeneralView: View {
    @EnvironmentObject var core: Core
    @Binding var showPair: Bool

    var body: some View {
        List {
            Section("Computers") {
                if core.hosts().isEmpty {
                    Text("No paired computers yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(core.hosts()) { h in
                    HostRow(host: h)
                }
            }
            Section {
                Button("Pair with address…") { showPair = true }
                NearbyList()
            } header: {
                Text("Nearby")
            }
            Section("Settings") {
                NavigationLink("Device name") {
                    DeviceNameView()
                }
                Toggle("Receive computer sound", isOn: Binding(
                    get: { core.sync.get("audio", "in") },
                    set: { core.sync.set("audio", "in", $0) }
                ))
                Toggle("Send clipboard to computer", isOn: Binding(
                    get: { core.sync.get("clipboard", "out") },
                    set: { core.sync.set("clipboard", "out", $0) }
                ))
                Toggle("Receive clipboard from computer", isOn: Binding(
                    get: { core.sync.get("clipboard", "in") },
                    set: { core.sync.set("clipboard", "in", $0) }
                ))
                Toggle("Clipboard pictures", isOn: Binding(
                    get: { core.clip.picturesOn },
                    set: { core.clip.setPictures($0) }
                ))
                Toggle("Receive notifications", isOn: Binding(
                    get: { core.sync.get("notifs", "in") },
                    set: { core.sync.set("notifs", "in", $0) }
                ))
            }
        }
        .navigationTitle("General")
    }
}

struct HostRow: View {
    @EnvironmentObject var core: Core
    let host: Host

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(host.name)
                Text(host.os)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if core.host?.id == host.id {
                Text("Connected")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Connect") { core.connect(host) }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
            }
            Button(role: .destructive) {
                core.forget(host.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

struct NearbyList: View {
    @EnvironmentObject var core: Core

    var body: some View {
        let near = core.discovery.list().filter { f in
            !core.hosts().contains { $0.id == f.id }
        }
        if near.isEmpty {
            Text("None on this network")
                .foregroundStyle(.secondary)
        }
        ForEach(near) { f in
            HStack {
                VStack(alignment: .leading) {
                    Text(f.name)
                    Text(f.os)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(f.invited ? "Pair (invited)" : "Pair") { core.pair(f) }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
            }
        }
    }
}

struct DeviceNameView: View {
    @EnvironmentObject var core: Core
    @State private var name = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Button("Save") {
                core.store.deviceName = name
            }
        }
        .navigationTitle("Device name")
        .onAppear { name = core.store.deviceName }
    }
}

struct ClipboardView: View {
    @EnvironmentObject var core: Core

    var body: some View {
        List {
            Section {
                Button("Send current clipboard to computer") {
                    _ = core.clip.sendCurrent(true)
                }
                .disabled(!core.link.connected)
            }
            Section("History") {
                if core.clip.history.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
                ForEach(core.clip.history) { item in
                    HStack {
                        Image(systemName: item.dir == "out" ? "arrow.up.right" : "arrow.down.left")
                            .foregroundStyle(item.dir == "out" ? .blue : .green)
                        Text(item.text)
                            .lineLimit(3)
                        Spacer()
                        Button {
                            core.clip.copyAgain(item)
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("Clipboard")
    }
}

struct FilesView: View {
    @EnvironmentObject var core: Core

    var body: some View {
        List {
            if !core.files.receiving.isEmpty {
                Section("Receiving") {
                    ForEach(core.files.receiving, id: \.name) { r in
                        VStack(alignment: .leading) {
                            Text(r.name)
                            ProgressView(value: Double(r.got), total: Double(max(r.bytes, 1)))
                            Text("\(pct(r.got, r.bytes))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Recent") {
                if core.files.recent.isEmpty {
                    Text("Files from the computer land in Documents/TwinDesk")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(core.files.recent.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
        }
        .navigationTitle("Files")
    }
}

struct NotificationsView: View {
    @EnvironmentObject var core: Core

    var body: some View {
        List {
            Section {
                Toggle("Receive notifications from computer", isOn: Binding(
                    get: { core.sync.get("notifs", "in") },
                    set: { core.sync.set("notifs", "in", $0) }
                ))
                if !core.notifs.peerAccepts {
                    Text("The computer is not accepting notifications from this iPad")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Settings")
            }
            Section("Shown here") {
                Text("\(core.notifs.shown) notification(s) this session")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notifications")
    }
}
