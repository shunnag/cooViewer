import Foundation
import CoreGraphics
import CoreImage
import Metal
import Darwin

enum ImageResampler {
    static func cgResample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

@main struct Probe {
    static func main() {
        setbuf(stdout, nil)
        print("device", MTLCreateSystemDefaultDevice()?.name ?? "NONE")
        let mode = CommandLine.arguments.dropFirst().first ?? "matrix"
        let late = mode.hasSuffix("late")
        var lanczos = late ? nil : LanczosDownscaler()
        var nr = late ? nil : NoiseReducer()
        if mode == "wide-metalfx" {
            let ctx = CGContext(data: nil, width: 16384, height: 2, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let image = ctx.makeImage()!
            let result = MetalFXUpscaler()?.upscale(image, to: CGSize(width: 32768, height: 4))
            print("WIDE", result?.width ?? -1, result?.height ?? -1)
            return
        }
        if mode == "benchmark" {
            let ctx = CGContext(data: nil, width: 2048, height: 1536, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
            let image = ctx.makeImage()!
            let metal = MetalFXUpscaler()
            for (name, count) in [("lanczos", 150), ("noise", 60), ("metal", 60)] {
                var elapsed: [Double] = []
                for index in 0..<(count + 10) {
                    autoreleasepool {
                        let start = ProcessInfo.processInfo.systemUptime
                        let output: CGImage?
                        switch name {
                        case "lanczos": output = lanczos?.downscale(image, to: CGSize(width: 978, height: 341))
                        case "noise": output = nr?.reduce(image, level: .medium)
                        default: output = metal?.upscale(image, to: CGSize(width: 2500, height: 2000))
                        }
                        precondition(output != nil)
                        if index >= 10 { elapsed.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                    }
                }
                elapsed.sort()
                print("BENCH", name, "n", count, "p50_ms", elapsed[count / 2], "p95_ms", elapsed[count * 95 / 100])
            }
            return
        }
        if mode.hasPrefix("invalid-") {
            let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let img = ctx.makeImage()!
            let value: CGFloat = CommandLine.arguments.dropFirst(2).first == "inf" ? .infinity : .nan
            print("INVALID",mode,value)
            if mode == "invalid-metalfx" { _ = MetalFXUpscaler()?.upscale(img, to: CGSize(width: value, height: 32)) }
            else { _ = lanczos?.downscale(img, to: CGSize(width: value, height: 8)) }
            print("SURVIVED")
            return
        }
        if mode.hasPrefix("fd-") {
            let ctx = CGContext(data: nil, width: 2048, height: 1536, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
            var img = ctx.makeImage()!
            let variant = CommandLine.arguments.dropFirst(3).first ?? "srgb"
            if variant == "cmyk" {
                let bytes = Data(repeating: 32, count: 2048*1536*4)
                img = CGImage(width: 2048, height: 1536, bitsPerComponent: 8,
                              bitsPerPixel: 32, bytesPerRow: 2048*4,
                              space: CGColorSpaceCreateDeviceCMYK(),
                              bitmapInfo: [], provider: CGDataProvider(data: bytes as CFData)!,
                              decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            } else if variant == "p3" {
                img = img.copy(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)!
            } else if variant.hasPrefix("icc-") {
                let names = ["icc-generic": "Generic RGB Profile.icc", "icc-adobe": "AdobeRGB1998.icc", "icc-romm": "ROMM RGB.icc"]
                if let name = names[variant],
                   let data = try? Data(contentsOf: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/" + name)),
                   let space = CGColorSpace(iccData: data as CFData) {
                    img = img.copy(colorSpace: space)!
                }
            }
            // late では別経路の CIContext による先行初期化も避ける。
            let metal = late ? nil : MetalFXUpscaler()
            var limit = rlimit()
            getrlimit(RLIMIT_NOFILE, &limit)
            print("nofile",limit.rlim_cur,limit.rlim_max)
            limit.rlim_cur = 256
            precondition(setrlimit(RLIMIT_NOFILE, &limit) == 0)
            var fds: [Int32] = []
            while true {
                let fd = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
                if fd < 0 { break }
                fds.append(fd)
            }
            print("exhausted",fds.count,"errno",errno)
            let spare = Int(CommandLine.arguments.dropFirst(2).first ?? "0")!
            for _ in 0..<min(spare,fds.count) { Darwin.close(fds.removeLast()) }
            print("render",mode,"spare",spare)
            if late { lanczos = LanczosDownscaler(); nr = NoiseReducer() }
            let result: CGImage?
            if mode.hasPrefix("fd-noise") { result = nr?.reduce(img, level: .medium) }
            else if mode == "fd-metal" { result = metal?.upscale(img, to: CGSize(width: 2500, height: 2000)) }
            else { result = lanczos?.downscale(img, to: CGSize(width: 978, height: 341)) }
            print("RESULT",result?.width ?? -1,result?.height ?? -1)
            if let result, let bytes = result.dataProvider?.data {
                let pointer = CFDataGetBytePtr(bytes)!
                let offset = result.height / 2 * result.bytesPerRow + result.width / 2 * 4
                print("PIXEL",pointer[offset],pointer[offset+1],pointer[offset+2],pointer[offset+3])
            }
            for fd in fds { Darwin.close(fd) }
            if result == nil {
                let recovered: CGImage?
                if mode.hasPrefix("fd-noise") { recovered = NoiseReducer()?.reduce(img, level: .medium) }
                else if mode == "fd-metal" { recovered = MetalFXUpscaler()?.upscale(img, to: CGSize(width: 2500, height: 2000)) }
                else { recovered = LanczosDownscaler()?.downscale(img, to: CGSize(width: 978, height: 341)) }
                print("RECOVERED", recovered?.width ?? -1, recovered?.height ?? -1)
                precondition(recovered != nil)
            }
            return
        }
        guard let lanczos, let nr else { fatalError("No GPU") }
        var count = 0
        let shapes = [(2048,3072),(3072,2048),(4096,4096),(8192,1024),(1,4096),(4096,1),(3,997),(997,3),(17,19),(1,1),(16384,2),(2,16384)]
        let spaces = [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace(name: CGColorSpace.displayP3)!, CGColorSpaceCreateDeviceGray(), CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!]
        for (si, space) in spaces.enumerated() {
            for (w,h) in shapes {
                let gray = space.model == .monochrome
                let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space, bitmapInfo: info) else { continue }
                ctx.setFillColor(gray ? CGColor(gray: 0.7, alpha: 1) : CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                let img = ctx.makeImage()!
                if mode == "noise" {
                    print("NR",si,w,h)
                    _ = nr.reduce(img, level: .medium)
                    count += 1
                    continue
                }
                for j in 1...50 {
                    let ow = max(1, Int(Double(w) * Double(j) / 51))
                    let oh = max(1, Int(Double(h) * Double(mode == "anisotropic" ? 51-j : j) / 51))
                    autoreleasepool {
                        if count % 25 == 0 { print("scale",count,si,w,h,ow,oh) }
                        let out = lanczos.downscale(img, to: CGSize(width: ow, height: oh))
                        if w > ow || h > oh { precondition(out?.width == ow && out?.height == oh) }
                    }
                    count += 1
                }
            }
        }
        print("PASS",count)
    }
}
