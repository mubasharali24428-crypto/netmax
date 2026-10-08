import Foundation
import PDFKit

/// PDF exporter for NetMax
class PDFExporter {
    static let shared = PDFExporter()
    
    private init() {}
    
    /// Export content to PDF
    func export(text: String, filename: String) -> URL? {
        let pdfData = text.data(using: .utf8)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(filename).pdf")
        try? pdfData?.write(to: url)
        return url
    }
}
