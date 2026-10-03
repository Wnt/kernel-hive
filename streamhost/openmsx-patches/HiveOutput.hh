// Kernel Hive host-native outputs. No window capture or PNG polling.
#pragma once
#include "FrameSource.hh"
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdlib>
#include <cstdint>
#include <fcntl.h>
#include <stdexcept>
#include <sys/mman.h>
#include <unistd.h>

namespace openmsx {
inline void hiveFrame(const FrameSource& frame)
{
    struct Mapping {
        enum : size_t { bytes = 64 + 640 * 480 * 4 };
        uint32_t* data = nullptr;
        Mapping() {
            const char* path = std::getenv("OPENMSX_SHM_PATH");
            if (!path) return;
            int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
            if (fd < 0 || ftruncate(fd, bytes)) throw std::runtime_error("IFB1 open/size failed");
            void* p = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            close(fd);
            if (p == MAP_FAILED) throw std::runtime_error("IFB1 mmap failed");
            data = static_cast<uint32_t*>(p);
            std::fill_n(data, bytes / 4, 0);
            data[1] = 1; data[2] = 640; data[3] = 480;
            data[4] = 640 * 4; data[5] = 32;
            data[10] = 640; data[11] = 480;
            data[0] = 0x31424649;
        }
        ~Mapping() { if (data) munmap(data, bytes); }
    };
    static Mapping map;
    if (!map.data) return;
    auto& seq = *reinterpret_cast<uint64_t*>(map.data + 6);
    std::atomic_ref<uint64_t> lock(seq);
    lock.fetch_add(1, std::memory_order_acq_rel);
    std::array<uint32_t, 640> work{};
    for (unsigned y = 0; y < 480; ++y) {
        auto line = frame.getLinePtr640_480(y, std::span<uint32_t, 640>(work));
        for (unsigned x = 0; x < 640; ++x) {
            auto p = line[x]; // openMSX RGBA -> IFB1 BGRA
            map.data[16 + y * 640 + x] = (p & 0xff00ff00) | ((p & 0xff) << 16) | ((p >> 16) & 0xff);
        }
    }
    lock.fetch_add(1, std::memory_order_release);
}

// Called by the paced SDL dummy callback, after float mixer output. Each write
// is <= PIPE_BUF and nonblocking: absent/slow readers never stall emulation.
inline void hiveAudio(const float* samples, size_t count)
{
    static int fd = [] {
        const char* path = std::getenv("OPENMSX_AUDIO_FIFO");
        return path ? open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC) : -1;
    }();
    if (fd < 0) return;
    std::array<int16_t, 2048> pcm{};
    while (count) {
        auto n = std::min(count, pcm.size());
        for (size_t i = 0; i < n; ++i) {
            pcm[i] = static_cast<int16_t>(std::clamp(samples[i], -1.0f, 1.0f) * 32767.0f);
        }
        auto ignored = write(fd, pcm.data(), n * sizeof(int16_t));
        (void)ignored;
        samples += n; count -= n;
    }
}
}
