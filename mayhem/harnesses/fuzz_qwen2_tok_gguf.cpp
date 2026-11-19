// Text-encoder GGUF: strata::image::Qwen2Tok::from_gguf (tokenizer.ggml.merges loading: merge-string
// splitting, the rank map) on top of the GGUF reader, then encoding a fixed prompt with the loaded merges.
#include "fuzz_tmpfile.hpp"
#include "strata/image/qwen2_tok.hpp"
#include <string>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    FuzzTmpFile f(data, size, ".gguf");
    if (!f.ok) return 0;
    std::string err;
    auto t = strata::image::Qwen2Tok::from_gguf(f.path, &err);
    if (!t) return 0;
    std::vector<int32_t> ids;
    (void) t->encode("a (red:1.2) cat <|im_start|>sitting on the mat, 1234 \xC3\xA9t\xC3\xA9!", ids, &err);
    strata::image::QwenImageTokens out;
    (void) strata::image::qwen_image_tokens(*t, "a [blue] bird <lora:x:0.5> over the sea", &out);
    return 0;
}
