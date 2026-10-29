#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
typedef struct { uint8_t *data; int64_t len; } file_bytes;
static char fixture_root[128];
int64_t silly_files_fixture_create(file_bytes output) {
    strcpy(fixture_root, "/tmp/silly-files-http-XXXXXX");
    if (!mkdtemp(fixture_root)) return -1;
    char path[256];
    snprintf(path, sizeof path, "%s/data.bin", fixture_root);
    int fd = open(path, O_CREAT | O_WRONLY | O_EXCL, 0600);
    if (fd < 0) return -1;
    uint8_t bytes[251];
    for (int i=0; i<251; i++) bytes[i]=(uint8_t)i;
    for (int at=0; at<10007;) {
        int count=10007-at; if (count>251) count=251;
        if (write(fd,bytes,(size_t)count)!=count) { close(fd); return -1; }
        at+=count;
    }
    close(fd);
    snprintf(path, sizeof path, "%s/generated.zip", fixture_root);
    fd=open(path,O_CREAT|O_WRONLY|O_EXCL,0600);
    uint8_t zip[22]={'P','K',5,6};
    if(fd<0) return -1;
    int ok=write(fd,zip,sizeof zip)==sizeof zip;
    close(fd);
    size_t len=strlen(fixture_root);
    if(!ok || output.len<(int64_t)len) return -1;
    memcpy(output.data,fixture_root,len);
    return (int64_t)len;
}
int32_t silly_files_fixture_remove(void) {
    char path[256];
    snprintf(path,sizeof path,"%s/data.bin",fixture_root); if(unlink(path))return -1;
    snprintf(path,sizeof path,"%s/generated.zip",fixture_root); if(unlink(path))return -1;
    return rmdir(fixture_root);
}
int32_t silly_files_fixture_truncate(void) {
    char path[256];
    snprintf(path, sizeof path, "%s/data.bin", fixture_root);
    return truncate(path, 0);
}
