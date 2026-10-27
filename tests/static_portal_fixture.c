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
typedef struct { uint8_t *data; int64_t len; } portal_bytes;
static char portal_root[128];
static const uint8_t compressed[]={31,139,8,0,0,0,0,0,2,255,203,72,205,201,201,87,40,200,47,42,73,204,225,2,0,233,29,193,18,13,0,0,0};
static const char *files[]={"asset.txt","asset.txt.gz","near.txt","near.txt.gz","stale.txt","stale.txt.gz",
    "plain.txt","index.html","a.txt","z<>&\".txt","sub/child.txt","index/index.html","space dir/child.txt","denied.txt","edge.txt","edge.txt.gz"};
static const char *dirs[]={"sub","index","space dir"};
static void path(char *out,size_t cap,const char *name) { snprintf(out,cap,"%s/%s",portal_root,name); }
static int make_file(const char *name,const uint8_t *data,size_t size,long nanoseconds) {
    char full[256]; path(full,sizeof full,name);
    int fd=open(full,O_CREAT|O_EXCL|O_WRONLY,0600);
    if(fd<0)return -1;
    time_t seconds=strcmp(name,"asset.txt.gz")==0?784111778:784111777;
    struct timespec times[2]={{seconds,nanoseconds},{seconds,nanoseconds}};
    int good=write(fd,data,size)==(ssize_t)size && futimens(fd,times)==0;
    close(fd);return good?0:-1;
}
int64_t silly_portal_fixture_create(portal_bytes output) {
    strcpy(portal_root,"/tmp/silly-static-portal-XXXXXX");
    if(!mkdtemp(portal_root))return -1;
    char full[256];
    for(size_t i=0;i<sizeof dirs/sizeof *dirs;i++) { path(full,sizeof full,dirs[i]);if(mkdir(full,0700))return -1; }
    for(size_t i=0;i<sizeof files/sizeof *files;i++) {
        int gzip=strstr(files[i],".gz")!=NULL;
        const uint8_t *data=gzip?compressed:(const uint8_t*)"hello portal\n";
        size_t size=gzip?sizeof compressed:13;
        long nano=i==3?491000000:i==5?489000000:i==15?490000000:500000000;
        if(i==7||i==11){data=(const uint8_t*)"<h1>spa</h1>";size=12;}
        if(make_file(files[i],data,size,nano))return -1;
    }
    path(full,sizeof full,"link");if(symlink("/etc/passwd",full))return -1;
    path(full,sizeof full,"denied.txt");if(chmod(full,0000))return -1;
    size_t length=strlen(portal_root);
    if(!output.data||output.len<(int64_t)length)return -1;
    memcpy(output.data,portal_root,length);return (int64_t)length;
}
int32_t silly_portal_fixture_remove(void) {
    char full[256];
    for(size_t i=0;i<sizeof files/sizeof *files;i++){path(full,sizeof full,files[i]);if(unlink(full))return -1;}
    path(full,sizeof full,"link");if(unlink(full))return -1;
    for(size_t i=0;i<sizeof dirs/sizeof *dirs;i++){path(full,sizeof full,dirs[i]);if(rmdir(full))return -1;}
    return rmdir(portal_root);
}
