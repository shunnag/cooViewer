import Foundation
import Metal

// GPU の一度きりの準備(設計書 §5): デバイス、コマンドキュー、実行時にコンパイルするパイプライン、定数表。
// カーネルは Kernels.swift の文字列から makeLibrary(source:options:) で作る(.metal ファイルも metallib も
// 置かない)。数値の規則は mathMode = .safe、精密な関数、ソース側の fp contract(off) で、Swift 側と同じ丸めになる。

/// エンジンが使うカーネル(既定の経路で使う 11 種)
enum Kernel: String, CaseIterable {
    case tileMeans, colFwd, prefilterStencil, rowNotch, colInvScatter, fillZero, normalise, blur, highpassSq,
         q3Window, gateEncodeQ3

    /// 1 スレッドグループに置くスレッドの最大数(Descreener のディスパッチと一致させる)。
    /// colFwd と colInvScatter は 512、rowNotch は 416、prefilterStencil と grid2D の 3 種は 256。
    /// grid1D の 4 種はパイプラインの上限に合わせて 256 以下に縮めるので、SIMD グループ 1 つ分あればよい
    var threadgroupSize: Int {
        switch self {
        case .colFwd, .colInvScatter: return 512
        case .rowNotch: return 416
        case .prefilterStencil, .normalise, .blur, .q3Window: return 256
        case .tileMeans, .fillZero, .highpassSq, .gateEncodeQ3: return 32
        }
    }

    /// カーネルが前提にする実行幅(simd_shuffle_xor・simd_ballot が 32 レーンを仮定する)と
    /// スレッドグループの大きさをパイプラインが満たすか(設計書 §5)
    func isSupported(threadExecutionWidth: Int, maxTotalThreadsPerThreadgroup: Int) -> Bool {
        threadExecutionWidth == 32 && maxTotalThreadsPerThreadgroup >= threadgroupSize
    }
}

/// デバイス・キュー・パイプライン・定数表。ページ間で使い回す。作成後は変更しない
final class GPUContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipes: [Kernel: MTLComputePipelineState]
    let twBuf: MTLBuffer       // float2[128]: exp(-2 pi i m / 128)(Double で求める)
    let hannBuf: MTLBuffer     // float[128]
    let eotfBuf: MTLBuffer     // float[256]
    let thrBuf: MTLBuffer      // float[256]: 再符号化のしきい値
    let wsumBuf: MTLBuffer     // float[32*32]
    let q3EncBuf: MTLBuffer    // uchar[256]: q3 が使う符号値 encodeByte(eotf[v])(恒等。q3EncLUT 参照)
    /// ライブラリとパイプラインの作成にかかった時間(ms)
    let compileMs: Double

    init() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            throw PrintAppearanceError.gpuUnavailable("Metal デバイスが無い")
        }
        device = dev
        queue = q
        let t0 = DispatchTime.now().uptimeNanoseconds
        let opts = MTLCompileOptions()
        opts.mathMode = .safe
        opts.mathFloatingPointFunctions = .precise
        let lib: MTLLibrary
        do {
            lib = try dev.makeLibrary(source: metalSource, options: opts)
        } catch {
            throw PrintAppearanceError.gpuUnavailable("カーネルのコンパイルに失敗: \(error)")
        }
        var made: [Kernel: MTLComputePipelineState] = [:]
        for kernel in Kernel.allCases {
            guard let f = lib.makeFunction(name: kernel.rawValue) else {
                throw PrintAppearanceError.gpuUnavailable("カーネル \(kernel.rawValue) が無い")
            }
            let pipeline: MTLComputePipelineState
            do {
                pipeline = try dev.makeComputePipelineState(function: f)
            } catch {
                throw PrintAppearanceError.gpuUnavailable("パイプライン \(kernel.rawValue) を作れない: \(error)")
            }
            // カーネルの前提を満たさない GPU では使わない(エンジンは CPU だけの経路になる)
            guard kernel.isSupported(threadExecutionWidth: pipeline.threadExecutionWidth,
                                     maxTotalThreadsPerThreadgroup: pipeline.maxTotalThreadsPerThreadgroup) else {
                throw PrintAppearanceError.gpuUnavailable(
                    "パイプライン \(kernel.rawValue) の実行幅 \(pipeline.threadExecutionWidth)・"
                        + "最大スレッド数 \(pipeline.maxTotalThreadsPerThreadgroup) がカーネルの前提に合わない")
            }
            made[kernel] = pipeline
        }
        pipes = made
        compileMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        var tw = [SIMD2<Float>](repeating: .zero, count: 128)
        for m in 0..<128 {
            let a = -2 * Double.pi * Double(m) / 128
            tw[m] = SIMD2(Float(cos(a)), Float(sin(a)))
        }
        func buf<T>(_ a: [T]) throws -> MTLBuffer {
            guard let b = a.withUnsafeBytes({
                dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }) else {
                throw PrintAppearanceError.allocationFailed("定数表のバッファ")
            }
            return b
        }
        twBuf = try buf(tw)
        hannBuf = try buf(hann)
        eotfBuf = try buf(eotf)
        thrBuf = try buf(encodeThresholds)
        wsumBuf = try buf(wsumPattern)
        q3EncBuf = try buf(q3EncLUT)
    }

    /// init が全種のパイプラインを作り終えているので、引けないことはない
    func pipe(_ kernel: Kernel) -> MTLComputePipelineState { pipes[kernel]! }

    func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let cb = queue.makeCommandBuffer() else {
            throw PrintAppearanceError.gpuFailed("コマンドバッファを作れない")
        }
        return cb
    }

    func makeEncoder(_ cb: MTLCommandBuffer) throws -> MTLComputeCommandEncoder {
        guard let enc = cb.makeComputeCommandEncoder() else {
            throw PrintAppearanceError.gpuFailed("コンピュートエンコーダを作れない")
        }
        return enc
    }
}

// Metal 側の構造体と同じ並び(Kernels.swift)
struct PageInfo { var W: Int32; var H: Int32; var nx: Int32; var ny: Int32 }
struct PrefilterParams { var scanCount: UInt32; var words: UInt32; var minPow3: Float; var kRadial: Float
                         var kBackground: Float; var tinyRing: Float; var tinyThresh: Float }
struct NotchTile { var entryStart: UInt32; var entryCount: UInt32; var nGuard: Int32; var pad: Int32 = 0 }
struct NotchEntry { var cxh: Float; var cxl: Float; var cyh: Float; var cyl: Float; var bu: Int32; var bv: Int32
                    var e: Int32; var flat: Float; var extent: Float; var inv2s2: Float; var omr: Float; var pad: Float = 0 }

extension MTLComputeCommandEncoder {
    func set(_ buffers: [MTLBuffer?]) { for (i, b) in buffers.enumerated() where b != nil { setBuffer(b, offset: 0, index: i) } }
    func bytes<T: BitwiseCopyable>(_ value: T, _ index: Int) {
        var v = value; setBytes(&v, length: MemoryLayout<T>.stride, index: index)
    }
    func grid1D(_ pipe: MTLComputePipelineState, _ count: Int) {
        setComputePipelineState(pipe)
        dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: min(256, pipe.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
    }
    func grid2D(_ pipe: MTLComputePipelineState, _ w: Int, _ h: Int) {
        setComputePipelineState(pipe)
        dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
    }
}
