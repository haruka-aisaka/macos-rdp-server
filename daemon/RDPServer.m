#import "daemon/RDPServer.h"
#import "daemon/RDPSession.h"
#import "display/VirtualDisplay.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#define RDP_LOG_COMPONENT "server"
#include "logging/RDPLog.h"
#include <stdatomic.h>

@interface RDPServer () <RDPSessionDelegate>
@property (nonatomic, assign) int listenFd;
@property (nonatomic, assign) uint16_t portValue;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSMutableArray<RDPSession *> *sessions;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, strong) dispatch_queue_t acceptQueue;
/* The single active (authenticated) session that owns the display. Guarded by
 * @synchronized(self) along with `sessions`. A new client that authenticates
 * supersedes whatever is here. */
@property (nonatomic, strong, nullable) RDPSession *activeSession;
/* Bumped by every session that ends, so only the last idle timer acts. */
@property (nonatomic, assign) uint64_t idleGeneration;
@end

/* Process-wide active-session flag. The daemon runs a single RDPServer, so a
 * class-level flag faithfully mirrors that instance's `_activeSession`. The
 * auto-updater reads this (off any thread) to decide whether to defer a swap. */
/* Previously volatile int32_t: volatile prevents register caching but not
 * CPU reordering — readers on other cores could see stale values.
 * _Atomic with acquire/release gives the correct happens-before guarantee. */
static _Atomic int32_t g_hasActiveSession = 0;

@implementation RDPServer

+ (BOOL)hasActiveSession {
    return atomic_load_explicit(&g_hasActiveSession, memory_order_acquire) != 0;
}

- (void)updateActiveSessionFlag {
    /* Caller holds @synchronized(self); the store pairs with the acquire load
     * in +hasActiveSession to form a proper happens-before edge. */
    atomic_store_explicit(&g_hasActiveSession,
                          (_activeSession != nil) ? 1 : 0,
                          memory_order_release);
}

- (instancetype)initWithPort:(uint16_t)port {
    if ((self = [super init])) {
        _portValue = port;
        _listenFd  = -1;
        _sessions  = [NSMutableArray array];
        _acceptQueue = dispatch_queue_create("com.macosrdp.accept",
                                             DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (uint16_t)port    { return _portValue; }
- (BOOL)isRunning   { return _running; }

- (BOOL)startWithError:(NSError **)error {
    rdp_verbose("creating IPv6 dual-stack listen socket on port %u", _portValue);

    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) {
        rdp_error("socket() failed: %s", strerror(errno));
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                code:errno userInfo:nil];
        return NO;
    }

    int yes = 1, no = 0;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);

    struct sockaddr_in6 addr = {0};
    addr.sin6_family = AF_INET6;
    addr.sin6_port   = htons(_portValue);
    addr.sin6_addr   = in6addr_any;

    /* RDP_LISTEN_ADDRESS: listen on one address only (an IPv4 or IPv6
     * literal), e.g. 127.0.0.1, or the Mac's Tailscale address so the port is
     * not reachable from the LAN. Unset: every address. */
    const char *listenAddress = getenv("RDP_LISTEN_ADDRESS");
    if (listenAddress && *listenAddress) {
        struct in_addr v4;
        if (inet_pton(AF_INET6, listenAddress, &addr.sin6_addr) == 1) {
            /* as given */
        } else if (inet_pton(AF_INET, listenAddress, &v4) == 1) {
            /* IPv4 on the dual-stack socket: the v4-mapped address ::ffff:a.b.c.d */
            memset(&addr.sin6_addr, 0, sizeof(addr.sin6_addr));
            addr.sin6_addr.s6_addr[10] = 0xff;
            addr.sin6_addr.s6_addr[11] = 0xff;
            memcpy(&addr.sin6_addr.s6_addr[12], &v4, sizeof(v4));
        } else {
            rdp_error("RDP_LISTEN_ADDRESS '%s' is not an IP address", listenAddress);
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
            close(fd);
            return NO;
        }
        rdp_info("listening on %s only", listenAddress);
    }

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        rdp_error("bind() failed on port %u: %s", _portValue, strerror(errno));
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                code:errno userInfo:nil];
        close(fd);
        return NO;
    }
    if (listen(fd, 8) < 0) {
        rdp_error("listen() failed: %s", strerror(errno));
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                code:errno userInfo:nil];
        close(fd);
        return NO;
    }

    _listenFd = fd;
    _running  = YES;
    rdp_debug("listen socket fd=%d ready", fd);

    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                           (uintptr_t)fd, 0, _acceptQueue);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        [weak acceptConnection];
    });
    dispatch_resume(_acceptSource);
    return YES;
}

- (void)acceptConnection {
    struct sockaddr_in6 clientAddr = {0};
    socklen_t len = sizeof(clientAddr);
    int clientFd = accept(_listenFd, (struct sockaddr *)&clientAddr, &len);
    if (clientFd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK)
            rdp_error("accept() failed: %s", strerror(errno));
        return;
    }

    char addrBuf[INET6_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET6, &clientAddr.sin6_addr, addrBuf, sizeof(addrBuf));
    NSString *addr = [NSString stringWithUTF8String:addrBuf];

    rdp_verbose("accepted connection from %s (fd=%d)", addrBuf, clientFd);

    RDPSession *session = [[RDPSession alloc] initWithFileDescriptor:clientFd
                                                       clientAddress:addr];
    session.delegate = self;

    @synchronized(self) { [_sessions addObject:session]; }
    rdp_debug("active sessions: %lu", (unsigned long)_sessions.count);

    [self.delegate serverDidAcceptSession:session];
    [session start];
}

- (void)stop {
    rdp_info("stopping server");
    _running = NO;
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
    if (_listenFd >= 0) {
        close(_listenFd);
        _listenFd = -1;
    }
    @synchronized(self) {
        rdp_verbose("disconnecting %lu active sessions", (unsigned long)_sessions.count);
        for (RDPSession *s in _sessions) [s disconnect];
        [_sessions removeAllObjects];
        _activeSession = nil;
        [self updateActiveSessionFlag];
    }
}

/* A session authenticated its client and wants to own the display. Make it the
 * single active session, superseding (disconnecting + waiting on the teardown
 * of) any session currently active. Called on the NEW session's serial queue;
 * the blocking wait happens off-lock so concurrent connection attempts don't
 * stall. Returns NO if the server is stopping. */
- (BOOL)sessionDidAuthenticateAndRequestActivation:(RDPSession *)session {
    if (!_running) {
        rdp_info("activation refused: server is stopping");
        return NO;
    }

    RDPSession *previous = nil;
    @synchronized(self) {
        previous = _activeSession;
        if (previous == session) {
            rdp_verbose("session %s already active", session.clientAddress.UTF8String);
            return YES;
        }
        /* Claim active immediately so a third concurrent client that authenticates
         * supersedes US in turn rather than racing on a stale pointer. */
        _activeSession = session;
        [self updateActiveSessionFlag];
    }

    if (previous) {
        rdp_info("TAKEOVER: %s superseding active session %s",
                 session.clientAddress.UTF8String,
                 previous.clientAddress.UTF8String);
        /* Tell the old session to exit its peer loop + tear down (releases its
         * virtual display + display assertions), then block until it has done so
         * BEFORE we let the new session create its own virtual display — two live
         * virtual displays would both map to the main display and fight. */
        [previous disconnect];
        if (![previous waitForTeardown:10.0])
            rdp_error("TAKEOVER: previous session %s did not tear down in time — "
                      "proceeding anyway (display may briefly conflict)",
                      previous.clientAddress.UTF8String);
        else
            rdp_info("TAKEOVER: previous session %s released the display",
                     previous.clientAddress.UTF8String);
    } else {
        rdp_info("session %s is now the active session (no prior session)",
                 session.clientAddress.UTF8String);
    }

    /* If a still-newer client superseded us while we waited, abort. */
    @synchronized(self) {
        if (_activeSession != session) {
            rdp_info("session %s was superseded while activating — aborting",
                     session.clientAddress.UTF8String);
            [self updateActiveSessionFlag];
            return NO;
        }
    }
    return YES;
}

- (void)sessionDidEnd:(RDPSession *)session error:(NSError *)error {
    @synchronized(self) {
        [_sessions removeObject:session];
        if (_activeSession == session) _activeSession = nil;
        [self updateActiveSessionFlag];
    }
    rdp_debug("session removed; %lu remaining", (unsigned long)_sessions.count);
    [self.delegate serverSession:session didEndWithError:error];
    [self scheduleVirtualDisplayRelease];
}

/* The virtual display outlives its session so a reconnect can take it over (a
 * second one would not come online in this process — see VirtualDisplay.h).
 * Once no client has come back for RDP_VIRTUAL_DISPLAY_KEEP seconds (default
 * 300; 0 = right away), release it and, under launchd, exit: launchd starts a
 * fresh daemon whose first virtual display works again. */
- (void)scheduleVirtualDisplayRelease {
    if (![VirtualDisplay reusable]) return;
    const char *env = getenv("RDP_VIRTUAL_DISPLAY_KEEP");
    long keep = env && *env ? strtol(env, NULL, 10) : 300;
    if (keep < 0) keep = 0;
    uint64_t generation;
    @synchronized(self) { generation = ++_idleGeneration; }
    rdp_info("virtual display kept for %ld s for a reconnect", keep);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)keep * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @synchronized(self) {
            if (generation != self->_idleGeneration || self->_activeSession || self->_sessions.count) return;
            /* Claim the release while holding the lock, so a client accepted now
             * is not handed a display that is going away. */
            self->_running = NO;
        }
        VirtualDisplay *vd = [VirtualDisplay reusable];
        [VirtualDisplay setReusable:nil];
        rdp_info("no client for %ld s: releasing virtual display %u", keep, vd.displayID);
        [vd destroy];
        if (getenv("XPC_SERVICE_NAME")) {   /* started by launchd, which starts a new one */
            rdp_info("restarting for a fresh virtual display");
            [self stop];
            exit(0);
        }
        @synchronized(self) { self->_running = YES; }
    });
}

@end
