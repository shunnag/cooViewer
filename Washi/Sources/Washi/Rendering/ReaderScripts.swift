import Foundation

/// WKWebView へ注入する JS / CSS。
/// ページネーションは「標準 CSS multicol の縦積みカラム」方式:
/// - 横書き(horizontal-tb): html を高さ固定 + column-width=ページ幅 →
///   カラムが横に並び、scrollX をストライド単位で切り替える(古典手法)
/// - 縦書き(vertical-rl/lr): html を幅 100%・高さ固定 + column-width=ページ高
///   → カラム(=ページ)が縦に積まれ、scrollY をストライドで切り替える。
///   ページ切替は behavior:instant のジャンプなので、利用者には「右→左の
///   ページ送り」にしか見えない(Bibi / Readium CSS と同じ実証済みモデル。
///   -webkit-column-axis は将来の WebKit で消え得るため使わない)
/// 行の途中でページが割れないのは multicol の断片化が行ボックス境界で
/// 起きるため(縦書きの行=縦の1行が丸ごと次ページへ送られる)
enum ReaderScripts {
    /// atDocumentStart で washi コンテンツワールドへ入れる本体スクリプト。
    /// 本の JS(scripted コンテンツ)からは見えない・触れない
    static let pageScript = #"""
    (function () {
        'use strict';
        if (window.__washi) { return; }
        const washi = {};
        window.__washi = washi;

        let mode = 'htb';        // 'htb' | 'vrl' | 'vlr'
        let pageW = 0, pageH = 0, gap = 0;
        let pageCount = 1;
        let currentPage = 0;     // 表示中スプレッドの先頭ページ(0 始まり)
        let pagesPerScreen = 1;  // 1=単ページ / 2=見開き(Apple Books 風)
        let page0DocStart = 0;   // ページ 0 の文書内開始座標(縦書き見開の校正値)
        let viewportW = 0;
        let fixedLayout = false;
        let imagePage = false;   // 表紙等「画像 1 枚だけのページ」
        let keysEnabled = true;
        let ready = false;       // setup 完了前のめくり要求は無視する(章飛び防止)

        function root() { return document.documentElement; }

        function post(message) {
            try { window.webkit.messageHandlers.washi.postMessage(message); }
            catch (e) { /* ハンドラ未登録(ラスタライザ等)は黙って無視 */ }
        }

        function ensureStyle(id) {
            let el = document.getElementById(id);
            if (!el) {
                el = document.createElement('style');
                el.id = id;
                (document.head || root()).appendChild(el);
            }
            return el;
        }

        // 表紙・口絵など「画像 1 枚だけで本文テキストがないページ」の判定。
        // 電書協テンプレートの p-cover(hltr + img.fit)もこの形。
        // このページは段組にせず 1 ページの中央フィット表示にする
        function detectImagePage() {
            const body = document.body;
            if (!body) { return false; }
            const text = (body.textContent || '').replace(/\s+/g, '');
            if (text.length > 0) { return false; }
            const imgs = body.querySelectorAll('img').length;
            const svgImages = body.querySelectorAll('svg image').length;
            return (imgs + svgImages) === 1;
        }

        function applyImagePageCSS() {
            const s = ensureStyle('washi-pagination');
            s.textContent = `
                html, body {
                    margin: 0 !important; padding: 0 !important;
                    width: ${pageW}px !important; height: ${pageH}px !important;
                    overflow: hidden !important;
                }
                body {
                    display: flex !important;
                    align-items: center !important;
                    justify-content: center !important;
                }
                /* 表紙はラッパー(青空文庫系の .cover-main 等)ごと中央へ。
                   body だけ flex にしてもラッパー箱の中で img が左に寄る。
                   画像 1 枚だけのページと確定済みなので全ラッパーに効かせる */
                body :not(img):not(svg):not(image) {
                    display: flex !important;
                    align-items: center !important;
                    justify-content: center !important;
                }
                body img, body svg {
                    max-width: ${pageW}px !important;
                    max-height: ${pageH}px !important;
                    width: auto; height: auto;
                    object-fit: contain;
                }`;
        }

        // body の writing-mode は主書字方向としてルートへ伝播するため両方見る
        function detectMode() {
            const rootWM = getComputedStyle(root()).writingMode || 'horizontal-tb';
            const bodyWM = document.body
                ? (getComputedStyle(document.body).writingMode || rootWM) : rootWM;
            const wm = bodyWM.indexOf('vertical') === 0 ? bodyWM : rootWM;
            if (wm === 'vertical-rl') { return 'vrl'; }
            if (wm === 'vertical-lr') { return 'vlr'; }
            return 'htb';
        }

        // 内部軸: 横書きは常に x。縦書きは単ページ=y(縦積みカラム)、
        // 見開き=x(-webkit-column-axis: horizontal でページボックスが
        // 横に並ぶ。WKWebView 専用の実測済み経路)
        function axisIsX() {
            return mode === 'htb' || pagesPerScreen === 2;
        }

        function stride() {
            if (mode === 'htb' || pagesPerScreen === 2) { return pageW + gap; }
            return pageH + gap;
        }

        function scrollExtent() {
            const r = root();
            return axisIsX() ? r.scrollWidth : r.scrollHeight;
        }

        // スプレッド s(先頭ページ番号)の目標スクロール量。
        // 縦書き見開きはページ 0 の実測開始座標(page0DocStart)基準で、
        // 先のページが小口の逆=右スロットに来るよう合わせる(右綴じの紙の本)。
        // vlr(縦書き左綴じ)はページが右方向へ増えるので左スロット基準
        function scrollTargetFor(s) {
            if (mode === 'htb' || pagesPerScreen === 1) {
                return s * stride();
            }
            if (mode === 'vlr') {
                return page0DocStart + s * stride();
            }
            // vrl 見開き: page s の文書内開始 = page0DocStart - s*stride。
            // 右スロットの表示位置 = viewportW - pageW
            return (page0DocStart - s * stride()) - (viewportW - pageW);
        }

        // 実スクロール位置 → 表示中スプレッドの先頭ページ(クランプ自己補正)
        function pageFromScroll() {
            if (!axisIsX()) {
                return Math.max(0, Math.round(window.scrollY / stride()));
            }
            const x = window.scrollX;
            let raw;
            if (mode === 'htb') {
                raw = x / stride();
            } else if (mode === 'vlr') {
                raw = (x - page0DocStart) / stride();
            } else {
                raw = (page0DocStart - (viewportW - pageW) - x) / stride();
            }
            return Math.max(0, Math.round(raw));
        }

        function applyPaginationCSS() {
            const s = ensureStyle('washi-pagination');
            // 画像等はページ内に収め、ページ境界の分割を禁止する(安全柵)
            const safeguards = `
                img, svg, video, figure {
                    break-inside: avoid;
                    page-break-inside: avoid;
                    -webkit-column-break-inside: avoid;
                    max-width: ${pageW}px !important;
                    max-height: ${pageH}px !important;
                    object-fit: contain;
                }
                /* ページ送りは内部的に文書スクロールで実装しているため、
                   スクロールバーは隠す(縦書き文書では WebKit が縦バーを
                   左端に出し、ページ切替のたびに左に現れて紛らわしい。
                   ページ位置はノンブルが示す) */
                html { scrollbar-width: none !important; }
                html::-webkit-scrollbar, body::-webkit-scrollbar {
                    display: none !important;
                    width: 0 !important;
                    height: 0 !important;
                }`;
            if (mode === 'htb') {
                s.textContent = `
                    html {
                        margin: 0 !important; padding: 0 !important;
                        box-sizing: border-box;
                        height: ${pageH}px !important;
                        column-width: ${pageW}px !important;
                        column-gap: ${gap}px !important;
                        column-fill: auto !important;
                    }
                    body { margin: 0 !important; }
                    ${safeguards}`;
            } else if (pagesPerScreen === 2) {
                // 縦書き見開き: ルートボックス=1 ページ。-webkit-column-axis で
                // ページボックスが横(綴じ方向)に並ぶ(WKWebView 実測済み)。
                // column-progression は使わない(壊れる。調査済み)
                s.textContent = `
                    html {
                        margin: 0 !important; padding: 0 !important;
                        box-sizing: border-box;
                        width: ${pageW}px !important;
                        height: ${pageH}px !important;
                        -webkit-column-axis: horizontal;
                        column-gap: ${gap}px !important;
                        column-fill: auto !important;
                    }
                    body { margin: 0 !important; }
                    ${safeguards}`;
            } else {
                s.textContent = `
                    html {
                        margin: 0 !important; padding: 0 !important;
                        box-sizing: border-box;
                        width: ${pageW}px !important;
                        height: ${pageH}px !important;
                        column-width: ${pageH}px !important;
                        column-count: 1 !important;
                        column-gap: ${gap}px !important;
                        column-fill: auto !important;
                    }
                    body { margin: 0 !important; }
                    ${safeguards}`;
            }
        }

        function recount() {
            // 実測式(検証済み): N = ceil((scrollExtent + gap) / stride)
            pageCount = Math.max(1, Math.ceil((scrollExtent() + gap) / stride()));
            // 縦書き見開きの校正: ページ 0 の文書内開始座標を実測する
            // (書字方向によりルートボックスが右寄せ/左寄せどちらに置かれるかは
            // レイアウト依存のため、決め打ちせず測る)
            if (axisIsX() && mode !== 'htb') {
                const rect = root().getBoundingClientRect();
                page0DocStart = rect.left + window.scrollX;
            } else {
                page0DocStart = 0;
            }
        }

        // スプレッドの先頭ページへ丸める(見開きは偶数ページ始まり)
        function spreadStart(n) {
            const clamped = Math.max(0, Math.min(Math.floor(n), pageCount - 1));
            return clamped - (clamped % pagesPerScreen);
        }

        function scrollToPage(n) {
            const offset = Math.round(scrollTargetFor(n));
            if (axisIsX()) {
                window.scrollTo({ left: offset, top: 0, behavior: 'instant' });
            } else {
                window.scrollTo({ left: 0, top: offset, behavior: 'instant' });
            }
        }

        function report() {
            post({ type: 'pageChanged', page: currentPage, pageCount: pageCount,
                   mode: mode, pagesPerScreen: pagesPerScreen });
        }

        washi.showPage = function (n) {
            scrollToPage(spreadStart(n));
            // クランプ(端の半端スプレッド等)を実スクロールから自己補正
            currentPage = spreadStart(pageFromScroll());
            report();
            return currentPage;
        };

        washi.showLastPage = function () { return washi.showPage(pageCount - 1); };

        /// 項目内進行率(0..1)からの復元
        washi.showProgression = function (p) {
            const n = Math.round(p * Math.max(0, pageCount - 1));
            return washi.showPage(n);
        };

        washi.currentProgression = function () {
            return pageCount <= 1 ? 0 : currentPage / (pageCount - 1);
        };

        washi.showFragment = function (id) {
            let el = null;
            try {
                el = document.getElementById(id)
                    || document.querySelector('[name="' + CSS.escape(id) + '"]');
            } catch (e) { el = null; }
            if (!el) { return washi.showPage(0); }
            const rect = el.getBoundingClientRect();
            let page;
            if (!axisIsX()) {
                page = Math.floor(Math.max(0, window.scrollY + rect.top) / stride());
            } else if (mode === 'htb') {
                page = Math.floor(Math.max(0, window.scrollX + rect.left) / stride());
            } else {
                // 縦書き見開き: 文書内 x → ページ番号(vrl は左へ進む)
                const docX = window.scrollX + rect.left;
                const raw = mode === 'vlr'
                    ? (docX - page0DocStart) / stride()
                    : (page0DocStart - docX) / stride() + 0.999;
                page = Math.max(0, Math.floor(raw));
            }
            return washi.showPage(page);
        };

        /// メディアオーバーレイ再生: 直前の active を外して id 要素へ付け直し、
        /// その要素が現在のスプレッドに無ければそのページへめくる(ページ計数は
        /// showPage 経由で同期)。id が空なら全 active を解除するだけ
        let mediaOverlayActiveIds = [];
        washi.mediaOverlayHighlight = function (id, cls) {
            try {
                mediaOverlayActiveIds.forEach(function (prev) {
                    const p = document.getElementById(prev);
                    if (p) { p.classList.remove(cls); }
                });
            } catch (e) {}
            mediaOverlayActiveIds.length = 0;
            if (!id) { return currentPage; }
            let el = null;
            try { el = document.getElementById(id); } catch (e) { el = null; }
            if (!el) { return currentPage; }
            // cls 不正(空・空白入り)なら classList.add が throw する。主対策は
            // Swift 側(mediaOverlayActiveClass が不正値を既定へフォールバック)だが、
            // ここでも try で囲みページ追従(下)が無音停止しないよう多層防御する
            try { el.classList.add(cls); } catch (e) {}
            mediaOverlayActiveIds.push(id);
            // 現在のスプレッド外なら該当ページへめくる(既に見えていれば据え置き)
            const before = currentPage;
            const target = washi.showFragment(id);
            if (target >= before && target < before + pagesPerScreen) {
                washi.showPage(before);  // 既に可視: めくらない
            }
            return currentPage;
        };

        /// 文書内で 1 画面(単ページ=1、見開き=2 ページ)進む/戻る。
        /// ページが変わったら true。境界を越えるときは native へ通知して false。
        /// setup 前(ready=false)は何もしない(読み込み直後の連打で
        /// pageCount=1 のまま境界扱いになり章を飛ばすのを防ぐ)
        washi.turnInDoc = function (forward) {
            if (!ready) { return 'ignored'; }
            const next = currentPage + (forward ? pagesPerScreen : -pagesPerScreen);
            if (next < 0 || next >= pageCount) {
                post({ type: 'boundary', forward: !!forward });
                return 'boundary';
            }
            const before = currentPage;
            washi.showPage(next);
            if (currentPage === before) {
                // pageCount は端数(本文の後端マージン等)で 1 ページ過大に
                // なり得る。目標へスクロールできず自己補正で元のページに
                // 戻ったら実質の端として扱う — でないと巻末で「同じページへ
                // めくれ続けて次の本にも進めない」無限ループになる
                scrollToPage(before);
                post({ type: 'boundary', forward: !!forward });
                return 'boundary';
            }
            return 'turned';
        };

        // ---- セットアップ(native から didFinish 後に呼ぶ) ----

        washi.setup = function (options) {
            fixedLayout = !!options.fixedLayout;
            keysEnabled = options.keysEnabled !== false;
            const s = ensureStyle('washi-user');
            s.textContent = options.userCSS || '';
            if (fixedLayout) {
                // FXL は拡縮を native(pageZoom + フレーム調整)が担う。
                // 丸め誤差の 1px はみ出しでスクロールバーが出ないよう隠す
                ensureStyle('washi-pagination').textContent = `
                    html { scrollbar-width: none !important; overflow: hidden !important; }
                    html::-webkit-scrollbar, body::-webkit-scrollbar {
                        display: none !important;
                        width: 0 !important; height: 0 !important;
                    }`;
                pageCount = 1;
                currentPage = 0;
                mode = 'htb';
                ready = true;
                return { pageCount: 1, mode: 'fxl' };
            }
            viewportW = Math.floor(options.width);
            pageH = Math.floor(options.height);
            imagePage = detectImagePage();
            if (imagePage) {
                // 表紙等は段組せず 1 ページの中央フィット(見開き時も単独表示。
                // Apple Books の表紙表示と同じ)
                pageW = viewportW;
                pagesPerScreen = 1;
                applyImagePageCSS();
                pageCount = 1;
                currentPage = 0;
                mode = 'htb';
                ready = true;
                return { pageCount: 1, mode: mode, imagePage: true,
                         pagesPerScreen: 1 };
            }
            mode = detectMode();
            if (options.spread) {
                // 見開き: 中央ノド(gutter)を挟んだ半幅 2 ページ
                pagesPerScreen = 2;
                gap = Math.floor(options.gutter || 48);
                pageW = Math.floor((viewportW - gap) / 2);
            } else {
                pagesPerScreen = 1;
                gap = Math.floor(options.gap || 0);
                pageW = viewportW;
            }
            applyPaginationCSS();
            recount();
            currentPage = spreadStart(Math.min(currentPage, pageCount - 1));
            ready = true;
            return { pageCount: pageCount, mode: mode, imagePage: false,
                     pagesPerScreen: pagesPerScreen };
        };

        /// 配色などページ割りに影響しない CSS の差し替え(再ページ割りなし)
        washi.setUserCSS = function (css) {
            ensureStyle('washi-user').textContent = css || '';
            return true;
        };

        /// リサイズ・フォント変更後の再ページ割り(進行率を保存して復元)
        washi.repaginate = function (options) {
            const p = washi.currentProgression();
            const result = washi.setup(options);
            if (result.mode !== 'fxl') { washi.showProgression(p); }
            return result;
        };

        // ---- 入力(ホイール・キー・リンク) ----

        // ページ内リンクは native が行き先(別 spine 項目 / フラグメント)を
        // 解決するため、既定動作を止めて通知する。リンク以外のクリックは
        // 正規化座標+ボタン+修飾キー付きで tap として通知
        // (ホストのマウス割当/端タップ送り)
        function postTap(event) {
            const w = window.innerWidth || 1;
            const h = window.innerHeight || 1;
            post({ type: 'tap',
                   x: Math.min(1, Math.max(0, event.clientX / w)),
                   y: Math.min(1, Math.max(0, event.clientY / h)),
                   button: event.button || 0,
                   shift: event.shiftKey, alt: event.altKey,
                   ctrl: event.ctrlKey, meta: event.metaKey });
        }
        // click を仕様書 §5.9 の意味論に揃える: 30pt 超のドラッグ・1 秒超の
        // 長押し・テキスト選択の解放は「クリック」にしない(画像本の
        // MouseGestureRecognizer と同じ閾値)。WebKit は選択ドラッグの解放でも
        // press/release の共通祖先で click を発火するため、素通しすると
        // ページがめくれて選択まで失われる
        var pressX = 0, pressY = 0, pressT = 0;
        document.addEventListener('mousedown', function (event) {
            pressX = event.clientX;
            pressY = event.clientY;
            pressT = Date.now();
        }, true);
        function suppressAsGesture(event) {
            if (!pressT) { return false; }
            if (Math.max(Math.abs(event.clientX - pressX),
                         Math.abs(event.clientY - pressY)) > 30) { return true; }
            if (Date.now() - pressT > 1000) { return true; }
            const sel = window.getSelection ? window.getSelection() : null;
            return !!(sel && !sel.isCollapsed);
        }
        document.addEventListener('click', function (event) {
            if (suppressAsGesture(event)) {
                // 選択ドラッグがリンク上で終わってもナビゲーションさせない
                event.preventDefault();
                event.stopPropagation();
                return;
            }
            // SVG の <a> は href でなく xlink:href を持つことがあり
            // a[href] に一致しない(名前空間付き属性)。画像マップの
            // <area> も含めて捕捉し、href は素の属性 → xlink 属性 →
            // SVGAnimatedString(href.baseVal)の順で取り出す
            const anchor = event.target && event.target.closest
                ? event.target.closest('a[href], a[*|href], area[href]') : null;
            if (anchor) {
                const href = anchor.getAttribute('href')
                    || anchor.getAttributeNS('http://www.w3.org/1999/xlink', 'href')
                    || (anchor.href && anchor.href.baseVal) || '';
                if (href) {
                    event.preventDefault();
                    event.stopPropagation();
                    post({ type: 'link', href: href });
                    return;
                }
            }
            postTap(event);
        }, true);
        // 中・サイドボタン(auxclick)。右クリック(button 2)は WebKit の
        // コンテキストメニューに委ねる。サイドボタンの既定動作(履歴移動等)は
        // 止めてホストの割当(戻る/進む相当)へ渡す
        document.addEventListener('auxclick', function (event) {
            if (event.button === 2) { return; }
            event.preventDefault();
            event.stopPropagation();
            if (suppressAsGesture(event)) { return; }
            postTap(event);
        }, true);

        // ホイール/トラックパッド: 「1 ジェスチャ = 1 ページ」に量子化する。
        // 蓄積が閾値を超えたら 1 回だけめくり、以後は**イベントが 250ms
        // 途切れるまでラッチ**する(トラックパッドの慣性イベントで
        // 何ページも飛ぶのを防ぐ。画像本のスワイプめくりと同じ感覚)。
        // めくり自体は native へ通知して行う(スライドアニメーション付与のため)
        var wheelAccumulator = 0;
        var wheelQuietTimer = 0;
        // 文書ロード直後は前文書から続くトラックパッド慣性を「新しい
        // ジェスチャ」と誤認して章頭で 1 ページ余分に進めないよう、250ms の
        // 静穏が経過するまでラッチしたまま始める(画像本の
        // swipeConsumeMomentum と同じ「残慣性は終端まで飲む」意味論)
        var wheelLatched = true;
        var wheelHorizontal = false;
        var wheelAxisChosen = false;
        function wheelUnlatch() {
            wheelLatched = false;
            wheelAccumulator = 0;
            wheelAxisChosen = false;
        }
        wheelQuietTimer = setTimeout(wheelUnlatch, 250);
        document.addEventListener('wheel', function (event) {
            // 混在本の FXL ページでも spine 送りとして機能させる
            // (native 側の goForward が FXL 項目を advanceSpine に振り分ける)
            event.preventDefault();
            clearTimeout(wheelQuietTimer);
            wheelQuietTimer = setTimeout(wheelUnlatch, 250);
            if (wheelLatched) { return; }
            // 軸はジェスチャ最初のイベントで確定(画像本の handleSwipeToTurn と
            // 同じ規則)。イベント毎に再判定すると斜め入力で水平/垂直の delta が
            // 単一 accumulator に混ざり、打ち消し合いや方向誤りが起きる
            if (!wheelAxisChosen) {
                wheelHorizontal = Math.abs(event.deltaX) > Math.abs(event.deltaY);
                wheelAxisChosen = true;
            }
            wheelAccumulator += wheelHorizontal ? event.deltaX : event.deltaY;
            if (Math.abs(wheelAccumulator) < 50) { return; }
            // JS は「生のスクロール方向と軸」だけを報告し、綴じ方向への変換は
            // native(turnPageLeft/Right)に任せる。writing-mode でここで反転
            // すると、表紙などの画像ページ(mode='htb' 固定)で同じジェスチャの
            // 向きが本文と食い違う — page-progression-direction を知るのは
            // native(キー処理のコメントと同じ分業)
            post({ type: 'wheelTurn',
                   forward: wheelAccumulator > 0,
                   horizontal: wheelHorizontal });
            wheelAccumulator = 0;
            wheelLatched = true;
        }, { passive: false });

        document.addEventListener('keydown', function (event) {
            if (!keysEnabled) {
                // ホストアプリがキーを扱う: native へ転送して既定動作は止める
                post({ type: 'key', key: event.key, code: event.code,
                       shift: event.shiftKey, alt: event.altKey,
                       ctrl: event.ctrlKey, meta: event.metaKey });
                if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown',
                     'PageUp', 'PageDown', ' ', 'Home', 'End'].includes(event.key)) {
                    event.preventDefault();
                }
                return;
            }
            if (fixedLayout) { return; }
            // 既定のキー操作: 矢印は「見た目の方向」で送る。
            // 縦書き(vrl)は左=次ページ。物理方向→論理方向は native が
            // page-progression-direction を知っているため、ここでは
            // 内部軸/直感軸のみ扱い、境界は boundary 通知で native が処理
            let handled = true;
            switch (event.key) {
            case 'ArrowLeft':
                (mode === 'vrl') ? washi.turnInDoc(true) : washi.turnInDoc(false);
                break;
            case 'ArrowRight':
                (mode === 'vrl') ? washi.turnInDoc(false) : washi.turnInDoc(true);
                break;
            case 'ArrowDown': case 'PageDown': case ' ':
                washi.turnInDoc(!event.shiftKey);
                break;
            case 'ArrowUp': case 'PageUp':
                washi.turnInDoc(false);
                break;
            case 'Home':
                washi.showPage(0);
                break;
            case 'End':
                washi.showLastPage();
                break;
            default:
                handled = false;
            }
            if (handled) { event.preventDefault(); }
        }, true);

        // 選択やドラッグでの意図しないスクロールを戻す(ページ位置維持)
        let scrollGuard = 0;
        window.addEventListener('scroll', function () {
            if (fixedLayout) { return; }
            clearTimeout(scrollGuard);
            scrollGuard = setTimeout(function () {
                if (!ready) { return; }
                const off = axisIsX() ? window.scrollX : window.scrollY;
                const expected = Math.round(scrollTargetFor(currentPage));
                if (Math.abs(off - expected) > 2) { scrollToPage(currentPage); }
            }, 120);
        }, { passive: true });
    })();
    """#

    /// 常時注入する基礎 CSS。
    /// - 電書協テンプレートの抽象フォント名(serif-ja 等)を macOS 実フォントへ
    ///   結び付ける @font-face ポリフィル(ヒラギノ明朝 ProN が唯一の
    ///   プリインストール明朝。游明朝はオンデマンド DL のため後順)
    /// - ルビの rt は選択・コピー対象から外す(Readium CSS と同じ配慮)
    static let baseCSS = """
        @font-face { font-family: "serif-ja"; \
        src: local("HiraMinProN-W3"), local("Hiragino Mincho ProN"), local("YuMincho-Medium"); }
        @font-face { font-family: "serif-ja"; font-weight: bold; \
        src: local("HiraMinProN-W6"), local("YuMincho-Demibold"); }
        @font-face { font-family: "serif-ja-v"; \
        src: local("HiraMinProN-W3"), local("Hiragino Mincho ProN"), local("YuMincho-Medium"); }
        @font-face { font-family: "serif-ja-v"; font-weight: bold; \
        src: local("HiraMinProN-W6"), local("YuMincho-Demibold"); }
        @font-face { font-family: "sans-serif-ja"; \
        src: local("HiraginoSans-W3"), local("Hiragino Kaku Gothic ProN"), local("YuGothic-Medium"); }
        @font-face { font-family: "sans-serif-ja"; font-weight: bold; \
        src: local("HiraginoSans-W6"), local("YuGothic-Bold"); }
        @font-face { font-family: "sans-serif-ja-v"; \
        src: local("HiraginoSans-W3"), local("Hiragino Kaku Gothic ProN"), local("YuGothic-Medium"); }
        @font-face { font-family: "sans-serif-ja-v"; font-weight: bold; \
        src: local("HiraginoSans-W6"), local("YuGothic-Bold"); }
        ruby > rt, ruby > rp { -webkit-user-select: none; user-select: none; }
        """

    /// 基礎 CSS を挿し込む起動スクリプト(atDocumentStart。head 出現を待つ)
    static var baseCSSInjector: String {
        let escaped = baseCSS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        return """
        (function () {
            function install() {
                if (document.getElementById('washi-base')) { return; }
                const el = document.createElement('style');
                el.id = 'washi-base';
                el.textContent = `\(escaped)`;
                (document.head || document.documentElement).appendChild(el);
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', install);
            }
            install();
        })();
        """
    }
}
