// The CPU quant layer's row decoders: strata::quant::dequant_row for every type can_dequant() accepts
// (Q2_0, Q4_0/1, Q5_0/1, Q8_0, MXFP4, NVFP4, the K-quants, the IQ types).  The first byte picks the type, the
// rest is the row's blocks; n is the number of whole blocks the input holds (types.hpp's geometry), as the
// engine's own callers size a row.
#include "strata/quant/dequant.hpp"
#include "strata/quant/types.hpp"
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    using namespace strata::quant;
    static const Type kTypes[] = {
        Type::F32, Type::F16, Type::Q4_0, Type::Q4_1, Type::Q5_0, Type::Q5_1, Type::Q8_0, Type::Q8_1,
        Type::Q2_K, Type::Q3_K, Type::Q4_K, Type::Q5_K, Type::Q6_K, Type::Q8_K, Type::IQ2_XXS, Type::IQ2_XS,
        Type::IQ3_XXS, Type::IQ1_S, Type::IQ4_NL, Type::IQ3_S, Type::IQ2_S, Type::IQ4_XS, Type::IQ1_M,
        Type::BF16, Type::MXFP4, Type::NVFP4, Type::Q1_0, Type::Q2_0,
    };
    if (size < 1) return -1;
    const Type t = kTypes[data[0] % (sizeof kTypes / sizeof kTypes[0])];
    if (!can_dequant(t)) return 0;
    const TypeInfo* ti = type_info(t);
    if (!ti || ti->blck <= 0 || ti->bytes == 0) return 0;
    const size_t blocks = (size - 1) / ti->bytes;
    if (blocks == 0) return 0;
    // a private copy holding exactly the whole blocks, so ASan sees any read past the row
    std::vector<uint8_t> src(data + 1, data + 1 + blocks * ti->bytes);
    std::vector<float> dst((size_t) blocks * (size_t) ti->blck);
    (void) dequant_row(t, src.data(), dst.data(), (int64_t) dst.size());
    return 0;
}
