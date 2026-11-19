// Shared helper for the path-taking readers: write the fuzz input to a fresh scratch file under
// $TMPDIR (fallback /tmp) and remove it afterwards.  Each input gets its own file, so nothing is
// kept between iterations.
#pragma once
#include <cstdint>
#include <cstdlib>
#include <string>
#include <unistd.h>

struct FuzzTmpFile {
    std::string path;
    bool ok = false;
    FuzzTmpFile(const uint8_t* data, size_t size, const char* suffix) {
        const char* dir = std::getenv("TMPDIR");
        if (!dir || !*dir) dir = "/tmp";
        std::string tmpl = std::string(dir) + "/strata-fuzz-XXXXXX" + suffix;
        int fd = mkstemps(&tmpl[0], (int) std::string(suffix).size());
        if (fd < 0) return;
        size_t off = 0;
        while (off < size) {
            ssize_t w = write(fd, data + off, size - off);
            if (w <= 0) { close(fd); unlink(tmpl.c_str()); return; }
            off += (size_t) w;
        }
        close(fd);
        path = tmpl;
        ok = true;
    }
    ~FuzzTmpFile() { if (ok) unlink(path.c_str()); }
};
