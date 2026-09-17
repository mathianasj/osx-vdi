#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <libkern/OSAtomic.h>
#include <math.h>

#define WIDTH 1280
#define HEIGHT 720
#define BPR (WIDTH * 4)
#define FRAME_SIZE (BPR * HEIGHT)
#define HEADER_SIZE 64
#define TOTAL_SIZE (HEADER_SIZE + FRAME_SIZE)

int main(void) {
    const char *name = "/vdi-shm-vdi-camera";
    shm_unlink(name);
    int fd = shm_open(name, O_CREAT | O_RDWR, 0666);
    if (fd < 0) { perror("shm_open"); return 1; }
    if (ftruncate(fd, TOTAL_SIZE) != 0) { perror("ftruncate"); return 1; }

    void *mem = mmap(NULL, TOTAL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mem == MAP_FAILED) { perror("mmap"); return 1; }

    memset(mem, 0, TOTAL_SIZE);
    printf("Writing test frames to shm:%s (%d bytes)\n", name, TOTAL_SIZE);
    printf("Press Ctrl+C to stop\n");

    uint64_t seq = 0;
    while (1) {
        uint8_t *pixels = (uint8_t *)mem + HEADER_SIZE;

        // Color bars pattern that changes each frame
        int shift = (int)(seq * 3) % WIDTH;
        for (int y = 0; y < HEIGHT; y++) {
            for (int x = 0; x < WIDTH; x++) {
                int idx = (y * WIDTH + x) * 4;
                int bar = ((x + shift) * 8 / WIDTH) % 8;
                // BGRA format
                switch (bar) {
                    case 0: pixels[idx]=255; pixels[idx+1]=255; pixels[idx+2]=255; break; // white
                    case 1: pixels[idx]=0;   pixels[idx+1]=255; pixels[idx+2]=255; break; // yellow
                    case 2: pixels[idx]=255; pixels[idx+1]=255; pixels[idx+2]=0;   break; // cyan
                    case 3: pixels[idx]=0;   pixels[idx+1]=255; pixels[idx+2]=0;   break; // green
                    case 4: pixels[idx]=255; pixels[idx+1]=0;   pixels[idx+2]=255; break; // magenta
                    case 5: pixels[idx]=0;   pixels[idx+1]=0;   pixels[idx+2]=255; break; // red
                    case 6: pixels[idx]=255; pixels[idx+1]=0;   pixels[idx+2]=0;   break; // blue
                    case 7: pixels[idx]=0;   pixels[idx+1]=0;   pixels[idx+2]=0;   break; // black
                }
                pixels[idx+3] = 255; // alpha
            }
        }

        // Write header fields
        *(uint32_t *)((uint8_t *)mem + 8) = WIDTH;
        *(uint32_t *)((uint8_t *)mem + 12) = HEIGHT;
        *(uint32_t *)((uint8_t *)mem + 16) = BPR;
        *(uint32_t *)((uint8_t *)mem + 24) = FRAME_SIZE;

        // Increment sequence atomically (signals new frame)
        seq++;
        OSAtomicIncrement64((volatile int64_t *)mem);

        usleep(33333); // ~30fps
    }

    munmap(mem, TOTAL_SIZE);
    close(fd);
    return 0;
}
