// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
import SwiftUI
import WebKit

// Pairing with the 6-digit numeric comparison code, like android/PairSheet.
struct PairSheet: View {
    @EnvironmentObject var core: Core
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Group {
                if let pair = core.link.pair {
                    switch pair.phase {
                    case "connecting", "starting":
                        ProgressView("Connecting to \(pair.name)…")
                    case "code":
                        VStack(spacing: 16) {
                            Text("Compare this code with the one on \(pair.name)")
                                .multilineTextAlignment(.center)
                            Text(pair.code)
                                .font(.system(size: 48, weight: .bold, design: .monospaced))
                                .padding(.vertical, 8)
                            Button("Codes match") { core.link.confirmCode() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            Button("Cancel") { core.link.cancelPairing() }
                        }
                        .padding()
                    case "waiting":
                        ProgressView("Waiting for \(pair.name)…")
                        Button("Cancel") { core.link.cancelPairing() }
                            .padding(.top)
                    case "failed":
                        VStack(spacing: 12) {
                            Image(systemName: "xmark.icloud")
                                .font(.largeTitle)
                                .foregroundStyle(.red)
                            Text(pair.error)
                                .multilineTextAlignment(.center)
                            Button("Done") {
                                core.link.cancelPairing()
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                    default:
                        EmptyView()
                    }
                } else {
                    Form {
                        Section("Pair by address") {
                            TextField("Computer IP or name", text: $address)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Pair") {
                                core.pairAddress(address)
                            }
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Section {
                            Text("Or pick a nearby computer on the General page, or wait for an invite from the computer.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        core.link.cancelPairing()
                        dismiss()
                    }
                }
            }
        }
    }
}

// Holds a WebHost once the view has its Core from the environment.
final class PageHolder: ObservableObject {
    @Published var host: WebHost?
    func setup(page: String, core: Core) {
        guard host == nil else { return }
        host = WebHost(page: page, core: core)
    }
}

// The computer's screen in a full-screen WebView (viewer.html), like android/ViewerActivity.
struct ViewerView: View {
    @EnvironmentObject var core: Core
    @Environment(\.dismiss) private var dismiss
    @StateObject private var holder = PageHolder()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if let h = holder.host {
                        core.screen.end()
                        core.screen.detach(h)
                    }
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                }
                Spacer()
                if core.screen.sharing {
                    Button("Mirror") { core.screen.pick("mirror") }
                        .buttonStyle(.bordered)
                    Button("Extend") { core.screen.pick("extend") }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if core.link.connected {
                    Button(core.screen.sharing ? "Stop" : "Start") {
                        core.screen.control(share: !core.screen.sharing)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            if let h = holder.host {
                WKView(host: h)
            } else {
                Color.black
            }
        }
        .background(Color.black)
        .onAppear {
            holder.setup(page: "viewer.html", core: core)
            if let h = holder.host {
                let size = UIScreen.main.bounds.size
                let scale = UIScreen.main.scale
                core.screen.attach(h, w: Int(size.width * scale), hpx: Int(size.height * scale))
            }
        }
    }
}

// The Remote page in a full-screen WebView (remote.html).
struct RemoteView: View {
    @EnvironmentObject var core: Core
    @Environment(\.dismiss) private var dismiss
    @StateObject private var holder = PageHolder()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if let h = holder.host { core.remote.detach(h) }
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                }
                Spacer()
                Text(core.host?.name ?? "Not connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            if let h = holder.host {
                WKView(host: h)
            } else {
                Color.black
            }
        }
        .background(Color.black)
        .onAppear {
            holder.setup(page: "remote.html", core: core)
            if let h = holder.host { core.remote.attach(h, mode: "pad") }
        }
    }
}

struct WKView: UIViewRepresentable {
    let host: WebHost

    func makeUIView(context: Context) -> WKWebView { host.view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
