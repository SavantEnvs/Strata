// The engine's header-only GGUF reader (strata/artifact/gguf_reader.hpp): GgufModel::open (header, metadata,
// tensor table, split validation), read_geometry / check_engine_architecture, and the block dequantizers of
// strata/artifact/dequant.hpp on each in-bounds tensor's first block - what `strata-gguf --check` and
// `strata-dequant` do with a model file.
#include "fuzz_tmpfile.hpp"
#include "strata/artifact/dequant.hpp"
#include "strata/artifact/gguf_reader.hpp"
#include <cstring>
#include <exception>
#include <vector>

// Only the types whose block geometry the reader itself reports (block_geometry), and only a whole block.
static void dequant_first_block(const char* tn, int be, int bb, const uint8_t* p, uint64_t avail) {
    if (be <= 0 || be > 256 || bb <= 0 || avail < (uint64_t) bb) return;
    float out[256 * 2];
    auto need = [&](uint64_t n) { return avail >= n; };   // F32/F16/BF16: 16 elements
    if (!std::strcmp(tn, "F32")) { if (need(4 * 16)) strata::dequantize_f32(p, out, 16); return; }
    if (!std::strcmp(tn, "F16")) { if (need(2 * 16)) strata::dequantize_f16(p, out, 16); return; }
    if (!std::strcmp(tn, "BF16")) { if (need(2 * 16)) strata::dequantize_bf16(p, out, 16); return; }
    struct { const char* name; uint64_t bytes; void (*fn)(const uint8_t*, float*); } table[] = {
        {"Q8_0", 34, strata::dequantize_q8_0},       {"Q4_0", 18, strata::dequantize_q4_0},
        {"Q5_0", 22, strata::dequantize_q5_0},       {"Q5_1", 24, strata::dequantize_q5_1},
        {"IQ4_NL", 18, strata::dequantize_iq4_nl},   {"Q6_K", 210, strata::dequantize_q6_K},
        {"Q4_K", 144, strata::dequantize_q4_K},      {"Q5_K", 176, strata::dequantize_q5_K},
        {"Q3_K", 110, strata::dequantize_q3_K},      {"IQ4_XS", 136, strata::dequantize_iq4_xs},
    };
    for (const auto& e : table)
        if (!std::strcmp(tn, e.name)) { if ((uint64_t) bb >= e.bytes) e.fn(p, out); return; }
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    FuzzTmpFile f(data, size, ".gguf");
    if (!f.ok) return 0;
    try {
        strata::GgufModel m = strata::GgufModel::open(f.path);
        const strata::GgufFile& g = m.meta();
        (void) strata::model_family(g);
        strata::core::ModelGeometry geo;
        (void) strata::read_geometry(g, geo);
        (void) strata::check_engine_architecture(g);
        for (size_t s = 0; s < m.size(); ++s) {
            const strata::GgufFile& sh = m.shard(s);
            for (const auto& t : sh.tensors()) {
                (void) t.elements();
                int be = 0, bb = 0;
                if (!strata::block_geometry(t.type, be, bb) || !m.in_bounds(t, s)) continue;
                const uint64_t payload = sh.file_size() - sh.data_start();
                dequant_first_block(t.type_name(), be, bb, sh.tensor_data(t), payload - t.offset);
            }
        }
    } catch (const std::exception&) {
        // the reader refuses a malformed file by throwing
    }
    return 0;
}
