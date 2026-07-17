import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders a `SessionReportView` behind a save panel — PNG as a 2x raster,
/// PDF as vector (selectable text). ImageRenderer is MainActor-bound.
@MainActor
enum SessionReportExporter {
    enum Format {
        case png
        case pdf

        var contentType: UTType {
            self == .png ? .png : .pdf
        }
    }

    private enum ExportError: LocalizedError {
        case renderFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .renderFailed: "Could not render the report."
            case .encodeFailed: "Could not encode the image."
            }
        }
    }

    /// Returns an error message to show, or nil on success and user cancel.
    static func promptAndExport(session: SessionRecord, hits: [HitRow],
                                displayName: String?, format: Format) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = suggestedFileName(session: session, displayName: displayName)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let report = SessionReportView(session: session, hits: hits, displayName: displayName)
        do {
            switch format {
            case .png: try writePNG(of: report, to: url)
            case .pdf: try writePDF(of: report, to: url)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func suggestedFileName(session: SessionRecord, displayName: String?) -> String {
        let base = (displayName ?? session.subtitle)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let stamp = session.startedAt.formatted(.iso8601.year().month().day())
        return "RhythmCoach – \(base) – \(stamp)"
    }

    private static func writePNG(of report: SessionReportView, to url: URL) throws {
        let renderer = ImageRenderer(content: report)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { throw ExportError.renderFailed }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ExportError.encodeFailed
        }
        try data.write(to: url)
    }

    private static func writePDF(of report: SessionReportView, to url: URL) throws {
        let renderer = ImageRenderer(content: report)
        var failure: Error?
        renderer.render { size, renderIn in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                failure = ExportError.renderFailed
                return
            }
            context.beginPDFPage(nil)
            renderIn(context)
            context.endPDFPage()
            context.closePDF()
        }
        if let failure { throw failure }
    }
}
