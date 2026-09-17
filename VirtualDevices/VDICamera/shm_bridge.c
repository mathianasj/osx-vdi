#include <sys/mman.h>
#include <fcntl.h>

int vdi_shm_open(const char *name, int oflag, int mode) {
    return shm_open(name, oflag, (mode_t)mode);
}

int vdi_shm_unlink(const char *name) {
    return shm_unlink(name);
}
