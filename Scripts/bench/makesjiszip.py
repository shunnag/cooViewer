# cp932(Shift-JIS)エントリ名の zip を作る(UTF-8 フラグなし=レガシー Windows 相当)。
import os
import struct
import sys
import zipfile


UTF8_FLAG = 0x0800
LOCAL_HEADER = b"PK\x03\x04"
CENTRAL_HEADER = b"PK\x01\x02"
END_OF_CENTRAL_DIRECTORY = b"PK\x05\x06"


class ShiftJISZipInfo(zipfile.ZipInfo):
    # zipfile の私的 API に依存するため、将来の Python 変更は下の生バイト検証で検出する。
    def _encodeFilenameFlags(self):
        return self.filename.encode("cp932"), self.flag_bits & ~UTF8_FLAG


class VerificationError(Exception):
    pass


def archive_name(index):
    vol = index // 200 + 1
    page = index % 200 + 1
    return f"第{vol:02d}巻/第{(index//20)%99+1:03d}話 ページ{page:04d} 扉絵つき.jpg"


def checked_slice(data, offset, size, description):
    end = offset + size
    if offset < 0 or end > len(data):
        raise VerificationError(f"{description}が書庫の範囲外です(offset={offset}, size={size})")
    return data[offset:end]


def verify_name(name_bytes, expected, index):
    try:
        decoded = name_bytes.decode("cp932")
    except UnicodeDecodeError as error:
        raise VerificationError(f"エントリ {index + 1} の名前を cp932 で復号できません: {error}") from error
    if decoded != expected:
        raise VerificationError(
            f"エントリ {index + 1} の名前が不一致です: {decoded!r} != {expected!r}"
        )
    try:
        name_bytes.decode("utf-8")
    except UnicodeDecodeError:
        return decoded
    raise VerificationError(f"エントリ {index + 1} の名前が UTF-8 としても妥当です: {decoded!r}")


def verify_archive(path, expected_names):
    with open(path, "rb") as archive:
        data = archive.read()

    # EOCD は最大 65535 バイトのコメントの手前にある。
    eocd_offset = data.rfind(END_OF_CENTRAL_DIRECTORY, max(0, len(data) - 65557))
    if eocd_offset < 0:
        raise VerificationError("中央ディレクトリ終了レコードがありません")
    checked_slice(data, eocd_offset, 22, "中央ディレクトリ終了レコード")
    disk, central_disk, disk_entries, total_entries, central_size, central_offset, comment_length = (
        struct.unpack_from("<4H2IH", data, eocd_offset + 4)
    )
    if disk != 0 or central_disk != 0 or disk_entries != total_entries:
        raise VerificationError("分割 ZIP は検証対象外です")
    if eocd_offset + 22 + comment_length != len(data):
        raise VerificationError("中央ディレクトリ終了レコードの長さが不正です")
    if total_entries != len(expected_names):
        raise VerificationError(f"エントリ数が不一致です: {total_entries} != {len(expected_names)}")
    if central_offset + central_size != eocd_offset:
        raise VerificationError("中央ディレクトリの位置または長さが不正です")

    verified = []
    cursor = central_offset
    for index, expected in enumerate(expected_names):
        header = checked_slice(data, cursor, 46, f"中央ヘッダ {index + 1}")
        if header[:4] != CENTRAL_HEADER:
            raise VerificationError(f"中央ヘッダ {index + 1} のシグネチャが不正です")
        central_flags = struct.unpack_from("<H", header, 8)[0]
        name_length, extra_length, entry_comment_length = struct.unpack_from("<3H", header, 28)
        local_offset = struct.unpack_from("<I", header, 42)[0]
        name_offset = cursor + 46
        name_bytes = checked_slice(data, name_offset, name_length, f"中央ヘッダ {index + 1} の名前")

        local_header = checked_slice(data, local_offset, 30, f"ローカルヘッダ {index + 1}")
        if local_header[:4] != LOCAL_HEADER:
            raise VerificationError(f"ローカルヘッダ {index + 1} のシグネチャが不正です")
        local_flags = struct.unpack_from("<H", local_header, 6)[0]
        local_name_length = struct.unpack_from("<H", local_header, 26)[0]
        local_name = checked_slice(data, local_offset + 30, local_name_length, f"ローカルヘッダ {index + 1} の名前")

        if local_flags & UTF8_FLAG:
            raise VerificationError(
                f"エントリ {index + 1} のローカルヘッダで UTF-8 フラグが ON です(flags=0x{local_flags:04x})"
            )
        if central_flags & UTF8_FLAG:
            raise VerificationError(
                f"エントリ {index + 1} の中央ディレクトリで UTF-8 フラグが ON です(flags=0x{central_flags:04x})"
            )
        if local_name != name_bytes:
            raise VerificationError(f"エントリ {index + 1} のローカル名と中央ディレクトリ名が不一致です")
        decoded = verify_name(name_bytes, expected, index)
        verified.append((local_flags, central_flags, name_bytes, decoded))
        cursor = name_offset + name_length + extra_length + entry_comment_length

    if cursor != central_offset + central_size:
        raise VerificationError("中央ディレクトリの解析終了位置が不一致です")
    return verified


def main():
    src, dst = sys.argv[1], sys.argv[2]
    files = sorted(os.listdir(src))
    expected_names = [archive_name(i) for i in range(len(files))]
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for filename, jp in zip(files, expected_names):
            with open(os.path.join(src, filename), "rb") as source:
                archive.writestr(ShiftJISZipInfo(jp, (2020, 1, 1, 0, 0, 0)), source.read())

    try:
        verified = verify_archive(dst, expected_names)
    except VerificationError as error:
        print(f"検証失敗: {dst}: {error}", file=sys.stderr)
        return 1

    print(
        f"検証OK: {len(verified)} エントリ全てでローカル/中央フラグ bit 11=OFF、"
        "cp932 名一致、UTF-8 として不正"
    )
    for index in sorted({0, len(verified) // 2, len(verified) - 1}):
        local_flags, central_flags, name_bytes, decoded = verified[index]
        print(
            f"  [{index + 1}/{len(verified)}] local=0x{local_flags:04x} central=0x{central_flags:04x} "
            f"bytes={name_bytes.hex()} cp932={decoded!r}"
        )
    print("sjis zip done:", dst)
    return 0


if __name__ == "__main__":
    sys.exit(main())
