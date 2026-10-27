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
#include <strings.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

typedef struct { uint8_t *data; int64_t len; } client_bytes;
typedef struct { int64_t *data; int64_t len; } client_ints;
enum { C_INVALID=1, C_CAPACITY, C_UNSUPPORTED, C_DNS, C_CONNECT, C_TLS, C_TIMEOUT,
       C_CANCELLED, C_RESET, C_LIMIT, C_PROTOCOL, C_INTERNAL, C_STALE, C_BUSY, C_DECODING };
enum { C_FREE=-1, C_QUEUED, C_ACTIVE, C_COMPLETED, C_FAILED };
enum { P_QUEUE, P_CONNECT, P_RESPONSE, P_BODY, P_COMPLETE, P_UPLOAD };
enum { CLIENT_SLOTS=64, CLIENT_URL=4096, CLIENT_HEADERS=16384 };
struct client_slot {
    int status, error, phase, native_code, cancelled, paused, send_paused, abandoned;
    int body_mode, decode, upload_eof, upload_done, final_ready, interim_count, decoded, bodyless, head_open, location_error;
    int64_t upload_length, upload_total, upload_sent;
    size_t upload_count, upload_taken, header_total;
    char method[33], request_headers[CLIENT_HEADERS+1], location[CLIENT_URL+1];
    uint8_t upload[65536];
    struct curl_slist *custom_headers;
    z_stream inflater;
    int encoding, inflater_started, decode_end, network_done;
    size_t encoded_count, encoded_taken;
    uint8_t encoded[CURL_MAX_WRITE_SIZE];
    int64_t token, admitted_ms, phase_ms, activity_ms, total, connects, pauses;
    long http_status;
    size_t pending, taken, header_count;
    char url[CLIENT_URL+1];
    uint8_t body[CURL_MAX_WRITE_SIZE], headers[CLIENT_HEADERS];
    CURL *easy;
};
struct client_pool {
    int64_t epoch, options[12];
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
    case CURLE_BAD_CONTENT_ENCODING: return C_DECODING;
    default: return C_INTERNAL;
    }
}
static void client_global_init(void) {
    client_global_error = curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK;
}

// The decoder consumes transfer-decoded bytes, validates EOF and retains only two fixed stages.
static void client_decode_pump(struct client_slot *slot) {
    if (slot->error || !slot->encoding || slot->pending!=slot->taken) return;
    if (slot->encoding>2) { slot->error=C_DECODING; return; }
    size_t input=slot->encoded_count-slot->encoded_taken;
    if (slot->decode_end) {
        if (!input) return;
        if (slot->encoding!=1 || inflateReset2(&slot->inflater,31)!=Z_OK) { slot->error=C_DECODING; return; }
        slot->decode_end=0;
    }
    if (!slot->inflater_started) {
        int result=inflateInit2(&slot->inflater,slot->encoding==1 ? 31 : 15);
        if (result!=Z_OK) { slot->error=C_INTERNAL; return; }
        slot->inflater_started=1;
    }
    slot->inflater.next_in=slot->encoded+slot->encoded_taken;
    slot->inflater.avail_in=(uInt)input;
    slot->inflater.next_out=slot->body;
    slot->inflater.avail_out=(uInt)sizeof slot->body;
    int result=inflate(&slot->inflater,slot->network_done && !input ? Z_FINISH : Z_NO_FLUSH);
    slot->encoded_taken+=input-slot->inflater.avail_in;
    size_t produced=sizeof slot->body-slot->inflater.avail_out;
    if ((int64_t)produced>client_pool.options[3]-slot->total) { slot->error=C_LIMIT; return; }
    if (produced) {
        slot->pending=produced; slot->taken=0; slot->total+=(int64_t)produced;
        slot->activity_ms=client_now(); client_notify();
    }
    if (result==Z_STREAM_END) slot->decode_end=1;
    else if (result!=Z_OK && result!=Z_BUF_ERROR) slot->error=C_DECODING;
    else if (slot->network_done && slot->encoded_taken==slot->encoded_count && !produced) slot->error=C_DECODING;
}

// Callbacks retain only native slots. No libcurl call occurs while an API reader owns the mutex.
static size_t client_body(char *bytes, size_t size, size_t count, void *opaque) {
    struct client_slot *slot = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    pthread_mutex_lock(&client_lock);
    if (slot->cancelled) { pthread_mutex_unlock(&client_lock); return 0; }
    if (slot->decoded) {
        if (slot->encoded_count!=slot->encoded_taken) {
            slot->paused=1; ++slot->pauses; client_notify(); pthread_mutex_unlock(&client_lock);
            return CURL_WRITEFUNC_PAUSE;
        }
        if (length>sizeof slot->encoded) slot->error=C_LIMIT;
        else {
            if (length) memcpy(slot->encoded,bytes,length);
            slot->encoded_count=length; slot->encoded_taken=0; slot->activity_ms=client_now();
            client_decode_pump(slot);
        }
        int error=slot->error; pthread_mutex_unlock(&client_lock); return error ? 0 : length;
    }
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
static int client_header_is(const char *bytes, size_t length, const char *name) {
    size_t n=strlen(name);
    return length>n && !strncasecmp(bytes,name,n) && bytes[n]==':';
}
static size_t client_header(char *bytes, size_t size, size_t count, void *opaque) {
    struct client_slot *slot=opaque;
    if (size && count>SIZE_MAX/size) return 0;
    size_t length=size*count;
    pthread_mutex_lock(&client_lock);
    if (slot->cancelled) { pthread_mutex_unlock(&client_lock); return 0; }
    if ((int64_t)length>client_pool.options[2]-(int64_t)slot->header_total) {
        slot->error=C_LIMIT; pthread_mutex_unlock(&client_lock); return 0;
    }
    slot->header_total+=length;
    if (length>=12 && !memcmp(bytes,"HTTP/",5) && bytes[8]==' '
        && bytes[9]>='0' && bytes[9]<='9' && bytes[10]>='0' && bytes[10]<='9'
        && bytes[11]>='0' && bytes[11]<='9') {
        slot->http_status=(bytes[9]-'0')*100+(bytes[10]-'0')*10+bytes[11]-'0';
        slot->header_count=0; slot->final_ready=0; slot->head_open=1;
        slot->decoded=0; slot->encoding=0; slot->location[0]=0; slot->location_error=0;
        slot->bodyless=!strcmp(slot->method,"HEAD") || slot->http_status==204 || slot->http_status==304;
        if (slot->http_status<200) ++slot->interim_count;
        else slot->phase=P_BODY;
        if (slot->http_status==101) slot->error=C_PROTOCOL;
    }
    if (slot->head_open) {
        memcpy(slot->headers+slot->header_count,bytes,length); slot->header_count+=length;
        if (client_header_is(bytes,length,"Content-Encoding") && slot->decode && !slot->bodyless) {
            size_t first=17, last=length;
            while (first<last && (bytes[first]==' ' || bytes[first]=='\t')) ++first;
            while (last>first && (bytes[last-1]=='\r' || bytes[last-1]=='\n' || bytes[last-1]==' ' || bytes[last-1]=='\t')) --last;
            if (last>first && !(last-first==8 && !strncasecmp(bytes+first,"identity",8))) {
                slot->decoded=1;
                if (slot->encoding) slot->encoding=3;
                else if (last-first==4 && !strncasecmp(bytes+first,"gzip",4)) slot->encoding=1;
                else if (last-first==7 && !strncasecmp(bytes+first,"deflate",7)) slot->encoding=2;
                else slot->encoding=3;
            }
        }
        if (client_header_is(bytes,length,"Location")) {
            size_t first=9,last=length;
            while (first<last && (bytes[first]==' ' || bytes[first]=='\t')) ++first;
            while (last>first && (bytes[last-1]=='\r' || bytes[last-1]=='\n' || bytes[last-1]==' ' || bytes[last-1]=='\t')) --last;
            for (size_t at=first; at<last; ++at)
                if ((unsigned char)bytes[at]<32 || (unsigned char)bytes[at]==127) slot->location_error=C_PROTOCOL;
            if (last-first>CLIENT_URL) slot->location_error=C_LIMIT;
            else if (slot->location[0]) slot->location_error=C_PROTOCOL;
            else { memcpy(slot->location,bytes+first,last-first); slot->location[last-first]=0; }
        }
        if ((length==2 && bytes[0]=='\r' && bytes[1]=='\n') || (length==1 && bytes[0]=='\n')) {
            slot->head_open=0;
            if (slot->http_status>=200) slot->final_ready=1;
            else slot->header_count=0;
        }
    }
    if (slot->final_ready) slot->phase=P_BODY;
    slot->activity_ms=client_now();
    int error=slot->error;
    client_notify(); pthread_mutex_unlock(&client_lock);
    return error ? 0 : length;
}
static size_t client_upload_read(char *out, size_t size, size_t count, void *opaque) {
    struct client_slot *slot=opaque;
    if (size && count>SIZE_MAX/size) return CURL_READFUNC_ABORT;
    size_t capacity=size*count;
    pthread_mutex_lock(&client_lock);
    if (slot->cancelled || slot->error) { pthread_mutex_unlock(&client_lock); return CURL_READFUNC_ABORT; }
    size_t available=slot->upload_count-slot->upload_taken;
    if (!available && !slot->upload_eof) {
        slot->send_paused=1; client_notify(); pthread_mutex_unlock(&client_lock); return CURL_READFUNC_PAUSE;
    }
    size_t amount=available<capacity ? available : capacity;
    if (amount) {
        memcpy(out,slot->upload+slot->upload_taken,amount); slot->upload_taken+=amount;
        slot->upload_sent+=(int64_t)amount; slot->activity_ms=client_now();
    }
    if ((!amount && slot->upload_eof) || (slot->upload_length>=0 && slot->upload_sent==slot->upload_length)) {
        slot->upload_done=1;
        if (!slot->final_ready) { slot->phase=P_RESPONSE; slot->phase_ms=client_now(); }
    }
    client_notify(); pthread_mutex_unlock(&client_lock);
    return amount;
}
static int client_prereq(void *opaque, char *primary, char *local, int port, int local_port) {
    (void)primary; (void)local; (void)port; (void)local_port;
    struct client_slot *slot = opaque;
    pthread_mutex_lock(&client_lock);
    slot->phase = slot->body_mode && !slot->upload_done ? P_UPLOAD : P_RESPONSE;
    slot->phase_ms = slot->activity_ms = client_now();
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
    CLIENT_SET(CURLOPT_CUSTOMREQUEST, slot->method);
    CLIENT_SET(CURLOPT_HTTP_TRANSFER_DECODING, 1L);
    CLIENT_SET(CURLOPT_HTTP_CONTENT_DECODING, 0L);
    if (slot->decode) CLIENT_SET(CURLOPT_ACCEPT_ENCODING, "gzip, deflate");
    if (!strcmp(slot->method,"HEAD")) CLIENT_SET(CURLOPT_NOBODY, 1L);
    if (slot->body_mode) {
        CLIENT_SET(CURLOPT_UPLOAD, 1L);
        CLIENT_SET(CURLOPT_READFUNCTION, client_upload_read);
        CLIENT_SET(CURLOPT_READDATA, slot);
        CLIENT_SET(CURLOPT_INFILESIZE_LARGE, (curl_off_t)slot->upload_length);
        // Streaming admission must not wait for a server's optional 100 response.
        slot->custom_headers=curl_slist_append(NULL,"Expect:");
        if (!slot->custom_headers) return CURLE_OUT_OF_MEMORY;
    }
    const char *start=slot->request_headers;
    while (*start) {
        const char *end=strstr(start,"\r\n");
        size_t length=(size_t)(end-start);
        char line[CLIENT_HEADERS+1]; memcpy(line,start,length); line[length]=0;
        char *colon=strchr(line,':'), *value=colon ? colon+1 : NULL;
        while (value && (*value==' ' || *value=='\t')) ++value;
        if (value && !*value) { *colon=';'; colon[1]=0; }
        struct curl_slist *next=curl_slist_append(slot->custom_headers,line);
        if (!next) return CURLE_OUT_OF_MEMORY;
        slot->custom_headers=next; start=end+2;
    }
    if (slot->custom_headers) CLIENT_SET(CURLOPT_HTTPHEADER, slot->custom_headers);
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
        curl_slist_free_all(slot->custom_headers); slot->custom_headers=NULL;
    }
    if (slot->inflater_started) { inflateEnd(&slot->inflater); slot->inflater_started=0; }
    pthread_mutex_lock(&client_lock);
    if (slot->status == C_ACTIVE) --client_pool.active;
    if (slot->cancelled) error = C_CANCELLED;
    if (slot->error && error != C_CANCELLED) error = slot->error;
    slot->error = error; slot->native_code = code;
    slot->status = error ? C_FAILED : C_COMPLETED;
    if (!error) slot->phase = P_COMPLETE;
    slot->http_status = status; slot->connects = connects;
    if (error) slot->pending = slot->taken = 0;
    if (slot->abandoned) { memset(slot,0,sizeof *slot); slot->status=C_FREE; }
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
        if (live && !cancel && !expired && slot->decoded) client_decode_pump(slot);
        int decode_error=live && slot->error;
        int decoded_done=live && slot->network_done && slot->decode_end
            && slot->encoded_count==slot->encoded_taken;
        int recv_resume=live && !slot->network_done && slot->paused && slot->pending==slot->taken
            && slot->encoded_count==slot->encoded_taken;
        int send_resume=live && slot->send_paused && (slot->upload_count>slot->upload_taken || slot->upload_eof);
        int resume=!cancel && !expired && (recv_resume || send_resume);
        if (resume) {
            if (recv_resume) slot->paused=0;
            if (send_resume) slot->send_paused=0;
        }
        int mask=(slot->paused ? CURLPAUSE_RECV : 0) | (slot->send_paused ? CURLPAUSE_SEND : 0);
        pthread_mutex_unlock(&client_lock);
        if (cancel || expired) { client_complete(slot,cancel ? C_CANCELLED : C_TIMEOUT,CURLE_OK); continue; }
        if (decode_error || decoded_done) { client_complete(slot,decode_error ? C_DECODING : 0,CURLE_OK); continue; }
        if (resume) {
            CURLcode code=curl_easy_pause(slot->easy,mask);
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
        if (slot) {
            pthread_mutex_lock(&client_lock);
            int deferred=message->data.result==CURLE_OK && slot->decoded;
            if (deferred) { slot->network_done=1; client_notify(); }
            pthread_mutex_unlock(&client_lock);
            if (!deferred) client_complete(slot,client_curl_error(message->data.result),message->data.result);
        }
    }
}
static int client_poll_timeout(void) {
    int64_t now=client_now(), timeout=client_pool.options[9];
    for (int i=0; i<client_pool.capacity; ++i) {
        struct client_slot *slot=&client_pool.slots[i];
        if (slot->status!=C_QUEUED && slot->status!=C_ACTIVE) continue;
        if (slot->decoded && !slot->error && slot->pending==slot->taken
            && (slot->encoded_count>slot->encoded_taken || slot->network_done)) return 0;
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
    if (!options.data || (options.len != 10 && options.len != 12)) return 0;
    const int64_t *o=options.data;
    if (o[0]<1 || o[0]>CLIENT_SLOTS || o[1]<0 || o[1]>CLIENT_SLOTS-o[0]
        || o[2]<1 || o[2]>CLIENT_HEADERS || o[3]<1) return 0;
    if (options.len==12 && (o[10]<1 || o[10]>CLIENT_HEADERS || o[11]<1)) return 0;
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
    memcpy(client_pool.options, options.data, (size_t)options.len*sizeof(int64_t));
    if (options.len==10) { client_pool.options[10]=CLIENT_HEADERS; client_pool.options[11]=64*1024*1024; }
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
static int client_token(const uint8_t *value, size_t length) {
    if (!length) return 0;
    for (size_t i=0; i<length; ++i) {
        unsigned c=value[i];
        if (!((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9')
            || (c && strchr("!#$%&'*+-.^_`|~",(int)c)))) return 0;
    }
    return 1;
}
static int client_request_headers(client_bytes headers, int decode) {
    if (headers.len<0 || headers.len>CLIENT_HEADERS || (!headers.data && headers.len)) return 0;
    size_t at=0, fields=0;
    while (at<(size_t)headers.len) {
        size_t end=at, colon=at;
        while (end<(size_t)headers.len && headers.data[end]!='\r' && headers.data[end]!='\n') ++end;
        if (end+1>=(size_t)headers.len || headers.data[end]!='\r' || headers.data[end+1]!='\n') return 0;
        while (colon<end && headers.data[colon]!=':') ++colon;
        if (colon==end || !client_token(headers.data+at,colon-at) || ++fields>128) return 0;
        size_t name=colon-at;
        const char *forbidden[]={"Content-Length","Transfer-Encoding","Trailer","Connection","Expect","Upgrade"};
        for (size_t i=0; i<sizeof forbidden/sizeof *forbidden; ++i)
            if (strlen(forbidden[i])==name && !strncasecmp((char *)headers.data+at,forbidden[i],name)) return 0;
        if (decode && name==15 && !strncasecmp((char *)headers.data+at,"Accept-Encoding",15)) return 0;
        for (size_t i=colon+1; i<end; ++i)
            if ((headers.data[i]<32 && headers.data[i]!='\t') || headers.data[i]==127) return 0;
        at=end+2;
    }
    return 1;
}
int64_t silly_client_request(int64_t epoch, client_bytes url, client_bytes method,
                            client_bytes headers, client_bytes body, client_ints options) {
    if (!options.data || options.len!=3 || options.data[0]<0 || options.data[0]>2
        || options.data[1]<-1 || options.data[2]<0 || options.data[2]>1) return -C_INVALID;
    int mode=(int)options.data[0], decode=(int)options.data[2];
    if (!method.data || method.len<1 || method.len>32 || !client_token(method.data,(size_t)method.len)
        || !client_request_headers(headers,decode) || body.len<0
        || (!body.data && body.len) || (mode!=1 && body.len)
        || (mode==1 && options.data[1]>=0 && options.data[1]!=body.len)
        || (mode==0 && options.data[1]>0)) return -C_INVALID;
    if (body.len>65536) return -C_LIMIT;
    if (method.len==4 && !memcmp(method.data,"HEAD",4) && mode) return -C_INVALID;
    char copied[CLIENT_URL+1];
    if (!client_copy_string(copied,url,0)
        || (strncasecmp(copied,"http://",7) && strncasecmp(copied,"https://",8))) return -C_INVALID;
    pthread_mutex_lock(&client_lock);
    if (!epoch || epoch!=client_pool.epoch || client_pool.stopping) {
        pthread_mutex_unlock(&client_lock); return -C_STALE;
    }
    if (headers.len>client_pool.options[10] || body.len>client_pool.options[11]
        || (mode==2 && options.data[1]>client_pool.options[11])) {
        pthread_mutex_unlock(&client_lock); return -C_LIMIT;
    }
    int index=0;
    while (index<client_pool.capacity && client_pool.slots[index].status!=C_FREE) ++index;
    if (index==client_pool.capacity) { pthread_mutex_unlock(&client_lock); return -C_CAPACITY; }
    if (client_token_counter==INT64_MAX) { pthread_mutex_unlock(&client_lock); return -C_LIMIT; }
    struct client_slot *slot=&client_pool.slots[index];
    memset(slot,0,sizeof *slot);
    slot->status=C_QUEUED; slot->phase=P_QUEUE; slot->token=++client_token_counter;
    slot->admitted_ms=slot->phase_ms=slot->activity_ms=client_now();
    memcpy(slot->url,copied,strlen(copied)+1); memcpy(slot->method,method.data,(size_t)method.len);
    if (headers.len) memcpy(slot->request_headers,headers.data,(size_t)headers.len);
    slot->body_mode=mode; slot->decode=decode;
    slot->upload_length=mode==1 ? body.len : mode==2 ? options.data[1] : 0;
    slot->upload_eof=mode!=2 || options.data[1]==0; slot->upload_done=slot->upload_length==0;
    if (body.len) memcpy(slot->upload,body.data,(size_t)body.len);
    slot->upload_count=(size_t)body.len; slot->upload_total=body.len;
    int64_t token=slot->token;
    client_wakeup(); client_notify(); pthread_mutex_unlock(&client_lock); return token;
}
int64_t silly_client_submit(int64_t epoch, client_bytes url) {
    int64_t values[3]={0,-1,0};
    return silly_client_request(epoch,url,(client_bytes){(uint8_t *)"GET",3},
        (client_bytes){NULL,0},(client_bytes){NULL,0},(client_ints){values,3});
}
int64_t silly_client_upload(int64_t epoch, int64_t token, client_bytes bytes) {
    if (bytes.len<0 || (!bytes.data && bytes.len)) return -C_INVALID;
    pthread_mutex_lock(&client_lock);
    struct client_slot *slot=client_find(epoch,token);
    int error=!slot ? C_STALE : slot->status==C_FAILED ? slot->error
        : slot->body_mode!=2 || slot->upload_eof || slot->status==C_COMPLETED ? C_INVALID : 0;
    if (!error && bytes.len>client_pool.options[11]-slot->upload_total) error=C_LIMIT;
    if (!error && slot->upload_length>=0 && bytes.len>slot->upload_length-slot->upload_total) error=C_INVALID;
    if (error) { pthread_mutex_unlock(&client_lock); return -error; }
    size_t remaining=slot->upload_count-slot->upload_taken;
    size_t amount=16384-remaining;
    if ((uint64_t)bytes.len<amount) amount=(size_t)bytes.len;
    if (amount) {
        memmove(slot->upload,slot->upload+slot->upload_taken,remaining);
        memcpy(slot->upload+remaining,bytes.data,amount);
        slot->upload_count=remaining+amount; slot->upload_taken=0; slot->upload_total+=(int64_t)amount;
        slot->activity_ms=client_now(); client_wakeup();
    }
    pthread_mutex_unlock(&client_lock); return (int64_t)amount;
}
int64_t silly_client_upload_end(int64_t epoch, int64_t token) {
    pthread_mutex_lock(&client_lock);
    struct client_slot *slot=client_find(epoch,token);
    int error=!slot ? C_STALE : slot->status==C_FAILED ? slot->error : slot->body_mode!=2 ? C_INVALID : 0;
    if (!error && slot->upload_length>=0 && slot->upload_total!=slot->upload_length) error=C_INVALID;
    if (!error && !slot->upload_eof) { slot->upload_eof=1; slot->activity_ms=client_now(); client_wakeup(); }
    pthread_mutex_unlock(&client_lock); return -error;
}
int64_t silly_client_response(int64_t epoch, int64_t token, client_ints fields) {
    if (!fields.data || fields.len<4) return -C_INVALID;
    pthread_mutex_lock(&client_lock);
    struct client_slot *slot=client_find(epoch,token);
    if (!slot) { pthread_mutex_unlock(&client_lock); return -C_STALE; }
    fields.data[0]=slot->final_ready; fields.data[1]=slot->interim_count;
    fields.data[2]=slot->decoded; fields.data[3]=slot->bodyless;
    pthread_mutex_unlock(&client_lock); return 0;
}
int64_t silly_client_redirect_url(int64_t epoch, int64_t token, client_bytes output) {
    if (output.len<0 || (!output.data && output.len)) return -C_INVALID;
    char base[CLIENT_URL+1], location[CLIENT_URL+1];
    pthread_mutex_lock(&client_lock);
    struct client_slot *slot=client_find(epoch,token);
    int error=!slot ? C_STALE : slot->location_error ? slot->location_error
        : !slot->final_ready || slot->http_status<300 || slot->http_status>399
        || !slot->location[0] ? C_INVALID : 0;
    if (!error) { memcpy(base,slot->url,sizeof base); memcpy(location,slot->location,sizeof location); }
    pthread_mutex_unlock(&client_lock);
    if (error) return -error;
    CURLU *url=curl_url(); char *resolved=NULL, *scheme=NULL;
    if (!url) return -C_INTERNAL;
    CURLUcode code=curl_url_set(url,CURLUPART_URL,base,0);
    if (!code) code=curl_url_set(url,CURLUPART_URL,location,0);
    if (!code) code=curl_url_get(url,CURLUPART_SCHEME,&scheme,0);
    if (!code && strcmp(scheme,"http") && strcmp(scheme,"https")) error=C_INVALID;
    if (!code && !error) code=curl_url_get(url,CURLUPART_URL,&resolved,0);
    if (code) error=C_INVALID;
    int64_t length=resolved ? (int64_t)strlen(resolved) : 0;
    if (!error && (length>CLIENT_URL || length>output.len)) error=C_LIMIT;
    if (!error && length) memcpy(output.data,resolved,(size_t)length);
    curl_free(scheme); curl_free(resolved); curl_url_cleanup(url);
    return error ? -error : length;
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
    size_t count=slot->final_ready ? slot->header_count : 0;
    if ((uint64_t)output.len<count) { pthread_mutex_unlock(&client_lock); return -C_LIMIT; }
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
// Relinquish the caller's handle now; only the worker destroys active curl/decoder owners.
int64_t silly_client_abandon(int64_t epoch, int64_t token) {
    pthread_mutex_lock(&client_lock);
    struct client_slot *slot=client_find(epoch,token);
    if (!slot) { pthread_mutex_unlock(&client_lock); return -C_STALE; }
    if (slot->status==C_QUEUED || slot->status==C_ACTIVE) {
        slot->abandoned=1; slot->cancelled=1; client_wakeup();
    } else { memset(slot,0,sizeof *slot); slot->status=C_FREE; }
    pthread_mutex_unlock(&client_lock); return 0;
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
