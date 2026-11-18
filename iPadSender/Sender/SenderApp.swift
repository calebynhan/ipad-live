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
    @Published private(set) var pairedMac: PairedMac?
    @Published private(set) var nearbyMacs: [LiveLinkPairingBrowser.Mac] = []
    @Published private(set) var isPairing = false
    @Published var statusMessage: String?

    private let browser = LiveLinkPairingBrowser(queue: .main)

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

    func pair(with mac: LiveLinkPairingBrowser.Mac, code: String) {
        guard !isPairing else { return }
        isPairing = true
        statusMessage = nil
        let deviceName = UIDevice.current.name
        LiveLinkPairing.pair(with: mac.endpoint, code: code, deviceName: deviceName, queue: .main) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPairing = false
                switch result {
                case .success(let pairing):
                    let paired = PairedMac(
                        macID: pairing.macID,
                        macName: pairing.macName,
                        streamKey: pairing.streamKey,
                        deviceName: deviceName
                    )
                    do {
                        try PairedMacStore.save(paired)
                        self.pairedMac = paired
                        self.statusMessage = "Paired with \(pairing.macName). Tap Start Streaming."
                    } catch {
                        self.statusMessage = error.localizedDescription
                    }
                case .failure(let error):
                    self.statusMessage = error.localizedDescription
                }
            }
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
    @State private var macToPair: LiveLinkPairingBrowser.Mac?
    @State private var code = ""

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
                            code = ""
                            macToPair = mac
                        } label: {
                            Label(mac.name, systemImage: "desktopcomputer")
                        }
                        .disabled(model.isPairing)
                    }
                    if model.isPairing {
                        ProgressView("Pairing…")
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
        .alert("Enter Pairing Code", isPresented: isAskingForCode) {
            TextField("123 456", text: $code)
                .keyboardType(.numberPad)
            Button("Pair") {
                if let mac = macToPair { model.pair(with: mac, code: code) }
                macToPair = nil
            }
            Button("Cancel", role: .cancel) { macToPair = nil }
        } message: {
            Text("Enter the 6-digit code shown on \(macToPair?.name ?? "your Mac").")
        }
    }

    private var isAskingForCode: Binding<Bool> {
        Binding(
            get: { macToPair != nil },
            set: { if !$0 { macToPair = nil } }
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
