#!/bin/zsh
set -euo pipefail

# 実ファイル・ユーザー設定を使わず、現行描画ソースを合成画像で検証する。
# fd-* 0 と invalid-* は、修正前に落ちた境界を確認する独立プロセス試験。
diagnostic_dir="${0:A:h}"
repository_dir="${diagnostic_dir:h:h}"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/cooviewer-resource-probe.XXXXXX")"
mkdir -p "$probe_dir/home"
xcrun swiftc -O -module-cache-path "$probe_dir/modules" \
    "$repository_dir/CooViewer/Core/FileDescriptorHeadroom.swift" \
    "$repository_dir/CooViewer/Core/Rendering/BitmapRendering.swift" \
    "$repository_dir/CooViewer/Core/Rendering/LanczosDownscaler.swift" \
    "$repository_dir/CooViewer/Core/Rendering/NoiseReduction.swift" \
    "$repository_dir/CooViewer/Core/Rendering/MetalFXUpscaler.swift" \
    "$diagnostic_dir/CoreImageResourceProbe.swift" -o "$probe_dir/probe"
exec env CFFIXED_USER_HOME="$probe_dir/home" "$probe_dir/probe" "$@"
