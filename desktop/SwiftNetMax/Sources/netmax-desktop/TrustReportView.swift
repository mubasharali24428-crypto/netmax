import SwiftUI

struct TrustReport: Codable {
    let samples: Int
    let median: Double
    let p95: Double
    let cv: Double
    let units: String
    let endpoint: String
    let setup: String
    let qualified: Bool
}

struct TrustReportView: View {
    let report: TrustReport
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measurement Trust Report")
                .font(.headline)
            
            HStack {
                Text("Endpoint: \(report.endpoint)")
                Spacer()
                Text("Setup: \(report.setup)")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            
            Divider()
            
            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    Text("Median")
                        .font(.caption)
                    Text("\(String(format: "%.1f", report.median)) \(report.units)")
                        .font(.title2)
                        .bold()
                }
                
                VStack(alignment: .leading) {
                    Text("p95")
                        .font(.caption)
                    Text("\(String(format: "%.1f", report.p95)) \(report.units)")
                        .font(.title2)
                        .bold()
                }
                
                VStack(alignment: .leading) {
                    Text("Variance (CV)")
                        .font(.caption)
                    Text("\(String(format: "%.1f", report.cv * 100))%")
                        .font(.title2)
                        .bold()
                        .foregroundColor(report.qualified ? .primary : .red)
                }
            }
            
            if !report.qualified {
                Text("⚠️ Unqualified Measurement: Variance > 5%")
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            } else {
                Text("✅ Qualified Measurement: Stable throughput")
                    .font(.footnote)
                    .foregroundColor(.green)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(report.qualified ? Color.green.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
        )
    }
}
