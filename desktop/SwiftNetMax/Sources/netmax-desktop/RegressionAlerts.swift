import SwiftUI

struct RegressionAlertsView: View {
    @State private var alertsEnabled = true
    @State private var hasAlert = true // Mock state for 3 consecutive breaches
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable Local Regression Alerts", isOn: $alertsEnabled)
            Text("Uses on-device history. No network request or remote AI call.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if alertsEnabled && hasAlert {
                VStack(alignment: .leading, spacing: 8) {
                    Text("⚠️ Alert: High Latency Detected")
                        .font(.headline)
                        .foregroundColor(.red)
                    Text("3 consecutive checks breached the threshold.")
                        .font(.subheadline)
                    
                    Button("Dismiss Alert") {
                        hasAlert = false
                    }
                    .buttonStyle(BorderedButtonStyle())
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
    }
}
