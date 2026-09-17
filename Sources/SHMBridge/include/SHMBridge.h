#ifndef SHM_BRIDGE_H
#define SHM_BRIDGE_H

int vdi_shm_open(const char *name, int oflag, int mode);
int vdi_shm_unlink(const char *name);

#endif
