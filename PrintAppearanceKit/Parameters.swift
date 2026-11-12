// 印刷の見え方エンジンの調整値(設計書 §5)。
// 値はすべて定数で、変えると出力のバイトが変わるため engineVersion を上げる。
// 全項目の値はテスト(PrintAppearanceKernelTests)で固定している。

extension Params {
    /// エンジンが使う 26 項目の値。構造体の既定値とは異なるため、必ずこちらを使う
    static let printAppearance = Params(
        tile: 128, hop: 32, rminBins: 3, kBackground: 20, kRadial: 4, radialOffsetBins: 3, ampMin: 0.006,
        notchFlatBins: 1, notchSigmaBins: 1, notchExtentBins: 4.5, notchFlatFrac: 0.15, notchSigmaFrac: 0.07,
        subMaxOrder: 16, subMinProminence: 4, screenMaxPeriodMM: 1.3, aliasMaxOrder: 0, aliasTolBins: 1.5,
        gateSigmaPx: 2, gateHighpassSigmaPx: 1.5, floorAtBinRetention: true, minNeighbours: 2, neighbourTolBins: 1.5,
        bMaskRetention: 0.5, bCutoffRetention: 0.5, colourLevel: 32, colourFrac: 0.005)
}

extension A2Params {
    /// A2 判定(連結成分の一貫性)の 15 項目の値。構造体の既定値とは異なるため、必ずこちらを使う
    static let printAppearance = A2Params(
        fillBlock: 16, clusterMinTiles: 5, fillCore: 0.65, clusterTolBins: 2.5, clusterBigTiles: 48,
        partnerAngleMin: 70, partnerAngleMax: 110, partnerRadiusTol: 0.15, partnerEnabled: true, partnerMinFill: 0.35,
        orthoAngleTol: 10, orthoRadiusTol: 0.08, closureOrder: 3, closureTolBins: 1.5, orthoMinTiles: 2)
}
