// One audited boundary. The native worker owns every curl handle and callback buffer.
#define _POSIX_C_SOURCE 200809L
#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct { uint8_t *data; int64_t len; } client_bytes;
typedef struct { int64_t *data; int64_t len; } client_ints;
enum { C_INVALID=1, C_CAPACITY, C_UNSUPPORTED, C_DNS, C_CONNECT, C_TLS, C_TIMEOUT,
       C_CANCELLED, C_RESET, C_LIMIT, C_PROTOCOL, C_INTERNAL, C_STALE, C_BUSY };
enum { C_FREE=-1, C_QUEUED, C_ACTIVE, C_COMPLETED, C_FAILED };
enum { P_QUEUE, P_CONNECT, P_RESPONSE, P_BODY, P_COMPLETE };
enum { CLIENT_SLOTS=64, CLIENT_URL=4096, CLIENT_HEADERS=16384 };
struct client_slot {
    int status, error, phase, native_code, cancelled, paused;
    int64_t token, admitted_ms, phase_ms, activity_ms, total, connects, pauses;
    long http_status;
    size_t pending, taken, header_count;
    char url[CLIENT_URL+1];
    uint8_t body[CURL_MAX_WRITE_SIZE], headers[CLIENT_HEADERS];
    CURL *easy;
};
struct client_pool {
    int64_t epoch, options[10];
    int capacity, stopping, exited, active;
    int notification[2];
    char ca_file[CLIENT_URL+1];
    CURLM *multi;
    pthread_t worker;
    struct client_slot slots[CLIENT_SLOTS];
};
static struct client_pool client_pool;
static pthread_mutex_t client_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t client_once = PTHREAD_ONCE_INIT;
static int client_global_error;
static int64_t client_epoch_counter, client_token_counter;

static int64_t client_now(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value)) return 0;
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static void client_notify(void) {
    uint8_t byte = 1;
    ssize_t result;
    do { result=write(client_pool.notification[1], &byte, 1); } while (result<0 && errno==EINTR);
}
static void client_wakeup(void) {
    if (client_pool.multi && !client_pool.stopping) curl_multi_wakeup(client_pool.multi);
}
static struct client_slot *client_find(int64_t epoch, int64_t token) {
    if (!epoch || epoch != client_pool.epoch || token <= 0) return NULL;
    for (int i=0; i<client_pool.capacity; ++i)
        if (client_pool.slots[i].status != C_FREE && client_pool.slots[i].token == token)
            return &client_pool.slots[i];
    return NULL;
}
static int client_curl_error(CURLcode code) {
    switch (code) {
    case CURLE_OK: return 0;
    case CURLE_COULDNT_RESOLVE_HOST: case CURLE_COULDNT_RESOLVE_PROXY: return C_DNS;
    case CURLE_COULDNT_CONNECT: return C_CONNECT;
    case CURLE_PEER_FAILED_VERIFICATION: case CURLE_SSL_CONNECT_ERROR:
    case CURLE_SSL_CERTPROBLEM: case CURLE_SSL_CIPHER: case CURLE_SSL_CACERT_BADFILE:
    case CURLE_SSL_ISSUER_ERROR: return C_TLS;
    case CURLE_OPERATION_TIMEDOUT: return C_TIMEOUT;
    case CURLE_RECV_ERROR: case CURLE_SEND_ERROR: case CURLE_PARTIAL_FILE:
    case CURLE_GOT_NOTHING: return C_RESET;
    case CURLE_UNSUPPORTED_PROTOCOL: case CURLE_URL_MALFORMAT: return C_INVALID;
    case CURLE_WEIRD_SERVER_REPLY: return C_PROTOCOL;
    default: return C_INTERNAL;
    }
}
static void client_global_init(void) {
    client_global_error = curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK;
}

// Callbacks retain only native slots. No libcurl call occurs while an API reader owns the mutex.
static size_t client_body(char *bytes, size_t size, size_t count, void *opaque) {
    struct client_slot *slot = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    pthread_mutex_lock(&client_lock);
    if (slot->cancelled) { pthread_mutex_unlock(&client_lock); return 0; }
    if (slot->pending != slot->taken) {
        slot->paused = 1; ++slot->pauses;
        client_notify(); pthread_mutex_unlock(&client_lock);
        return CURL_WRITEFUNC_PAUSE;
    }
    if (length > sizeof slot->body || (int64_t)length > client_pool.options[3] - slot->total) {
        slot->error = C_LIMIT;
        pthread_mutex_unlock(&client_lock); return 0;
    }
    if (length) memcpy(slot->body, bytes, length);
    slot->pending = length; slot->taken = 0; slot->total += (int64_t)length;
    slot->phase = P_BODY; slot->activity_ms = client_now();
    client_notify(); pthread_mutex_unlock(&client_lock);
    return length;
}
static size_t client_header(char *bytes, size_t size, size_t count, void *opaque) {
    struct client_slot *slot = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    pthread_mutex_lock(&client_lock);
    if (slot->cancelled) { pthread_mutex_unlock(&client_lock); return 0; }
    if ((int64_t)length > client_pool.options[2] - (int64_t)slot->header_count) {
        slot->error = C_LIMIT;
        pthread_mutex_unlock(&client_lock); return 0;
    }
    memcpy(slot->headers + slot->header_count, bytes, length);
    slot->header_count += length;
    if (length>=12 && !memcmp(bytes,"HTTP/",5) && bytes[8]==' '
        && bytes[9]>='0' && bytes[9]<='9' && bytes[10]>='0' && bytes[10]<='9'
        && bytes[11]>='0' && bytes[11]<='9')
        slot->http_status=(bytes[9]-'0')*100+(bytes[10]-'0')*10+bytes[11]-'0';
    slot->phase = P_BODY; slot->activity_ms = client_now();
    client_notify(); pthread_mutex_unlock(&client_lock);
    return length;
}
static int client_prereq(void *opaque, char *primary, char *local, int port, int local_port) {
    (void)primary; (void)local; (void)port; (void)local_port;
    struct client_slot *slot = opaque;
    pthread_mutex_lock(&client_lock);
    slot->phase = P_RESPONSE; slot->phase_ms = slot->activity_ms = client_now();
    int cancelled = slot->cancelled;
    pthread_mutex_unlock(&client_lock);
    return cancelled ? CURL_PREREQFUNC_ABORT : CURL_PREREQFUNC_OK;
}
static CURLcode client_configure(struct client_slot *slot) {
    CURL *easy = slot->easy;
#define CLIENT_SET(option,value) do { CURLcode rc=curl_easy_setopt(easy, option, value); if(rc) return rc; } while(0)
    CLIENT_SET(CURLOPT_URL, slot->url);
    CLIENT_SET(CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    CLIENT_SET(CURLOPT_PROTOCOLS_STR, "http,https");
    CLIENT_SET(CURLOPT_FOLLOWLOCATION, 0L);
    CLIENT_SET(CURLOPT_PROXY, "");
    CLIENT_SET(CURLOPT_DNS_CACHE_TIMEOUT, 0L);
    CLIENT_SET(CURLOPT_SSL_SESSIONID_CACHE, 0L);
    CLIENT_SET(CURLOPT_NOSIGNAL, 1L);
    CLIENT_SET(CURLOPT_SSL_VERIFYPEER, 1L);
    CLIENT_SET(CURLOPT_SSL_VERIFYHOST, 2L);
    if (client_pool.ca_file[0]) CLIENT_SET(CURLOPT_CAINFO, client_pool.ca_file);
    CLIENT_SET(CURLOPT_CONNECTTIMEOUT_MS, (long)client_pool.options[5]);
    CLIENT_SET(CURLOPT_WRITEFUNCTION, client_body);
    CLIENT_SET(CURLOPT_WRITEDATA, slot);
    CLIENT_SET(CURLOPT_HEADERFUNCTION, client_header);
    CLIENT_SET(CURLOPT_HEADERDATA, slot);
    CLIENT_SET(CURLOPT_PREREQFUNCTION, client_prereq);
    CLIENT_SET(CURLOPT_PREREQDATA, slot);
    CLIENT_SET(CURLOPT_PRIVATE, slot);
#undef CLIENT_SET
    return CURLE_OK;
}
static void client_complete(struct client_slot *slot, int error, CURLcode code) {
    long status=0, connects=0;
    if (slot->easy) {
        curl_easy_getinfo(slot->easy, CURLINFO_RESPONSE_CODE, &status);
        curl_easy_getinfo(slot->easy, CURLINFO_NUM_CONNECTS, &connects);
        curl_multi_remove_handle(client_pool.multi, slot->easy);
        curl_easy_cleanup(slot->easy);
        slot->easy = NULL;
    }
    pthread_mutex_lock(&client_lock);
    if (slot->status == C_ACTIVE) --client_pool.active;
    if (slot->cancelled) error = C_CANCELLED;
    if (slot->error && error != C_CANCELLED) error = slot->error;
    slot->error = error; slot->native_code = code;
    slot->status = error ? C_FAILED : C_COMPLETED;
    if (!error) slot->phase = P_COMPLETE;
    slot->http_status = status; slot->connects = connects;
    if (error) slot->pending = slot->taken = 0;
    client_notify(); pthread_mutex_unlock(&client_lock);
}
static int client_expired(struct client_slot *slot, int64_t now) {
    const int64_t *o = client_pool.options;
    if (o[8] && now - slot->admitted_ms >= o[8]) return 1;
    if (slot->status == C_QUEUED) return now - slot->admitted_ms >= o[4];
    if (slot->phase == P_CONNECT) return now - slot->phase_ms >= o[5];
    if (slot->phase == P_RESPONSE) return now - slot->phase_ms >= o[6];
    return now - slot->activity_ms >= o[7];
}
static void client_admit_queued(void) {
    // Token order is admission order; slot reuse cannot starve older queued work.
    for (int turn=0; turn<client_pool.capacity; ++turn) {
        pthread_mutex_lock(&client_lock);
        struct client_slot *next=NULL;
        if (!client_pool.stopping && client_pool.active<client_pool.options[0]) {
            for (int i=0; i<client_pool.capacity; ++i) {
                struct client_slot *slot=&client_pool.slots[i];
                if (slot->status==C_QUEUED && (!next || slot->token<next->token)) next=slot;
            }
        }
        if (!next) { pthread_mutex_unlock(&client_lock); return; }
        int cancel=next->cancelled, expired=client_expired(next,client_now());
        if (!cancel && !expired) {
            next->status=C_ACTIVE; next->phase=P_CONNECT;
            next->phase_ms=next->activity_ms=client_now(); ++client_pool.active;
        }
        pthread_mutex_unlock(&client_lock);
        if (cancel || expired) { client_complete(next,cancel ? C_CANCELLED : C_TIMEOUT,CURLE_OK); continue; }
        next->easy=curl_easy_init();
        CURLcode code=next->easy ? client_configure(next) : CURLE_OUT_OF_MEMORY;
        if (code!=CURLE_OK || curl_multi_add_handle(client_pool.multi,next->easy)!=CURLM_OK)
            client_complete(next,client_curl_error(code) ? client_curl_error(code) : C_INTERNAL,code);
    }
}
static void client_turn_slots(void) {
    for (int i=0; i<client_pool.capacity; ++i) {
        struct client_slot *slot=&client_pool.slots[i];
        pthread_mutex_lock(&client_lock);
        int live=slot->status==C_QUEUED || slot->status==C_ACTIVE;
        int cancel=live && (slot->cancelled || client_pool.stopping);
        int expired=live && client_expired(slot,client_now());
        if (cancel) slot->cancelled=1;
        int resume=live && !cancel && !expired && slot->paused && slot->pending==slot->taken;
        if (resume) slot->paused=0;
        pthread_mutex_unlock(&client_lock);
        if (cancel || expired) { client_complete(slot,cancel ? C_CANCELLED : C_TIMEOUT,CURLE_OK); continue; }
        if (resume) {
            CURLcode code=curl_easy_pause(slot->easy,CURLPAUSE_CONT);
            if (code!=CURLE_OK) client_complete(slot,client_curl_error(code),code);
        }
    }
    client_admit_queued();
}
static void client_messages(void) {
    int count;
    CURLMsg *message;
    while ((message = curl_multi_info_read(client_pool.multi, &count))) {
        if (message->msg != CURLMSG_DONE) continue;
        struct client_slot *slot = NULL;
        curl_easy_getinfo(message->easy_handle, CURLINFO_PRIVATE, &slot);
        if (slot) client_complete(slot, client_curl_error(message->data.result), message->data.result);
    }
}
static int client_poll_timeout(void) {
    int64_t now=client_now(), timeout=client_pool.options[9];
    for (int i=0; i<client_pool.capacity; ++i) {
        struct client_slot *slot=&client_pool.slots[i];
        if (slot->status!=C_QUEUED && slot->status!=C_ACTIVE) continue;
        int64_t remaining;
        if (slot->status==C_QUEUED) remaining=client_pool.options[4]-(now-slot->admitted_ms);
        else if (slot->phase==P_CONNECT) remaining=client_pool.options[5]-(now-slot->phase_ms);
        else if (slot->phase==P_RESPONSE) remaining=client_pool.options[6]-(now-slot->phase_ms);
        else remaining=client_pool.options[7]-(now-slot->activity_ms);
        if (remaining<timeout) timeout=remaining;
        if (client_pool.options[8]) {
            remaining=client_pool.options[8]-(now-slot->admitted_ms);
            if (remaining<timeout) timeout=remaining;
        }
    }
    return timeout<0 ? 0 : (int)timeout;
}
static void client_break_pool(void) {
    for (int i=0; i<client_pool.capacity; ++i) {
        pthread_mutex_lock(&client_lock);
        struct client_slot *slot=&client_pool.slots[i];
        int live=slot->status==C_QUEUED || slot->status==C_ACTIVE;
        pthread_mutex_unlock(&client_lock);
        if (live) client_complete(slot,C_INTERNAL,CURLE_FAILED_INIT);
    }
    pthread_mutex_lock(&client_lock); client_pool.stopping=1; pthread_mutex_unlock(&client_lock);
}
static void *client_worker(void *unused) {
    (void)unused;
    for (;;) {
        client_turn_slots();
        pthread_mutex_lock(&client_lock);
        int stop=client_pool.stopping, live=0;
        for (int i=0; i<client_pool.capacity; ++i)
            live += client_pool.slots[i].status==C_QUEUED || client_pool.slots[i].status==C_ACTIVE;
        if (stop && !live) {
            CURLM *multi=client_pool.multi; client_pool.multi=NULL;
            pthread_mutex_unlock(&client_lock);
            curl_multi_cleanup(multi);
            pthread_mutex_lock(&client_lock); client_pool.exited=1; client_notify();
            pthread_mutex_unlock(&client_lock); return NULL;
        }
        pthread_mutex_unlock(&client_lock);
        int running;
        CURLMcode result=curl_multi_perform(client_pool.multi,&running);
        client_messages();
        if (result!=CURLM_OK) { client_break_pool(); continue; }
        pthread_mutex_lock(&client_lock);
        int timeout=client_poll_timeout();
        pthread_mutex_unlock(&client_lock);
        if (curl_multi_poll(client_pool.multi,NULL,0,timeout,NULL)!=CURLM_OK) client_break_pool();
    }
}


static int client_copy_string(char *target, client_bytes value, int empty) {
    if (value.len < (empty ? 0 : 1) || value.len > CLIENT_URL || (!value.data && value.len)) return 0;
    for (int64_t i=0; i<value.len; ++i) if (value.data[i] < 32 || value.data[i] == 127) return 0;
    if (value.len) memcpy(target, value.data, (size_t)value.len);
    target[value.len] = 0;
    return 1;
}
static int client_valid_options(client_ints options) {
    if (!options.data || options.len != 10) return 0;
    const int64_t *o=options.data;
    if (o[0]<1 || o[0]>CLIENT_SLOTS || o[1]<0 || o[1]>CLIENT_SLOTS-o[0]
        || o[2]<1 || o[2]>CLIENT_HEADERS || o[3]<1) return 0;
    for (int i=4; i<8; ++i) if (o[i]<1 || o[i]>INT_MAX) return 0;
    return o[8]>=0 && o[8]<=INT_MAX && o[9]>=1 && o[9]<=1000;
}
static int client_notification_pipe(int output[2]) {
    if (pipe(output)) return 0;
    for (int i=0; i<2; ++i) {
        if (fcntl(output[i], F_SETFL, O_NONBLOCK) < 0 || fcntl(output[i], F_SETFD, FD_CLOEXEC) < 0) {
            close(output[0]); close(output[1]); return 0;
        }
    }
    return 1;
}
int64_t silly_client_start(client_ints options, client_bytes ca) {
    if (!client_valid_options(options)) return -C_INVALID;
    char ca_file[CLIENT_URL+1];
    if (!client_copy_string(ca_file, ca, 1)) return -C_INVALID;
    pthread_once(&client_once, client_global_init);
    if (client_global_error) return -C_INTERNAL;
    const curl_version_info_data *version=curl_version_info(CURLVERSION_NOW);
    if (version->version_num < 0x075500 || !(version->features & CURL_VERSION_ASYNCHDNS)
        || !(version->features & CURL_VERSION_SSL)) return -C_UNSUPPORTED;
    pthread_mutex_lock(&client_lock);
    if (client_pool.epoch) { pthread_mutex_unlock(&client_lock); return -C_BUSY; }
    if (client_epoch_counter == INT64_MAX) { pthread_mutex_unlock(&client_lock); return -C_LIMIT; }
    memset(&client_pool, 0, sizeof client_pool);
    memcpy(client_pool.options, options.data, sizeof client_pool.options);
    memcpy(client_pool.ca_file, ca_file, strlen(ca_file)+1);
    client_pool.capacity=(int)(options.data[0]+options.data[1]);
    for (int i=0; i<CLIENT_SLOTS; ++i) client_pool.slots[i].status=C_FREE;
    if (!client_notification_pipe(client_pool.notification)) { pthread_mutex_unlock(&client_lock); return -C_INTERNAL; }
    client_pool.multi=curl_multi_init();
    if (!client_pool.multi) {
        close(client_pool.notification[0]); close(client_pool.notification[1]);
        pthread_mutex_unlock(&client_lock); return -C_INTERNAL;
    }
    CURLMcode result=curl_multi_setopt(client_pool.multi, CURLMOPT_MAX_TOTAL_CONNECTIONS, (long)options.data[0]);
    if (result==CURLM_OK) result=curl_multi_setopt(client_pool.multi, CURLMOPT_MAX_HOST_CONNECTIONS, (long)options.data[0]);
    if (result==CURLM_OK) result=curl_multi_setopt(client_pool.multi, CURLMOPT_MAXCONNECTS, (long)options.data[0]);
    if (result!=CURLM_OK) {
        curl_multi_cleanup(client_pool.multi); client_pool.multi=NULL;
        close(client_pool.notification[0]); close(client_pool.notification[1]);
        pthread_mutex_unlock(&client_lock); return -C_INTERNAL;
    }
    client_pool.epoch=++client_epoch_counter;
    if (pthread_create(&client_pool.worker, NULL, client_worker, NULL)) {
        client_pool.epoch=0; curl_multi_cleanup(client_pool.multi); client_pool.multi=NULL;
        close(client_pool.notification[0]); close(client_pool.notification[1]);
        pthread_mutex_unlock(&client_lock); return -C_INTERNAL;
    }
    int64_t epoch=client_pool.epoch;
    pthread_mutex_unlock(&client_lock);
    return epoch;
}
int64_t silly_client_submit(int64_t epoch, client_bytes url) {
    char copied[CLIENT_URL+1];
    if (!client_copy_string(copied, url, 0)
        || (strncmp(copied,"http://",7) && strncmp(copied,"https://",8))) return -C_INVALID;
    pthread_mutex_lock(&client_lock);
    if (!epoch || epoch!=client_pool.epoch || client_pool.stopping) {
        pthread_mutex_unlock(&client_lock); return -C_STALE;
    }
    int index=0;
    while (index<client_pool.capacity && client_pool.slots[index].status!=C_FREE) ++index;
    if (index==client_pool.capacity) { pthread_mutex_unlock(&client_lock); return -C_CAPACITY; }
    if (client_token_counter==INT64_MAX) { pthread_mutex_unlock(&client_lock); return -C_LIMIT; }
    struct client_slot *slot=&client_pool.slots[index];
    memset(slot,0,sizeof *slot);
    slot->status=C_QUEUED; slot->phase=P_QUEUE; slot->token=++client_token_counter;
    slot->admitted_ms=slot->phase_ms=slot->activity_ms=client_now();
    memcpy(slot->url,copied,strlen(copied)+1);
    int64_t token=slot->token;
    client_wakeup(); client_notify();
    pthread_mutex_unlock(&client_lock);
    return token;
}
int64_t silly_client_poll(int64_t epoch, int64_t token, client_ints fields) {
    if (!fields.data || fields.len<9) return -C_INVALID;
    pthread_mutex_lock(&client_lock);
    struct client_slot *slot=client_find(epoch,token);
    if (!slot) { pthread_mutex_unlock(&client_lock); return -C_STALE; }
    fields.data[0]=slot->status; fields.data[1]=slot->error; fields.data[2]=slot->phase;
    fields.data[3]=slot->native_code; fields.data[4]=slot->http_status;
    fields.data[5]=(int64_t)(slot->pending-slot->taken); fields.data[6]=slot->total;
    fields.data[7]=slot->connects; fields.data[8]=slot->pauses;
    pthread_mutex_unlock(&client_lock);
    return 0;
}
int64_t silly_client_read(int64_t epoch, int64_t token, client_bytes output) {
    if (output.len<0 || (!output.data && output.len)) return -C_INVALID;
    pthread_mutex_lock(&client_lock);
    struct client_slot *slot=client_find(epoch,token);
    if (!slot) { pthread_mutex_unlock(&client_lock); return -C_STALE; }
    if (slot->status==C_FAILED) { int error=slot->error; pthread_mutex_unlock(&client_lock); return -error; }
    size_t count=slot->pending-slot->taken;
    if ((uint64_t)output.len<count) count=(size_t)output.len;
    if (count) {
        memcpy(output.data,slot->body+slot->taken,count); slot->taken+=count;
        slot->activity_ms=client_now();
        if (slot->taken==slot->pending) { slot->pending=slot->taken=0; client_wakeup(); }
    }
    pthread_mutex_unlock(&client_lock);
    return (int64_t)count;
}
int64_t silly_client_headers(int64_t epoch, int64_t token, client_bytes output) {
    if (output.len<0 || (!output.data && output.len)) return -C_INVALID;
    pthread_mutex_lock(&client_lock);
    struct client_slot *slot=client_find(epoch,token);
    if (!slot) { pthread_mutex_unlock(&client_lock); return -C_STALE; }
    if ((uint64_t)output.len<slot->header_count) { pthread_mutex_unlock(&client_lock); return -C_LIMIT; }
    size_t count=slot->header_count;
    if (count) memcpy(output.data,slot->headers,count);
    pthread_mutex_unlock(&client_lock);
    return (int64_t)count;
}
int64_t silly_client_cancel(int64_t epoch, int64_t token) {
    pthread_mutex_lock(&client_lock);
    struct client_slot *slot=client_find(epoch,token);
    if (!slot) { pthread_mutex_unlock(&client_lock); return -C_STALE; }
    if (slot->status==C_QUEUED || slot->status==C_ACTIVE) { slot->cancelled=1; client_wakeup(); }
    pthread_mutex_unlock(&client_lock);
    return 0;
}
int64_t silly_client_release(int64_t epoch, int64_t token) {
    pthread_mutex_lock(&client_lock);
    struct client_slot *slot=client_find(epoch,token);
    if (!slot) { pthread_mutex_unlock(&client_lock); return -C_STALE; }
    if (slot->status<C_COMPLETED) { pthread_mutex_unlock(&client_lock); return -C_BUSY; }
    memset(slot,0,sizeof *slot); slot->status=C_FREE;
    client_wakeup(); pthread_mutex_unlock(&client_lock);
    return 0;
}
int64_t silly_client_wake_fd(int64_t epoch) {
    pthread_mutex_lock(&client_lock);
    int64_t result=epoch && epoch==client_pool.epoch ? client_pool.notification[0] : -C_STALE;
    pthread_mutex_unlock(&client_lock);
    return result;
}
int64_t silly_client_drain(int64_t epoch) {
    pthread_mutex_lock(&client_lock);
    if (!epoch || epoch!=client_pool.epoch) { pthread_mutex_unlock(&client_lock); return -C_STALE; }
    uint8_t bytes[256];
    while (read(client_pool.notification[0],bytes,sizeof bytes)>0) {}
    pthread_mutex_unlock(&client_lock);
    return 0;
}
int64_t silly_client_stop(int64_t epoch) {
    pthread_mutex_lock(&client_lock);
    if (!epoch || epoch!=client_pool.epoch) { pthread_mutex_unlock(&client_lock); return -C_STALE; }
    if (!client_pool.stopping) { client_wakeup(); client_pool.stopping=1; }
    pthread_mutex_unlock(&client_lock);
    return 0;
}
int64_t silly_client_finish(int64_t epoch) {
    pthread_mutex_lock(&client_lock);
    if (!epoch || epoch!=client_pool.epoch) { pthread_mutex_unlock(&client_lock); return -C_STALE; }
    if (!client_pool.stopping || !client_pool.exited) { pthread_mutex_unlock(&client_lock); return 0; }
    pthread_join(client_pool.worker,NULL);
    close(client_pool.notification[0]); close(client_pool.notification[1]);
    memset(&client_pool,0,sizeof client_pool);
    pthread_mutex_unlock(&client_lock);
    return 1;
}
