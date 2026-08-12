import SwiftUI

/// 設定ペインの定義(macOS のシステム設定風サイドバー。設計書 §2.4)。
/// rawValue は保存キー SettingsSelectedTab の値。旧 TabView 時代の 0-4 の
/// 意味(0=一般/1=表示/2=操作/3=キー割り当て/4=高度)を維持したまま、
/// 新設ペインを 5 以降に追加している。表示順は sidebarOrder が決める。
enum SettingsPane: Int, CaseIterable, Identifiable {
    case general = 0
    case display = 1
    case control = 2
    case keyBindings = 3
    case advanced = 4
    case books = 5
    case pageNumber = 6
    case pageBar = 7
    case decoders = 8

    var id: Int { rawValue }

    /// サイドバーの表示順(rawValue の並びとは独立)
    static let sidebarOrder: [SettingsPane] = [
        .general, .books, .display, .pageNumber, .pageBar,
        .control, .keyBindings, .decoders, .advanced,
    ]

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .books: String(localized: "Books")
        case .display: String(localized: "Display")
        case .pageNumber: String(localized: "Page Number")
        case .pageBar: String(localized: "Page Bar")
        case .control: String(localized: "Control")
        case .keyBindings: String(localized: "Key Bindings")
        case .decoders: String(localized: "Decoders")
        case .advanced: String(localized: "Advanced")
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .books: "books.vertical"
        case .display: "book"
        case .pageNumber: "number"
        case .pageBar: "slider.horizontal.below.rectangle"
        case .control: "computermouse"
        case .keyBindings: "keyboard"
        case .decoders: "cpu"
        case .advanced: "gearshape.2"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: .gray
        case .books: .blue
        case .display: .purple
        case .pageNumber: .orange
        case .pageBar: .teal
        case .control: .green
        case .keyBindings: .indigo
        case .decoders: .red
        case .advanced: .brown
        }
    }
}

/// 設定画面(旧 PreferenceController の主要項目。仕様書 §6)。
/// システム設定(macOS 26)風の「サイドバー+検索+詳細」構成。検索語は
/// 各ペインの索引(SettingsSearch)でサイドバーを絞り込む。
/// 旧実装の「Cancel で全ロールバック」方式と異なり即時反映(設計書 §2.4)。
struct SettingsView: View {
    @AppStorage("ReadMode") private var readMode = 0
    @AppStorage("SpreadCoverSingle") private var spreadCoverSingle = false
    @AppStorage("SortMode") private var sortMode = 0
    @AppStorage("LoopCheck") private var loopCheck = 0
    @AppStorage("GoToLastPage") private var goToLastPage = 0
    @AppStorage("ReadSubFolder") private var readSubFolder = false
    @AppStorage("RememberBookSettings") private var rememberBookSettings = false
    @AppStorage("OpenLastFolder") private var openLastFolder = true
    @AppStorage("AlwaysRememberLastPage") private var alwaysRememberLastPage = false
    @AppStorage("OpenRecentLimit") private var openRecentLimit = 10

    @AppStorage("SingleSetting") private var singleSetting = 740
    @AppStorage("FitMode") private var fitMode = 0
    @AppStorage("PageTurnAnimation") private var pageTurnAnimation = 0
    @AppStorage("NoiseReductionLevel") private var noiseReductionLevel = 0
    @AppStorage("NoiseReductionScope") private var noiseReductionScope = 0
    /// 「強(ML モデル)」の同意済みフラグ(初回のみ確認を出す)
    @AppStorage("NoiseReductionMLAccepted") private var mlModelAccepted = false
    /// 「最高(×4 ML)」の同意済みフラグ(強とは別モデルなので別に確認する)
    @AppStorage("NoiseReductionSRAccepted") private var srModelAccepted = false
    @State private var showsMLConsentAlert = false
    @State private var showsSRConsentAlert = false
    @ObservedObject private var mlStatus = MLModelInstallStatus.noise
    @ObservedObject private var srStatus = MLModelInstallStatus.superResolution

    /// モデルの導入状態の表示文(強・最高で共通の文面)
    private var mlStatusDescription: String {
        let state = noiseReductionLevel == 4 ? srStatus.state : mlStatus.state
        switch state {
        case .notInstalled:
            return String(localized: "Model: not downloaded yet")
        case .downloading:
            return String(localized: "Model: downloading…")
        case .ready:
            return String(localized: "Model: ready")
        case .failed:
            return String(localized: "Model: unavailable (retried automatically when needed)")
        }
    }
    @AppStorage("Interpolation") private var interpolation = 0
    @AppStorage("ShowNumber") private var showNumber = true
    @AppStorage("ShowPageBar") private var showPageBar = true
    @AppStorage("PlayAnimatedImages") private var playAnimatedImages = true
    @State private var thumbnailRows = ThumbnailGridSetting.read().rows
    @State private var thumbnailColumns = ThumbnailGridSetting.read().columns

    // ページ番号/ページバー(仕様書 §3.4, §6.1。色と寸法は SettingsStore 経由)
    @AppStorage("ShowRelativePaths") private var showRelativePaths = false
    @AppStorage("PageNumPosition") private var pageNumPosition = 0
    @AppStorage("PageNumAutoHide") private var pageNumAutoHide = false
    @AppStorage("PageNumFontFamily") private var pageNumFontFamily = ""
    @AppStorage("PageNumFontSize") private var pageNumFontSize = 11.0
    @AppStorage("PageBarPosition") private var pageBarPosition = 0
    @AppStorage("PageBarAutoHide") private var pageBarAutoHide = false
    // PageBarSize は辞書のため @AppStorage が使えない。@State を鏡にして
    // onAppear で読み込み、変更時に SettingsStore へ書き戻す
    @State private var pageBarWidth = 200.0
    @State private var pageBarHeight = 15.0
    @State private var pageBarShowsThumbnail = true

    @AppStorage("CanScrollMode") private var canScrollMode = 0
    @AppStorage("SwipeToTurnPage") private var swipeToTurnPage = true
    @AppStorage("FlipSwipeDirection") private var flipSwipeDirection = true
    @AppStorage("WheelSensitivity") private var wheelSensitivity = 1.0
    @AppStorage("PrevPageMode") private var prevPageMode = 0
    @AppStorage("SlideshowDelay") private var slideshowDelay = 0.0

    // 高度な設定(SettingsStore.AdvancedDefault と同値の既定)
    @AppStorage("AdaptiveMediaTuning") private var adaptiveMediaTuning = true
    @AppStorage("AdvancedSpoolPolicy") private var advSpoolPolicy = 0
    @AppStorage("AdvancedSettingsEnabled") private var advancedEnabled = false
    @AppStorage("AdvancedMemoryPercent") private var advMemoryPercent =
        SettingsStore.AdvancedDefault.memoryPercent
    @AppStorage("AdvancedPrefetchAhead") private var advPrefetchAhead =
        SettingsStore.AdvancedDefault.prefetchAhead
    @AppStorage("AdvancedPrefetchBehind") private var advPrefetchBehind =
        SettingsStore.AdvancedDefault.prefetchBehind
    @AppStorage("AdvancedDisplayPixelCap") private var advDisplayPixelCap =
        SettingsStore.AdvancedDefault.displayPixelCap
    @AppStorage("AdvancedSpoolLimitGB") private var advSpoolLimitGB =
        SettingsStore.AdvancedDefault.spoolLimitGB
    @AppStorage("AdvancedPrepareNextBookPages") private var advPrepareNextBook =
        SettingsStore.AdvancedDefault.prepareNextBookPages
    @AppStorage("AdvancedThumbnailCacheDays") private var advThumbnailDays =
        SettingsStore.AdvancedDefault.thumbnailCacheDays

    // 独自デコーダの形式トグル(RetroFormatToggle と同じキー。既定は有効)
    @AppStorage("RetroDecodeMAG") private var retroDecodeMAG = true
    @AppStorage("RetroDecodeMAKI") private var retroDecodeMAKI = true
    @AppStorage("RetroDecodePi") private var retroDecodePi = true
    @AppStorage("RetroDecodePIC") private var retroDecodePIC = true
    @AppStorage("RetroDecodePNM") private var retroDecodePNM = true

    /// 前回選択していたペイン(検証用に引数 -SettingsSelectedTab n でも指定可。
    /// 値は SettingsPane.rawValue)
    @AppStorage("SettingsSelectedTab") private var selectedTab = 0

    /// 検索語(検証用に引数 -SettingsSearchText <語> で初期値を注入できる。
    /// アプリ自身はこのキーへ保存しないため通常起動では常に空)
    @State private var searchText =
        UserDefaults.standard.string(forKey: "SettingsSearchText") ?? ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
                .navigationTitle(selectedPane.title)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var selectedPane: SettingsPane {
        SettingsPane(rawValue: selectedTab) ?? .general
    }

    // MARK: - サイドバー

    private var sidebar: some View {
        List(selection: selectedPaneBinding) {
            ForEach(sidebarMatches, id: \.id) { match in
                if let pane = SettingsPane(rawValue: match.id) {
                    paneRow(pane, matchedTerms: match.matchedTerms)
                        .tag(pane)
                }
            }
            if sidebarMatches.isEmpty {
                Text(String(localized: "No Results"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { searchField }
        .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 260)
    }

    private var selectedPaneBinding: Binding<SettingsPane?> {
        Binding(
            get: { SettingsPane(rawValue: selectedTab) ?? .general },
            set: { if let pane = $0 { selectedTab = pane.rawValue } })
    }

    /// 検索語でサイドバーを絞り込んだ結果(空なら全ペイン)
    private var sidebarMatches: [SettingsSearch.Match] {
        SettingsSearch.filter(
            query: searchText,
            entries: SettingsPane.sidebarOrder.map {
                SettingsSearch.Entry(id: $0.rawValue, title: $0.title,
                                     terms: Self.searchTerms(for: $0))
            })
    }

    /// システム設定風の行(角丸カラーアイコン+タイトル。検索中は一致した
    /// 設定名を下に添える)
    private func paneRow(_ pane: SettingsPane, matchedTerms: [String]) -> some View {
        HStack(spacing: 7) {
            Image(systemName: pane.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pane.iconColor.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title)
                if !matchedTerms.isEmpty {
                    Text(matchedTerms.prefix(2).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quaternary.opacity(0.6)))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// ペイン内の設定項目ラベル(検索索引。項目を増やしたらここにも追加)
    static func searchTerms(for pane: SettingsPane) -> [String] {
        switch pane {
        case .general: [
            String(localized: "Open the last book at launch"),
            String(localized: "Recent books to keep: \(10)"),
            String(localized: "Restore last page:"),
            String(localized: "Always remember the last page"),
            String(localized: "Remember settings per book"),
        ]
        case .books: [
            String(localized: "Sort by:"),
            String(localized: "Read subfolders"),
            String(localized: "At the end of a book:"),
        ]
        case .display: [
            String(localized: "Reading direction:"),
            String(localized: "Show the Cover Page Alone"),
            String(localized: "Spread threshold (width/height):"),
            String(localized: "View mode:"),
            String(localized: "Page turn effect:"),
            String(localized: "Interpolation:"),
            String(localized: "Apply ML processing to:"),
            String(localized: "Play animated images (GIF, WebP, etc.)"),
            String(localized: "Background color:"),
            String(localized: "Thumbnails"),
        ]
        case .pageNumber: [
            String(localized: "Show page number"),
            String(localized: "File name display:"),
            String(localized: "Position:"),
            String(localized: "Text color:"),
            String(localized: "Font:"),
            String(localized: "Hide automatically (show on mouse move)"),
        ]
        case .pageBar: [
            String(localized: "Show page bar"),
            String(localized: "Position:"),
            String(localized: "Show a thumbnail while hovering"),
            String(localized: "Background color:"),
            String(localized: "Hide automatically (show on mouse move)"),
        ]
        case .control: [
            String(localized: "Turn pages with a trackpad swipe"),
            String(localized: "Reverse swipe direction"),
            String(localized: "Scroll wheel:"),
            String(localized: "Wheel page-turn threshold:"),
            String(localized: "When returning to previous page:"),
            String(localized: "Slideshow interval (seconds):"),
        ]
        case .keyBindings: [
            String(localized: "Reset to Defaults"),
        ]
        case .decoders: [
            String(localized: "Built-in image decoders"),
            "MAG", "MAKI", "Pi", "PIC", "PBM",
        ]
        case .advanced: [
            String(localized: "Adapt to media speed (SSD / HDD / network)"),
            String(localized: "Use advanced settings"),
            String(localized: "Memory & Cache"),
            String(localized: "Page cache memory:"),
            String(localized: "Archive spooling:"),
            String(localized: "Prefetch"),
            String(localized: "Max decode size (long edge):"),
            String(localized: "Restore Defaults"),
        ]
        }
    }

    // MARK: - 詳細ペイン

    @ViewBuilder
    private var detailPane: some View {
        switch selectedPane {
        case .general: generalPane
        case .books: booksPane
        case .display: displayPane
        case .pageNumber: pageNumberPane
        case .pageBar: pageBarPane
        case .control: controlPane
        // タイトルバー(ツールバー)と重ならないよう上に余白を入れる
        case .keyBindings: KeyBindingsPane().padding(.top, 12)
        case .decoders: decodersPane
        case .advanced: advancedPane
        }
    }

    // MARK: - 一般(起動・履歴・記憶)

    private var generalPane: some View {
        Form {
            Section {
                Toggle(String(localized: "Open the last book at launch"), isOn: $openLastFolder)
                Stepper(String(localized: "Recent books to keep: \(openRecentLimit)"),
                        value: $openRecentLimit, in: 0...50)
            }
            Section {
                Picker(String(localized: "Restore last page:"), selection: $goToLastPage) {
                    Text(String(localized: "Ask")).tag(0)
                    Text(String(localized: "Always")).tag(1)
                    Text(String(localized: "Never")).tag(2)
                }
                // 履歴から溢れた本のページも LastPages に残す(仕様書 §7.3)
                Toggle(String(localized: "Always remember the last page"),
                       isOn: $alwaysRememberLastPage)
                Toggle(String(localized: "Remember settings per book"),
                       isOn: $rememberBookSettings)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 本(読み込みと巡回)

    private var booksPane: some View {
        Form {
            Section {
                Picker(String(localized: "Sort by:"), selection: $sortMode) {
                    Text(String(localized: "Name (numeric aware)")).tag(0)
                    Text(String(localized: "Name (simple)")).tag(4)
                    Text(String(localized: "Creation date")).tag(2)
                    Text(String(localized: "Modification date")).tag(3)
                    Text(String(localized: "Shuffle")).tag(1)
                }
                Toggle(String(localized: "Read subfolders"), isOn: $readSubFolder)
            }
            Section {
                Picker(String(localized: "At the end of a book:"), selection: $loopCheck) {
                    Text(String(localized: "Loop")).tag(0)
                    Text(String(localized: "Open the next book (first page)")).tag(1)
                    Text(String(localized: "Open the next book (backward: last page)")).tag(2)
                    Text(String(localized: "Do nothing")).tag(3)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 表示

    private var displayPane: some View {
        Form {
            Section {
                Picker(String(localized: "Reading direction:"), selection: $readMode) {
                    Text(String(localized: "Right to Left")).tag(0)
                    Text(String(localized: "Left to Right")).tag(1)
                    Text(String(localized: "Right to Left (single page)")).tag(2)
                    Text(String(localized: "Left to Right (single page)")).tag(3)
                }
                // 表紙(先頭ページ)を単ページで表示(見開きモード時のみ効果)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(String(localized: "Show the Cover Page Alone"),
                           isOn: $spreadCoverSingle)
                    Text(String(localized:
                        "Takes effect in two-page (spread) modes."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                sliderRow(
                    label: String(localized: "Spread threshold (width/height):"),
                    value: singleSettingBinding, range: 0.4...1.0,
                    display: String(format: "%.2f", Double(singleSetting) / 1000)
                )
                // 表示モード(メニュー ⌘1-4 と同じ設定を共有。仕様書 §3.2)
                Picker(String(localized: "View mode:"), selection: $fitMode) {
                    Text(String(localized: "Fit to Screen")).tag(0)
                    Text(String(localized: "Fit to Screen Width")).tag(1)
                    Text(String(localized: "No Scale")).tag(2)
                    Text(String(localized: "Fit to Screen Width (divide)")).tag(3)
                }
                // ページめくり効果(表示メニューと同じ設定を共有。既定なし)
                Picker(String(localized: "Page turn effect:"),
                       selection: $pageTurnAnimation) {
                    Text(String(localized: "None")).tag(0)
                    Text(String(localized: "Fade")).tag(1)
                    Text(String(localized: "Slide")).tag(2)
                    Text(String(localized: "Zoom Fade")).tag(3)
                    Text(String(localized: "Page Curl")).tag(4)
                }
            }
            Section {
                // 補間=描画品質 5 段階(基礎補間+ML 高画質化の統合。
                // 保存は旧互換の Interpolation と NoiseReductionLevel の組合せ)。
                // ML 段階は初回選択時に「ダウンロードが必要・処理が重い」ことへの
                // 同意をモデル毎に取ってから設定する
                VStack(alignment: .leading, spacing: 4) {
                    Picker(String(localized: "Interpolation:"),
                           selection: renderQualityBinding) {
                        Text(String(localized: "None")).tag(RenderQuality.none.rawValue)
                        Text(String(localized: "Standard"))
                            .tag(RenderQuality.standard.rawValue)
                        Text(String(localized: "High")).tag(RenderQuality.high.rawValue)
                        Text(String(localized: "Very High (ML denoise)"))
                            .tag(RenderQuality.mlDenoise.rawValue)
                        Text(String(localized: "Maximum (×4 ML upscale)"))
                            .tag(RenderQuality.mlSuperRes.rawValue)
                    }
                    .help(interpolationDescription)
                    // 選択中モードの処理内容(ツールチップと同文)
                    Text(interpolationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if renderQualityValue == RenderQuality.mlSuperRes.rawValue {
                        Text(String(localized:
                            "Very large pages (over 2048 px) and the loupe / View Original fall back to Very High."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if renderQualityValue >= RenderQuality.mlDenoise.rawValue {
                        Text(mlStatusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear {
                    if noiseReductionLevel == 3, mlModelAccepted {
                        Task { await MLNoiseReducer.shared.ensureModel() }
                    }
                    if noiseReductionLevel == 4, srModelAccepted {
                        Task { await MLSuperResolver.shared.ensureModel() }
                    }
                }
                .alert(String(localized: "Use the “Very High (ML denoise)” level?"),
                       isPresented: $showsMLConsentAlert) {
                    Button(String(localized: "Download and Use")) {
                        mlModelAccepted = true
                        applyRenderQuality(.mlDenoise)
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized:
                        "A small model (about 1.2 MB) will be downloaded on first use. This method is much heavier: displaying a page can take a few seconds."))
                }
                .alert(String(localized: "Use the “Maximum (×4 ML upscale)” level?"),
                       isPresented: $showsSRConsentAlert) {
                    Button(String(localized: "Download and Use")) {
                        srModelAccepted = true
                        applyRenderQuality(.mlSuperRes)
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized:
                        "A model (about 9 MB) will be downloaded on first use. Each page is upscaled 4× by a neural network — this is the heaviest level: a page can take several seconds, and results are cached on disk."))
                }
                // ML 高画質化(超高・最高)をルーペ・原寸表示にも掛けるか
                Picker(String(localized: "Apply ML processing to:"),
                       selection: $noiseReductionScope) {
                    Text(String(localized: "Main view only")).tag(0)
                    Text(String(localized: "Main view and loupe")).tag(1)
                    Text(String(localized: "Everywhere (incl. View Original)")).tag(2)
                }
                .disabled(noiseReductionLevel == 0)
                Toggle(String(localized: "Play animated images (GIF, WebP, etc.)"),
                       isOn: $playAnimatedImages)
                ColorPicker(String(localized: "Background color:"),
                            selection: backgroundColorBinding, supportsOpacity: false)
            }
            Section(String(localized: "Thumbnails")) {
                Stepper(String(localized: "Thumbnail rows: \(thumbnailRows)"),
                        value: $thumbnailRows, in: 1...8)
                    .onChange(of: thumbnailRows) { saveThumbnailGrid() }
                Stepper(String(localized: "Thumbnail columns: \(thumbnailColumns)"),
                        value: $thumbnailColumns, in: 1...8)
                    .onChange(of: thumbnailColumns) { saveThumbnailGrid() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - ページ番号

    private var pageNumberPane: some View {
        Form {
            Section {
                Toggle(String(localized: "Show page number"), isOn: $showNumber)
                // サムネイル一覧のフッターと原寸表示のタイトルにも効く
                Picker(String(localized: "File name display:"),
                       selection: $showRelativePaths) {
                    Text(String(localized: "File name only")).tag(false)
                    Text(String(localized: "Relative path in book")).tag(true)
                }
                positionPicker(selection: $pageNumPosition)
                Toggle(String(localized: "Hide automatically (show on mouse move)"),
                       isOn: $pageNumAutoHide)
            }
            Section {
                ColorPicker(String(localized: "Text color:"),
                            selection: colorBinding(\.pageNumTextColor),
                            supportsOpacity: true)
                ColorPicker(String(localized: "Background color:"),
                            selection: colorBinding(\.pageNumBackgroundColor),
                            supportsOpacity: true)
                ColorPicker(String(localized: "Border color:"),
                            selection: colorBinding(\.pageNumBorderColor),
                            supportsOpacity: true)
                Picker(String(localized: "Font:"), selection: $pageNumFontFamily) {
                    Text(String(localized: "System font")).tag("")
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) {
                        Text(verbatim: $0).tag($0)
                    }
                }
                Stepper(String(localized: "Font size: \(Int(pageNumFontSize))"),
                        value: $pageNumFontSize, in: 8...32)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - ページバー

    private var pageBarPane: some View {
        Form {
            Section {
                Toggle(String(localized: "Show page bar"), isOn: $showPageBar)
                positionPicker(selection: $pageBarPosition)
                pageBarSizeSteppers
                Toggle(String(localized: "Show a thumbnail while hovering"),
                       isOn: $pageBarShowsThumbnail)
                    .onAppear {
                        pageBarShowsThumbnail = SettingsStore.shared.pageBarShowThumbnail
                    }
                    .onChange(of: pageBarShowsThumbnail) {
                        SettingsStore.shared.pageBarShowThumbnail = pageBarShowsThumbnail
                    }
                Toggle(String(localized: "Hide automatically (show on mouse move)"),
                       isOn: $pageBarAutoHide)
            }
            Section {
                ColorPicker(String(localized: "Background color:"),
                            selection: colorBinding(\.pageBarBackgroundColor),
                            supportsOpacity: true)
                ColorPicker(String(localized: "Border color:"),
                            selection: colorBinding(\.pageBarBorderColor),
                            supportsOpacity: true)
                ColorPicker(String(localized: "Read color:"),
                            selection: colorBinding(\.pageBarReadColor),
                            supportsOpacity: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 操作

    private var controlPane: some View {
        Form {
            Section {
                Toggle(String(localized: "Turn pages with a trackpad swipe"),
                       isOn: $swipeToTurnPage)
                Toggle(String(localized: "Reverse swipe direction"),
                       isOn: $flipSwipeDirection)
                    .disabled(!swipeToTurnPage)
                Picker(String(localized: "Scroll wheel:"), selection: $canScrollMode) {
                    Text(String(localized: "Scroll only")).tag(0)
                    Text(String(localized: "Scroll, then move within page")).tag(1)
                    Text(String(localized: "Scroll, then turn page")).tag(2)
                    Text(String(localized: "Always turn page")).tag(3)
                }
                sliderRow(
                    label: String(localized: "Wheel page-turn threshold:"),
                    value: $wheelSensitivity, range: 0...2.0,
                    display: wheelSensitivity == 0
                        ? String(localized: "Disabled")
                        : String(format: "%.1f", wheelSensitivity)
                )
            }
            Section {
                Picker(String(localized: "When returning to previous page:"),
                       selection: $prevPageMode) {
                    Text(String(localized: "Show from top")).tag(0)
                    Text(String(localized: "Show from bottom")).tag(1)
                }
                sliderRow(
                    label: String(localized: "Slideshow interval (seconds):"),
                    value: $slideshowDelay, range: 0...30,
                    display: String(format: "%.1f", slideshowDelay)
                )
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - デコーダ

    /// 独自デコーダの形式トグル(高度な設定のマスタースイッチとは独立。
    /// 判定は先頭マジックなので OFF にした形式は壊れページ表示になるだけ)
    private var decodersPane: some View {
        Form {
            Section(String(localized: "Built-in image decoders")) {
                Toggle(isOn: $retroDecodeMAG) { Text(verbatim: "MAG (.mag / .max)") }
                Toggle(isOn: $retroDecodeMAKI) { Text(verbatim: "MAKI (.mki)") }
                Toggle(isOn: $retroDecodePi) { Text(verbatim: "Pi (.pi)") }
                Toggle(isOn: $retroDecodePIC) { Text(verbatim: "PIC (.pic)") }
                Toggle(isOn: $retroDecodePNM) { Text(verbatim: "PBM P4 (.pbm / .pnm)") }
                Text(String(localized:
                    "Formats decoded by cooViewer itself rather than macOS. Changes apply when the next book is opened."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 高度

    /// 挙動チューニング(設計書 キャッシュ・先読み節)。マスタースイッチが
    /// OFF の間、SettingsStore 側は保存値を無視して既定値で動作する
    private var advancedPane: some View {
        Form {
            Section {
                Toggle(String(localized: "Adapt to media speed (SSD / HDD / network)"),
                       isOn: $adaptiveMediaTuning)
                Text(String(localized:
                    "Detects where the book is stored and tunes reading, prefetch, and archive spooling. Explicit values below always take precedence. Takes effect when the next book is opened."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(String(localized: "Use advanced settings"), isOn: $advancedEnabled)
                Text(String(localized: "When off, the recommended defaults are used."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "Memory & Cache")) {
                Stepper(value: $advMemoryPercent, in: 5...50, step: 5) {
                    Text(String(localized: "Page cache memory:")
                         + " \(advMemoryPercent)% (\(advancedMemoryDisplay))")
                }
                Picker(String(localized: "Archive spooling:"), selection: $advSpoolPolicy) {
                    Text(String(localized: "Automatic (by media speed)")).tag(0)
                    // "Always"/"Never" は別文脈の既存訳と衝突するため独立キー
                    Text(String(localized: "spool.policy.always",
                                defaultValue: "Always")).tag(1)
                    Text(String(localized: "spool.policy.never",
                                defaultValue: "Never")).tag(2)
                }
                Stepper(String(localized: "Archive spool limit: \(advSpoolLimitGB) GB"),
                        value: $advSpoolLimitGB, in: 1...64)
                    .disabled(advSpoolPolicy == 2)
                Stepper(String(localized: "Keep thumbnails for: \(advThumbnailDays) days"),
                        value: $advThumbnailDays, in: 1...365)
            }
            .disabled(!advancedEnabled)
            Section(String(localized: "Prefetch")) {
                Stepper(String(localized: "Prefetch ahead: \(advPrefetchAhead) pages"),
                        value: $advPrefetchAhead, in: 2...64)
                Stepper(String(localized: "Prefetch behind: \(advPrefetchBehind) pages"),
                        value: $advPrefetchBehind, in: 0...16)
                Stepper(String(localized:
                    "Prepare the next book in the last \(advPrepareNextBook) pages (0: off)"),
                        value: $advPrepareNextBook, in: 0...20)
                if !advancedEnabled {
                    Text(String(localized:
                        "While advanced settings are off, prefetch depth follows the media speed: SSD 12/3, HDD 16/4, network 20/4."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!advancedEnabled)
            Section {
                Picker(String(localized: "Max decode size (long edge):"),
                       selection: $advDisplayPixelCap) {
                    ForEach([2048, 4096, 6144, 8192], id: \.self) { size in
                        Text(verbatim: "\(size) px").tag(size)
                    }
                }
            }
            .disabled(!advancedEnabled)
            Section {
                LabeledContent {
                    Button(String(localized: "Restore Defaults")) {
                        restoreAdvancedDefaults()
                    }
                    .disabled(!advancedEnabled)
                } label: {
                    Text(String(localized:
                        "Cache and spool sizes apply when the next book is opened."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 現在のパーセント指定が実メモリで何バイトになるかの表示
    private var advancedMemoryDisplay: String {
        let bytes = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
            / 100 * Int64(advMemoryPercent)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func restoreAdvancedDefaults() {
        advMemoryPercent = SettingsStore.AdvancedDefault.memoryPercent
        advPrefetchAhead = SettingsStore.AdvancedDefault.prefetchAhead
        advPrefetchBehind = SettingsStore.AdvancedDefault.prefetchBehind
        advDisplayPixelCap = SettingsStore.AdvancedDefault.displayPixelCap
        advSpoolLimitGB = SettingsStore.AdvancedDefault.spoolLimitGB
        advSpoolPolicy = 0
        advPrepareNextBook = SettingsStore.AdvancedDefault.prepareNextBookPages
        advThumbnailDays = SettingsStore.AdvancedDefault.thumbnailCacheDays
    }

    // MARK: - 部品

    /// ラベル+スライダー+現在値の 1 行(値は幅固定でガタつかないように)
    private func sliderRow(
        label: String, value: Binding<Double>,
        range: ClosedRange<Double>, display: String
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .frame(width: 180)
                Text(display)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }

    /// 現在の描画品質(2 キーの組合せから導出。SettingsStore.renderQuality と同じ規則)
    private var renderQualityValue: Int {
        if noiseReductionLevel == 4 { return RenderQuality.mlSuperRes.rawValue }
        if noiseReductionLevel == 3 { return RenderQuality.mlDenoise.rawValue }
        switch interpolation {
        case 1: return RenderQuality.none.rawValue
        case 3: return RenderQuality.high.rawValue
        default: return RenderQuality.standard.rawValue  // 既定・旧「低」
        }
    }

    /// 描画品質を 2 キーへ分解して保存し、必要なら ML モデルの導入を始める
    private func applyRenderQuality(_ quality: RenderQuality) {
        interpolation = quality.interpolationRawValue
        noiseReductionLevel = quality.noiseReductionRawValue
        if quality == .mlDenoise {
            Task { await MLNoiseReducer.shared.ensureModel() }
        } else if quality == .mlSuperRes {
            Task { await MLSuperResolver.shared.ensureModel() }
        }
    }

    /// 補間ピッカーのバインディング。ML 段階は未同意なら値を変えずに
    /// 確認を出す(OK のときだけ applyRenderQuality)
    private var renderQualityBinding: Binding<Int> {
        Binding(
            get: { renderQualityValue },
            set: { newValue in
                guard let quality = RenderQuality(rawValue: newValue) else { return }
                if quality == .mlDenoise, !mlModelAccepted {
                    showsMLConsentAlert = true
                    return
                }
                if quality == .mlSuperRes, !srModelAccepted {
                    showsSRConsentAlert = true
                    return
                }
                applyRenderQuality(quality)
            })
    }

    /// 補間(描画品質)モードごとの処理内容(設計書 §5 描画品質)
    private var interpolationDescription: String {
        switch RenderQuality(rawValue: renderQualityValue) ?? .standard {
        case .none: String(localized: "None: pixels are scaled as-is (for pixel art).")
        case .standard: String(localized:
            "Standard: high-quality downscaling that reduces moiré on screentones.")
        case .high: String(localized:
            "High: high-quality downscaling plus MetalFX upscaling for enlargement.")
        case .mlDenoise: String(localized:
            "Very High: High plus ML denoising (waifu2x) applied to every page.")
        case .mlSuperRes: String(localized:
            "Maximum: High plus ×4 ML upscaling (Real-ESRGAN) applied to every page.")
        }
    }

    /// 4 隅の位置選択(仕様書 §6.1: 0=左上/1=右上/2=左下/3=右下)
    private func positionPicker(selection: Binding<Int>) -> some View {
        Picker(String(localized: "Position:"), selection: selection) {
            Text(String(localized: "Top left")).tag(0)
            Text(String(localized: "Top right")).tag(1)
            Text(String(localized: "Bottom left")).tag(2)
            Text(String(localized: "Bottom right")).tag(3)
        }
    }

    private var pageBarSizeSteppers: some View {
        Group {
            Stepper(String(localized: "Width: \(Int(pageBarWidth))"),
                    value: $pageBarWidth, in: 50...1000, step: 25)
                .onChange(of: pageBarWidth) { savePageBarSize() }
            Stepper(String(localized: "Height: \(Int(pageBarHeight))"),
                    value: $pageBarHeight, in: 6...40)
                .onChange(of: pageBarHeight) { savePageBarSize() }
        }
        .onAppear {
            let size = SettingsStore.shared.pageBarSize
            pageBarWidth = Double(size.width)
            pageBarHeight = Double(size.height)
        }
    }

    private func savePageBarSize() {
        SettingsStore.shared.pageBarSize = CGSize(
            width: pageBarWidth, height: pageBarHeight)
    }

    private func colorBinding(
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, NSColor>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: SettingsStore.shared[keyPath: keyPath]) },
            set: { SettingsStore.shared[keyPath: keyPath] = NSColor($0) }
        )
    }

    private func saveThumbnailGrid() {
        ThumbnailGridSetting.write(rows: thumbnailRows, columns: thumbnailColumns)
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: SettingsStore.shared.viewBackgroundColor) },
            set: { SettingsStore.shared.viewBackgroundColor = NSColor($0) }
        )
    }

    private var singleSettingBinding: Binding<Double> {
        Binding(
            get: { Double(singleSetting) / 1000 },
            set: { singleSetting = Int($0 * 1000) }
        )
    }
}
