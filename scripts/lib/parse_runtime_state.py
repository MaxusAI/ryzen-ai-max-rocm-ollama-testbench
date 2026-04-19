#!/usr/bin/env python3
"""Parse Ollama runner / llama.cpp log lines from stdin into a single
JSON object on stdout describing the runtime state of the most recently
loaded model.

Used by scripts/lib/snapshot.sh's snapshot_ollama_ru ntime_state_json.
Lives as a standalone file because the regexes are dense and the
fallback chain for flash-attn detection is easier to maintain in
proper Python with comments than inside a bash heredoc.

The caller is expected to pre-grep the log for these markers before
piping in (the heavy lifting is keeping the journal slice small):

  - "starting runner ... cmd=\"... --model PATH ... --port N\""
  - "llama_context: flash_attn    = auto|on|off"        (requested)
  - "Flash Attention was auto, set to enabled|disabled" (resolved)
  - "msg=\"enabling flash attention\""                  (Ollama daemon explicit FA)
  - "msg=load request=\"{...FlashAttention:Enabled..."  (canonical FA decision)
  - "llama_kv_cache: size = X MiB (Y cells, Z layers, A/B seqs), K (T): C MiB, V (T): D MiB"
  - "llama_context:      ROCm0 compute buffer size = X MiB"
  - "llama_context:  ROCm_Host compute buffer size = X MiB"
  - "msg=\"inference compute\" ... library=L compute=ARCH ..."

For every marker we use the LAST match (most recent model load wins),
so multiple loads in the same Ollama InvocationID don't confuse the
output.

Output: single-line JSON on stdout, or "null" if no useful field could
be extracted. Always exits 0; callers guard on the literal "null".
"""

import json
import re
import sys


def main() -> int:
    lines = [l.strip() for l in sys.stdin if l.strip()]

    def last(pattern: str):
        rx = re.compile(pattern)
        for l in reversed(lines):
            m = rx.search(l)
            if m:
                return m
        return None

    out: dict = {}

    # library / compute (daemon-level "inference compute" line).
    m = last(r"library=(\S+)\s+compute=(\S+)")
    if m:
        out["library"] = m.group(1)
        out["compute"] = m.group(2)

    # Most recent model load: extract path/digest from the runner cmd line.
    m = last(r"--model\s+(\S+)")
    if m:
        p = m.group(1)
        out["model_path"] = p
        # Short form: "sha256-abcd..." -> "sha256-abcd1234"
        short = p.rsplit("/", 1)[-1]
        if short.startswith("sha256-"):
            short = short[:14]
        out["model_short"] = short

    # Flash-attn: requested vs resolved. There are THREE log shapes we
    # care about, in priority order for the resolved value:
    #  1. Auto path (most common): "Flash Attention was auto, set to enabled"
    #  2. Explicit-on path:        "msg=\"enabling flash attention\"" (Ollama daemon)
    #  3. Load-request canonical:  "FlashAttention:Enabled" / "Disabled"
    # The 2nd and 3rd shapes appear when the user sets
    # OLLAMA_FLASH_ATTENTION=1 explicitly - llama.cpp does not print the
    # "was auto" message because no auto-resolution happened.
    m = last(r"llama_context: flash_attn\s*=\s*(\S+)")
    if m:
        out["flash_attn_requested"] = m.group(1)
    m = last(r"Flash Attention was \S+, set to (\S+)")
    if m:
        out["flash_attn_resolved"] = m.group(1)
    else:
        # Fallback 1: Ollama daemon-level explicit-enable log.
        if last(r'msg="enabling flash attention"'):
            out["flash_attn_resolved"] = "enabled"
        else:
            # Fallback 2: load-request struct exposes the final decision.
            m = last(r"FlashAttention:(\S+?)[\s}]")
            if m:
                out["flash_attn_resolved"] = m.group(1).lower()

    # KV cache: total + K/V quant types and sizes + sequence count. The
    # total can look "bigger than expected" when OLLAMA_NUM_PARALLEL > 1
    # because Ollama allocates one KV slot per concurrent sequence; we
    # capture the seq count so the printer can show per-seq size too.
    #   "llama_kv_cache: size = 15232.00 MiB (131072 cells,  28 layers,  2/2 seqs),
    #       K (q8_0): 7616.00 MiB, V (q8_0): 7616.00 MiB"
    m = last(
        r"llama_kv_cache: size = ([\d.]+) MiB \((\d+) cells,\s*(\d+) layers,\s*(\d+)/(\d+) seqs.*"
        r"K \((\S+)\): ([\d.]+) MiB, V \((\S+)\): ([\d.]+) MiB"
    )
    if m:
        out["kv_cache_total_mib"] = float(m.group(1))
        out["kv_cache_cells"] = int(m.group(2))
        out["kv_cache_layers"] = int(m.group(3))
        out["kv_cache_seqs"] = int(m.group(5))
        out["kv_cache_k_type"] = m.group(6)
        out["kv_cache_k_mib"] = float(m.group(7))
        out["kv_cache_v_type"] = m.group(8)
        out["kv_cache_v_mib"] = float(m.group(9))

    # Compute scratch buffers (device + host pinned). The two log lines
    # look like:
    #   "llama_context:      ROCm0      compute buffer size =   408.01 MiB"
    #   "llama_context:  ROCm_Host      compute buffer size =   262.01 MiB"
    # We want them in the right slots: device buffer is NOT *_Host, host
    # buffer IS *_Host. Negative lookahead keeps `_Host` lines out of the
    # device match.
    m = last(r"llama_context:\s+(?!\S+_Host)\S+\s+compute buffer size =\s*([\d.]+) MiB")
    if m:
        out["compute_buffer_mib"] = float(m.group(1))
    m = last(r"llama_context:\s+\S+_Host\s+compute buffer size =\s*([\d.]+) MiB")
    if m:
        out["host_compute_buffer_mib"] = float(m.group(1))

    print(json.dumps(out, separators=(",", ":")) if out else "null")
    return 0


if __name__ == "__main__":
    sys.exit(main())
