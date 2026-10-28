import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct PDFRendererMemoryProbe {
    static func generate(_ url: URL) throws {
        // 画像は 1800×2560、用紙は 300dpi 相当。異なる線画 JPEG を埋め込む(設計書 §7.6)。
        var box = CGRect(x: 0, y: 0, width: 432, height: 614.4)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw BookSourceError.pageLoadFailed("fixture")
        }
        for index in 0..<40 {
            try autoreleasepool {
                let bitmap = CGContext(data: nil, width: 1800, height: 2560,
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                bitmap.setFillColor(gray: 0.97, alpha: 1)
                bitmap.fill(CGRect(x: 0, y: 0, width: 1800, height: 2560))
                var state = UInt32(index + 7)
                func random() -> CGFloat {
                    state = state &* 1664525 &+ 1013904223
                    return CGFloat(state >> 8) / CGFloat(1 << 24)
                }
                func point() -> CGPoint { CGPoint(x: random() * 1800, y: random() * 2560) }
                for _ in 0..<400 {
                    bitmap.setStrokeColor(gray: random() * 0.3, alpha: 1)
                    bitmap.setLineWidth(1 + random() * 4)
                    bitmap.move(to: point())
                    bitmap.addCurve(to: point(), control1: point(), control2: point())
                    bitmap.strokePath()
                }
                for _ in 0..<30 {
                    bitmap.setFillColor(gray: random(), alpha: 1)
                    bitmap.fill(CGRect(x: random() * 1800, y: random() * 2560,
                                       width: random() * 200, height: random() * 200))
                }
                let data = NSMutableData()
                let destination = CGImageDestinationCreateWithData(
                    data, UTType.jpeg.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, bitmap.makeImage()!, [
                    kCGImageDestinationLossyCompressionQuality: 0.85,
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination),
                      let source = CGImageSourceCreateWithData(data, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw BookSourceError.pageLoadFailed("fixture image")
                }
                pdf.beginPDFPage(nil)
                pdf.draw(image, in: box)
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
    }

    static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw BookSourceError.pageLoadFailed("task_info: \(result)") }
        return info.phys_footprint
    }

    // 非同期の呼出しフレームにも出力画像を残さず、解放後に測定する(設計書 §7.6)。
    @inline(never) static func draw(_ source: PDFSource, entry: PageEntry) async throws {
        let image = try await source.image(for: entry, maxPixelSize: 2880)
        precondition(image.width > 0)
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            print("usage: probe generate|before|after /tmp/distinct-images.pdf")
            return
        }
        let mode = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        if mode == "generate" { try generate(url); return }
        guard mode == "before" || mode == "after" else { return }
        let source = try autoreleasepool { try PDFSource(url: url) }
        let entries = try await source.entries()
        guard entries.count >= 40 else { throw BookSourceError.pageLoadFailed("requires 40 pages") }
        print("mode,page,footprint_mib,recycles,resident_distinct_pages")
        print("\(mode),0,\(Double(try footprint()) / 1048576),0,0")
        for (index, entry) in entries.prefix(40).enumerated() {
            try await draw(source, entry: entry)
            #if PDF_RECYCLE
            let stats = await source.debugRendererStatistics()
            let recycles = stats.display.reduce(0) { $0 + $1.recycleCount }
            let pages = stats.display.reduce(0) { $0 + $1.distinctPageCount }
            #else
            let recycles = 0
            let pages = index + 1
            #endif
            print("\(mode),\(index + 1),\(Double(try footprint()) / 1048576),\(recycles),\(pages)")
        }
    }
}
