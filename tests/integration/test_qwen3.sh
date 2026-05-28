#!/bin/bash
# shellcheck shell=bash disable=SC2154  # ALL_TESTS comes from common.sh

# Qwen3-TTS integration tests — voice cloning via /v1/audio/speech, CUDA-only.
#
# Exercises:
#   - Builtin voices show up in /v1/audio/voices with origin=builtin.
#   - Custom voices dropped into $TALKIES_TEST_CACHE/custom-voices/ at runtime
#     surface as nested-path voice names with origin=custom and shadow
#     builtins on name collision.
#   - Synthesis with a baked-in voice produces well-formed PCM/WAV.
#   - Cross-modality round-trip Qwen3 → ASR → expected words.
#   - 400 on unknown voice and on empty input.
#
# Skips cleanly if qwen3-tts-0.6b isn't in /v1/models so a TALKIES_ENABLED_MODELS
# scope that filters it out doesn't fail the whole suite.

QWEN3_MODEL="qwen3-tts-0.6b"

# Same phrase as kokoro round-trip — short common English words give the most
# stable ASR-side assertion across backends.
QWEN3_TEST_PHRASE="The quick brown fox jumps over the lazy dog."
QWEN3_EXPECTED_WORDS=(quick brown fox jumps lazy dog)

_qwen3_model_available() {
    local models_json
    models_json=$(talkies_get "/v1/models") || return 1
    echo "$models_json" | jq -e --arg m "$QWEN3_MODEL" '.data[] | select(.id==$m)' >/dev/null 2>&1
}

# ── Builtin voices show up tagged origin=builtin ─────────────────────────────

test_qwen3_voices_builtin_listed() {
    if ! _qwen3_model_available; then
        echo "  SKIP: $QWEN3_MODEL not in /v1/models"
        return 0
    fi
    local out builtin_count
    out=$(talkies_get "/v1/audio/voices") || { echo "  FAIL: /v1/audio/voices unreachable"; return 1; }
    builtin_count=$(echo "$out" | jq --arg m "$QWEN3_MODEL" \
        '[.voices[] | select(.model==$m) | select(.origin=="builtin")] | length' 2>/dev/null || echo 0)
    if [ "$builtin_count" -lt 1 ]; then
        echo "  FAIL: expected at least 1 builtin voice for $QWEN3_MODEL, got $builtin_count"
        echo "  raw: $(echo "$out" | jq -c --arg m "$QWEN3_MODEL" '[.voices[] | select(.model==$m)]')"
        return 1
    fi
    echo "  ok: $builtin_count builtin voice(s)"
    echo "OK: qwen3_voices_builtin_listed"
}

# ── Custom voices dropped at runtime show up as origin=custom with nested name

test_qwen3_voices_custom_discovery() {
    if ! _qwen3_model_available; then
        echo "  SKIP: $QWEN3_MODEL not in /v1/models"
        return 0
    fi
    # Repo root — run.sh cd'd here before sourcing this file.
    local src_wav="voices/qwen3/alloy.wav"
    if [ ! -f "$src_wav" ]; then
        echo "  SKIP: $src_wav missing — repo not laid out as expected"
        return 0
    fi
    local custom_dir="$TALKIES_TEST_CACHE/custom-voices/foo/bar"
    mkdir -p "$custom_dir"
    cp "$src_wav" "$custom_dir/test_clone.wav"
    # shellcheck disable=SC2064
    trap "rm -f '$custom_dir/test_clone.wav'" RETURN

    local out custom_entry
    out=$(talkies_get "/v1/audio/voices") || { echo "  FAIL: /v1/audio/voices unreachable"; return 1; }
    custom_entry=$(echo "$out" | jq -c --arg m "$QWEN3_MODEL" \
        '.voices[] | select(.model==$m) | select(.voice=="foo/bar/test_clone")' 2>/dev/null)
    if [ -z "$custom_entry" ]; then
        echo "  FAIL: nested custom voice foo/bar/test_clone not in /v1/audio/voices"
        echo "  qwen3 voices: $(echo "$out" | jq -c --arg m "$QWEN3_MODEL" '[.voices[] | select(.model==$m) | .voice]')"
        return 1
    fi
    local origin
    origin=$(echo "$custom_entry" | jq -r '.origin')
    if [ "$origin" != "custom" ]; then
        echo "  FAIL: expected origin=custom for foo/bar/test_clone, got '$origin'"
        return 1
    fi
    echo "  ok: foo/bar/test_clone origin=custom"
    echo "OK: qwen3_voices_custom_discovery"
}

# ── Custom voice with builtin name shadows the builtin ──────────────────────

test_qwen3_voices_custom_shadows_builtin() {
    if ! _qwen3_model_available; then
        echo "  SKIP: $QWEN3_MODEL not in /v1/models"
        return 0
    fi
    local src_wav="voices/qwen3/alloy.wav"
    if [ ! -f "$src_wav" ]; then
        echo "  SKIP: $src_wav missing"
        return 0
    fi
    local custom_dir="$TALKIES_TEST_CACHE/custom-voices"
    mkdir -p "$custom_dir"
    cp "$src_wav" "$custom_dir/alloy.wav"
    # shellcheck disable=SC2064
    trap "rm -f '$custom_dir/alloy.wav'" RETURN

    local out alloy_origin
    out=$(talkies_get "/v1/audio/voices") || { echo "  FAIL: /v1/audio/voices unreachable"; return 1; }
    alloy_origin=$(echo "$out" | jq -r --arg m "$QWEN3_MODEL" \
        '.voices[] | select(.model==$m) | select(.voice=="alloy") | .origin' 2>/dev/null)
    if [ "$alloy_origin" != "custom" ]; then
        echo "  FAIL: expected alloy.origin=custom after shadowing, got '$alloy_origin'"
        return 1
    fi
    echo "  ok: builtin alloy shadowed by custom override"
    echo "OK: qwen3_voices_custom_shadows_builtin"
}

# ── Synthesize with builtin voice → well-formed wav ─────────────────────────

test_qwen3_speech_builtin_voice() {
    if ! _qwen3_model_available; then
        echo "  SKIP: $QWEN3_MODEL not in /v1/models"
        return 0
    fi
    local outfile size head4
    outfile=$(mktemp -t qwen3_speech.XXXXXX) || return 2
    # shellcheck disable=SC2064
    trap "rm -f '$outfile'" RETURN
    if ! talkies_speech "$QWEN3_MODEL" "alloy" "Hello world." "wav" "$outfile"; then
        echo "  FAIL: qwen3 alloy synthesis"
        return 1
    fi
    size=$(stat -c %s "$outfile" 2>/dev/null || stat -f %z "$outfile" 2>/dev/null || echo 0)
    if [ "$size" -lt 4096 ]; then
        echo "  FAIL: wav suspiciously small ($size bytes)"
        return 1
    fi
    head4=$(head -c 4 "$outfile" | od -An -c | tr -d ' \n')
    if [ "$head4" != "RIFF" ]; then
        echo "  FAIL: wav missing RIFF header (got '$head4')"
        return 1
    fi
    echo "  ok: alloy wav size=${size}B"
    echo "OK: qwen3_speech_builtin_voice"
}

# ── Cross-modality round-trip: Qwen3 → ASR → expected words present ────────

test_qwen3_speech_round_trip_through_asr() {
    if ! _qwen3_model_available; then
        echo "  SKIP: $QWEN3_MODEL not in /v1/models"
        return 0
    fi
    local asr_model
    asr_model=$(talkies_pick_fast_asr_model) || {
        echo "  SKIP: no fast ASR model available on server"
        return 0
    }
    echo "  using asr_model=$asr_model"

    local tmp wavfile
    tmp=$(mktemp -d -t qwen3_roundtrip.XXXXXX) || return 2
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    wavfile="${tmp}/spoken.wav"

    # Fresh slate so the test exercises cold-load + sibling eviction (qwen3 is
    # CUDA-graph-captured on first run, so first synth is the heavy path).
    talkies_method POST "/unload" >/dev/null 2>&1 || true

    if ! talkies_speech "$QWEN3_MODEL" "alloy" "$QWEN3_TEST_PHRASE" "wav" "$wavfile"; then
        echo "  FAIL: qwen3 synthesis"
        return 1
    fi
    local size
    size=$(stat -c %s "$wavfile" 2>/dev/null || stat -f %z "$wavfile" 2>/dev/null || echo 0)
    if [ "$size" -lt 4096 ]; then
        echo "  FAIL: synthesized wav too small ($size bytes)"
        return 1
    fi
    echo "  qwen3 produced wav ($size bytes)"

    local out text normalized
    out=$(talkies_transcribe "$asr_model" "$wavfile" "json") || {
        echo "  FAIL: ASR round-trip via $asr_model"
        return 1
    }
    text=$(echo "$out" | jq -r '.text' 2>/dev/null || echo "")
    if [ -z "$text" ] || [ "$text" = "null" ]; then
        echo "  FAIL: ASR returned empty text"
        return 1
    fi
    normalized=$(echo "$text" | talkies_normalize_text)
    echo "  transcribed: \"$normalized\""

    local missing=() word
    for word in "${QWEN3_EXPECTED_WORDS[@]}"; do
        if [[ " $normalized " != *" $word "* ]]; then
            missing+=("$word")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "  FAIL: round-trip transcript missing words: ${missing[*]}"
        echo "  spoken phrase: \"$QWEN3_TEST_PHRASE\""
        echo "  raw asr text:  \"$text\""
        return 1
    fi
    echo "  ok: all expected words present (${QWEN3_EXPECTED_WORDS[*]})"
    echo "OK: qwen3_speech_round_trip_through_asr"
}

# ── Error path: unknown voice → 400 ──────────────────────────────────────────

test_qwen3_speech_unknown_voice_400() {
    if ! _qwen3_model_available; then
        echo "  SKIP: $QWEN3_MODEL not in /v1/models"
        return 0
    fi
    local body code
    body=$(jq -n --arg m "$QWEN3_MODEL" \
        '{model:$m, voice:"does/not/exist", input:"hi", response_format:"wav"}')
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
        -H "Content-Type: application/json" -d "$body" \
        "${TALKIES_BASE_URL}/v1/audio/speech")
    assert_eq "$code" "400" "qwen3 unknown voice → 400" || return 1
    echo "OK: qwen3_speech_unknown_voice_400"
}

# ── Error path: empty input → 400 ────────────────────────────────────────────

test_qwen3_speech_empty_input_400() {
    if ! _qwen3_model_available; then
        echo "  SKIP: $QWEN3_MODEL not in /v1/models"
        return 0
    fi
    local body code
    body=$(jq -n --arg m "$QWEN3_MODEL" \
        '{model:$m, voice:"alloy", input:"   ", response_format:"wav"}')
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
        -H "Content-Type: application/json" -d "$body" \
        "${TALKIES_BASE_URL}/v1/audio/speech")
    assert_eq "$code" "400" "qwen3 empty input → 400" || return 1
    echo "OK: qwen3_speech_empty_input_400"
}

ALL_TESTS+=(
    test_qwen3_voices_builtin_listed
    test_qwen3_voices_custom_discovery
    test_qwen3_voices_custom_shadows_builtin
    test_qwen3_speech_builtin_voice
    test_qwen3_speech_round_trip_through_asr
    test_qwen3_speech_unknown_voice_400
    test_qwen3_speech_empty_input_400
)
