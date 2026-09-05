import Foundation

/// WKWebView へ注入する JS / CSS。
/// ページネーションは「標準 CSS multicol の縦積みカラム」方式:
/// - 横書き(horizontal-tb): html を高さ固定 + column-width=ページ幅 →
///   カラムが横に並び、scrollX をストライド単位で切り替える(古典手法)
/// - 縦書き(vertical-rl/lr): html を幅 100%・高さ固定 + column-width=ページ高
///   → 単ページではカラム(=ページ)を縦に積み、scrollY をストライド単位で
///   切り替える。見開きでは -webkit-column-axis: horizontal で半幅カラムを
///   横に並べ、scrollX を切り替える。ページ切替は behavior:instant のジャンプ
///   (Bibi / Readium CSS と同じ実証済みモデル)
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
        let paddedPageCount = 1; // 見開き末尾の空列を含む内部スクロール列数
        let currentPage = 0;     // 表示中スプレッドの先頭ページ(0 始まり)
        let pagesPerScreen = 1;  // 1=単ページ / 2=見開き(Apple Books 風)
        let page0DocStart = 0;   // ページ 0 の文書内開始座標(縦書き見開の校正値)
        let viewportW = 0;
        let fixedLayout = false;
        let imagePage = false;   // 表紙等「画像 1 枚だけのページ」
        let keysEnabled = true;
        let horizontalRTL = false;
        let defersTapsForDoubleClick = false;
        let doubleClickDelayMS = 500;
        let excludesGlyphClassification = false;
        let ready = false;       // setup 完了前のめくり要求は無視する(章飛び防止)
        let detectedColumnAxisSupport = null;
        let paginationPseudoHost = null;
        let paginationPseudoAttribute = null;
        let paginationHeadStyleSnapshot = null;
        const glyphImageObservers = new WeakSet();
        const internalStyleIDs = new Set([
            'washi-base', 'washi-default-font', 'washi-font-scale',
            'washi-pagination', 'washi-user'
        ]);

        function root() { return document.documentElement; }

        function supportsColumnAxis() {
            // cooViewer-oxr.48: WebKit の機能検出は文書ごとに 1 回だけ行う。
            // 強制フラグは未対応 WebKit の単ページフォールバック検証用。
            if (washi.__forceNoColumnAxis === true) { return false; }
            if (detectedColumnAxisSupport === null) {
                detectedColumnAxisSupport = typeof CSS !== 'undefined'
                    && typeof CSS.supports === 'function'
                    && CSS.supports('-webkit-column-axis', 'horizontal');
            }
            return detectedColumnAxisSupport;
        }

        function post(message) {
            try { window.webkit.messageHandlers.washi.postMessage(message); }
            catch (e) { /* ハンドラ未登録(ラスタライザ等)は黙って無視 */ }
        }

        function ensureStyle(id) {
            let el = document.getElementById(id);
            if (!el) {
                el = document.createElement('style');
                el.id = id;
                // runtime style API は navigation 完了後にだけ呼ばれるため head は存在する。
                // root へ退避すると著者の構造 selector を壊すので許可しない。
                document.head.appendChild(el);
            }
            return el;
        }

        // cooViewer-oxr.77: 既定フォントだけは著者 stylesheet より前の
        // 最初の layer へ置き、:where(html) と合わせて「本が常に勝つ」を保証する。
        function installDefaultFontCSS(css) {
            // setup は navigation 完了後に実行されるため、root へは挿入しない。
            const container = document.head;
            let el = document.getElementById('washi-default-font');
            if (!el) {
                el = document.createElement('style');
                el.id = 'washi-default-font';
            }
            el.textContent = css || '';
            const firstBookSheet = Array.from(container.children).find(node => {
                if (node === el || internalStyleIDs.has(node.id || '')) { return false; }
                if (node.localName === 'style') { return true; }
                return node.localName === 'link'
                    && (node.getAttribute('rel') || '').toLowerCase()
                        .split(/\s+/).includes('stylesheet');
            });
            // 著者 sheet がない文書でも washi-base の直後へ置き、基礎 CSS を
            // head の先頭に保つ。著者 sheet があれば従来どおりその直前へ置く。
            const baseStyle = document.getElementById('washi-base');
            const firstAfterBase = baseStyle && baseStyle.parentNode === container
                ? baseStyle.nextSibling : container.firstChild;
            const insertionPoint = firstBookSheet || firstAfterBase;
            if (el !== insertionPoint) { container.insertBefore(el, insertionPoint); }
        }

        // cooViewer-oxr.60 / cooViewer-oxr.76: body が著者 CSS の px/pt で
        // 固定される本だけを 1rem へ正規化する。%/em/rem の本は倍率を保つ。
        function bookBodyUsesAbsoluteFontSize() {
            const body = document.body;
            if (!body) { return false; }
            const absolute = value =>
                /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:px|pt)$/i.test((value || '').trim());
            if (absolute(body.style.getPropertyValue('font-size'))) { return true; }
            function matchingRule(rules) {
                if (!rules) { return false; }
                for (const rule of Array.from(rules)) {
                    try {
                        const mediaText = rule.media && rule.media.mediaText || '';
                        if (mediaText && mediaText !== 'all'
                            && typeof matchMedia === 'function'
                            && !matchMedia(mediaText).matches) { continue; }
                        if (rule.style && rule.selectorText
                            && absolute(rule.style.getPropertyValue('font-size'))
                            && body.matches(rule.selectorText)) { return true; }
                        // @import は cssRules でなく styleSheet 側へ規則を持つ。
                        if (rule.styleSheet
                            && matchingRule(rule.styleSheet.cssRules)) { return true; }
                        if (rule.cssRules && matchingRule(rule.cssRules)) { return true; }
                    } catch (e) { /* 未対応 selector / 読取不能 stylesheet は無視 */ }
                }
                return false;
            }
            for (const sheet of Array.from(document.styleSheets)) {
                const ownerID = sheet.ownerNode && sheet.ownerNode.id || '';
                if (internalStyleIDs.has(ownerID)) { continue; }
                try {
                    if (matchingRule(sheet.cssRules)) { return true; }
                } catch (e) { /* 別 origin の stylesheet は著者指定のまま尊重 */ }
            }
            return false;
        }

        function applyFontScale(value) {
            const s = ensureStyle('washi-font-scale');
            const userStyle = document.getElementById('washi-user');
            if (userStyle && userStyle.parentNode === s.parentNode) {
                // 著者 CSS → 倍率 → host userCSS の従来優先順を維持する。
                s.parentNode.insertBefore(s, userStyle);
            }
            // repaginate で前回の実 px 値を著者値として再び掛けない。
            s.textContent = '';
            const requested = Number(value);
            const scale = Number.isFinite(requested) && requested > 0 ? requested : 1;
            if (Math.abs(scale - 1) < 0.000001) { return; }
            const authorRootSize = parseFloat(getComputedStyle(root()).fontSize);
            if (!Number.isFinite(authorRootSize) || authorRootSize <= 0) { return; }
            const authorBodySize = document.body
                ? parseFloat(getComputedStyle(document.body).fontSize) : NaN;
            const rootRule = `html { font-size: ${authorRootSize * scale}px !important; }\n`;
            s.textContent = rootRule;
            const scaledBodySize = document.body
                ? parseFloat(getComputedStyle(document.body).fontSize) : NaN;
            const normalizeBody = bookBodyUsesAbsoluteFontSize()
                && Number.isFinite(authorBodySize) && Number.isFinite(scaledBodySize)
                && Math.abs(scaledBodySize - authorBodySize) < 0.05;
            if (normalizeBody) {
                s.textContent = rootRule + 'body { font-size: 1rem !important; }\n';
            }
        }

        // 表紙・口絵など「画像 1 枚だけで本文テキストがないページ」の判定。
        // 電書協テンプレートの p-cover(hltr + img.fit)もこの形。
        // このページは段組にせず 1 ページの中央フィット表示にする
        function detectImagePage() {
            const body = document.body;
            if (!body) { return false; }
            // cooViewer-oxr.6: Core の画像ページ判定と同じく、本文以外の文字と
            // 非表示の代替文を除く。WebKit ではスタイルシートの display も評価する。
            function hasVisibleText(node) {
                if (node.nodeType === Node.TEXT_NODE) { return /\S/.test(node.textContent); }
                if (node.nodeType !== Node.ELEMENT_NODE) { return false; }
                if (['script', 'style', 'title', 'desc'].includes(node.localName)
                    || node.hasAttribute('hidden')
                    || getComputedStyle(node).display === 'none') { return false; }
                return Array.from(node.childNodes).some(hasVisibleText);
            }
            if (hasVisibleText(body)) { return false; }
            // cooViewer-oxr.6: KCC のパネル表示用に複製された同一画像は 1 枚と数える。
            const sources = Array.from(body.querySelectorAll('img, svg image')).map(el =>
                el.localName === 'img' ? el.getAttribute('src')
                    : (el.getAttributeNS('http://www.w3.org/1999/xlink', 'href')
                        || el.getAttribute('xlink:href') || el.getAttribute('href')));
            return sources.length > 0 && sources.every(src => src && src.trim())
                && new Set(sources).size === 1;
        }

        // cooViewer-oxr.78: 透明 PNG かどうかを画素走査せず、既知 class と
        // 自然寸法・表示寸法だけで外字画像を推定する。写真の誤反転を避けるため
        // figure、画像単独ページ、画像ページ用 class、SVG source は除外する。
        // この簡易 heuristic は小さなインライン挿絵を外字と判定し得るため、
        // host 側には反転を無効化する設定を用意する。
        function classifyGlyphImage(img, singleImageDocument) {
            const generated = img.hasAttribute('data-washi-glyph-classified');
            if (generated) {
                img.classList.remove('washi-glyph');
                img.removeAttribute('data-washi-glyph-classified');
            }
            if (singleImageDocument || img.closest('figure')
                || img.classList.contains('washi-image')
                || img.closest('svg.washi-image')) { return false; }
            const src = (img.getAttribute('src') || '').trim();
            if (/^data:image\/svg\+xml(?:[;,]|$)/i.test(src)
                || /\.svg(?:[?#]|$)/i.test(src)) { return false; }

            const commonClass = Array.from(img.classList).some(value =>
                ['gaiji', 'kigou', 'glyph'].includes(value.toLowerCase()));
            let sizedLikeCharacter = false;
            const width = Number(img.naturalWidth);
            const height = Number(img.naturalHeight);
            const parent = img.parentElement;
            if (width > 0 && height > 0 && width <= 96 && height <= 96 && parent) {
                const style = getComputedStyle(img);
                const parentFontSize = parseFloat(getComputedStyle(parent).fontSize);
                const renderedHeight = img.getBoundingClientRect().height;
                sizedLikeCharacter = (style.display === 'inline'
                    || style.display === 'inline-block')
                    && Number.isFinite(parentFontSize) && parentFontSize > 0
                    && renderedHeight > 0 && renderedHeight <= 1.8 * parentFontSize;
            }
            if (!commonClass && !sizedLikeCharacter) { return false; }
            // 著者が既に同名 class を付けた場合は所有印を付けず、再判定時にも
            // 著者 class を消さない。
            if (!img.classList.contains('washi-glyph')) {
                img.classList.add('washi-glyph');
                img.setAttribute('data-washi-glyph-classified', '');
            }
            return true;
        }

        function classifyGlyphImages(singleImageDocument) {
            document.querySelectorAll('img').forEach(img => {
                classifyGlyphImage(img, singleImageDocument);
                if (glyphImageObservers.has(img)) { return; }
                glyphImageObservers.add(img);
                const classifyAfterDecode = () =>
                    classifyGlyphImage(img, excludesGlyphClassification);
                // load は遅延画像を、decode promise は complete 済みだが描画待ちの
                // 画像を覆う。どちらも class の付け直しだけなので重複しても安全。
                img.addEventListener('load', classifyAfterDecode);
                if (typeof img.decode === 'function') {
                    img.decode().then(classifyAfterDecode).catch(() => {});
                }
            });
        }

        let imagePagePrepared = false;
        function prepareImagePage() {
            if (imagePagePrepared) { return; }
            imagePagePrepared = true;
            // cooViewer-oxr.3 / Washi ミラー issue #1: SVG の auto × auto は
            // 高さ未確定の flex ラッパー内で 0×0 になる。比率から高さを確定する。
            document.body.querySelectorAll('img, svg[viewBox]').forEach(el => {
                if (el.localName === 'svg' && !el.querySelector('image')) { return; }
                const wrappers = [];
                for (let node = el; node && node !== root(); node = node.parentElement) {
                    // cooViewer-oxr.6: 非表示のパネル複製を flex 指定で再表示しない。
                    if (node.hasAttribute('hidden') || getComputedStyle(node).display === 'none') {
                        return;
                    }
                    if (node !== el && node !== document.body) { wrappers.push(node); }
                }
                wrappers.forEach(node => node.classList.add('washi-image-wrapper'));
                el.classList.add('washi-image');
                function setRatio(width, height) {
                    if (width > 0 && height > 0) {
                        el.style.setProperty('--washi-ratio', String(width / height));
                    }
                }
                if (el.localName === 'svg') {
                    const box = el.viewBox.baseVal;
                    setRatio(box.width, box.height);
                    // cooViewer-oxr.3: Calibre/Kindle の none による表紙の引き伸ばしを防ぐ。
                    el.setAttribute('preserveAspectRatio', 'xMidYMid meet');
                    el.querySelectorAll('image').forEach(image =>
                        image.setAttribute('preserveAspectRatio', 'xMidYMid meet'));
                } else {
                    const updateRatio = () => setRatio(
                        el.naturalWidth || Number(el.getAttribute('width')),
                        el.naturalHeight || Number(el.getAttribute('height')));
                    updateRatio();
                    if (!el.complete) { el.addEventListener('load', updateRatio, { once: true }); }
                }
            });
        }

        function applyImagePageCSS() {
            const s = ensureStyle('washi-pagination');
            // cooViewer-oxr.3 / Washi ミラー issue #1: 報告者提案の viewport 単位を
            // 採用し、repaginate の待ち時間中も追従する。WebView 自体がページ箱。
            s.textContent = `
                html, body, body .washi-image-wrapper {
                    margin: 0 !important; padding: 0 !important;
                    width: 100vw !important; height: 100vh !important;
                    overflow: hidden !important;
                }
                body, body .washi-image-wrapper {
                    display: flex !important;
                    align-items: center !important;
                    justify-content: center !important;
                }
                svg.washi-image, img.washi-image {
                    height: min(100vh, calc(100vw / var(--washi-ratio, 0.7))) !important;
                    width: auto !important;
                    max-width: none !important; max-height: none !important;
                    display: block; margin: 0 auto;
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

        // 表示領域(スクロール可能量の分母)。cooViewer-97e:
        // 末尾の単独ページはスプレッド先頭に揃わずスクロール上限を超えるため、
        // 目標スクロール量を到達可能な範囲へクランプして決定論にする
        function clientExtent() {
            const r = root();
            return axisIsX() ? r.clientWidth : r.clientHeight;
        }

        function clampScroll(offset) {
            const max = Math.max(0, scrollExtent() - clientExtent());
            // cooViewer-oxr.1: vrl 見開きは page0DocStart = rect.left + scrollX
            // で校正した右起点から後続ページへ scrollX が負方向に進むため、
            // 到達範囲も [-max, 0] として符号を保つ。cooViewer-oxr.57 の
            // 横書き RTL も WebKit のカラム進行が同じ負方向になる。
            if (axisIsX() && (mode === 'vrl' || (mode === 'htb' && horizontalRTL))) {
                return Math.max(-max, Math.min(offset, 0));
            }
            return Math.max(0, Math.min(offset, max));
        }

        // スプレッド s(先頭ページ番号)の目標スクロール量。
        // 縦書き見開きはページ 0 の実測開始座標(page0DocStart)基準で、
        // 先のページが小口の逆=右スロットに来るよう合わせる(右綴じの紙の本)。
        // vlr(縦書き左綴じ)はページが右方向へ増えるので左スロット基準
        function scrollTargetFor(s) {
            if (mode === 'htb') {
                // cooViewer-oxr.57: horizontal RTL multicol は右端 0 から負方向へ進む。
                return (horizontalRTL ? -s : s) * stride();
            }
            if (pagesPerScreen === 1) {
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
                raw = (horizontalRTL ? -x : x) / stride();
            } else if (mode === 'vlr') {
                raw = (x - page0DocStart) / stride();
            } else {
                raw = (page0DocStart - (viewportW - pageW) - x) / stride();
            }
            return Math.max(0, Math.round(raw));
        }

        function applyPaginationCSS() {
            const s = ensureStyle('washi-pagination');
            // cooViewer-oxr.25 / cooViewer-oxr.26: 書籍側 html の min/max 制約で
            // カラムピッチがページ送りストライドからずれないよう無効化する。
            // 画像等はページ内に収め、ページ境界の分割を禁止する(安全柵)
            const safeguards = `
                img, svg, video {
                    break-inside: avoid;
                    page-break-inside: avoid;
                    -webkit-column-break-inside: avoid;
                    max-width: ${pageW}px !important;
                    max-height: ${pageH}px !important;
                    object-fit: contain;
                }
                /* cooViewer-oxr.59: figure 自体を max-height で縮めると caption が
                   使用高に含まれず後続本文へ重なる。媒体側に caption 分を空ける。 */
                figure {
                    break-inside: avoid;
                    page-break-inside: avoid;
                    -webkit-column-break-inside: avoid;
                    box-sizing: border-box;
                    max-width: ${pageW}px !important;
                    max-height: none !important;
                }
                figure > img, figure > svg, figure > video {
                    max-height: calc(${pageH}px - 3em) !important;
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
                        max-width: none !important; max-height: none !important;
                        min-width: 0 !important; min-height: 0 !important;
                        width: ${pagesPerScreen === 2 ? 2 * pageW + gap : pageW}px !important;
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
                        max-width: none !important; max-height: none !important;
                        min-width: 0 !important; min-height: 0 !important;
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
                        max-width: none !important; max-height: none !important;
                        min-width: 0 !important; min-height: 0 !important;
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

        function resetPaginationMarkers() {
            // cooViewer-oxr.58: 前回だけに使った pseudo selector を無効化し、
            // 著者 DOM と生成 content を変えないまま再ページ割りする。
            if (paginationPseudoHost && paginationPseudoAttribute) {
                paginationPseudoHost.removeAttribute(paginationPseudoAttribute);
            }
            if (paginationHeadStyleSnapshot) {
                const marker = paginationHeadStyleSnapshot.element;
                const authored = paginationHeadStyleSnapshot.styleAttribute;
                if (authored === null) { marker.removeAttribute('style'); }
                else { marker.setAttribute('style', authored); }
            }
            paginationPseudoHost = null;
            paginationPseudoAttribute = null;
            paginationHeadStyleSnapshot = null;
            paddedPageCount = pageCount;
        }

        function finalBoxedContentRect() {
            const body = document.body;
            if (!body) { return null; }
            // cooViewer-oxr.61: marker 自身が line box や :last-child の cascade を
            // 変えて幽霊列を作らない。末尾 child node から調べることで、要素の
            // 後ろにある直下 Text と display:contents の子孫も取りこぼさない。
            for (let node = body.lastChild; node; node = node.previousSibling) {
                if (node.nodeType === Node.ELEMENT_NODE) {
                    const elementRects = node.getClientRects();
                    if (elementRects.length) {
                        return elementRects[elementRects.length - 1];
                    }
                }
                try {
                    const range = document.createRange();
                    range.selectNodeContents(node);
                    const rects = range.getClientRects();
                    if (rects.length) { return rects[rects.length - 1]; }
                } catch (e) {}
            }
            return null;
        }

        function generatedPseudoInfo(element, pseudo) {
            try {
                const style = getComputedStyle(element, pseudo);
                const content = (style.content || '').trim();
                const hasContent = !!content && content !== 'none' && content !== 'normal';
                const floatValue = (style.cssFloat
                    || style.getPropertyValue('float') || 'none').trim().toLowerCase();
                const display = (style.display || '').trim().toLowerCase();
                // CSS Fragmentation 上、break-before の対象は block-level box、
                // flex/grid item、table row group/row。任意の内部 table box や
                // inline/ruby box へは適用されない。
                const breakableDisplays = new Set([
                    'block', 'flow-root', 'list-item', 'flex', 'grid', 'table',
                    '-webkit-box', 'table-row-group', 'table-header-group',
                    'table-footer-group', 'table-row'
                ]);
                const acceptsBreakBefore = breakableDisplays.has(display)
                    || display.startsWith('block ');
                return {
                    hasContent: hasContent,
                    hasBox: hasContent && display !== 'none',
                    participatesInFlow: hasContent && display !== 'none'
                        && style.position !== 'absolute' && style.position !== 'fixed'
                        && floatValue === 'none',
                    forcesBreakBefore: acceptsBreakBefore && [
                        style.breakBefore,
                        style.getPropertyValue('-webkit-column-break-before'),
                        style.pageBreakBefore
                    ].some(value => [
                        'always', 'column', 'page', 'left', 'right', 'recto', 'verso'
                    ].includes((value || '').trim().toLowerCase()))
                };
            } catch (e) {
                return { hasContent: false, hasBox: false,
                         participatesInFlow: false, forcesBreakBefore: false };
            }
        }

        function paginationEndpoints() {
            const endpoints = [];
            const contentRect = finalBoxedContentRect();
            const body = document.body;
            if (!body) { return contentRect ? [contentRect] : endpoints; }
            if (contentRect) { endpoints.push(contentRect); }
            // cooViewer-oxr.61: body の generated content が通常フローへ入る本は、
            // fragment 化された body の全箱も候補にする。display:contents 等の
            // principal box がない場合は実 DOM の端点だけへ安全に縮退する。
            const bodyStyle = getComputedStyle(body);
            const generatedInFlow = ['::before', '::after'].some(pseudo =>
                generatedPseudoInfo(body, pseudo).participatesInFlow);
            if (generatedInFlow && bodyStyle.display !== 'none'
                && bodyStyle.display !== 'contents') {
                endpoints.push(...Array.from(body.getClientRects()));
            }
            // 候補がない空 body は recount が明示的に 1 ページとする。DOM marker を
            // 入れないため body:empty / :last-child の著者条件を変えない。
            return endpoints;
        }

        function appendTrailingSpreadPadding() {
            paddedPageCount = pageCount;
            if (pagesPerScreen !== 2 || pageCount % 2 === 0 || !document.body) { return; }
            paddedPageCount = pageCount + 1;
            const requiredExtent = Math.max(
                clientExtent(), paddedPageCount * stride() - gap);
            // authored generated content や spread の最小 viewport が既に相手面を
            // 用意している場合は、DOM/CSS を一切変えない。
            if (scrollExtent() + 0.5 >= requiredExtent) { return; }

            // cooViewer-oxr.58: 奇数末尾を先頭読書スロットへ置けるよう、
            // native へ報告しない物理容量を末尾へ 1 枚だけ足す。未使用の
            // html::after なら通常フローの column とし、著者 root pseudo は触らない。
            function identity(host, pseudo) {
                const token = `${Date.now().toString(36)}-${Math.random()
                    .toString(36).slice(2)}`;
                const attribute = `data-washi-pagination-padding-${token}`;
                const guard = Array.from({ length: 16 }, (_, index) =>
                    `:not(#washi-pagination-padding-${token}-${index})`).join('');
                const target = host === root() ? 'html' : 'html > body';
                return { host: host, attribute: attribute,
                         selector: `${target}${guard}[${attribute}]${pseudo}` };
            }

            const style = ensureStyle('washi-pagination');
            const baseCSS = style.textContent;
            const negative = mode === 'vrl' || (mode === 'htb' && horizontalRTL);
            const side = negative ? 'right' : 'left';

            function commitMarker(owned, marker, ruleForOffset) {
                owned.host.setAttribute(owned.attribute, '');
                let offset = Math.max(0, requiredExtent - 1);
                for (let attempt = 0; attempt < 4; attempt += 1) {
                    style.textContent = baseCSS + ruleForOffset(offset);
                    void marker.getBoundingClientRect();
                    const error = requiredExtent - scrollExtent();
                    if (error <= 0.5) {
                        paginationPseudoHost = owned.host;
                        paginationPseudoAttribute = owned.attribute;
                        return true;
                    }
                    if (!Number.isFinite(error)) { break; }
                    offset = Math.max(0, offset + error);
                }
                // cooViewer-oxr.58: overflow を増やさない clipped host を採用して
                // padded count だけを返さない。完全に戻して次候補を試す。
                owned.host.removeAttribute(owned.attribute);
                style.textContent = baseCSS;
                void root().getBoundingClientRect();
                return false;
            }

            const rootAfter = generatedPseudoInfo(root(), '::after');
            if (!rootAfter.hasContent) {
                const owned = identity(root(), '::after');
                if (commitMarker(owned, root(), () => `
                        ${owned.selector} {
                            all: initial !important;
                            content: "" !important; display: block !important;
                            width: 1px !important; height: 1px !important;
                            margin: 0 !important; padding: 0 !important;
                            border: 0 !important; visibility: hidden !important;
                            position: static !important; float: none !important;
                            writing-mode: inherit !important;
                            direction: inherit !important; unicode-bidi: isolate !important;
                            font-size: 0 !important; line-height: 0 !important;
                            overflow: hidden !important;
                            break-before: column !important;
                            -webkit-column-break-before: always !important;
                            pointer-events: none !important;
                        }`)) { return; }
            }

            // authored html::after は root の真の末尾なので変更しない。空いている
            // ::before を絶対配置し、現在の全 overflow より後ろまで透明容量だけ
            // 延ばす。DOM 順と無関係なので body:empty/:last-child も維持できる。
            const bodyCanHost = !['none', 'contents'].includes(
                getComputedStyle(document.body).display);
            const candidates = [[root(), '::before'], [root(), '::after']];
            if (bodyCanHost) {
                candidates.push([document.body, '::before'], [document.body, '::after']);
            }
            for (const [host, pseudo] of candidates) {
                if (generatedPseudoInfo(host, pseudo).hasContent) { continue; }
                const owned = identity(host, pseudo);
                if (commitMarker(owned, root(), offset => `
                        ${owned.selector} {
                            all: initial !important; content: "" !important;
                            display: block !important; position: absolute !important;
                            ${side}: ${offset}px !important; top: 0 !important;
                            width: 1px !important; height: 1px !important;
                            margin: 0 !important; padding: 0 !important;
                            border: 0 !important; opacity: 0 !important;
                            writing-mode: horizontal-tb !important;
                            direction: ltr !important; unicode-bidi: isolate !important;
                            pointer-events: none !important;
                        }`)) { return; }
            }

            // 四つの root/body pseudo 全てが著者 content を持つ場合は、既存の
            // head principal box を透明な絶対配置 marker として使う。root へ要素を
            // 足さないので body:nth-child(2) / head:first-child 等を壊さない。
            if (document.head) {
                const owned = identity(root(), '');
                if (commitMarker(owned, document.head, offset => `
                    ${owned.selector} > head {
                        all: initial !important; display: block !important;
                        position: absolute !important; ${side}: ${offset}px !important;
                        top: 0 !important; width: 1px !important; height: 1px !important;
                        margin: 0 !important; padding: 0 !important;
                        border: 0 !important; overflow: hidden !important;
                        contain: strict !important; visibility: hidden !important;
                        pointer-events: none !important;
                    }`)) { return; }

                // inline !important は stylesheet の important より常に強い。
                // 著者の head inline style を完全保存し、この稀な経路だけ marker
                // geometry へ一時置換して次の setup で寸分違わず復元する。
                const head = document.head;
                const snapshot = {
                    element: head, styleAttribute: head.getAttribute('style')
                };
                let offset = Math.max(0, requiredExtent - 1);
                for (let attempt = 0; attempt < 4; attempt += 1) {
                    head.style.cssText = `
                        all: initial !important; display: block !important;
                        position: absolute !important; ${side}: ${offset}px !important;
                        top: 0 !important; width: 1px !important; height: 1px !important;
                        margin: 0 !important; padding: 0 !important;
                        border: 0 !important; overflow: hidden !important;
                        contain: strict !important; visibility: hidden !important;
                        pointer-events: none !important;`;
                    void head.getBoundingClientRect();
                    const error = requiredExtent - scrollExtent();
                    if (error <= 0.5) {
                        paginationHeadStyleSnapshot = snapshot;
                        return;
                    }
                    if (!Number.isFinite(error)) { break; }
                    offset = Math.max(0, offset + error);
                }
                if (snapshot.styleAttribute === null) { head.removeAttribute('style'); }
                else { head.setAttribute('style', snapshot.styleAttribute); }
                void root().getBoundingClientRect();
            }
            // 全候補が clipped なら到達不能な内部ページ数を公開しない。
            paddedPageCount = pageCount;
        }

        function firstPageOnRight() {
            return pagesPerScreen === 2
                && (mode === 'vrl' || (mode === 'htb' && horizontalRTL));
        }

        function trailingRootGeneratedPageDelta(contentCount) {
            const info = generatedPseudoInfo(root(), '::after');
            if (!info.participatesInFlow) { return 0; }
            const withAfter = scrollExtent();
            const token = `${Date.now().toString(36)}-${Math.random()
                .toString(36).slice(2)}`;
            const attribute = `data-washi-pagination-measure-${token}`;
            const guard = Array.from({ length: 16 }, (_, index) =>
                `:not(#washi-pagination-measure-${token}-${index})`).join('');
            const style = ensureStyle('washi-pagination');
            const baseCSS = style.textContent;
            root().setAttribute(attribute, '');
            style.textContent = baseCSS + `
                html${guard}[${attribute}]::after {
                    content: none !important; display: none !important;
                }`;
            const withoutAfter = scrollExtent();
            root().removeAttribute(attribute);
            style.textContent = baseCSS;
            void root().getBoundingClientRect();
            // column overflow は stride 刻み。spread の最小 viewport 内に収まる
            // root generated content は装飾として既存ページに残し、増えた列だけ数える。
            const measured = Math.max(
                0, Math.round((withAfter - withoutAfter) / stride()));
            // cooViewer-oxr.61: 見開きの scrollExtent は最低 2 ページなので、
            // 1 ページ本文の直後へ強制改ページされた root::after は差分に出ない。
            // break-before の意味論から、その隠れた実ページを明示的に補う。
            const hiddenForcedPage = info.forcesBreakBefore
                && contentCount < pagesPerScreen ? 1 : 0;
            return measured + hiddenForcedPage;
        }

        function recount(endpointRects) {
            // 縦書き見開きの校正: ページ 0 の文書内開始座標を実測する
            // (書字方向によりルートボックスが右寄せ/左寄せどちらに置かれるかは
            // レイアウト依存のため、決め打ちせず測る)
            if (axisIsX() && mode !== 'htb') {
                const rect = root().getBoundingClientRect();
                page0DocStart = rect.left + window.scrollX;
            } else if (axisIsX() && horizontalRTL) {
                // cooViewer-oxr.57: RTL は各 fragment の右端を、ページ 0 の
                // 文書右端からの距離へ写す(見開き右スロットにも共通)。
                const rect = root().getBoundingClientRect();
                page0DocStart = rect.right + window.scrollX;
            } else {
                page0DocStart = 0;
            }
            // cooViewer-oxr.61: spread の scrollExtent は短章でも viewport 2 枚分
            // より小さくならない。実 DOM/body fragment を全て校正して最大ページを
            // 求め、末尾 html::after が実際に増やした列も加える。extent 式は
            // 壊れた矩形への上限としてだけ使う。
            const extentCount = Math.max(1, Math.ceil((scrollExtent() + gap) / stride()));
            let contentCount = 1;
            if (endpointRects && endpointRects.length) {
                contentCount = Math.max(...endpointRects.map(rect => pageForRect(rect) + 1));
            }
            contentCount += trailingRootGeneratedPageDelta(contentCount);
            pageCount = Math.max(1, Math.min(extentCount, contentCount));
            appendTrailingSpreadPadding();
        }

        // スプレッドの先頭ページへ丸める(見開きは偶数ページ始まり)
        function spreadStart(n) {
            const clamped = Math.max(0, Math.min(Math.floor(n), pageCount - 1));
            return clamped - (clamped % pagesPerScreen);
        }

        function scrollToPage(n) {
            const offset = Math.round(clampScroll(scrollTargetFor(n)));
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
            const requestedPage = spreadStart(n);
            scrollToPage(requestedPage);
            // cooViewer-oxr.58 / cooViewer-oxr.61: 末尾奇数には空列があるため
            // 到達位置を安全に読み戻せる。幽霊ページなら元位置へ自己補正する。
            currentPage = spreadStart(Math.min(pageFromScroll(), pageCount - 1));
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

        // viewport 矩形の文書座標から、その位置を含むページを求める。
        // showFragment と本文 Range の着地で同じ校正式を使う
        function pageForRect(rect) {
            if (!axisIsX()) {
                return Math.floor(Math.max(0, window.scrollY + rect.top) / stride());
            }
            if (mode === 'htb') {
                if (horizontalRTL) {
                    const docRight = window.scrollX + rect.right;
                    return Math.floor(Math.max(0, page0DocStart - docRight) / stride());
                }
                return Math.floor(Math.max(0, window.scrollX + rect.left) / stride());
            }
            // 縦書き見開き: 文書内 x → ページ番号(vrl は左へ進む)
            const docX = window.scrollX + rect.left;
            const raw = mode === 'vlr'
                ? (docX - page0DocStart) / stride()
                : (page0DocStart - docX) / stride() + 0.999;
            return Math.max(0, Math.floor(raw));
        }

        // cooViewer-oxr.38: 現在 spine の印刷ページ境界をレイアウト後に
        // 一度走査する。epub:type は namespace API と prefix 付き属性の両方を
        // 見て、role/class の既知ヒューリスティックも同じ候補集合へ畳む。
        function collectPrintPageMarkers(singlePage = false) {
            const namespace = 'http://www.idpf.org/2007/ops';
            const candidates = Array.from(document.querySelectorAll('*')).filter(el => {
                const epubType = el.getAttributeNS(namespace, 'type')
                    || el.getAttribute('epub:type') || '';
                const role = el.getAttribute('role') || '';
                return epubType.split(/\s+/).includes('pagebreak')
                    || role.split(/\s+/).includes('doc-pagebreak')
                    || (el.localName === 'span'
                        && (el.classList.contains('pagebreak')
                            || el.classList.contains('pb')));
            });
            return candidates.map(el => {
                const rect = el.getClientRects()[0] || el.getBoundingClientRect();
                const label = (el.getAttribute('title')
                    || el.getAttribute('aria-label') || el.textContent || '').trim();
                if (!label) { return null; }
                return { label: label,
                         page: singlePage ? 0 : pageForRect(rect) };
            }).filter(Boolean);
        }

        washi.printPageMarkers = collectPrintPageMarkers;

        washi.showFragment = function (id) {
            let el = null;
            try {
                el = document.getElementById(id)
                    || document.querySelector('[name="' + CSS.escape(id) + '"]');
            } catch (e) { el = null; }
            if (!el) { return washi.showPage(0); }
            // cooViewer-oxr.5: 縦書き見開きの結合矩形は最終ページまで左へ伸びる。
            // locateAndShow と同じ先頭断片を使い、章ラッパーでも冒頭へ着地する。
            const rect = el.getClientRects()[0] || el.getBoundingClientRect();
            return washi.showPage(pageForRect(rect));
        };

        // WashiCore の appendPlainText / collapsingWhitespace と同じ本文を
        // 作りながら、正規化後の UTF-16 各単位を元 Text ノードへ対応づける。
        // キャッシュの無効化は不要: 地図は DOM のみに依存し(レイアウト・
        // ページ割り・repaginate には依存しない)、DOM は変異させず、spine 項目の
        // 読み込みで文書ごと差し替わる(= JS コンテキストも新しくなる)
        // TODO(cooViewer-oxr.69): locateAndShow 完了後は UTF-16 単位の
        // 対応表を保持せず、次の要求に必要な範囲だけへ縮小する。
        var textMapCache = null;

        washi.buildTextMap = function () {
            if (textMapCache) { return textMapCache; }

            const raw = [];
            // cooViewer-oxr.89: Core と同じ名前空間文脈で不可視注釈を除く。
            const skipped = {
                always: new Set(['script', 'style', 'rt', 'rp', 'rtc']),
                svg: new Set(['title', 'desc']),
                mathML: new Set(['annotation', 'annotation-xml'])
            };
            const breaking = new Set([
                // cooViewer-oxr.92: 表題・見出し・セルを改行境界にする。
                'p', 'div', 'br', 'li', 'tr', 'td', 'th', 'caption',
                'section', 'article',
                'blockquote', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
                'figure', 'figcaption', 'table', 'ul', 'ol', 'dl', 'dd',
                'dt', 'hr', 'pre'
            ]);

            function appendBreak() {
                if (raw.length === 0 || raw[raw.length - 1].unit !== '\n') {
                    raw.push({ unit: '\n', node: null, offset: 0, endOffset: 0 });
                }
            }

            function appendText(node) {
                const value = node.data || '';
                for (let offset = 0; offset < value.length; offset += 1) {
                    raw.push({ unit: value.slice(offset, offset + 1), node: node,
                               offset: offset, endOffset: offset + 1 });
                }
            }

            function appendChildren(element, insideSVG = false,
                                    insideMathML = false) {
                for (let child = element.firstChild; child; child = child.nextSibling) {
                    // CDATASection も Text の派生型なのでここで拾う。
                    // WashiCore(NSXML)は XML 空白(SP/TAB/CR/LF)だけのテキスト
                    // ノードを DOM から落とす(要素間の整形改行に加え、
                    // </span> <span> の間の半角スペースも。実測)ため、同じ
                    // ノードを本文に数えない。U+3000 等は XML 空白でないので残る
                    if (child instanceof Text) {
                        // NSXML は隣接する Text/CDATA を 1 ノードへ結合してから
                        // 空白判定する(cooViewer-659)。同じ連続を束ねて判定し、
                        // 非空白なら各ノードの位置を保ったまま本文へ加える
                        const run = [child];
                        let next = child.nextSibling;
                        while (next && next instanceof Text) {
                            run.push(next);
                            next = next.nextSibling;
                        }
                        const combined = run.map(node => node.data || '').join('');
                        if (!/^[\t\n\r ]*$/.test(combined)) {
                            run.forEach(appendText);
                        }
                        child = run[run.length - 1];
                        continue;
                    }
                    if (child.nodeType !== Node.ELEMENT_NODE) { continue; }
                    const name = (child.localName || '').toLowerCase();
                    const isSVG = insideSVG
                        || child.namespaceURI === 'http://www.w3.org/2000/svg'
                        || name === 'svg';
                    const isMathML = insideMathML
                        || child.namespaceURI === 'http://www.w3.org/1998/Math/MathML'
                        || name === 'math';
                    if (skipped.always.has(name)
                        || (isSVG && skipped.svg.has(name))
                        || (isMathML && skipped.mathML.has(name))) { continue; }
                    if (breaking.has(name)) { appendBreak(); }
                    appendChildren(child, isSVG, isMathML);
                    if (breaking.has(name)) { appendBreak(); }
                }
            }

            const body = document.body || document.documentElement;
            if (body) { appendChildren(body); }

            // 要素境界から作った改行には Text ノードがない。直前(無ければ
            // 直後)の Text 境界を与え、正規化本文の全単位を Range 境界へ写す。
            // cooViewer-oxr.34: 前方走査を先にしないと、次段落の先頭選択が
            // その直前の合成改行まで含む offset へ逆写像される。
            let previousPoint = null;
            for (const item of raw) {
                if (item.node && item.endOffset !== item.offset) {
                    previousPoint = { node: item.node, offset: item.endOffset };
                } else if (!item.node && previousPoint) {
                    item.node = previousPoint.node;
                    item.offset = previousPoint.offset;
                    item.endOffset = previousPoint.offset;
                }
            }
            let nextPoint = null;
            for (let index = raw.length - 1; index >= 0; index -= 1) {
                const item = raw[index];
                if (item.node && item.endOffset !== item.offset) {
                    nextPoint = { node: item.node, offset: item.offset };
                } else if (!item.node && nextPoint) {
                    item.node = nextPoint.node;
                    item.offset = nextPoint.offset;
                    item.endOffset = nextPoint.offset;
                }
            }

            // components(separatedBy: .whitespaces) と同じ集合:
            // Unicode Zs + TAB。改行系はこの段階では畳まない
            const isWhitespace = unit => /[\p{Zs}\u0009]/u.test(unit);
            const lines = [{ units: [], separatorBefore: null }];
            for (const item of raw) {
                if (item.unit === '\n') {
                    lines.push({ units: [], separatorBefore: item });
                } else {
                    lines[lines.length - 1].units.push(item);
                }
            }

            function collapseLine(units) {
                const result = [];
                let pendingWhitespace = null;
                let hasText = false;
                for (const item of units) {
                    if (isWhitespace(item.unit)) {
                        if (hasText && !pendingWhitespace) { pendingWhitespace = item; }
                        continue;
                    }
                    if (pendingWhitespace) {
                        result.push({ unit: ' ', node: pendingWhitespace.node,
                                      offset: pendingWhitespace.offset,
                                      endOffset: pendingWhitespace.endOffset });
                        pendingWhitespace = null;
                    }
                    result.push(item);
                    hasText = true;
                }
                return result;
            }

            // 空行の連続を 1 本へ丸める
            const collapsedLines = [];
            for (const line of lines) {
                const units = collapseLine(line.units);
                if (units.length === 0 && collapsedLines.length > 0
                    && collapsedLines[collapsedLines.length - 1].units.length === 0) {
                    continue;
                }
                collapsedLines.push({ units: units,
                                      separatorBefore: line.separatorBefore });
            }

            const normalized = [];
            for (let index = 0; index < collapsedLines.length; index += 1) {
                const line = collapsedLines[index];
                if (index > 0) {
                    const separator = line.separatorBefore;
                    if (separator && separator.node) {
                        normalized.push({ unit: '\n', node: separator.node,
                                          offset: separator.offset,
                                          endOffset: separator.endOffset });
                    }
                }
                normalized.push(...line.units);
            }

            // trimmingCharacters(in: .whitespacesAndNewlines) と同じ集合
            const isTrim = unit =>
                /[\p{Zs}\u0009\u000A\u000B\u000C\u000D\u0085\u2028\u2029]/u.test(unit);
            let lower = 0;
            let upper = normalized.length;
            while (lower < upper && isTrim(normalized[lower].unit)) { lower += 1; }
            while (upper > lower && isTrim(normalized[upper - 1].unit)) { upper -= 1; }
            const map = normalized.slice(lower, upper);
            textMapCache = { text: map.map(item => item.unit).join(''), map: map };
            return textMapCache;
        };

        // cooViewer-oxr.34: DOM 境界を正規化本文の UTF-16 境界へ戻す。
        // 直接対応がない要素境界・畳まれた空白は Range の文書順で最寄りの
        // 正規化単位へ寄せる。
        washi.textOffsetFor = function (node, domOffset) {
            const textMap = washi.buildTextMap();
            if (!node || !Number.isInteger(domOffset) || domOffset < 0) {
                return null;
            }
            let lastDirect = null;
            for (let index = 0; index < textMap.map.length; index += 1) {
                const item = textMap.map[index];
                if (item.node !== node) { continue; }
                if (domOffset <= item.offset) { return index; }
                if (domOffset <= item.endOffset) { return index + 1; }
                lastDirect = index + 1;
            }
            if (lastDirect !== null) { return lastDirect; }
            try {
                const boundary = document.createRange();
                boundary.setStart(node, domOffset);
                boundary.collapse(true);
                for (let index = 0; index < textMap.map.length; index += 1) {
                    const item = textMap.map[index];
                    if (!(item.node instanceof Text)) { continue; }
                    const point = document.createRange();
                    point.setStart(item.node, item.offset);
                    point.collapse(true);
                    if (boundary.compareBoundaryPoints(Range.START_TO_START, point) <= 0) {
                        return index;
                    }
                }
                return textMap.map.length;
            } catch (e) {
                return null;
            }
        };

        function domRangeForTextRange(utf16Offset, utf16Length) {
            if (!Number.isInteger(utf16Offset) || !Number.isInteger(utf16Length)
                || utf16Offset < 0 || utf16Length <= 0) { return null; }
            const textMap = washi.buildTextMap();
            const end = utf16Offset + utf16Length;
            if (!Number.isSafeInteger(end) || end > textMap.map.length) { return null; }
            const first = textMap.map[utf16Offset];
            const last = textMap.map[end - 1];
            if (!first || !last || !(first.node instanceof Text)
                || !(last.node instanceof Text)) { return null; }
            try {
                const range = document.createRange();
                range.setStart(first.node, first.offset);
                range.setEnd(last.node, last.endOffset);
                return { range: range, textMap: textMap, first: first,
                         last: last, end: end };
            } catch (e) {
                return null;
            }
        }

        washi.rectsForTextRange = function (utf16Offset, utf16Length) {
            const mapped = domRangeForTextRange(utf16Offset, utf16Length);
            if (!mapped) { return []; }
            return Array.from(mapped.range.getClientRects()).map(rect => ({
                x: rect.x, y: rect.y, w: rect.width, h: rect.height
            }));
        };

        let selectionReportTimer = 0;
        function postSelection() {
            const selection = window.getSelection ? window.getSelection() : null;
            if (!selection || selection.isCollapsed || selection.rangeCount === 0) {
                post({ type: 'selection', text: '' });
                return;
            }
            const range = selection.getRangeAt(0);
            const start = washi.textOffsetFor(range.startContainer, range.startOffset);
            const end = washi.textOffsetFor(range.endContainer, range.endOffset);
            const textMap = washi.buildTextMap();
            if (!Number.isInteger(start) || !Number.isInteger(end) || end <= start
                || end > textMap.map.length) {
                post({ type: 'selection', text: '' });
                return;
            }
            const rects = Array.from(range.getClientRects()).map(rect => ({
                x: rect.x, y: rect.y, w: rect.width, h: rect.height
            }));
            post({ type: 'selection', text: textMap.text.slice(start, end),
                   start: start, end: end, rects: rects });
        }
        document.addEventListener('selectionchange', function () {
            clearTimeout(selectionReportTimer);
            selectionReportTimer = setTimeout(postSelection, 120);
        });
        washi.clearSelection = function () {
            const selection = window.getSelection ? window.getSelection() : null;
            if (selection) { selection.removeAllRanges(); }
            clearTimeout(selectionReportTimer);
            post({ type: 'selection', text: '' });
            return true;
        };

        // 失敗時も null ではなく { found: false } を返す: WebKit の Swift async
        // callAsyncJavaScript は戻り値が非 Optional で、JS の null/undefined を
        // 受け取れず継続が破棄される(InvalidTransition。実測)
        washi.locateAndShow = function (utf16Offset, utf16Length) {
            const mappedRange = domRangeForTextRange(utf16Offset, utf16Length);
            if (!mappedRange) { return { found: false }; }
            const textMap = mappedRange.textMap;
            const end = mappedRange.end;
            const first = mappedRange.first;
            const last = mappedRange.last;
            try {
                const range = mappedRange.range;
                const beforeRects = range.getClientRects();
                // レイアウト箱を持たない範囲(display:none 等。抽出本文には含まれる)は
                // 位置を特定できないので null を返し、呼び出し側の近似へ委ねる
                // (cooViewer-cvt。零矩形で現在ページへ着地したと偽らない)
                if (beforeRects.length === 0) { return { found: false }; }
                // 返す page は「範囲の先頭を含むページ」(doc の契約)。showPage は
                // 見開きでは先頭ページへ丸めるため、その戻り値は使わない(cooViewer-tlo)
                const targetPage = pageForRect(beforeRects[0]);
                washi.showPage(targetPage);
                const rects = Array.from(range.getClientRects()).map(rect => ({
                    x: rect.x, y: rect.y, w: rect.width, h: rect.height
                }));
                if (rects.length === 0) { return { found: false }; }
                // text は地図上の正規化本文(=検索した文字列)。range.toString() は
                // 地図が飛ばした空白ノードや rt を含む DOM 生テキストなので別枠で返し、
                // 端点の UTF-16 単位は Range が正しい DOM 位置を指す証明に使う
                const mapped = textMap.map.slice(utf16Offset, end)
                    .map(item => item.unit).join('');
                return {
                    found: true,
                    page: targetPage, text: mapped, domText: range.toString(),
                    firstUnit: first.node.data.charCodeAt(first.offset),
                    lastUnit: last.node.data.charCodeAt(last.endOffset - 1),
                    rects: rects
                };
            } catch (e) {
                return { found: false };
            }
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
            // cooViewer-oxr.5 / cooViewer-oxr.23: 先頭断片のページを直接
            // 計算し、可視中は pageChanged を出す往復ページ送りを行わない。
            const rect = el.getClientRects()[0] || el.getBoundingClientRect();
            const target = pageForRect(rect);
            if (target < currentPage || target >= currentPage + pagesPerScreen) {
                washi.showPage(target);
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
            resetPaginationMarkers();
            fixedLayout = !!options.fixedLayout;
            keysEnabled = options.keysEnabled !== false;
            configureTapDeferral(options.deferTaps, options.doubleClickDelayMS);
            const columnAxisSupported = supportsColumnAxis();
            const s = ensureStyle('washi-user');
            const userCSS = options.userCSS || '';
            // cooViewer-oxr.60 / cooViewer-oxr.76: 著者 root を測る間は
            // 前回/今回の後置 userCSS を外し、倍率の二重適用を防ぐ。
            s.textContent = '';
            installDefaultFontCSS(options.defaultFontCSS || '');
            if (fixedLayout) {
                ensureStyle('washi-font-scale').textContent = '';
                s.textContent = userCSS;
                excludesGlyphClassification = detectImagePage();
                classifyGlyphImages(excludesGlyphClassification);
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
                // cooViewer-oxr.33: FXL でも文書の実際の書字方向に
                // 従い、縦組みへ reader 字間を適用しない。
                root().classList.toggle('washi-vertical', detectMode() !== 'htb');
                horizontalRTL = false;
                paddedPageCount = 1;
                ready = true;
                return { pageCount: 1, mode: 'fxl', imagePage: false,
                         pagesPerScreen: 1, paddedPageCount: 1,
                         printPageMarkers: collectPrintPageMarkers(true),
                         firstPageOnRight: false,
                         supportsColumnAxis: columnAxisSupported };
            }
            viewportW = Math.max(1, Math.floor(Number(options.width) || 1));
            pageH = Math.max(1, Math.floor(Number(options.height) || 1));
            applyFontScale(options.fontScale);
            // host userCSS は倍率規則より後で、従来どおり最優先。
            s.textContent = userCSS;
            imagePage = detectImagePage();
            excludesGlyphClassification = imagePage;
            classifyGlyphImages(excludesGlyphClassification);
            if (imagePage) {
                // 表紙等は段組せず 1 ページの中央フィット(見開き時も単独表示。
                // Apple Books の表紙表示と同じ)
                pageW = viewportW;
                pagesPerScreen = 1;
                prepareImagePage();
                applyImagePageCSS();
                pageCount = 1;
                paddedPageCount = 1;
                currentPage = 0;
                mode = 'htb';
                root().classList.toggle('washi-vertical', detectMode() !== 'htb');
                horizontalRTL = false;
                ensureStyle('washi-font-scale').textContent = '';
                ready = true;
                return { pageCount: 1, mode: mode, imagePage: true,
                         pagesPerScreen: 1, paddedPageCount: 1,
                         printPageMarkers: collectPrintPageMarkers(true),
                         firstPageOnRight: false,
                         supportsColumnAxis: columnAxisSupported };
            }
            mode = detectMode();
            // cooViewer-oxr.33: 縦組みでは reader の letter-spacing 規則を
            // 無効化する印。repaginate のたび computed writing-mode と同期する。
            root().classList.toggle('washi-vertical', mode !== 'htb');
            horizontalRTL = mode === 'htb'
                && getComputedStyle(root()).direction === 'rtl';
            if (options.spread && viewportW >= 2
                && (mode === 'htb' || columnAxisSupported)) {
                // 見開き: 中央ノド(gutter)を挟んだ半幅 2 ページ
                pagesPerScreen = 2;
                const requestedGutter = Number(options.gutter);
                const nominalGap = Number.isFinite(requestedGutter)
                    ? Math.max(0, Math.floor(requestedGutter)) : 48;
                const usableGap = Math.min(nominalGap, Math.max(0, viewportW - 2));
                pageW = Math.max(1, Math.floor((viewportW - usableGap) / 2));
                // cooViewer-oxr.56: 余った 1px はノドへ渡し、WebKit に
                // column-width を 0.5px 伸長させない。常に 2W+gap=viewport。
                gap = viewportW - 2 * pageW;
            } else {
                pagesPerScreen = 1;
                const requestedGap = Number(options.gap);
                gap = Number.isFinite(requestedGap)
                    ? Math.max(0, Math.floor(requestedGap)) : 0;
                pageW = viewportW;
            }
            applyPaginationCSS();
            const endpointRects = paginationEndpoints();
            recount(endpointRects);
            currentPage = spreadStart(Math.min(currentPage, pageCount - 1));
            scrollToPage(currentPage);
            ready = true;
            return { pageCount: pageCount, mode: mode, imagePage: false,
                     pagesPerScreen: pagesPerScreen,
                     paddedPageCount: paddedPageCount,
                     printPageMarkers: collectPrintPageMarkers(),
                     firstPageOnRight: firstPageOnRight(),
                     supportsColumnAxis: columnAxisSupported };
        };

        /// 配色などページ割りに影響しない CSS の差し替え(再ページ割りなし)
        washi.setUserCSS = function (css) {
            ensureStyle('washi-user').textContent = css || '';
            // cooViewer-oxr.78: theme/反転設定だけの変更も再ページ割りせず、
            // 現在 DOM の分類を更新して即時 CSS の対象へ載せる。
            classifyGlyphImages(excludesGlyphClassification);
            return true;
        };

        // cooViewer-oxr.24: 読み込み後のキーボード処理設定を反映する。
        washi.setKeysEnabled = function (flag) {
            keysEnabled = !!flag;
            return keysEnabled;
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
        let pendingPrimaryTapTimer = 0;
        let pendingPrimaryTap = null;
        function cancelPendingPrimaryTap() {
            if (pendingPrimaryTapTimer) { clearTimeout(pendingPrimaryTapTimer); }
            pendingPrimaryTapTimer = 0;
            pendingPrimaryTap = null;
        }
        function configureTapDeferral(flag, delay) {
            cancelPendingPrimaryTap();
            defersTapsForDoubleClick = flag === true;
            if (!defersTapsForDoubleClick) { return false; }
            const requestedDelay = Number(delay);
            doubleClickDelayMS = Number.isFinite(requestedDelay)
                ? Math.max(250, Math.min(1000, requestedDelay)) : 500;
            return true;
        }
        // cooViewer-oxr.27: 読み込み後の opt-in 切替も再ページ割りなしで反映する。
        washi.setTapDeferral = function (flag, delay) {
            return configureTapDeferral(flag, delay);
        };
        function queuePrimaryTap(event) {
            if (pendingPrimaryTapTimer) {
                // cooViewer-oxr.27: 別の detail=1 が来た時点で前の click は今回の
                // ダブルクリック対ではないため、落とさず先に確定する。
                clearTimeout(pendingPrimaryTapTimer);
                pendingPrimaryTapTimer = 0;
                postTap(pendingPrimaryTap);
            }
            // cooViewer-oxr.27: 二回目の click/dblclick が届く猶予を置き、
            // ダブルクリックの一回目をページ送りとして確定しない。
            pendingPrimaryTap = {
                clientX: event.clientX, clientY: event.clientY,
                button: event.button, shiftKey: event.shiftKey,
                altKey: event.altKey, ctrlKey: event.ctrlKey,
                metaKey: event.metaKey
            };
            pendingPrimaryTapTimer = setTimeout(function () {
                const tap = pendingPrimaryTap;
                pendingPrimaryTapTimer = 0;
                pendingPrimaryTap = null;
                if (tap) { postTap(tap); }
            }, doubleClickDelayMS);
        }
        // click を仕様書 §5.9 の意味論に揃える: 30pt 超のドラッグ・1 秒超の
        // 長押し・テキスト選択の解放は「クリック」にしない(画像本の
        // MouseGestureRecognizer と同じ閾値)。WebKit は選択ドラッグの解放でも
        // press/release の共通祖先で click を発火するため、素通しすると
        // ページがめくれて選択まで失われる
        var pressX = 0, pressY = 0, pressT = 0;
        var selectionAtPress = false, releasedGesture = false;
        function hasSelection() {
            const selection = window.getSelection ? window.getSelection() : null;
            return !!(selection && !selection.isCollapsed);
        }
        document.addEventListener('mousedown', function (event) {
            pressX = event.clientX;
            pressY = event.clientY;
            pressT = Date.now();
            // cooViewer-oxr.27: click 時には選択が解除済みのことがあるため、
            // マウスダウン時点の非折りたたみ選択を保持する。
            selectionAtPress = hasSelection();
            releasedGesture = false;
        }, true);
        document.addEventListener('mouseup', function (event) {
            if (pressT) {
                releasedGesture = selectionAtPress || hasSelection()
                    || Math.max(Math.abs(event.clientX - pressX),
                                Math.abs(event.clientY - pressY)) > 30
                    || Date.now() - pressT > 1000;
            }
            // cooViewer-oxr.27: キーボード・VoiceOver 合成 click へ
            // 過去のポインター状態を持ち越さない。
            pressT = 0;
            selectionAtPress = false;
        }, true);
        function suppressAsGesture(event) {
            let suppress = releasedGesture;
            releasedGesture = false;
            if (!pressT) { return suppress; }
            suppress = suppress || selectionAtPress || hasSelection()
                || Math.max(Math.abs(event.clientX - pressX),
                            Math.abs(event.clientY - pressY)) > 30
                || Date.now() - pressT > 1000;
            return suppress;
        }
        function targetsInteractiveControl(event) {
            // cooViewer-oxr.82: 操作部品の既定動作をページタップへ横取りしない。
            return !!(event.target && event.target.closest
                && event.target.closest(
                    'audio,video,button,input,select,textarea,summary,label,[contenteditable]'));
        }

        // cooViewer-oxr.32: EPUB 名前空間を第一候補にし、名前空間を失った
        // HTML DOM の epub:type も実在本向けの fallback として読む。
        function epubTypeOf(element) {
            if (!element || !element.getAttribute) { return null; }
            return element.getAttributeNS(
                'http://www.idpf.org/2007/ops', 'type')
                || element.getAttribute('epub:type') || null;
        }
        function rawHrefOf(element) {
            if (!element || !element.getAttribute) { return ''; }
            return element.getAttribute('href')
                || element.getAttributeNS(
                    'http://www.w3.org/1999/xlink', 'href')
                || (element.href && element.href.baseVal) || '';
        }
        function nearestBlock(element) {
            let candidate = element;
            while (candidate && candidate !== document.documentElement) {
                const display = getComputedStyle(candidate).display || '';
                if (display === 'none' || display === 'contents'
                    || display.startsWith('inline')) {
                    candidate = candidate.parentElement;
                    continue;
                }
                return candidate;
            }
            return element;
        }
        function containsBacklink(scope, anchorID) {
            if (!scope || !anchorID) { return false; }
            function pointsBack(candidate) {
                const href = rawHrefOf(candidate);
                if (!href.startsWith('#')) { return false; }
                let fragment = href.slice(1);
                try { fragment = decodeURIComponent(fragment); } catch (e) {}
                return fragment === anchorID;
            }
            if ((scope.localName || '').toLowerCase() === 'a'
                && pointsBack(scope)) { return true; }
            return Array.from(scope.querySelectorAll('a[href], a[*|href]'))
                .some(pointsBack);
        }
        function sameDocumentTarget(href) {
            try {
                const destination = new URL(href, document.baseURI);
                const current = new URL(document.location.href);
                const destinationDocument = destination.href.split('#', 1)[0];
                const currentDocument = current.href.split('#', 1)[0];
                if (!destination.hash
                    || destinationDocument !== currentDocument) { return null; }
                let fragment = destination.hash.slice(1);
                try { fragment = decodeURIComponent(fragment); } catch (e) {}
                return document.getElementById(fragment);
            } catch (e) {
                return null;
            }
        }
        function internalLinkMessage(anchor, href) {
            const rect = anchor.getBoundingClientRect();
            const anchorID = anchor.getAttribute('id') || null;
            const message = {
                type: 'link', href: href,
                epubType: epubTypeOf(anchor),
                role: anchor.getAttribute('role') || null,
                anchorId: anchorID,
                anchorRect: { x: rect.x, y: rect.y,
                              w: rect.width, h: rect.height },
                backlink: false,
                targetTag: null,
                targetEpubType: null
            };
            const target = sameDocumentTarget(href);
            if (target) {
                const block = nearestBlock(target);
                message.backlink = containsBacklink(target, anchorID)
                    || (block !== target && containsBacklink(block, anchorID));
                message.targetTag = (target.localName || target.tagName || '')
                    .toLowerCase() || null;
                message.targetEpubType = epubTypeOf(target);
            }
            return message;
        }
        document.addEventListener('click', function (event) {
            const synthesized = event.detail === 0;
            const repeatedClick = !synthesized && event.detail >= 2;
            if (synthesized) {
                // cooViewer-oxr.27: 合成 click は座標をタップとして扱わない。
                pressT = 0;
                selectionAtPress = false;
                releasedGesture = false;
            } else if (defersTapsForDoubleClick && repeatedClick) {
                // cooViewer-oxr.27: 選択生成で gesture 抑止になる二回目でも、
                // 一回目の保留を消す。
                cancelPendingPrimaryTap();
                releasedGesture = false;
            } else if (suppressAsGesture(event)) {
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
                const href = rawHrefOf(anchor);
                if (href) {
                    event.preventDefault();
                    event.stopPropagation();
                    // cooViewer-oxr.27: 二回目も既定遷移は止めるが、同じ
                    // native リンク通知を重複させない。
                    if (!repeatedClick) { post(internalLinkMessage(anchor, href)); }
                    return;
                }
            }
            if (targetsInteractiveControl(event)) { return; }
            // cooViewer-oxr.27: 合成 click は常に除外する。既定モードでは
            // detail=1/2/3... を各 1 タップとして即時送信し、opt-in 時だけ
            // 二回目を落として一回目をシステム間隔まで保留する。
            if (synthesized || (defersTapsForDoubleClick && repeatedClick)) { return; }
            if (defersTapsForDoubleClick) { queuePrimaryTap(event); }
            else { postTap(event); }
        }, true);
        document.addEventListener('dblclick', function () {
            if (defersTapsForDoubleClick) { cancelPendingPrimaryTap(); }
        }, true);
        // 中・サイドボタン(auxclick)。右クリック(button 2)は WebKit の
        // コンテキストメニューに委ねる。サイドボタンの既定動作(履歴移動等)は
        // 止めてホストの割当(戻る/進む相当)へ渡す
        document.addEventListener('auxclick', function (event) {
            if (event.button === 2) { return; }
            if (targetsInteractiveControl(event)) { return; }
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
                // cooViewer-oxr.81: FXL は項目内 1 ページなので native 境界へ戻す。
                fixedLayout ? washi.turnInDoc(false) : washi.showPage(0);
                break;
            case 'End':
                fixedLayout ? washi.turnInDoc(true) : washi.showLastPage();
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
                const expected = Math.round(clampScroll(scrollTargetFor(currentPage)));
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
            let observer = null;
            function install() {
                const head = document.head;
                if (!head) { return false; }
                let el = document.getElementById('washi-base');
                if (!el) {
                    el = document.createElement('style');
                    el.id = 'washi-base';
                    el.textContent = `\(escaped)`;
                }
                if (el.parentNode !== head || el !== head.firstChild) {
                    head.insertBefore(el, head.firstChild);
                }
                if (observer) {
                    observer.disconnect();
                    observer = null;
                }
                document.removeEventListener('DOMContentLoaded', install);
                return true;
            }
            if (!install()) {
                if (document.documentElement) {
                    observer = new MutationObserver(install);
                    observer.observe(document.documentElement, { childList: true });
                }
                document.addEventListener('DOMContentLoaded', install, { once: true });
            }
        })();
        """
    }
}
