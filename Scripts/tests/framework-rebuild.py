#!/usr/bin/env python3
"""framework ラッパーの更新判定を、実コンパイラや兄弟 checkout を使わず検査する。"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(0o755)


def exercise(scripts, name, change):
    with tempfile.TemporaryDirectory(prefix="cooviewer framework test ") as directory:
        root = Path(directory)
        project = root / "Viewer"
        source = root / name
        inputs = source / "Sources"
        write(source / "Package.swift", "// package fixture\n")
        write(inputs / "Retained.swift", "// first\n")
        write(inputs / "Removed.swift", "// removable\n")
        wrapper = scripts / f"build-{name.lower()}-framework.sh"
        script = wrapper.read_text()
        if name == "KaitoKit":
            # ツールチェーンの検出だけを定数に置換。更新判定と配置処理は実スクリプト。
            script, count = re.subn(
                r'SWIFT_VERSION="\$\(env -i .*?\)"',
                'SWIFT_VERSION="fixture"', script, count=1, flags=re.S)
            assert count == 1
            write(source / "Scripts/build-framework.sh", '''#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
echo build >> "$ROOT/build.log"
FW="$ROOT/Frameworks/KaitoKit.framework/Versions/A"
mkdir -p "$FW/Modules/KaitoKit.swiftmodule" "$FW/Modules/KaitoKitCompat.swiftmodule"
echo fixture > "$FW/KaitoKit"
''', executable=True)
        else:
            # SwiftPM の出力だけを小さな fixture に置換し、バンドル組立も実行する。
            script, count = re.subn(r'run_swift\(\) \{.*?\n\}', '''run_swift() {
    if [[ "$1" == --version ]]; then
        echo fixture
        return
    fi
    echo build >> "$SOURCE_DIR/build.log"
    mkdir -p "$BIN/Washi.swiftmodule" "$BIN/WashiCore.swiftmodule"
    echo fixture > "$BIN/libWashiDynamic.dylib"
    for name in Washi WashiCore; do
        echo fixture > "$BIN/$name.swiftmodule/arm64-apple-macos.swiftmodule"
        echo fixture > "$BIN/$name.swiftmodule/arm64-apple-macos.swiftinterface"
    done
}''', script, count=1, flags=re.S)
            assert count == 1

        destination = project / "Scripts" / wrapper.name
        write(destination, script)
        fingerprint = scripts / "framework-source-fingerprint.sh"
        if fingerprint.exists():
            write(destination.parent / fingerprint.name, fingerprint.read_text(), executable=True)
        # ダミーバイナリの署名/ロードコマンド編集は行わない。
        fake_tools = root / "tools"
        for command in ["codesign", "install_name_tool"]:
            write(fake_tools / command, "#!/bin/sh\nexit 0\n", executable=True)
        environment = dict(os.environ, PATH=f"{fake_tools}:/usr/bin:/bin:/usr/sbin:/sbin")

        def build():
            run = subprocess.run(["/bin/zsh", str(destination)], env=environment,
                                 capture_output=True, text=True)
            assert run.returncode == 0, run.stdout + run.stderr
            return len((source / "build.log").read_text().splitlines())

        assert build() == 1
        assert build() == 1, "変更なしで再ビルドされた"
        retained = inputs / "Retained.swift"
        original_time = retained.stat().st_mtime_ns
        if change == "delete":
            (inputs / "Removed.swift").unlink()
        elif change == "restore_timestamp":
            retained.write_text("// changed with preserved timestamp\n")
            os.utime(retained, ns=(original_time, original_time))
        elif change == "add_old_file":
            added = inputs / "Added.swift"
            added.write_text("// restored old file\n")
            os.utime(added, ns=(original_time, original_time))
        else:
            raise AssertionError(change)
        builds = build()
        return {"framework": name, "change": change, "builds": builds,
                "passed": builds == 2}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scripts-dir", type=Path, default=Path(__file__).resolve().parents[1])
    arguments = parser.parse_args()
    results = [exercise(arguments.scripts_dir, name, change)
               for name in ["Washi", "KaitoKit"]
               for change in ["delete", "restore_timestamp", "add_old_file"]]
    print(json.dumps(results, indent=2))
    raise SystemExit(0 if all(row["passed"] for row in results) else 1)
