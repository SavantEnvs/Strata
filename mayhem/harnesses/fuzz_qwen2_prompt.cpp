// Image-prompt text: the A1111 prompt-weight parser (parse_prompt_attention), the LoRA-tag stripper, and the
// Qwen2 tokenizer (UTF-8 validation, pre-tokenizer, byte-level BPE, chat template via qwen_image_tokens).
// The tokenizer is built once from a fixed merge list and only read afterwards (encode is const; no trace set).
#include "strata/image/qwen2_tok.hpp"
#include <memory>
#include <string>
#include <vector>

static const strata::image::Qwen2Tok* tok() {
    static std::unique_ptr<strata::image::Qwen2Tok> t = [] {
        // Merges are byte-level BPE strings ("Ġ" = U+0120 is the space byte).
        const std::vector<std::pair<int, std::string>> merges = {
            {0, "\xC4\xA0 t"}, {1, "t h"}, {2, "\xC4\xA0 a"}, {3, "i n"}, {4, "e r"}, {5, "\xC4\xA0 th"},
            {6, "o n"}, {7, "r e"}, {8, "a t"}, {9, "e n"}, {10, "o r"}, {11, "\xC4\xA0 the"}, {12, "e s"},
            {13, "a n"}, {14, "a r"}, {15, "\xC4\xA0 c"}, {16, "\xC4\xA0 s"}, {17, "a l"}, {18, "i t"},
        };
        std::string err;
        return strata::image::Qwen2Tok::from_ranked(merges, 151387, &err);
    }();
    return t.get();
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    const std::string text(reinterpret_cast<const char*>(data), size);
    (void) strata::image::parse_prompt_attention(text);
    (void) strata::image::strip_lora_tags(text);
    const strata::image::Qwen2Tok* t = tok();
    if (!t) return 0;
    std::vector<int32_t> ids;
    std::string err;
    (void) t->encode(text, ids, &err);
    strata::image::QwenImageTokens out;
    (void) strata::image::qwen_image_tokens(*t, text, &out);
    return 0;
}
