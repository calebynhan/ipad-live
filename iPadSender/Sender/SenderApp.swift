import ReplayKit
import SwiftUI
import UIKit

@main
struct SenderApp: App {
    @StateObject private var model = SenderModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

/// Pairing state for the app's one screen.
@MainActor
final class SenderModel: ObservableObject {
    /// Where pairing with a Mac has got to.
    enum PairingStep: Equatable {
        case idle
        case connecting(macName: String)
        /// Both screens show this code; the person checks they match.
        case comparing(macName: String, code: String)
        case waitingForMac(macName: String)
    }

    @Published private(set) var pairedMac: PairedMac?
    @Published private(set) var nearbyMacs: [LiveLinkPairingBrowser.Mac] = []
    @Published private(set) var step: PairingStep = .idle
    @Published var statusMessage: String?

    var isPairing: Bool { step != .idle }

    private let browser = LiveLinkPairingBrowser(queue: .main)
    private var session: LiveLinkPairingSession?

    init() {
        pairedMac = PairedMacStore.load()
        browser.onChange = { [weak self] macs in
            MainActor.assumeIsolated { self?.nearbyMacs = macs }
        }
    }

    /// Lists Macs whose "Pair iPad" window is open. The first time, iPadOS asks for Local Network access.
    func startBrowsing() {
        browser.start()
    }

    /// Starts pairing: both screens will show a code to compare.
    func pair(with mac: LiveLinkPairingBrowser.Mac) {
        guard session == nil else { return }
        statusMessage = nil
        step = .connecting(macName: mac.name)
        let deviceName = UIDevice.current.name
        let session = LiveLinkPairingSession(endpoint: mac.endpoint, deviceName: deviceName, queue: .main)
        session.onCode = { [weak self] code in
            MainActor.assumeIsolated { self?.step = .comparing(macName: mac.name, code: code) }
        }
        session.onPaired = { [weak self] result in
            MainActor.assumeIsolated { self?.finishPairing(result, deviceName: deviceName) }
        }
        session.onFailed = { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.session = nil
                self.step = .idle
                self.statusMessage = error.localizedDescription
            }
        }
        self.session = session
        session.start()
    }

    /// The person checked the codes match.
    func confirmCode() {
        guard case .comparing(let macName, _) = step else { return }
        step = .waitingForMac(macName: macName)
        session?.confirm()
    }

    func cancelPairing() {
        session?.cancel()
        session = nil
        step = .idle
    }

    private func finishPairing(_ result: PairingCrypto.Result, deviceName: String) {
        session = nil
        step = .idle
        let paired = PairedMac(
            macID: result.macID,
            macName: result.macName,
            deviceID: result.deviceID,
            streamKey: result.streamKey,
            deviceName: deviceName
        )
        do {
            try PairedMacStore.save(paired)
            pairedMac = paired
            statusMessage = "Paired with \(result.macName). Tap Start Streaming."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func forgetMac() {
        PairedMacStore.clear()
        pairedMac = nil
        statusMessage = nil
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: SenderModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Your Mac") {
                    if let mac = model.pairedMac {
                        LabeledContent("Paired with", value: mac.macName)
                    } else {
                        Text("Not paired yet. Pair with your Mac below.")
                            .foregroundStyle(.secondary)
                    }
                }

                if model.pairedMac != nil {
                    Section("Stream") {
                        HStack(spacing: 16) {
                            BroadcastButton(extensionBundleID: Self.broadcastExtensionID)
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Start Streaming").font(.headline)
                                Text("Tap the button, then Start Broadcast.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("You can also start from Control Center: touch and hold Screen Recording, "
                            + "choose iPad Live, then Start Broadcast. To stop, tap the red indicator "
                            + "at the top of the screen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if model.nearbyMacs.isEmpty {
                        Text("On your Mac, open iPad Live and choose Device → Pair iPad Wirelessly. It will appear here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.nearbyMacs) { mac in
                        Button {
                            model.pair(with: mac)
                        } label: {
                            Label(mac.name, systemImage: "desktopcomputer")
                        }
                        .disabled(model.isPairing)
                    }
                    switch model.step {
                    case .idle:
                        EmptyView()
                    case .connecting(let macName):
                        ProgressView("Connecting to \(macName)…")
                    case .comparing:
                        Text("Check the code on both screens.")
                    case .waitingForMac(let macName):
                        ProgressView("Now click Pair on \(macName).")
                    }
                    if let message = model.statusMessage {
                        Text(message).font(.callout)
                    }
                } header: {
                    Text(model.pairedMac == nil ? "Pair with a Mac" : "Pair Again")
                } footer: {
                    Text("Keep this iPad and your Mac on the same Wi-Fi.")
                }

                if model.pairedMac != nil {
                    Section {
                        Button("Forget This Mac", role: .destructive) { model.forgetMac() }
                    }
                }
            }
            .navigationTitle("iPad Live Sender")
        }
        .onAppear { model.startBrowsing() }
        .alert(comparisonTitle, isPresented: isComparingCodes) {
            Button("Pair") { model.confirmCode() }
            Button("Cancel", role: .cancel) { model.cancelPairing() }
        } message: {
            Text("Check that your Mac shows the same code. If it does, tap Pair here and click Pair on the Mac. "
                + "If it doesn't, tap Cancel: you may be connecting to the wrong device.")
        }
    }

    private var comparisonTitle: String {
        guard case .comparing(_, let code) = model.step else { return "" }
        return "Code: \(code.prefix(3)) \(code.suffix(3))"
    }

    private var isComparingCodes: Binding<Bool> {
        Binding(
            get: {
                if case .comparing = model.step { return true }
                return false
            },
            set: { _ in } // dismissed only through the buttons
        )
    }

    private static var broadcastExtensionID: String {
        (Bundle.main.bundleIdentifier ?? "") + ".broadcast"
    }
}

/// Apple's system button that starts a broadcast with our extension.
struct BroadcastButton: UIViewRepresentable {
    let extensionBundleID: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.preferredExtension = extensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {}
}
