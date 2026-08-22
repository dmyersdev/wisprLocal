import SwiftUI

struct MicrophoneSettingsCard: View {
    var body: some View {
        SettingsCard(
            title: "Microphone",
            subtitle: "Choose what WisprLocal listens to and check the live input level."
        ) {
            MicrophoneInputPanel()
        }
    }
}

struct MicrophoneInputPanel: View {
    @EnvironmentObject private var controller: AudioInputController
    @State private var monitoringOwner = UUID()

    private var selection: Binding<String?> {
        Binding(
            get: { controller.selectedDeviceUID },
            set: { controller.setSelectedDeviceUID($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input device")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Picker("Input device", selection: selection) {
                        automaticOption
                        unavailableSelectionOption
                        ForEach(controller.devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("microphone.input.picker")
                }

                Button {
                    controller.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh microphones")
                .accessibilityLabel("Refresh microphones")

                Button("Sound Settings…") {
                    controller.openSoundInputSettings()
                }
                .buttonStyle(.bordered)
            }

            inputPreview

            if let warning = controller.selectionWarning {
                feedback(warning, icon: "exclamationmark.triangle.fill", color: .orange)
            }
            if let error = controller.deviceError {
                feedback(error, icon: "exclamationmark.circle.fill", color: .red)
            }
            if let error = controller.monitorError {
                feedback(error, icon: "waveform.slash", color: .orange)
            }
        }
        .onAppear {
            controller.beginMonitoring(owner: monitoringOwner)
        }
        .onDisappear {
            controller.endMonitoring(owner: monitoringOwner)
        }
        .accessibilityIdentifier("microphone.input.panel")
    }

    private var automaticOption: some View {
        let defaultName = controller.selectedDeviceUID == nil
            ? controller.effectiveDevice?.name
            : nil
        return Text(defaultName.map { "Automatic (\($0))" } ?? "Automatic")
            .tag(String?.none)
    }

    @ViewBuilder
    private var unavailableSelectionOption: some View {
        if let selectedUID = controller.selectedDeviceUID,
           !controller.devices.contains(where: { $0.id == selectedUID }) {
            Text("\(controller.selectedDeviceName ?? "Saved microphone") (Unavailable)")
                .tag(Optional(selectedUID))
        }
    }

    private var inputPreview: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.12))
                Image(systemName: controller.isMonitoring ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(controller.isMonitoring ? Color.purple : Color.secondary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 5) {
                Text(inputStatusTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if controller.isMonitoring {
                    MicrophoneLevelMeter(level: controller.level)
                        .accessibilityLabel("Microphone input level")
                        .accessibilityValue(levelDescription)
                } else if let device = controller.effectiveDevice {
                    Text("\(device.name) is selected, but the live test is not running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connect an input device, then refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
        )
    }

    private var inputStatusTitle: String {
        if let device = controller.effectiveDevice, controller.isMonitoring {
            return "Listening to \(device.name)"
        }
        if controller.monitorError != nil {
            return "Microphone test unavailable"
        }
        if controller.effectiveDevice != nil {
            return "Microphone test paused"
        }
        return "No microphone found"
    }

    private var levelDescription: String {
        switch controller.level {
        case 0..<0.12: return "No signal"
        case 0..<0.4: return "Low"
        case 0..<0.72: return "Good"
        default: return "Strong"
        }
    }

    private func feedback(_ message: String, icon: String, color: Color) -> some View {
        Label(message, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct MicrophoneLevelMeter: View {
    let level: Float

    private let heights: [CGFloat] = [5, 7, 9, 12, 15, 18, 21, 24, 21, 18, 15, 12, 9, 7, 5]

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 3
            let barWidth = max(
                2,
                (geometry.size.width - spacing * CGFloat(heights.count - 1)) / CGFloat(heights.count)
            )

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                    Capsule(style: .continuous)
                        .fill(barColor(at: index))
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func barColor(at index: Int) -> Color {
        let threshold = Float(index + 1) / Float(heights.count)
        if level >= threshold {
            return threshold > 0.8 ? .orange : .purple
        }
        return Color(nsColor: .tertiaryLabelColor).opacity(0.2)
    }
}
