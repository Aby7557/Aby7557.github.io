#!/bin/bash
# Index debs/ into an APT source served by GitHub Pages.
# Runs in GitHub Actions on every push to main, and by hand on a machine
# that has dpkg-dev (dpkg-scanpackages), gzip, bzip2, xz and python3.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/_site}"
SOURCE_URL="https://aby7557.github.io"
ORIGIN="Abyss"
LABEL="Abyss"
CODENAME="abyss"

rm -rf "${OUT:?}"
mkdir -p "$OUT/debs"

# Pages serves these as they are.
touch "$OUT/.nojekyll"
for f in index.html CydiaIcon.png sileo-featured.json; do
    [ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$OUT/$f"
done
if [ -d "$ROOT/depictions" ]; then
    cp -R "$ROOT/depictions" "$OUT/depictions"
fi

# Every package, flat, under debs/.
shopt -s nullglob
count=0
for deb in "$ROOT"/debs/*.deb; do
    cp -p "$deb" "$OUT/debs/"
    count=$((count + 1))
done
echo "Packages copied: $count"

# Index every debs/*.deb from its control file, with the checksums and
# size of the file as it is served. Paths in Filename are relative to
# the source root; the Packages file sits at it.
python3 - "$OUT" <<'PYIDX'
import hashlib
import io
import shutil
import os
import subprocess
import sys
import tarfile

def zstd_available():
    return shutil.which("zstd") is not None


def _zstd_huffman(payload, pos):
    """Decode a Huffman block of pure literals (no sequences, no repeats)."""
    header = payload[pos]
    pos += 1
    if header >= 128:
        count = header - 127
        weights = [((payload[pos + i // 2] >> (4 * (i % 2))) & 0xF)
                   for i in range(count)]
        pos += (count + 1) // 2
    else:
        size = header
        data = payload[pos:pos + size]
        pos += size
        bitrev = int.from_bytes(data, "little") if data else 0
        total = 1 << size
        bits = [(bitrev >> (total - 1 - i)) & 1 for i in range(total)]
        weights = []
        i = 0
        while i < total:
            value, run = 0, 0
            while bits[i] == 0:
                run += 1
                i += 1
            i += 1
            for _ in range(run):
                value = (value << 1) | bits[i]
                i += 1
            weights.append(value)
    weights = weights[:max(0, len(weights) - 1)]  # the final weight is implicit
    if not weights or all(w == 0 for w in weights):
        return None, pos
    last = weights[-1]
    weights.append((last - 1) if last > 0 else 0)
    max_bits = max(weights)
    symbols = [s for s in range(len(weights)) if weights[s]]
    code = {s: (weights[s], 0) for s in symbols}
    tail = payload[pos:]
    bitrev = int.from_bytes(tail, "little") if tail else 0
    total_bits = len(tail) * 8
    bits_read = 0
    sizes = [0] * (max_bits + 2)
    for s in symbols:
        sizes[code[s][0]] += 1
    cumulative = [0] * (max_bits + 1)
    for i in range(2, max_bits + 1):
        cumulative[i] = cumulative[i - 1] + sizes[i - 1]
    table = [0] * (1 << max_bits)
    for s in symbols:
        w, s_rank = code[s]
        length = max_bits + 1 - w
        rank_i = cumulative[w]
        cumulative[w] += 1
        rev = int(format(rank_i, "0%db" % length)[::-1], 2) if length else 0
        order = list(range(length - 1, -1, -1))
        step = 1 << (max_bits - length)
        base = rev << (max_bits - length)
        start = base & ~(step - 1) if step > 1 else base
        for i in range(step):
            if base + i >= len(table):
                return None, pos
            table[base + i] = (length << 8) | s
    out = bytearray()
    while total_bits - bits_read >= max_bits:
        v = (bitrev >> bits_read) & ((1 << max_bits) - 1)
        entry = table[v]
        length = entry >> 8
        if not length:
            return None, pos
        out.append(entry & 0xFF)
        bits_read += length
    return bytes(out), pos


def zstd_blocks(data):
    """Best-effort: decompress a small zstd frame made of raw, RLE and
    Huffman-literal blocks, which is all a control.tar.zst needs."""
    out = bytearray()
    pos = 0
    while pos + 4 <= len(data):
        magic = int.from_bytes(data[pos:pos + 4], "little")
        if magic & 0xFFFFFFF0 == 0x184D2A50:
            pos += 8 + int.from_bytes(data[pos + 4:pos + 8], "little")
            continue
        if magic != 0xFD2FB528:
            return None
        pos += 4
        if pos >= len(data):
            return None
        descriptor = data[pos]
        pos += 1
        single = (descriptor >> 5) & 1
        checksum = (descriptor >> 2) & 1
        dict_flag = descriptor & 3
        content_size_flag = descriptor >> 6
        if not single:
            pos += 1
        pos += [0, 1, 2, 4][dict_flag]
        pos += [single, 2, 4, 8][content_size_flag]
        while True:
            if pos + 3 > len(data):
                return None
            header = int.from_bytes(data[pos:pos + 3], "little")
            last = header & 1
            block_type = (header >> 1) & 3
            size = header >> 3
            pos += 3
            if block_type == 0:
                out += data[pos:pos + size]
                pos += size
            elif block_type == 1:
                out += data[pos:pos + 1] * size
                pos += 1
            elif block_type == 2:
                literals, _ = _zstd_huffman(data, pos)
                if literals is None or len(literals) != size:
                    return None
                out += literals
                pos += size
            else:
                return None
            if last:
                break
        if checksum:
            pos += 4
    return bytes(out) if out else None


KNOWN_FIELDS = [
    "Package", "Name", "Version", "Architecture", "Maintainer", "Author",
    "Installed-Size", "Size", "Filename", "MD5sum", "SHA1", "SHA256", "SHA512",
    "Pre-Depends", "Depends", "Recommends", "Suggests", "Conflicts", "Breaks",
    "Replaces", "Provides", "Section", "Priority", "Essential", "Homepage",
    "Description", "Icon", "Depiction", "Sileodepiction", "Tag", "Dev",
    "Sponsor", "Supported", "Source",
]

out = sys.argv[1]
debs_dir = os.path.join(out, "debs")
blocks = []

for name in sorted(os.listdir(debs_dir)):
    if not name.endswith(".deb"):
        continue
    path = os.path.join(debs_dir, name)
    with open(path, "rb") as f:
        data = f.read()

    control = None
    if data[:8] == b"!<arch>\n":
        # Debian archive: ar members, control.tar.* after debian-binary.
        offset = 8
        while offset + 60 <= len(data):
            header = data[offset:offset + 60]
            member = header[:16].decode("ascii", "replace").strip().rstrip("/")
            size = int(header[48:58].decode("ascii").strip())
            body = data[offset + 60:offset + 60 + size]
            if member.startswith("control.tar"):
                control = (member, body)
                break
            offset += 60 + size + (size % 2)
    if control is None:
        print("no control archive in " + name, file=sys.stderr)
        continue

    member, body = control
    text = None
    if member.endswith(".zst") and not zstd_available():
        # zstd is not in Python's tarfile, and zstd may be missing here;
        # the control members are tiny, so scan the frame for "Package:".
        inflated = zstd_blocks(body)
        if inflated is not None:
            text = inflated.decode("utf-8", "replace")
    if text is None:
        if member.endswith(".zst"):
            body = subprocess.run(["zstd", "-dc"], input=body,
                                  check=True, capture_output=True).stdout
        with tarfile.open(fileobj=io.BytesIO(body), mode="r:*") as tar:
            for info in tar.getmembers():
                if info.name.lstrip("./") == "control":
                    text = tar.extractfile(info).read().decode("utf-8", "replace")
                    break
    if not text:
        print("no control file in " + name, file=sys.stderr)
        continue

    # control.tar also holds the maintainer scripts; keep the header only.
    if "\nPackage:" in text or text.startswith("Package:"):
        parts = text.split("\n\n")
        text = parts[0] if parts[0].lstrip("\n").startswith("Package:") else next(
            (part for part in parts if part.lstrip("\n").startswith("Package:")), parts[0])

    fields = {}
    current = None
    for line in text.splitlines():
        if line.startswith(" ") and current:
            fields[current] += "\n" + line
        elif ":" in line:
            current, value = line.split(":", 1)
            current = current.strip()
            # Clients match field names exactly, and a field already set wins.
            for known in KNOWN_FIELDS:
                if known.lower() == current.lower():
                    current = known
                    break
            fields.setdefault(current, value.strip())

    fields["Filename"] = "debs/" + name
    fields["Size"] = str(len(data))
    fields["MD5sum"] = hashlib.md5(data).hexdigest()
    fields["SHA1"] = hashlib.sha1(data).hexdigest()
    fields["SHA256"] = hashlib.sha256(data).hexdigest()

    # Link optional depiction files without modifying or repacking the deb.
    package_id = fields.get("Package")
    depiction_dir = os.path.join(out, "depictions", package_id) if package_id else ""
    if depiction_dir and os.path.isfile(os.path.join(depiction_dir, "index.html")):
        fields["Depiction"] = f"https://aby7557.github.io/depictions/{package_id}/"
    if depiction_dir and os.path.isfile(os.path.join(depiction_dir, "depiction.json")):
        fields["Sileodepiction"] = f"https://aby7557.github.io/depictions/{package_id}/depiction.json"
    if depiction_dir and os.path.isfile(os.path.join(depiction_dir, "icon.png")):
        fields["Icon"] = f"https://aby7557.github.io/depictions/{package_id}/icon.png"

    first = ["Package", "Version", "Architecture", "Maintainer", "Installed-Size",
             "Pre-Depends", "Depends", "Recommends", "Suggests", "Conflicts",
             "Breaks", "Replaces", "Provides", "Filename", "Size", "MD5sum",
             "SHA1", "SHA256", "SHA512", "Section", "Priority", "Essential",
             "Homepage", "Icon", "Depiction", "Sileodepiction", "Tag", "Author",
             "Dev", "Sponsor", "Description"]
    keys = [k for k in first if k in fields] + [k for k in fields if k not in first]
    blocks.append("\n".join(k + ": " + fields[k] for k in keys))

with open(os.path.join(out, "Packages"), "w", encoding="utf-8") as f:
    f.write("\n\n".join(blocks) + "\n")
print("Indexed packages:", len(blocks))
PYIDX

# Compress and list only what debs/ holds, in the output root: after cd,
# a bare Packages names the served index, and an index.html in the working
# directory would make "> Packages" a directory instead of a file.
cd "$OUT"
OUT="$(pwd)"
gzip -9 -n -c Packages > Packages.gz
xz -9 -c Packages > Packages.xz
if command -v bzip2 >/dev/null 2>&1; then
    bzip2 -9 -c Packages > Packages.bz2
fi

python3 - "$OUT" "$ORIGIN" "$LABEL" "$CODENAME" "$SOURCE_URL" <<'PY'
import hashlib
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

root, origin, label, codename, source_url = sys.argv[1:6]
root = Path(root).resolve()

architectures = set()
for block in (root / "Packages").read_text(encoding="utf-8", errors="replace").split("\n\n"):
    for line in block.splitlines():
        if line.startswith("Architecture:"):
            architectures.add(line.split(":", 1)[1].strip())
for arch in ("iphoneos-arm", "iphoneos-arm64", "iphoneos-arm64e"):
    architectures.add(arch)

release = [
    f"Origin: {origin}",
    f"Label: {label}",
    f"Suite: stable",
    f"Codename: {codename}",
    "Version: 1.0",
    "Architectures: " + " ".join(sorted(architectures)),
    "Components: main",
    "Description: Abyss jailbreak repository",
    f"Date: {format_datetime(datetime.now(timezone.utc))}",
    f"Support: {source_url}",
]

for heading, algorithm in (
    ("MD5Sum", "md5"),
    ("SHA1", "sha1"),
    ("SHA256", "sha256"),
    ("SHA512", "sha512"),
):
    lines = [heading + ":"]
    for name in ("Packages", "Packages.gz", "Packages.bz2", "Packages.xz"):
        if not (root / name).exists():
            continue
        data = (root / name).read_bytes()
        digest = hashlib.new(algorithm, data).hexdigest()
        lines.append(f" {digest} {len(data):>16} {name}")
    release.extend(lines)

(root / "Release").write_text("\n".join(release) + "\n", encoding="utf-8")
print("Release written for", " ".join(sorted(architectures)))
PY
