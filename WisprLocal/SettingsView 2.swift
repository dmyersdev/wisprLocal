import SwiftUI

struct SettingsView: View {
    @AppStorage("enableDictationOnLaunch") private var enableDictationOnLaunch = false

    var body: some View {
        Form {
            Toggle("Enable dictation on launch", isOn: $enableDictationOnLaunch)
            Text("Configure WisprLocal settings.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    SettingsView()
}
