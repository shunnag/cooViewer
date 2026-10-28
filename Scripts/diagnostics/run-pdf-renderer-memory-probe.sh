#!/bin/zsh
set -euo pipefail

# 同じ 40 枚を新規プロセスで読み、生成時のメモリを測定へ混ぜない(設計書 §7.6)。
diagnostic_dir="${0:A:h}"
repository_dir="${diagnostic_dir:h:h}"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/cv-pdf-memory.XXXXXX")"
print -u2 "probe artifacts: $probe_dir"
baseline_ref="${PDF_BASELINE_REF:-HEAD}"
git --no-optional-locks -C "$repository_dir" show \
    "${baseline_ref}:CooViewer/Core/Source/PDFSource.swift" > "$probe_dir/PDFSource-before.swift"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O \
    -module-cache-path "$probe_dir/modules" \
    "$probe_dir/PDFSource-before.swift" \
    "$repository_dir/CooViewer/Core/FileDescriptorHeadroom.swift" \
    "$diagnostic_dir/PDFSourceProbeSupport.swift" \
    "$diagnostic_dir/PDFRendererMemoryProbe.swift" -o "$probe_dir/before"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -D PDF_RECYCLE \
    -module-cache-path "$probe_dir/modules" \
    "$repository_dir/CooViewer/Core/Source/PDFSource.swift" \
    "$repository_dir/CooViewer/Core/Source/PDFPageRenderer.swift" \
    "$repository_dir/CooViewer/Core/FileDescriptorHeadroom.swift" \
    "$diagnostic_dir/PDFSourceProbeSupport.swift" \
    "$diagnostic_dir/PDFRendererMemoryProbe.swift" -o "$probe_dir/after"
if (( $# > 0 )); then
    pdf_path="$1"
else
    pdf_path="$probe_dir/pages.pdf"
    "$probe_dir/after" generate "$pdf_path"
fi
"$probe_dir/before" before "$pdf_path" | tee "$probe_dir/before.csv"
"$probe_dir/after" after "$pdf_path" | tee "$probe_dir/after.csv"
