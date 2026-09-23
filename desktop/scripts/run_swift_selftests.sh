#!/usr/bin/env bash
# run_swift_selftests.sh — compile package sources (DEBUG) + an @main entry
# that invokes every discovered top-level harness `runAll()`; fail on any.
#
# House pattern: same probe approach as verify_phase1.sh. No SPM test target.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../SwiftNetMax/Sources"

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/netmax_swift_selftest.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

copied=()
while IFS= read -r src; do
  [[ -z "$src" ]] && continue
  if grep -qE '^[[:space:]]*@main' "$src"; then
    continue
  fi
  f="$(basename "$src")"
  cp "$src" "$probe_dir/$f"
  copied+=("$probe_dir/$f")
done < <(find "$SRC_DIR" -name '*.swift' -type f | sort)

if [[ ${#copied[@]} -eq 0 ]]; then
  echo "no compilable .swift under $SRC_DIR" >&2
  exit 9
fi

# Entry: @main + @MainActor so MainActor-isolated harnesses compile.
python3 - "$SRC_DIR" > "$probe_dir/Entry.swift" <<'PY'
import pathlib, re, sys

src = pathlib.Path(sys.argv[1])
harnesses = []
for path in sorted(src.rglob("*.swift")):
    if path.name == "App.swift":
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    for m in re.finditer(r"(?m)^enum\s+(\w+)\s*\{", text):
        name = m.group(1)
        if not re.search(r"(Tests|SelfCheck|Probe)$", name):
            continue
        window = text[m.end(): m.end() + 8000]
        if "static func runAll" not in window:
            continue
        harnesses.append(name)

seen, ordered = set(), []
for h in harnesses:
    if h not in seen:
        seen.add(h)
        ordered.append(h)

print("import Foundation")
print("")
print("@main")
print("struct SwiftSelfTests {")
print("    @MainActor")
print("    static func main() {")
print("        var totalFailures = 0")
print("        var ranCount = 0")
for h in ordered:
    print(f'        let n_{h} = {h}.runAll()')
    print(f'        ranCount += 1')
    print(f'        totalFailures += n_{h}')
    print(f'        if n_{h} == 0 {{ print("PASS {h}") }} else {{ print("FAIL {h}: \\(n_{h}) failure(s)") }}')
if not ordered:
    print('        print("ERROR: no harnesses discovered")')
    print("        exit(2)")
print("        if totalFailures > 0 {")
print('            print("swift selftests: \\(totalFailures) failure(s) across \\(ranCount) harness(es))")')
print("            exit(1)")
print("        }")
print('        print("swift selftests: all green (\\(ranCount) harness(es))")')
print("        exit(0)")
print("    }")
print("}")
PY

echo "Discovered harnesses:"
grep 'let n_' "$probe_dir/Entry.swift" | sed 's/^ */  /' | head -40

echo "Compiling ${#copied[@]} sources + Entry (-DDEBUG -parse-as-library)..."
if ! ( cd "$probe_dir" && swiftc -DDEBUG -parse-as-library -suppress-warnings \
       "${copied[@]}" Entry.swift -o selftest_bin ) 2> "$probe_dir/main.err"; then
  sed 's/^/    /' "$probe_dir/main.err" | head -60 >&2
  exit 8
fi

( cd "$probe_dir" && ./selftest_bin )
