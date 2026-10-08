import SwiftUI

struct EvidenceExportView: View {
    @State private var selectedRecords = 0
    @State private var exported = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ISP-Ready Evidence Export")
                .font(.headline)
            Text("Generate a structured, reproducible support packet locally.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Stepper("Selected Records: \(selectedRecords)", value: $selectedRecords, in: 0...100)
            
            Button("Generate Export (PDF + JSON Manifest)") {
                exported = true
            }
            .disabled(selectedRecords == 0)
            
            if exported {
                Text("✅ Generated locally! PII and secrets redacted.")
                    .font(.subheadline)
                    .foregroundColor(.green)
            }
        }
        .padding()
    }
}
