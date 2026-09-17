#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <stdint.h>
#include <signal.h>

#define WIDTH 1280
#define HEIGHT 720
#define BPR (WIDTH * 4)
#define FRAME_SIZE (BPR * HEIGHT)
#define HEADER_SIZE 64
#define PORT 18423

static int write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, p + sent, len - sent);
        if (n <= 0) return -1;
        sent += n;
    }
    return 0;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return 1; }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    if (listen(server_fd, 1) < 0) {
        perror("listen"); return 1;
    }

    printf("Listening on localhost:%d for camera extension...\n", PORT);
    printf("Press Ctrl+C to stop\n");

    uint8_t *frame_buf = malloc(HEADER_SIZE + FRAME_SIZE);
    if (!frame_buf) { perror("malloc"); return 1; }

    while (1) {
        printf("Waiting for connection...\n");
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) { perror("accept"); continue; }
        printf("Client connected!\n");

        uint64_t seq = 0;
        while (1) {
            uint8_t *pixels = frame_buf + HEADER_SIZE;
            int shift = (int)(seq * 3) % WIDTH;
            for (int y = 0; y < HEIGHT; y++) {
                for (int x = 0; x < WIDTH; x++) {
                    int idx = (y * WIDTH + x) * 4;
                    int bar = ((x + shift) * 8 / WIDTH) % 8;
                    switch (bar) {
                        case 0: pixels[idx]=255; pixels[idx+1]=255; pixels[idx+2]=255; break;
                        case 1: pixels[idx]=0;   pixels[idx+1]=255; pixels[idx+2]=255; break;
                        case 2: pixels[idx]=255; pixels[idx+1]=255; pixels[idx+2]=0;   break;
                        case 3: pixels[idx]=0;   pixels[idx+1]=255; pixels[idx+2]=0;   break;
                        case 4: pixels[idx]=255; pixels[idx+1]=0;   pixels[idx+2]=255; break;
                        case 5: pixels[idx]=0;   pixels[idx+1]=0;   pixels[idx+2]=255; break;
                        case 6: pixels[idx]=255; pixels[idx+1]=0;   pixels[idx+2]=0;   break;
                        case 7: pixels[idx]=0;   pixels[idx+1]=0;   pixels[idx+2]=0;   break;
                    }
                    pixels[idx+3] = 255;
                }
            }

            seq++;
            memset(frame_buf, 0, HEADER_SIZE);
            *(uint64_t *)(frame_buf + 0) = seq;
            *(uint32_t *)(frame_buf + 8) = WIDTH;
            *(uint32_t *)(frame_buf + 12) = HEIGHT;
            *(uint32_t *)(frame_buf + 16) = BPR;
            *(uint32_t *)(frame_buf + 24) = FRAME_SIZE;

            if (write_all(client_fd, frame_buf, HEADER_SIZE + FRAME_SIZE) < 0) {
                printf("Client disconnected\n");
                break;
            }

            usleep(33333);
        }
        close(client_fd);
    }

    free(frame_buf);
    close(server_fd);
    return 0;
}
