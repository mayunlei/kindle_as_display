import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum CastError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

struct CastDocument {
    enum Body {
        case image(CGImage)
        case pdf(CGPDFDocument)
        case text(String)
    }

    let name: String
    let body: Body

    init(name: String, body: Body) {
        self.name = name
        self.body = body
    }

    init(url: URL) throws {
        name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let pdf = CGPDFDocument(url as CFURL), !pdf.isEncrypted || pdf.isUnlocked,
                  pdf.numberOfPages > 0 else {
                throw CastError.message("无法打开这份 PDF。若它有密码，请先导出一份已解锁的副本。")
            }
            body = .pdf(pdf)
        case "txt", "md", "markdown", "text":
            let info = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = info.fileSize, size <= 512 * 1024 else {
                throw CastError.message("文本文件请控制在 512 KB 以内。")
            }
            var encoding = String.Encoding.utf8
            body = .text(try String(contentsOf: url, usedEncoding: &encoding))
        default:
            let settings = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, settings) else {
                throw CastError.message("支持图片、PDF、TXT 和 Markdown。其他文档可以先框选截图。")
            }
            body = .image(image)
        }
    }
}

struct PageRenderer {
    static let width = 824
    static let height = 1200

    let document: CastDocument
    let landscape: Bool
    private let canvas: CGRect
    private let textFrames: [CTFrame]

    init(document: CastDocument, landscape: Bool) throws {
        self.document = document
        self.landscape = landscape
        canvas = CGRect(x: 0, y: 0, width: landscape ? Self.height : Self.width,
                        height: landscape ? Self.width : Self.height)
        if case .text(let text) = document.body {
            guard text.utf8.count <= 512 * 1024 else {
                throw CastError.message("文本请控制在 512 KB 以内。")
            }
            textFrames = try Self.paginate(text, in: canvas.insetBy(dx: 52, dy: 48))
        } else {
            textFrames = []
        }
    }

    var count: Int {
        switch document.body {
        case .image: return 1
        case .pdf(let pdf): return pdf.numberOfPages
        case .text: return textFrames.count
        }
    }

    func render(page index: Int) throws -> CGImage {
        guard (0..<count).contains(index),
              let context = CGContext(data: nil, width: Self.width, height: Self.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw CastError.message("无法生成墨水屏预览。")
        }
        if landscape {
            context.translateBy(x: CGFloat(Self.width), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(canvas)
        context.interpolationQuality = .high
        let inset = canvas.insetBy(dx: 12, dy: 12)

        switch document.body {
        case .image(let image):
            let scale = min(inset.width / CGFloat(image.width), inset.height / CGFloat(image.height))
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            context.draw(image, in: CGRect(x: inset.midX - width / 2, y: inset.midY - height / 2,
                                           width: width, height: height))
        case .pdf(let pdf):
            guard let page = pdf.page(at: index + 1) else {
                throw CastError.message("无法读取 PDF 的这一页。")
            }
            context.saveGState()
            context.clip(to: inset)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: inset, rotate: 0,
                                                          preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.restoreGState()
        case .text:
            CTFrameDraw(textFrames[index], context)
        }
        guard let frame = context.makeImage() else {
            throw CastError.message("无法生成墨水屏预览。")
        }
        return frame
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString,
                                                             1, nil) else {
            throw CastError.message("无法建立 PNG 编码器。")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else {
            throw CastError.message("无法编码投放画面。")
        }
        return data as Data
    }

    private static func paginate(_ text: String, in rect: CGRect) throws -> [CTFrame] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 11
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text.isEmpty ? " " : text,
            attributes: [
                .font: NSFont(name: "PingFangSC-Regular", size: 29) ?? NSFont.systemFont(ofSize: 29),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
        )
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        var result: [CTFrame] = []
        var offset = 0
        while offset < attributed.length {
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw CastError.message("无法完成文本分页。") }
            result.append(frame)
            offset += visible.length
        }
        return result
    }
}
