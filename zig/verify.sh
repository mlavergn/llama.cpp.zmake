#!/bin/bash
# Diffs the tokens two llama-cli builds generate: greedy sampling, a fixed
# seed, each prompt on each -ngl given. This is CLAUDE.md's "How to verify a
# change" as a script, with its two traps checked rather than remembered:
# every run must exit 0, and every run must have generated text. Two crashed
# runs print nothing, and nothing diffs clean.
#
#   verify.sh <reference llama-cli> <llama-cli under test> <model.gguf> [ngl ...]
#
# ngl defaults to "99 0": Metal (or whatever GPU backend is built) and CPU.
# Outputs are kept in $VERIFY_DIR (default: a fresh temporary directory),
# named by case. Exits 0 only when every case matches.
#
# Three lines differ between builds by design and are stripped before
# comparing: the `build :` banner line (build number, commit, compiler -- a
# CMake reference built inside this checkout even reads this repository's
# git), the throughput line, and the `Loading model...` spinner, which
# writes one frame per tick to stdout, so its length follows load time.
set -uo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: verify.sh <reference llama-cli> <llama-cli under test> <model.gguf> [ngl ...]" >&2
    exit 2
fi

ref="$1" test_bin="$2" model="$3"
shift 3
ngls=("$@")
[[ ${#ngls[@]} -eq 0 ]] && ngls=(99 0)

for f in "$ref" "$test_bin"; do
    [[ -x "$f" ]] || { echo "verify: not an executable: $f" >&2; exit 2; }
done
[[ -f "$model" ]] || { echo "verify: no model at $model" >&2; exit 2; }

prompts=(
    "Explain gravity in one sentence:"
    "Write a haiku about rivers."
    "List three prime numbers and explain why each is prime."
)

dir="${VERIFY_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/llama-verify.XXXXXX")}"
mkdir -p "$dir"

# The output with the by-design differences removed.
strip_run() {
    grep -v -E '^build +: |^\[ Prompt: .* t/s \]$|^Loading model\.\.\.' "$1"
}

# The text generated after the prompt's echo, up to the CLI's sign-off.
generated() {
    awk -v p="> $2" 'found && /^Exiting\.\.\.$/ { exit } found { print } $0 == p { found = 1 }' "$1" \
        | tr -d '[:space:]'
}

fail=0
n=0
for ngl in "${ngls[@]}"; do
    for i in "${!prompts[@]}"; do
        prompt="${prompts[$i]}"
        n=$((n + 1))
        base="$dir/ngl$ngl-p$i"
        args=(-m "$model" -ngl "$ngl" --temp 0 -s 42 -n 48 -st -p "$prompt")

        "$ref" "${args[@]}" < /dev/null > "$base.ref.out" 2> "$base.ref.err"
        ref_exit=$?
        "$test_bin" "${args[@]}" < /dev/null > "$base.test.out" 2> "$base.test.err"
        test_exit=$?

        strip_run "$base.ref.out" > "$base.ref.txt"
        strip_run "$base.test.out" > "$base.test.txt"

        why=""
        [[ $ref_exit -eq 0 ]] || why+=" reference exited $ref_exit;"
        [[ $test_exit -eq 0 ]] || why+=" test exited $test_exit;"
        [[ -n "$(generated "$base.ref.txt" "$prompt")" ]] || why+=" reference generated nothing;"
        [[ -n "$(generated "$base.test.txt" "$prompt")" ]] || why+=" test generated nothing;"
        cmp -s "$base.ref.txt" "$base.test.txt" || why+=" output differs;"

        if [[ -z "$why" ]]; then
            echo "SAME  ngl=$ngl  $prompt"
        else
            fail=$((fail + 1))
            echo "FAIL  ngl=$ngl  $prompt --${why%;}"
            diff "$base.ref.txt" "$base.test.txt" | head -20 | sed 's/^/      /'
            for e in ref test; do
                [[ -s "$base.$e.err" ]] && tail -3 "$base.$e.err" | sed "s/^/      $e stderr: /"
            done
        fi
    done
done

echo "$((n - fail)) of $n matched; outputs in $dir"
[[ $fail -eq 0 ]]
