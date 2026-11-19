// PLE table GGUF reader: strata::kernels::PleTable::open (table size/offset checks, the 8 row formats'
// dequantizers, the Direct and Mmap readers), then read_row and gather_batch on the opened table.
#include "fuzz_tmpfile.hpp"
#include "strata/kernels/ngram.hpp"
#include <string>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    namespace k = strata::kernels;
    FuzzTmpFile f(data, size, ".gguf");
    if (!f.ok) return 0;
    for (k::PleIo mode : {k::PleIo::Mmap, k::PleIo::Direct}) {
        k::PleTable t;
        std::string err;
        k::PleIoOptions io;
        io.mode = mode;
        io.cache_rows = 0;
        if (!t.open(f.path, err, io)) continue;
        const uint64_t n = t.rows();
        std::vector<float> row(k::PLE_HEAD_DIM);
        if (n) {
            t.read_row(0, row.data());
            t.read_row((uint32_t) (n - 1), row.data());
            // 2 tokens x 16 rows, indices taken from the input (the table bounds them itself).
            std::vector<uint32_t> rows(32);
            for (size_t i = 0; i < rows.size(); ++i) {
                uint32_t v = 0;
                for (int b = 0; b < 4; ++b) v = (v << 8) | data[(i * 4 + b) % size];
                rows[i] = v % (uint32_t) (n + 1);   // n itself = one past the end, which gather_batch must handle
            }
            std::vector<float> out(2 * 16 * k::PLE_HEAD_DIM);
            t.gather_batch(rows.data(), 2, out.data(), err);
        }
        t.close();
    }
    return 0;
}
