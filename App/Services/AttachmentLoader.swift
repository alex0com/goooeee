import AppKit
import GoooeeeCore
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum AttachmentError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn't read “\(name)”."
        case .unsupported(let name): "“\(name)” isn't an image, PDF or text file."
        case .tooLarge(let name): "“\(name)” is too large to attach."
        }
    }
}

/// Turns files, images and pasted content into attachments (images downscaled, PDFs extracted).
enum AttachmentLoader {
    static let maxTextBytes = 4 * 1024 * 1024

    static func load(url: URL, maxMegapixels: Double, pdfAsImages: Bool) throws -> Attachment {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw AttachmentError.unreadable(name) }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            guard let attachment = image(from: data, name: name, maxMegapixels: maxMegapixels) else { throw AttachmentError.unreadable(name) }
            return attachment
        }
        if type.conforms(to: .pdf) {
            return pdf(from: data, name: name, renderPages: pdfAsImages)
        }
        if data.count <= maxTextBytes, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
            type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .data) && !text.contains("\0")
        {
            return Attachment(kind: .text, name: name, mimeType: type.preferredMIMEType ?? "text/plain", text: text)
        }
        if data.count > maxTextBytes { throw AttachmentError.tooLarge(name) }
        throw AttachmentError.unsupported(name)
    }

    /// Downscales to `maxMegapixels` (0 = keep size) and re-encodes as JPEG, or PNG when the image has alpha.
    static func image(from data: Data, name: String, maxMegapixels: Double) -> Attachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        var maxDimension = max(width, height)
        if maxMegapixels > 0, width > 0, height > 0 {
            let pixels = Double(width * height)
            let limit = maxMegapixels * 1_000_000
            if pixels > limit {
                let scale = (limit / pixels).squareRoot()
                maxDimension = Int(Double(max(width, height)) * scale)
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxDimension, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let type: UTType = hasAlpha ? .png : .jpeg
        guard let encoded = encode(image, type: type) else { return nil }
        let baseName = (name as NSString).deletingPathExtension
        return Attachment(
            kind: .image,
            name: baseName + (hasAlpha ? ".png" : ".jpg"),
            mimeType: hasAlpha ? "image/png" : "image/jpeg",
            data: encoded,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double = 0.85) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func pdf(from data: Data, name: String, renderPages: Bool, maxPages: Int = 20) -> Attachment {
        let document = PDFDocument(data: data)
        let text = document?.string ?? ""
        var pages: [Data]?
        if renderPages, let document {
            pages = (0..<min(document.pageCount, maxPages)).compactMap { index in
                guard let page = document.page(at: index) else { return nil }
                let image = page.thumbnail(of: CGSize(width: 1400, height: 1400), for: .mediaBox)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return encode(cgImage, type: .png)
            }
        }
        return Attachment(kind: .pdf, name: name, mimeType: "application/pdf", data: data, text: text, pageImages: pages)
    }

    /// Attachments from a pasteboard: file URLs, images, or nothing.
    static func fromPasteboard(_ pasteboard: NSPasteboard, maxMegapixels: Double, pdfAsImages: Bool) -> [Result<Attachment, Error>] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map { url in Result { try load(url: url, maxMegapixels: maxMegapixels, pdfAsImages: pdfAsImages) } }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")] {
            if let data = pasteboard.data(forType: type), let attachment = image(from: data, name: "Pasted image", maxMegapixels: maxMegapixels) {
                return [.success(attachment)]
            }
        }
        return []
    }

    static func thumbnail(for attachment: Attachment, maxSize: CGFloat = 160) -> NSImage? {
        guard attachment.kind == .image || attachment.mimeType.hasPrefix("image/"), let data = attachment.data,
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize * 2,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }

    static func icon(for attachment: Attachment) -> String {
        switch attachment.kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        case .mcpResource: "shippingbox"
        case .mcpPrompt: "text.bubble"
        }
    }
}
