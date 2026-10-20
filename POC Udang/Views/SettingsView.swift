import SwiftUI

struct SettingsView: View {
    @ObservedObject var session: CountingSession
    @Binding var showIDs: Bool
    @Binding var showBoxes: Bool
    @Binding var showConfidence: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: InferenceSettings
    @State private var applying = false

    init(session: CountingSession, showIDs: Binding<Bool>, showBoxes: Binding<Bool>, showConfidence: Binding<Bool>) {
        self.session = session
        _showIDs = showIDs
        _showBoxes = showBoxes
        _showConfidence = showConfidence
        _draft = State(initialValue: session.settings)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tampilan") {
                    Toggle("Tampilkan ID", isOn: $showIDs)
                    Toggle("Tampilkan bounding box", isOn: $showBoxes)
                    Toggle("Tampilkan confidence score", isOn: $showConfidence)
                    Text("Mengubah tampilan tidak mengubah hitungan.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Deteksi dan tracking") {
                    Picker("Tracking", selection: $draft.backend) {
                        ForEach(TrackingBackendKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Model lokal", selection: $draft.modelName) {
                        ForEach(session.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Confidence: \(draft.confidence, specifier: "%.2f")")
                        Slider(value: $draft.confidence, in: 0.05...0.95, step: 0.05)
                            .accessibilityLabel("Confidence")
                    }
                    VStack(alignment: .leading) {
                        Text("NMS IoU: \(draft.nmsIoU, specifier: "%.2f")")
                        Slider(value: $draft.nmsIoU, in: 0.1...0.95, step: 0.05)
                            .accessibilityLabel("NMS IoU")
                    }
                    Stepper("Konfirmasi ID: \(draft.confirmIDFrames) frame", value: $draft.confirmIDFrames, in: 1...10)
                    Text("Confidence lebih tinggi menyaring deteksi lemah. IoU lebih rendah membuang lebih banyak kotak tumpang tindih.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("Perubahan tracking, model, atau threshold memulai sesi baru dari ID 1. Foto diproses ulang; video dimulai ulang dengan tombol Mulai. Log sesi sebelumnya tetap tersimpan lokal.")
                        .font(.footnote)
                    if let error = session.error { Text(error).foregroundStyle(.red) }
                    if applying { ProgressView("Memuat model…") }
                }
            }
            .disabled(applying)
            .navigationTitle("Pengaturan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }.disabled(applying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terapkan") {
                        applying = true
                        Task {
                            if await session.applySettings(draft) { dismiss() }
                            applying = false
                        }
                    }.disabled(applying)
                }
            }
            .interactiveDismissDisabled(applying)
        }
    }
}
