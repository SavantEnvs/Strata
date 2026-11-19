// strata-split's own GGUF reader (engine/src/split/src/gguf.cpp, fnx::Gguf): header, metadata (ints, floats,
// strings, integer arrays, tokenizer tokens), tensor index and type table, then what the loader asks of it.
#include "fuzz_tmpfile.hpp"
#include "gguf.hpp"
#include <exception>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    FuzzTmpFile f(data, size, ".gguf");
    if (!f.ok) return 0;
    try {
        fnx::Gguf g(f.path);
        static const char* keys[] = {"general.architecture", "qwen35moe.block_count", "qwen35moe.embedding_length",
                                     "qwen35moe.rope.freq_base", "tokenizer.ggml.eos_token_id", "general.alignment"};
        for (const char* k : keys) {
            try {
                if (g.has(k)) { (void) g.num(k); }
                if (g.has_key(k)) { (void) g.s(k); }
            } catch (const std::exception&) {}
            try { (void) g.ia(k); } catch (const std::exception&) {}
        }
#if FNX_27B
        try { (void) g.tokens(); } catch (const std::exception&) {}
#endif
        for (const auto& kv : g.tensors()) {
            (void) kv.second.row_bytes();
            (void) kv.second.nrows();
            (void) g.find(kv.first);
        }
    } catch (const std::exception&) {
        // the reader refuses a malformed file by throwing
    }
    return 0;
}
