#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
typedef struct { uint8_t *data; int64_t len; } metadata_bytes;
static char metadata_root[128];
static const char *names[]={"index.html","module.mjs","style.css","code.wasm","note.txt","opaque.bin","empty.txt","replace.txt","replacement.tmp","default.txt"};
static int make_file(const char *name,const uint8_t *data,size_t size,time_t stamp) {
    char path[256];
    snprintf(path,sizeof path,"%s/%s",metadata_root,name);
    int fd=open(path,O_CREAT|O_EXCL|O_WRONLY,0600);
    if(fd<0)return -1;
    struct timespec times[2]={{stamp,0},{stamp,0}};
    int good=write(fd,data,size)==(ssize_t)size && futimens(fd,times)==0;
    close(fd);
    return good?0:-1;
}
int64_t silly_metadata_fixture_create(metadata_bytes output) {
    strcpy(metadata_root,"/tmp/silly-static-metadata-XXXXXX");
    if(!mkdtemp(metadata_root))return -1;
    static const uint8_t wasm[]={0,'a','s','m',1,0,0,0};
    static const uint8_t binary[]={0,255,1,2};
    const uint8_t *data[]={(const uint8_t*)"<p>x</p>",(const uint8_t*)"export{}",(const uint8_t*)"a{}",wasm,
        (const uint8_t*)"hi\n",binary,(const uint8_t*)"",(const uint8_t*)"old-content",(const uint8_t*)"new-data-longer",(const uint8_t*)"default!\n"};
    size_t lengths[]={8,8,3,8,3,4,0,11,15,9};
    for(size_t i=0;i<sizeof names/sizeof names[0];i++)
        if(make_file(names[i],data[i],lengths[i],i==8?784198177:784111777))return -1;
    size_t length=strlen(metadata_root);
    if(output.len<(int64_t)length)return -1;
    memcpy(output.data,metadata_root,length);
    return (int64_t)length;
}
int32_t silly_metadata_fixture_replace(void) {
    char source[256],target[256];
    snprintf(source,sizeof source,"%s/replacement.tmp",metadata_root);
    snprintf(target,sizeof target,"%s/replace.txt",metadata_root);
    return rename(source,target);
}
int32_t silly_metadata_fixture_remove(void) {
    char path[256];
    for(size_t i=0;i<sizeof names/sizeof names[0];i++) {
        snprintf(path,sizeof path,"%s/%s",metadata_root,names[i]);
        if(unlink(path) && errno!=ENOENT)return -1;
    }
    return rmdir(metadata_root);
}
