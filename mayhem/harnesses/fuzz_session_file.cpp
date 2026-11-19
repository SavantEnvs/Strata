// Saved session (conversation) files: strata::core::session_file_read - the v1 header, then the bounded
// payload parser (state arrays, checkpoints, K/V layers, hashes).  Read twice: with the default limits, and
// with tight SessionReadLimits as the engine uses when RAM is short.
#include "fuzz_tmpfile.hpp"
#include "strata/core/conversation_file.hpp"
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    using namespace strata::core;
    FuzzTmpFile f(data, size, ".bin");
    if (!f.ok) return 0;
    const SessionFileIdentity id{};   // identity 0/0, as the seeds were written with
    {
        SavedConversation img;
        size_t bytes = 0;
        std::string err;
        (void) session_file_read(f.path, id, img, bytes, err);
    }
    {
        SessionReadLimits lim;
        lim.max_file_bytes = 1u << 20;
        lim.max_tokens = 4096;
        lim.max_checkpoints = 8;
        SavedConversation img;
        size_t bytes = 0;
        std::string err;
        (void) session_file_read(f.path, id, img, bytes, err, lim);
    }
    return 0;
}
