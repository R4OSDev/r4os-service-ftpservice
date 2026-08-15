const r4os = @import("r4os");

const service_name = "FTPSVC";
const service_path = "C:\\R4OS\\SERVICES\\FTPSVC.R4X";
const service_args = "/RUN";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";
const status_arg = "/STATUS";

const fixed_user = "r4os";
const fixed_password = "rosebud";
const listen_port: u16 = 21;
const passive_data_port: u16 = 2020;
const op_status: u16 = 1;
const op_ping: u16 = 2;

const path_max: usize = @as(usize, r4os.abi.file_path_max_bytes) + 1;
const line_max: usize = path_max + 128;
const listen_wait_ticks: u32 = 450;
const service_register_wait_ticks: u32 = 120;
const tcp_service_wait_ms: u64 = 500;
const tcp_write_wait_ms: u64 = 5000;
const session_idle_ms: u64 = 5 * 60 * 1000;
const accept_idle_poll_ticks: u64 = 10;
const data_accept_wait_ms: u64 = 10000;
const data_idle_ms: u64 = 3000;
const transfer_chunk_max: usize = 4096;
var store_stage_nonce: u32 = 1;

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
        };
    }
};

const AuthState = enum(u8) {
    new,
    user_seen,
    logged_in,
};

const DataMode = enum(u8) {
    none,
    passive,
    active,
};

const StoreReadEnd = enum(u8) {
    peer_closed,
    idle_timeout,
    failed,
};

const TcpReadRecovery = enum(u8) {
    transient,
    closed,
    failed,
};

const FileLookupState = enum(u8) {
    found,
    not_found,
    io,
};

const Session = struct {
    active: bool = false,
    conn_id: u32 = 0,
    auth: AuthState = .new,
    user_ok: bool = false,
    data_mode: DataMode = .none,
    data_conn_id: u32 = 0,
    passive_open: bool = false,
    passive_port: u16 = passive_data_port,
    passive_ip: [4]u8 = .{0} ** 4,
    active_ip: [4]u8 = .{0} ** 4,
    active_port: u16 = 0,
    rename_from: [path_max]u8 = .{0} ** path_max,
    rename_from_len: usize = 0,
    // STOR writes a private 8.3 sibling and publishes it create-only. Keep all
    // three names until either publication succeeds or owner-checked Abort
    // proves that no StreamSlot remains. The long-lived service ProgramThread
    // must not lose this claim between FTP commands or sessions.
    stor_cleanup_pending: bool = false,
    stor_publish_pending: bool = false,
    stor_target_path: [path_max]u8 = .{0} ** path_max,
    stor_target_path_len: usize = 0,
    stor_cleanup_path: [path_max]u8 = .{0} ** path_max,
    stor_cleanup_path_len: usize = 0,
    stor_backup_path: [path_max]u8 = .{0} ** path_max,
    stor_backup_path_len: usize = 0,
    cwd: [path_max]u8 = .{0} ** path_max,
    cwd_len: usize = 1,
    line: [line_max]u8 = .{0} ** line_max,
    line_len: usize = 0,
    last_activity: u64 = 0,
};

const ServiceStats = struct {
    requests: u32 = 0,
    status_requests: u32 = 0,
    pings: u32 = 0,
    bad_ops: u32 = 0,
    listen_ready: u32 = 0,
    accepted: u32 = 0,
    active_sessions: u32 = 0,
    closed: u32 = 0,
    commands: u32 = 0,
    auth_ok: u32 = 0,
    auth_failed: u32 = 0,
    cwd_ok: u32 = 0,
    cwd_failed: u32 = 0,
    list_root: u32 = 0,
    list_dirs: u32 = 0,
    passive_setups: u32 = 0,
    active_setups: u32 = 0,
    data_accepts: u32 = 0,
    data_connects: u32 = 0,
    retr_ok: u32 = 0,
    stor_ok: u32 = 0,
    deletes_ok: u32 = 0,
    renames_ok: u32 = 0,
    mkdir_ok: u32 = 0,
    rmdir_ok: u32 = 0,
    transfer_failures: u32 = 0,
    transfer_aborts: u32 = 0,
    path_errors: u32 = 0,
    tcp_errors: u32 = 0,
    tcp_service_transients: u32 = 0,
    tcp_read_transients: u32 = 0,
    tcp_write_transients: u32 = 0,
    bytes_rx: u64 = 0,
    bytes_tx: u64 = 0,
    data_bytes_rx: u64 = 0,
    data_bytes_tx: u64 = 0,
    last_tcp_result: i32 = 0,
    last_tcp_flags: u32 = 0,
    last_tcp_service_status: u32 = 0,
    last_tcp_lifecycle: u32 = 0,
    last_command: [16]u8 = .{0} ** 16,
    last_path: [128]u8 = .{0} ** 128,
    last_error: [32]u8 = .{0} ** 32,
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(app.sys.argsRaw(), selftest_arg)) return runSelfTest(&app);
    if (hasArg(app.sys.argsRaw(), ping_arg)) return runPingClient(&app);
    if (hasArg(app.sys.argsRaw(), status_arg)) return runStatusClient(&app);
    return runService(&app);
}

fn runService(app: *const App) i32 {
    if (!app.sys.hasFn("service_call")) return r4os.abi.service_api_result_invalid;

    var stats = ServiceStats{};
    setLastError(&stats, "init");

    var info: r4os.abi.ServiceInfo = .{};
    var endpoint_handle: u32 = 0;
    var waited: u32 = 0;
    while (waited < service_register_wait_ticks and endpoint_handle == 0) : (waited += 1) {
        const rc = app.sys.serviceEndpointRegister(service_name, 0, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            endpoint_handle = info.handle;
            app.sys.write("FTPSVC endpoint handle=");
            app.sys.printU64(@intCast(endpoint_handle));
            app.sys.println("");
            break;
        }
        app.sys.sleepTicks(1);
    }
    if (endpoint_handle == 0) {
        app.sys.println("FTPSVC endpoint registration failed");
        return r4os.abi.service_api_result_no_endpoint;
    }

    if (!waitForListen(app, &stats)) {
        _ = app.sys.serviceEndpointUnregister(endpoint_handle);
        app.sys.println("FTPSVC listen failed");
        return -1;
    }

    var session = Session{};
    _ = setVirtualRoot(session.cwd[0..]) orelse unreachable;
    session.cwd_len = 1;
    var next_accept_poll: u64 = 0;

    while (!app.sys.programShouldClose()) {
        const poll = app.sys.serviceEndpointPoll(endpoint_handle);
        if (poll < 0) {
            closeSession(app, &session, &stats, "endpoint-poll");
            closeListener(app, &stats);
            _ = app.sys.serviceEndpointUnregister(endpoint_handle);
            return poll;
        }
        if (poll > 0) {
            const rc = handleRequest(app, endpoint_handle, &stats);
            if (rc < 0) {
                closeSession(app, &session, &stats, "endpoint-request");
                closeListener(app, &stats);
                _ = app.sys.serviceEndpointUnregister(endpoint_handle);
                return rc;
            }
        }

        if (!session.active) {
            const now = app.sys.ticks();
            if (now >= next_accept_poll) {
                if (session.stor_cleanup_pending) {
                    // Do not overwrite the retained cleanup claim by
                    // resetting Session for a new client. Retry at the same
                    // bounded cadence as accept polling until Abort proves
                    // that the exact caller-owned stream is gone.
                    _ = resolveStoreTransfer(app, &session, &stats);
                    next_accept_poll = now + accept_idle_poll_ticks;
                } else if (pollClient(app, &session, &stats)) {
                    next_accept_poll = now;
                } else {
                    next_accept_poll = now + accept_idle_poll_ticks;
                }
            }
        } else {
            const now = app.sys.ticks();
            if (session.stor_cleanup_pending and now >= next_accept_poll) {
                // Retry independently of further client commands. A client
                // is allowed to stop after the 451 response, but the service
                // must still resolve or relinquish the retained owner claim.
                _ = resolveStoreTransfer(app, &session, &stats);
                next_accept_poll = now + accept_idle_poll_ticks;
            }
            pollSession(app, endpoint_handle, &session, &stats);
        }
        app.sys.sleepTicks(1);
    }

    closeSession(app, &session, &stats, "program-close");
    closeListener(app, &stats);
    _ = app.sys.serviceEndpointUnregister(endpoint_handle);
    app.sys.println("FTPSVC stopped cleanly");
    return 0;
}

fn handleRequest(app: *const App, endpoint_handle: u32, stats: *ServiceStats) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    var payload: [r4os.abi.service_api_max_payload]u8 = undefined;
    const got = app.sys.serviceEndpointRecv(endpoint_handle, &header, payload[0..]);
    if (got < 0) return got;
    if (got == 0 and header.magic != r4os.abi.service_api_magic) return 0;

    stats.requests +%= 1;
    return switch (header.op) {
        op_status => replyStatus(app, endpoint_handle, header.request_id, stats),
        op_ping => replyPing(app, endpoint_handle, header.request_id, stats),
        else => blk: {
            stats.bad_ops +%= 1;
            setLastError(stats, "bad-op");
            break :blk app.sys.serviceEndpointReply(endpoint_handle, header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
        },
    };
}

fn replyStatus(app: *const App, endpoint_handle: u32, request_id: u32, stats: *ServiceStats) i32 {
    stats.status_requests +%= 1;
    var out: [r4os.abi.service_api_max_payload]u8 = .{0} ** r4os.abi.service_api_max_payload;
    var pos: usize = 0;
    _ = appendText(out[0..], &pos, "FTPSVC OK port=");
    _ = appendU64(out[0..], &pos, @intCast(listen_port));
    _ = appendText(out[0..], &pos, " user=");
    _ = appendText(out[0..], &pos, fixed_user);
    _ = appendText(out[0..], &pos, " root=virtual-drives");
    _ = appendText(out[0..], &pos, " listen=");
    _ = appendU64(out[0..], &pos, @intCast(stats.listen_ready));
    _ = appendText(out[0..], &pos, " accepted=");
    _ = appendU64(out[0..], &pos, @intCast(stats.accepted));
    _ = appendText(out[0..], &pos, " active=");
    _ = appendU64(out[0..], &pos, @intCast(stats.active_sessions));
    _ = appendText(out[0..], &pos, " closed=");
    _ = appendU64(out[0..], &pos, @intCast(stats.closed));
    _ = appendText(out[0..], &pos, " commands=");
    _ = appendU64(out[0..], &pos, @intCast(stats.commands));
    _ = appendText(out[0..], &pos, " auth_ok=");
    _ = appendU64(out[0..], &pos, @intCast(stats.auth_ok));
    _ = appendText(out[0..], &pos, " auth_fail=");
    _ = appendU64(out[0..], &pos, @intCast(stats.auth_failed));
    _ = appendText(out[0..], &pos, " cwd_ok=");
    _ = appendU64(out[0..], &pos, @intCast(stats.cwd_ok));
    _ = appendText(out[0..], &pos, " cwd_fail=");
    _ = appendU64(out[0..], &pos, @intCast(stats.cwd_failed));
    _ = appendText(out[0..], &pos, " list_root=");
    _ = appendU64(out[0..], &pos, @intCast(stats.list_root));
    _ = appendText(out[0..], &pos, " list_dirs=");
    _ = appendU64(out[0..], &pos, @intCast(stats.list_dirs));
    _ = appendText(out[0..], &pos, " pasv=");
    _ = appendU64(out[0..], &pos, @intCast(stats.passive_setups));
    _ = appendText(out[0..], &pos, " port=");
    _ = appendU64(out[0..], &pos, @intCast(stats.active_setups));
    _ = appendText(out[0..], &pos, " data_accepts=");
    _ = appendU64(out[0..], &pos, @intCast(stats.data_accepts));
    _ = appendText(out[0..], &pos, " data_connects=");
    _ = appendU64(out[0..], &pos, @intCast(stats.data_connects));
    _ = appendText(out[0..], &pos, " retr=");
    _ = appendU64(out[0..], &pos, @intCast(stats.retr_ok));
    _ = appendText(out[0..], &pos, " stor=");
    _ = appendU64(out[0..], &pos, @intCast(stats.stor_ok));
    _ = appendText(out[0..], &pos, " del=");
    _ = appendU64(out[0..], &pos, @intCast(stats.deletes_ok));
    _ = appendText(out[0..], &pos, " ren=");
    _ = appendU64(out[0..], &pos, @intCast(stats.renames_ok));
    _ = appendText(out[0..], &pos, " mkdir=");
    _ = appendU64(out[0..], &pos, @intCast(stats.mkdir_ok));
    _ = appendText(out[0..], &pos, " rmdir=");
    _ = appendU64(out[0..], &pos, @intCast(stats.rmdir_ok));
    _ = appendText(out[0..], &pos, " transfer_fail=");
    _ = appendU64(out[0..], &pos, @intCast(stats.transfer_failures));
    _ = appendText(out[0..], &pos, " transfer_abort=");
    _ = appendU64(out[0..], &pos, @intCast(stats.transfer_aborts));
    _ = appendText(out[0..], &pos, " path_errors=");
    _ = appendU64(out[0..], &pos, @intCast(stats.path_errors));
    _ = appendText(out[0..], &pos, " tcp_errors=");
    _ = appendU64(out[0..], &pos, @intCast(stats.tcp_errors));
    _ = appendText(out[0..], &pos, " svc_retry=");
    _ = appendU64(out[0..], &pos, @intCast(stats.tcp_service_transients));
    _ = appendText(out[0..], &pos, " read_retry=");
    _ = appendU64(out[0..], &pos, @intCast(stats.tcp_read_transients));
    _ = appendText(out[0..], &pos, " write_retry=");
    _ = appendU64(out[0..], &pos, @intCast(stats.tcp_write_transients));
    _ = appendText(out[0..], &pos, " rx=");
    _ = appendU64(out[0..], &pos, stats.bytes_rx);
    _ = appendText(out[0..], &pos, " tx=");
    _ = appendU64(out[0..], &pos, stats.bytes_tx);
    _ = appendText(out[0..], &pos, " data_rx=");
    _ = appendU64(out[0..], &pos, stats.data_bytes_rx);
    _ = appendText(out[0..], &pos, " data_tx=");
    _ = appendU64(out[0..], &pos, stats.data_bytes_tx);
    if (stats.last_tcp_result != 0 or stats.last_tcp_flags != 0 or stats.last_tcp_service_status != 0 or stats.last_tcp_lifecycle != 0) {
        _ = appendText(out[0..], &pos, " tcp_result=");
        _ = appendI64(out[0..], &pos, @intCast(stats.last_tcp_result));
        _ = appendText(out[0..], &pos, " tcp_status=");
        _ = appendU64(out[0..], &pos, @intCast(stats.last_tcp_service_status));
        _ = appendText(out[0..], &pos, " tcp_life=");
        _ = appendU64(out[0..], &pos, @intCast(stats.last_tcp_lifecycle));
        _ = appendText(out[0..], &pos, " tcp_flags=");
        _ = appendU64(out[0..], &pos, @intCast(stats.last_tcp_flags));
    }
    _ = appendText(out[0..], &pos, " last_cmd=");
    _ = appendText(out[0..], &pos, spanZ(stats.last_command[0..]));
    _ = appendText(out[0..], &pos, " last_path=");
    _ = appendText(out[0..], &pos, spanZ(stats.last_path[0..]));
    _ = appendText(out[0..], &pos, " last=");
    _ = appendText(out[0..], &pos, spanZ(stats.last_error[0..]));
    return app.sys.serviceEndpointReply(endpoint_handle, request_id, r4os.abi.service_api_result_ok, out[0..pos]);
}

fn replyPing(app: *const App, endpoint_handle: u32, request_id: u32, stats: *ServiceStats) i32 {
    stats.pings +%= 1;
    return app.sys.serviceEndpointReply(endpoint_handle, request_id, r4os.abi.service_api_result_ok, "FTPSVC PONG");
}

fn pollClient(app: *const App, session: *Session, stats: *ServiceStats) bool {
    var accept: r4os.abi.TcpAcceptResult = .{};
    var structured: r4os.abi.NetServiceTcpResult = .{};
    const rc = app.net.tcpAcceptPollServiceResultWait(listen_port, &accept, &structured, tcpServiceWaitTicks(app));
    stats.last_tcp_result = if (rc == 0) structured.result else rc;
    if (rc == 0) return false;
    if (rc < 0 or accept.conn_id == 0 or structured.result != r4os.abi.tcp_result_ok) {
        stats.tcp_errors +%= 1;
        if (accept.conn_id != 0) closeTcpHandle(app, accept.conn_id);
        setLastError(stats, "accept");
        return false;
    }

    session.* = .{};
    session.active = true;
    session.conn_id = accept.conn_id;
    session.cwd[0] = '/';
    session.cwd_len = 1;
    session.last_activity = app.sys.ticks();
    stats.accepted +%= 1;
    stats.active_sessions = 1;
    setLastError(stats, "accepted");
    app.sys.write("FTPSVC client accepted conn=");
    app.sys.printU64(@intCast(accept.conn_id));
    app.sys.println("");
    _ = sendReply(app, session.conn_id, stats, "220 R4OS FTPSVC ready\r\n");
    return true;
}

fn pollSession(app: *const App, endpoint_handle: u32, session: *Session, stats: *ServiceStats) void {
    if (!session.active) return;
    const now = app.sys.ticks();
    if (now - session.last_activity > app.sys.ticksFromMilliseconds(session_idle_ms)) {
        _ = sendReply(app, session.conn_id, stats, "421 Idle timeout\r\n");
        closeSession(app, session, stats, "idle-timeout");
        return;
    }

    var buf: [128]u8 = undefined;
    // 0.56.40: auch der Control-Kanal-Read ist KONSUMIEREND - verfiel
    // der Bounded-Servicecall nach dem Kernel-Read, ging die komplette
    // Kommandozeile verloren (Gate-Befund bei 1000 Hz: RETR kam nie an,
    // Client sah leere Antwort; endpoint timeout=1 cancel=1). Gleiche
    // Klasse wie der 0.56.39-STOR-Tail-Verlust.
    const got = app.net.tcpReadWaitServiceConsumeSafe(session.conn_id, buf[0..], app.sys.ticksFromMilliseconds(1), tcpServiceWaitTicks(app));
    if (got < 0) {
        if (tcpReadTransientRecoverable(app, session.conn_id, stats)) {
            app.sys.sleepTicks(1);
            return;
        }
        stats.tcp_errors +%= 1;
        closeSession(app, session, stats, "read");
        return;
    }
    if (got == 0) return;

    const got_len: usize = @intCast(got);
    stats.bytes_rx +%= got_len;
    session.last_activity = now;
    var i: usize = 0;
    while (i < got_len and session.active) : (i += 1) {
        const ch = buf[i];
        if (ch == '\r') continue;
        if (ch == '\n') {
            const line = session.line[0..session.line_len];
            processCommand(app, endpoint_handle, session, stats, line);
            session.line_len = 0;
            continue;
        }
        if (session.line_len >= session.line.len) {
            session.line_len = 0;
            _ = sendReply(app, session.conn_id, stats, "500 Line too long\r\n");
            setLastError(stats, "line-too-long");
            continue;
        }
        session.line[session.line_len] = ch;
        session.line_len += 1;
    }
}

fn processCommand(app: *const App, endpoint_handle: u32, session: *Session, stats: *ServiceStats, line_raw: []const u8) void {
    const line = trim(line_raw);
    if (line.len == 0) return;
    var split: usize = 0;
    while (split < line.len and line[split] != ' ' and line[split] != '\t') : (split += 1) {}
    const cmd = line[0..split];
    const arg = trim(line[split..]);
    copyFixed(stats.last_command[0..], cmd);
    stats.commands +%= 1;

    if (equalsIgnoreCase(cmd, "QUIT")) {
        _ = sendReply(app, session.conn_id, stats, "221 Bye\r\n");
        closeSession(app, session, stats, "quit");
        return;
    }
    if (session.stor_cleanup_pending) {
        setLastError(stats, "stor-cleanup-pending");
        _ = sendReply(app, session.conn_id, stats, "451 Previous upload cleanup pending\r\n");
        return;
    }
    if (equalsIgnoreCase(cmd, "NOOP")) {
        _ = sendReply(app, session.conn_id, stats, "200 NOOP ok\r\n");
        return;
    }
    if (equalsIgnoreCase(cmd, "USER")) {
        session.user_ok = equalsIgnoreCase(arg, fixed_user);
        session.auth = .user_seen;
        _ = sendReply(app, session.conn_id, stats, "331 Password required\r\n");
        return;
    }
    if (equalsIgnoreCase(cmd, "PASS")) {
        if (session.auth == .user_seen and session.user_ok and bytesEq(arg, fixed_password)) {
            session.auth = .logged_in;
            stats.auth_ok +%= 1;
            setLastError(stats, "auth-ok");
            _ = sendReply(app, session.conn_id, stats, "230 Login successful\r\n");
        } else {
            session.auth = .new;
            session.user_ok = false;
            stats.auth_failed +%= 1;
            setLastError(stats, "auth-fail");
            _ = sendReply(app, session.conn_id, stats, "530 Login incorrect\r\n");
        }
        return;
    }
    if (equalsIgnoreCase(cmd, "SYST")) {
        _ = sendReply(app, session.conn_id, stats, "215 R4OS\r\n");
        return;
    }
    if (equalsIgnoreCase(cmd, "FEAT")) {
        _ = sendReply(app, session.conn_id, stats, "211-Features\r\n UTF8\r\n PASV\r\n EPSV\r\n PORT\r\n LIST\r\n NLST\r\n SIZE\r\n RETR\r\n STOR\r\n DELE\r\n RNFR\r\n RNTO\r\n MKD\r\n RMD\r\n211 End\r\n");
        return;
    }
    if (session.auth != .logged_in) {
        _ = sendReply(app, session.conn_id, stats, "530 Please login with USER and PASS\r\n");
        return;
    }
    if (equalsIgnoreCase(cmd, "OPTS")) {
        if (startsWithIgnoreCase(arg, "UTF8")) {
            _ = sendReply(app, session.conn_id, stats, "200 UTF8 enabled\r\n");
        } else {
            _ = sendReply(app, session.conn_id, stats, "502 Option not implemented\r\n");
        }
        return;
    }
    if (equalsIgnoreCase(cmd, "TYPE")) {
        if (equalsIgnoreCase(arg, "A") or equalsIgnoreCase(arg, "I")) {
            _ = sendReply(app, session.conn_id, stats, "200 Type set\r\n");
        } else {
            _ = sendReply(app, session.conn_id, stats, "504 Type not supported\r\n");
        }
        return;
    }
    if (equalsIgnoreCase(cmd, "PWD") or equalsIgnoreCase(cmd, "XPWD")) {
        replyPwd(app, session, stats);
        return;
    }
    if (equalsIgnoreCase(cmd, "CWD") or equalsIgnoreCase(cmd, "XCWD")) {
        changeDirectory(app, session, stats, arg);
        return;
    }
    if (equalsIgnoreCase(cmd, "CDUP") or equalsIgnoreCase(cmd, "XCUP")) {
        changeDirectory(app, session, stats, "..");
        return;
    }
    if (equalsIgnoreCase(cmd, "LIST") or equalsIgnoreCase(cmd, "NLST") or equalsIgnoreCase(cmd, "STAT")) {
        listPath(app, endpoint_handle, session, stats, arg, equalsIgnoreCase(cmd, "NLST"), equalsIgnoreCase(cmd, "STAT"));
        return;
    }
    if (equalsIgnoreCase(cmd, "PASV")) {
        preparePassive(app, session, stats, false);
        return;
    }
    if (equalsIgnoreCase(cmd, "EPSV")) {
        preparePassive(app, session, stats, true);
        return;
    }
    if (equalsIgnoreCase(cmd, "PORT")) {
        prepareActive(app, session, stats, arg);
        return;
    }
    if (equalsIgnoreCase(cmd, "RETR")) {
        retrieveFile(app, endpoint_handle, session, stats, arg);
        return;
    }
    if (equalsIgnoreCase(cmd, "STOR")) {
        storeFile(app, endpoint_handle, session, stats, arg);
        return;
    }
    if (equalsIgnoreCase(cmd, "DELE")) {
        deleteFile(app, session, stats, arg);
        return;
    }
    if (equalsIgnoreCase(cmd, "RNFR")) {
        renameFrom(app, session, stats, arg);
        return;
    }
    if (equalsIgnoreCase(cmd, "RNTO")) {
        renameTo(app, session, stats, arg);
        return;
    }
    if (equalsIgnoreCase(cmd, "SIZE")) {
        replySize(app, session, stats, arg);
        return;
    }
    if (equalsIgnoreCase(cmd, "MKD") or equalsIgnoreCase(cmd, "XMKD")) {
        makeDirectory(app, session, stats, arg);
        return;
    }
    if (equalsIgnoreCase(cmd, "RMD") or equalsIgnoreCase(cmd, "XRMD")) {
        removeDirectory(app, session, stats, arg);
        return;
    }
    if (equalsIgnoreCase(cmd, "ABOR")) {
        abortData(app, session, stats, "abor");
        _ = sendReply(app, session.conn_id, stats, "226 Abort OK\r\n");
        return;
    }
    _ = sendReply(app, session.conn_id, stats, "502 Command not implemented\r\n");
}

fn changeDirectory(app: *const App, session: *Session, stats: *ServiceStats, arg: []const u8) void {
    var normalized: [path_max]u8 = .{0} ** path_max;
    const path = normalizeFtpPath(session.cwd[0..session.cwd_len], arg, normalized[0..]) orelse {
        stats.path_errors +%= 1;
        stats.cwd_failed +%= 1;
        setLastError(stats, "cwd-path");
        _ = sendReply(app, session.conn_id, stats, "550 Bad path\r\n");
        return;
    };
    copyFixed(stats.last_path[0..], path);
    switch (directoryState(app, path)) {
        .found => {},
        .not_found => {
            stats.cwd_failed +%= 1;
            setLastError(stats, "cwd-missing");
            _ = sendReply(app, session.conn_id, stats, "550 Directory unavailable\r\n");
            return;
        },
        .io => {
            stats.cwd_failed +%= 1;
            setLastError(stats, "cwd-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 Directory lookup failed\r\n");
            return;
        },
    }

    copyPathInto(session.cwd[0..], &session.cwd_len, path) orelse {
        stats.path_errors +%= 1;
        stats.cwd_failed +%= 1;
        setLastError(stats, "cwd-copy");
        _ = sendReply(app, session.conn_id, stats, "550 Path too long\r\n");
        return;
    };
    stats.cwd_ok +%= 1;
    setLastError(stats, "cwd-ok");
    var ftp_path: [path_max]u8 = .{0} ** path_max;
    const display = dosToFtpPath(session.cwd[0..session.cwd_len], ftp_path[0..]) orelse "/";
    var reply: [line_max]u8 = .{0} ** line_max;
    var pos: usize = 0;
    _ = appendText(reply[0..], &pos, "250 Directory changed to ");
    _ = appendText(reply[0..], &pos, display);
    _ = appendText(reply[0..], &pos, "\r\n");
    _ = sendReply(app, session.conn_id, stats, reply[0..pos]);
}

fn replyPwd(app: *const App, session: *const Session, stats: *ServiceStats) void {
    var ftp_path: [path_max]u8 = .{0} ** path_max;
    const display = dosToFtpPath(session.cwd[0..session.cwd_len], ftp_path[0..]) orelse "/";
    var reply: [line_max]u8 = .{0} ** line_max;
    var pos: usize = 0;
    _ = appendText(reply[0..], &pos, "257 \"");
    _ = appendText(reply[0..], &pos, display);
    _ = appendText(reply[0..], &pos, "\"\r\n");
    _ = sendReply(app, session.conn_id, stats, reply[0..pos]);
}

fn listPath(app: *const App, endpoint_handle: u32, session: *Session, stats: *ServiceStats, arg: []const u8, names_only: bool, stat_control: bool) void {
    var normalized: [path_max]u8 = .{0} ** path_max;
    const path = normalizeFtpPath(session.cwd[0..session.cwd_len], if (trim(arg).len == 0) "." else arg, normalized[0..]) orelse {
        stats.path_errors +%= 1;
        setLastError(stats, "list-path");
        _ = sendReply(app, session.conn_id, stats, "550 Bad path\r\n");
        return;
    };
    copyFixed(stats.last_path[0..], path);
    switch (directoryState(app, path)) {
        .found => {},
        .not_found => {
            setLastError(stats, "list-missing");
            _ = sendReply(app, session.conn_id, stats, "550 Directory unavailable\r\n");
            return;
        },
        .io => {
            setLastError(stats, "list-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 Directory lookup failed\r\n");
            return;
        },
    }

    if (stat_control or session.data_mode == .none) {
        _ = sendReply(app, session.conn_id, stats, "150-Directory listing follows\r\n");
        if (isVirtualRoot(path)) {
            stats.list_root +%= 1;
            sendRootListing(app, session.conn_id, stats, names_only);
        } else {
            stats.list_dirs +%= 1;
            if (!sendDirectoryListing(app, session.conn_id, stats, path, names_only)) {
                setLastError(stats, "list-entry-lookup");
                _ = sendReply(app, session.conn_id, stats, "451 Directory listing failed\r\n");
                return;
            }
        }
        _ = sendReply(app, session.conn_id, stats, "150 End\r\n226 Directory send OK\r\n");
        return;
    }

    _ = sendReply(app, session.conn_id, stats, "150 Opening data connection for directory listing\r\n");
    const data_conn = openDataConnection(app, session, stats) orelse {
        stats.transfer_failures +%= 1;
        _ = sendReply(app, session.conn_id, stats, "425 Cannot open data connection\r\n");
        return;
    };
    var ok = true;
    if (isVirtualRoot(path)) {
        stats.list_root +%= 1;
        ok = sendRootListingData(app, data_conn, stats, names_only);
    } else {
        stats.list_dirs +%= 1;
        ok = sendDirectoryListingData(app, data_conn, stats, path, names_only);
    }
    pumpServiceRequests(app, endpoint_handle, stats);
    finishDataConnection(app, session, stats);
    if (!ok) {
        stats.transfer_failures +%= 1;
        _ = sendReply(app, session.conn_id, stats, "426 Data connection failed\r\n");
        return;
    }
    _ = sendReply(app, session.conn_id, stats, "226 Directory send OK\r\n");
}

fn sendRootListing(app: *const App, conn_id: u32, stats: *ServiceStats, names_only: bool) void {
    var index: u32 = 0;
    while (index < 26) : (index += 1) {
        const info = app.sys.driveInfo(index) orelse continue;
        if (info.mounted == 0) continue;
        const letter = if (info.letter != 0) upper(info.letter) else @as(u8, 'A') + @as(u8, @intCast(index));
        var line: [128]u8 = .{0} ** 128;
        var pos: usize = 0;
        if (!names_only) _ = appendText(line[0..], &pos, "dr-xr-xr-x 1 r4os r4os 0 Jan 01 00:00 ");
        _ = appendByte(line[0..], &pos, letter);
        _ = appendText(line[0..], &pos, "\r\n");
        _ = sendReply(app, conn_id, stats, line[0..pos]);
    }
}

fn sendDirectoryListing(app: *const App, conn_id: u32, stats: *ServiceStats, path: []const u8, names_only: bool) bool {
    var path_z: [path_max:0]u8 = .{0} ** path_max;
    const dir_z = copyZ(path_z[0..], path) orelse return false;
    var index: u32 = 2;
    while (index < 258) : (index += 1) {
        var entry_path_buf: [path_max:0]u8 = .{0} ** path_max;
        const kind = app.sys.dirEntry(dir_z, index, entry_path_buf[0 .. entry_path_buf.len - 1]);
        if (kind == r4os.r4sys.dir_entry_result_end) break;
        if (kind < 0) return false;
        const entry_path = spanZ(entry_path_buf[0..]);
        const name = baseName(entry_path);
        var size: u64 = 0;
        var entry_z: [path_max:0]u8 = .{0} ** path_max;
        if (copyZ(entry_z[0..], entry_path)) |z| {
            var info: r4os.abi.FileInfo = .{};
            switch (fileLookup(app, z, &info)) {
                .found => size = info.size,
                .not_found => continue,
                .io => return false,
            }
        }

        var line: [line_max]u8 = .{0} ** line_max;
        var pos: usize = 0;
        if (names_only) {
            _ = appendText(line[0..], &pos, name);
        } else {
            _ = appendByte(line[0..], &pos, if (kind == 1) 'd' else '-');
            _ = appendText(line[0..], &pos, "rwxr-xr-x 1 r4os r4os ");
            _ = appendU64(line[0..], &pos, size);
            _ = appendText(line[0..], &pos, " Jan 01 00:00 ");
            _ = appendText(line[0..], &pos, name);
        }
        _ = appendText(line[0..], &pos, "\r\n");
        _ = sendReply(app, conn_id, stats, line[0..pos]);
    }
    return true;
}

fn sendRootListingData(app: *const App, conn_id: u32, stats: *ServiceStats, names_only: bool) bool {
    var index: u32 = 0;
    while (index < 26) : (index += 1) {
        const info = app.sys.driveInfo(index) orelse continue;
        if (info.mounted == 0) continue;
        const letter = if (info.letter != 0) upper(info.letter) else @as(u8, 'A') + @as(u8, @intCast(index));
        var line: [128]u8 = .{0} ** 128;
        var pos: usize = 0;
        if (!names_only) _ = appendText(line[0..], &pos, "dr-xr-xr-x 1 r4os r4os 0 Jan 01 00:00 ");
        _ = appendByte(line[0..], &pos, letter);
        _ = appendText(line[0..], &pos, "\r\n");
        if (!sendData(app, conn_id, stats, line[0..pos])) return false;
    }
    return true;
}

fn sendDirectoryListingData(app: *const App, conn_id: u32, stats: *ServiceStats, path: []const u8, names_only: bool) bool {
    var path_z: [path_max:0]u8 = .{0} ** path_max;
    const dir_z = copyZ(path_z[0..], path) orelse return false;
    var index: u32 = 2;
    while (index < 258) : (index += 1) {
        var entry_path_buf: [path_max:0]u8 = .{0} ** path_max;
        const kind = app.sys.dirEntry(dir_z, index, entry_path_buf[0 .. entry_path_buf.len - 1]);
        if (kind == r4os.r4sys.dir_entry_result_end) break;
        if (kind < 0) return false;
        const entry_path = spanZ(entry_path_buf[0..]);
        const name = baseName(entry_path);
        var size: u64 = 0;
        var entry_z: [path_max:0]u8 = .{0} ** path_max;
        if (copyZ(entry_z[0..], entry_path)) |z| {
            var info: r4os.abi.FileInfo = .{};
            switch (fileLookup(app, z, &info)) {
                .found => size = info.size,
                .not_found => continue,
                .io => return false,
            }
        }

        var line: [line_max]u8 = .{0} ** line_max;
        var pos: usize = 0;
        if (names_only) {
            _ = appendText(line[0..], &pos, name);
        } else {
            _ = appendByte(line[0..], &pos, if (kind == 1) 'd' else '-');
            _ = appendText(line[0..], &pos, "rwxr-xr-x 1 r4os r4os ");
            _ = appendU64(line[0..], &pos, size);
            _ = appendText(line[0..], &pos, " Jan 01 00:00 ");
            _ = appendText(line[0..], &pos, name);
        }
        _ = appendText(line[0..], &pos, "\r\n");
        if (!sendData(app, conn_id, stats, line[0..pos])) return false;
    }
    return true;
}

fn preparePassive(app: *const App, session: *Session, stats: *ServiceStats, extended: bool) void {
    closeDataSetup(app, session, stats);

    var result: r4os.abi.NetServiceTcpResult = .{};
    const rc = app.net.tcpListenServiceResultWait(passive_data_port, &result, tcpServiceWaitTicks(app));
    stats.last_tcp_result = if (rc == 0) result.result else rc;
    if (rc != 0 or result.result != r4os.abi.tcp_result_ok) {
        stats.tcp_errors +%= 1;
        stats.transfer_failures +%= 1;
        setLastError(stats, "pasv-listen");
        _ = sendReply(app, session.conn_id, stats, "425 Cannot open passive listener\r\n");
        return;
    }

    session.data_mode = .passive;
    session.passive_open = true;
    session.passive_port = passive_data_port;
    session.passive_ip = result.local_ip;
    if (isZeroIp(session.passive_ip)) session.passive_ip = .{ 10, 0, 2, 15 };
    stats.passive_setups +%= 1;
    setLastError(stats, "pasv-ready");

    var reply: [128]u8 = .{0} ** 128;
    var pos: usize = 0;
    if (extended) {
        _ = appendText(reply[0..], &pos, "229 Entering Extended Passive Mode (|||");
        _ = appendU64(reply[0..], &pos, @intCast(session.passive_port));
        _ = appendText(reply[0..], &pos, "|)\r\n");
    } else {
        _ = appendText(reply[0..], &pos, "227 Entering Passive Mode (");
        appendIpTuple(reply[0..], &pos, session.passive_ip);
        _ = appendByte(reply[0..], &pos, ',');
        _ = appendU64(reply[0..], &pos, @intCast(session.passive_port / 256));
        _ = appendByte(reply[0..], &pos, ',');
        _ = appendU64(reply[0..], &pos, @intCast(session.passive_port % 256));
        _ = appendText(reply[0..], &pos, ")\r\n");
    }
    _ = sendReply(app, session.conn_id, stats, reply[0..pos]);
}

fn prepareActive(app: *const App, session: *Session, stats: *ServiceStats, arg: []const u8) void {
    closeDataSetup(app, session, stats);
    var ip: [4]u8 = .{0} ** 4;
    var port: u16 = 0;
    if (!parsePortArgument(arg, &ip, &port) or port == 0) {
        stats.path_errors +%= 1;
        setLastError(stats, "port-arg");
        _ = sendReply(app, session.conn_id, stats, "501 Bad PORT argument\r\n");
        return;
    }
    session.data_mode = .active;
    session.active_ip = ip;
    session.active_port = port;
    stats.active_setups +%= 1;
    setLastError(stats, "port-ready");
    _ = sendReply(app, session.conn_id, stats, "200 PORT command successful\r\n");
}

fn retrieveFile(app: *const App, endpoint_handle: u32, session: *Session, stats: *ServiceStats, arg: []const u8) void {
    var path_buf: [path_max]u8 = .{0} ** path_max;
    const path = normalizeFtpPath(session.cwd[0..session.cwd_len], arg, path_buf[0..]) orelse {
        stats.path_errors +%= 1;
        setLastError(stats, "retr-path");
        _ = sendReply(app, session.conn_id, stats, "550 Bad path\r\n");
        return;
    };
    copyFixed(stats.last_path[0..], path);
    var path_z: [path_max:0]u8 = .{0} ** path_max;
    const z = copyZ(path_z[0..], path) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Path too long\r\n");
        return;
    };
    var info: r4os.abi.FileInfo = .{};
    switch (fileLookup(app, z, &info)) {
        .found => {},
        .not_found => {
            _ = sendReply(app, session.conn_id, stats, "550 File unavailable\r\n");
            return;
        },
        .io => {
            setLastError(stats, "retr-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 File lookup failed\r\n");
            return;
        },
    }
    if (info.exists == 0 or info.is_dir != 0 or info.size > 0xffff_ffff) {
        _ = sendReply(app, session.conn_id, stats, "550 File unavailable\r\n");
        return;
    }

    _ = sendReply(app, session.conn_id, stats, "150 Opening data connection for download\r\n");
    const data_conn = openDataConnection(app, session, stats) orelse {
        stats.transfer_failures +%= 1;
        _ = sendReply(app, session.conn_id, stats, "425 Cannot open data connection\r\n");
        return;
    };

    var offset: u64 = 0;
    var buffer: [transfer_chunk_max]u8 = undefined;
    while (offset < info.size) {
        const remaining: usize = @intCast(@min(@as(u64, @intCast(buffer.len)), info.size - offset));
        const got_raw = app.sys.fileReadAt(z, @intCast(offset), buffer[0..remaining]);
        if (got_raw <= 0) {
            stats.transfer_failures +%= 1;
            finishDataConnection(app, session, stats);
            setLastError(stats, "retr-read");
            _ = sendReply(app, session.conn_id, stats, "451 Read failed\r\n");
            return;
        }
        const got: usize = @intCast(got_raw);
        if (!sendData(app, data_conn, stats, buffer[0..got])) {
            stats.transfer_failures +%= 1;
            finishDataConnection(app, session, stats);
            setLastError(stats, "retr-write");
            _ = sendReply(app, session.conn_id, stats, "426 Data connection failed\r\n");
            return;
        }
        offset += got;
        pumpServiceRequests(app, endpoint_handle, stats);
        cooperateTransfer(app, offset);
    }

    finishDataConnection(app, session, stats);
    stats.retr_ok +%= 1;
    setLastError(stats, "retr-ok");
    _ = sendReply(app, session.conn_id, stats, "226 Transfer complete\r\n");
}

fn clearStoreCleanup(session: *Session) void {
    session.stor_cleanup_pending = false;
    session.stor_publish_pending = false;
    session.stor_target_path_len = 0;
    session.stor_cleanup_path_len = 0;
    session.stor_backup_path_len = 0;
    @memset(session.stor_target_path[0..], 0);
    @memset(session.stor_cleanup_path[0..], 0);
    @memset(session.stor_backup_path[0..], 0);
}

fn copyStorePath(out: []u8, out_len: *usize, value: []const u8) bool {
    if (value.len == 0 or value.len >= out.len) return false;
    @memset(out, 0);
    @memcpy(out[0..value.len], value);
    out_len.* = value.len;
    return true;
}

fn nextStoreStageNonce(app: *const App, conn_id: u32) u32 {
    const sequence = store_stage_nonce;
    store_stage_nonce +%= 1;
    if (store_stage_nonce == 0) store_stage_nonce = 1;
    const tick_bits: u32 = @truncate(app.sys.ticks());
    return (tick_bits ^ (conn_id *% 0x9E37_79B9) ^ (sequence *% 0x85EB_CA6B)) & 0x0FFF_FFFF;
}

fn buildStoreSiblingPath(target: []const u8, prefix: u8, nonce: u32, extension: []const u8, out: []u8) bool {
    if (extension.len != 3) return false;
    var separator = target.len;
    while (separator > 0 and !isPathSeparator(target[separator - 1])) : (separator -= 1) {}
    if (separator == 0 or separator + 12 >= out.len) return false;
    @memset(out, 0);
    @memcpy(out[0..separator], target[0..separator]);
    var pos = separator;
    out[pos] = prefix;
    pos += 1;
    const digits = "0123456789ABCDEF";
    var value = nonce & 0x0FFF_FFFF;
    var hex_pos: usize = 7;
    while (hex_pos > 0) {
        hex_pos -= 1;
        out[pos + hex_pos] = digits[@intCast(value & 0x0F)];
        value >>= 4;
    }
    pos += 7;
    out[pos] = '.';
    pos += 1;
    @memcpy(out[pos .. pos + extension.len], extension);
    return true;
}

fn prepareStoreStagingPaths(app: *const App, session: *Session, target: []const u8) i32 {
    clearStoreCleanup(session);
    var attempt: u32 = 0;
    while (attempt < 16) : (attempt += 1) {
        const nonce = nextStoreStageNonce(app, session.conn_id);
        if (!buildStoreSiblingPath(target, 'F', nonce, "TMP", session.stor_cleanup_path[0..]) or
            !buildStoreSiblingPath(target, 'G', nonce, "BAK", session.stor_backup_path[0..]))
        {
            clearStoreCleanup(session);
            return r4os.abi.file_stream_error_invalid;
        }
        const staged = spanZ(session.stor_cleanup_path[0..]);
        const backup = spanZ(session.stor_backup_path[0..]);
        if (equalsIgnoreCase(target, staged) or
            equalsIgnoreCase(target, backup) or
            equalsIgnoreCase(staged, backup))
            continue;

        var staged_z: [path_max:0]u8 = .{0} ** path_max;
        var backup_z: [path_max:0]u8 = .{0} ** path_max;
        const staged_ptr = copyZ(staged_z[0..], staged) orelse {
            clearStoreCleanup(session);
            return r4os.abi.file_stream_error_invalid;
        };
        const backup_ptr = copyZ(backup_z[0..], backup) orelse {
            clearStoreCleanup(session);
            return r4os.abi.file_stream_error_invalid;
        };
        var info: r4os.abi.FileInfo = .{};
        switch (fileLookup(app, staged_ptr, &info)) {
            .found => continue,
            .not_found => {},
            .io => {
                clearStoreCleanup(session);
                return r4os.abi.file_stream_error_io;
            },
        }
        switch (fileLookup(app, backup_ptr, &info)) {
            .found => continue,
            .not_found => {},
            .io => {
                clearStoreCleanup(session);
                return r4os.abi.file_stream_error_io;
            },
        }
        if (!copyStorePath(session.stor_target_path[0..], &session.stor_target_path_len, target)) {
            clearStoreCleanup(session);
            return r4os.abi.file_stream_error_invalid;
        }
        session.stor_cleanup_path_len = staged.len;
        session.stor_backup_path_len = backup.len;
        session.stor_cleanup_pending = true;
        session.stor_publish_pending = false;
        return r4os.abi.file_stream_result_ok;
    }
    clearStoreCleanup(session);
    return r4os.abi.file_stream_error_exists;
}

fn publishStoreStage(app: *const App, session: *Session) i32 {
    if (!session.stor_cleanup_pending or
        session.stor_target_path_len == 0 or
        session.stor_cleanup_path_len == 0 or
        session.stor_backup_path_len == 0)
    {
        return r4os.r4sys.file_replace_atomic_error_invalid;
    }
    var target_z: [path_max:0]u8 = .{0} ** path_max;
    var staged_z: [path_max:0]u8 = .{0} ** path_max;
    var backup_z: [path_max:0]u8 = .{0} ** path_max;
    @memcpy(target_z[0..session.stor_target_path_len], session.stor_target_path[0..session.stor_target_path_len]);
    @memcpy(staged_z[0..session.stor_cleanup_path_len], session.stor_cleanup_path[0..session.stor_cleanup_path_len]);
    @memcpy(backup_z[0..session.stor_backup_path_len], session.stor_backup_path[0..session.stor_backup_path_len]);
    const flags =
        r4os.r4sys.file_replace_atomic_flag_consume_stage |
        r4os.r4sys.file_replace_atomic_flag_require_target_absent |
        r4os.r4sys.file_replace_atomic_flag_require_owned_stage;
    return app.sys.fileReplaceAtomic(&target_z, &staged_z, &backup_z, flags);
}

fn cleanupStoreStream(app: *const App, session: *Session, stats: *ServiceStats) i32 {
    if (!session.stor_cleanup_pending) return r4os.abi.file_stream_result_ok;
    if (session.stor_publish_pending) return r4os.abi.file_stream_error_io;
    if (session.stor_cleanup_path_len == 0 or
        session.stor_cleanup_path_len >= session.stor_cleanup_path.len)
    {
        return r4os.abi.file_stream_error_io;
    }

    var path_z: [path_max:0]u8 = .{0} ** path_max;
    const path_len = session.stor_cleanup_path_len;
    @memcpy(path_z[0..path_len], session.stor_cleanup_path[0..path_len]);
    stats.transfer_aborts +%= 1;
    const abort_rc = app.sys.fileStreamAbort(&path_z);
    if (abort_rc == r4os.abi.file_stream_result_ok or
        abort_rc == r4os.abi.file_stream_error_not_found)
    {
        clearStoreCleanup(session);
        return r4os.abi.file_stream_result_ok;
    }
    // In particular, retain the exact path after an early R4SYS I/O result:
    // the owner-checked Abort may not have reached the StreamSlot yet.
    setLastError(stats, "stor-cleanup-pending");
    return abort_rc;
}

fn resolveStoreTransfer(app: *const App, session: *Session, stats: *ServiceStats) i32 {
    if (!session.stor_cleanup_pending) return r4os.abi.file_stream_result_ok;
    if (!session.stor_publish_pending) return cleanupStoreStream(app, session, stats);
    const publish_rc = publishStoreStage(app, session);
    if (publish_rc == r4os.r4sys.file_replace_atomic_result_ok) {
        clearStoreCleanup(session);
        return r4os.abi.file_stream_result_ok;
    }
    // Once publication returned I/O, target/stage may already be aliases of
    // the same backend object. Keep the exact owner token and retry only the
    // create-only publish; a path-based Abort cannot safely decide this state.
    setLastError(stats, "stor-publish-pending");
    return publish_rc;
}

fn storeFile(app: *const App, endpoint_handle: u32, session: *Session, stats: *ServiceStats, arg: []const u8) void {
    var path_buf: [path_max]u8 = .{0} ** path_max;
    const path = normalizeFtpPath(session.cwd[0..session.cwd_len], arg, path_buf[0..]) orelse {
        stats.path_errors +%= 1;
        setLastError(stats, "stor-path");
        _ = sendReply(app, session.conn_id, stats, "550 Bad path\r\n");
        return;
    };
    copyFixed(stats.last_path[0..], path);
    if (isDirectSystemWriteBlocked(path)) {
        setLastError(stats, "stor-system-path");
        _ = sendReply(app, session.conn_id, stats, "550 Use the update inbox for system files\r\n");
        return;
    }
    if (isVirtualRoot(path) or driveRootLetter(path) != null) {
        stats.path_errors +%= 1;
        setLastError(stats, "stor-parent");
        _ = sendReply(app, session.conn_id, stats, "550 Target directory unavailable\r\n");
        return;
    }
    switch (parentDirectoryState(app, path)) {
        .found => {},
        .not_found => {
            stats.path_errors +%= 1;
            setLastError(stats, "stor-parent");
            _ = sendReply(app, session.conn_id, stats, "550 Target directory unavailable\r\n");
            return;
        },
        .io => {
            stats.transfer_failures +%= 1;
            setLastError(stats, "stor-parent-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 Target directory lookup failed\r\n");
            return;
        },
    }

    var target_z: [path_max:0]u8 = .{0} ** path_max;
    const target_ptr = copyZ(target_z[0..], path) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Path too long\r\n");
        return;
    };
    var target_info: r4os.abi.FileInfo = .{};
    switch (fileLookup(app, target_ptr, &target_info)) {
        .found => {
            _ = sendReply(app, session.conn_id, stats, "550 Target already exists\r\n");
            return;
        },
        .not_found => {},
        .io => {
            stats.transfer_failures +%= 1;
            setLastError(stats, "stor-target-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 Target lookup failed\r\n");
            return;
        },
    }

    const staging_rc = prepareStoreStagingPaths(app, session, path);
    if (staging_rc != r4os.abi.file_stream_result_ok) {
        stats.transfer_failures +%= 1;
        setLastError(stats, "stor-stage-name");
        _ = sendReply(app, session.conn_id, stats, "451 Upload staging unavailable\r\n");
        return;
    }
    var staged_z: [path_max:0]u8 = .{0} ** path_max;
    @memcpy(
        staged_z[0..session.stor_cleanup_path_len],
        session.stor_cleanup_path[0..session.stor_cleanup_path_len],
    );
    const begin_rc = app.sys.fileStreamBegin(&staged_z, r4os.abi.file_stream_open_create);
    if (begin_rc == r4os.abi.file_stream_result_ok) {
        // Declare the create-only publish intent so the durable claim
        // brackets the WHOLE transfer (0.60.30).  Without it a reset while
        // the payload is still streaming leaves a stage file that nothing
        // can attribute or remove.  Fail-soft on purpose: if the declaration
        // does not take, the upload proceeds exactly as before.
        var declare_target_z: [path_max:0]u8 = .{0} ** path_max;
        var declare_backup_z: [path_max:0]u8 = .{0} ** path_max;
        @memcpy(
            declare_target_z[0..session.stor_target_path_len],
            session.stor_target_path[0..session.stor_target_path_len],
        );
        @memcpy(
            declare_backup_z[0..session.stor_backup_path_len],
            session.stor_backup_path[0..session.stor_backup_path_len],
        );
        _ = app.sys.fileStreamDeclarePublish(
            &staged_z,
            &declare_target_z,
            &declare_backup_z,
            r4os.r4sys.file_stream_publish_protocol_ftp,
        );
    }
    if (begin_rc != r4os.abi.file_stream_result_ok) {
        stats.transfer_failures +%= 1;
        var cleanup_rc: i32 = r4os.abi.file_stream_result_ok;
        if (begin_rc == r4os.abi.file_stream_error_io) {
            // IO is the only ambiguous Begin result: the current
            // ProgramThread may already own a reserved/published StreamSlot.
            // Abort is owner-checked in R4SYS. Deterministic failures such as
            // EXISTS must never abort a different transfer on the same path.
            cleanup_rc = cleanupStoreStream(app, session, stats);
        } else {
            clearStoreCleanup(session);
        }
        setLastError(
            stats,
            if (cleanup_rc == r4os.abi.file_stream_result_ok) "stor-begin" else "stor-begin-cleanup",
        );
        _ = sendReply(app, session.conn_id, stats, "451 Stream begin failed\r\n");
        return;
    }

    _ = sendReply(app, session.conn_id, stats, "150 Opening data connection for upload\r\n");
    const data_conn = openDataConnection(app, session, stats) orelse {
        stats.transfer_failures +%= 1;
        _ = cleanupStoreStream(app, session, stats);
        _ = sendReply(app, session.conn_id, stats, "425 Cannot open data connection\r\n");
        return;
    };

    var offset: u64 = 0;
    var idle_start = app.sys.ticks();
    var buffer: [transfer_chunk_max]u8 = undefined;
    const idle_limit = app.sys.ticksFromMilliseconds(data_idle_ms);
    var read_end: StoreReadEnd = .idle_timeout;
    while (true) {
        if (app.sys.ticks() - idle_start >= idle_limit) {
            read_end = .idle_timeout;
            break;
        }
        // 0.56.39: consume-sicherer Read - der daten-konsumierende
        // Read-Op darf nicht per Service-Timeout verfallen, sonst geht
        // ein bereits ausgefuehrter Read-Chunk verloren (STOR-Tail-
        // Verlust-Befund: exakt tcp_read_max fehlte bei falschem 226).
        var got_raw = app.net.tcpReadWaitServiceConsumeSafe(data_conn, buffer[0..], app.sys.ticksFromMilliseconds(50), tcpServiceWaitTicks(app));
        if (got_raw < 0) {
            switch (tcpReadRecovery(app, data_conn, stats)) {
                .transient => {
                    pumpServiceRequests(app, endpoint_handle, stats);
                    app.sys.sleepTicks(1);
                    continue;
                },
                .closed => {
                    got_raw = app.net.tcpReadService(data_conn, buffer[0..]);
                    if (got_raw > 0) {
                        read_end = .peer_closed;
                    } else {
                        read_end = .peer_closed;
                        break;
                    }
                },
                .failed => read_end = .failed,
            }
            if (got_raw <= 0) break;
        }
        if (got_raw == 0) {
            if (app.sys.ticks() - idle_start >= idle_limit) {
                read_end = .idle_timeout;
                break;
            }
            pumpServiceRequests(app, endpoint_handle, stats);
            app.sys.sleepTicks(1);
            continue;
        }

        idle_start = app.sys.ticks();
        const got: usize = @intCast(got_raw);
        const wrote = app.sys.fileStreamWrite(&staged_z, offset, buffer[0..got], 0);
        if (wrote != @as(i32, @intCast(got))) {
            stats.transfer_failures +%= 1;
            _ = cleanupStoreStream(app, session, stats);
            finishDataConnection(app, session, stats);
            setLastError(stats, "stor-write");
            _ = sendReply(app, session.conn_id, stats, "451 Stream write failed\r\n");
            return;
        }
        offset += got;
        stats.data_bytes_rx +%= got;
        pumpServiceRequests(app, endpoint_handle, stats);
        cooperateTransfer(app, offset);
    }

    if (read_end != .peer_closed) {
        stats.transfer_failures +%= 1;
        _ = cleanupStoreStream(app, session, stats);
        finishDataConnection(app, session, stats);
        if (read_end == .failed) {
            setLastError(stats, "stor-read-fail");
            _ = sendReply(app, session.conn_id, stats, "426 Data connection failed\r\n");
        } else if (read_end == .idle_timeout) {
            setLastError(stats, "stor-read-timeout");
            _ = sendReply(app, session.conn_id, stats, "426 Data connection timeout\r\n");
        }
        return;
    }

    const finish_rc = app.sys.fileStreamFinish(
        &staged_z,
        offset,
        r4os.r4sys.file_stream_finish_keep_ownership,
    );
    finishDataConnection(app, session, stats);
    if (finish_rc != r4os.abi.file_stream_result_ok) {
        stats.transfer_failures +%= 1;
        _ = cleanupStoreStream(app, session, stats);
        setLastError(stats, "stor-finish");
        _ = sendReply(app, session.conn_id, stats, "451 Stream finish failed\r\n");
        return;
    }
    const publish_rc = publishStoreStage(app, session);
    if (publish_rc != r4os.r4sys.file_replace_atomic_result_ok) {
        stats.transfer_failures +%= 1;
        if (publish_rc == r4os.r4sys.file_replace_atomic_error_io) {
            session.stor_publish_pending = true;
            setLastError(stats, "stor-publish-pending");
        } else {
            _ = cleanupStoreStream(app, session, stats);
            setLastError(stats, "stor-publish");
        }
        _ = sendReply(app, session.conn_id, stats, "451 Atomic publish failed\r\n");
        return;
    }
    clearStoreCleanup(session);
    stats.stor_ok +%= 1;
    setLastError(stats, "stor-ok");
    _ = sendReply(app, session.conn_id, stats, "226 Transfer complete\r\n");
}

fn deleteFile(app: *const App, session: *Session, stats: *ServiceStats, arg: []const u8) void {
    var path_buf: [path_max]u8 = .{0} ** path_max;
    const path = normalizeFtpPath(session.cwd[0..session.cwd_len], arg, path_buf[0..]) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Bad path\r\n");
        return;
    };
    copyFixed(stats.last_path[0..], path);
    if (isDirectSystemWriteBlocked(path)) {
        setLastError(stats, "dele-system-path");
        _ = sendReply(app, session.conn_id, stats, "550 Use the update inbox for system files\r\n");
        return;
    }
    var path_z: [path_max:0]u8 = .{0} ** path_max;
    const z = copyZ(path_z[0..], path) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Path too long\r\n");
        return;
    };
    var info: r4os.abi.FileInfo = .{};
    switch (fileLookup(app, z, &info)) {
        .found => {
            if (info.is_dir != 0) {
                _ = sendReply(app, session.conn_id, stats, "550 Target is a directory\r\n");
                return;
            }
        },
        .not_found => {
            _ = sendReply(app, session.conn_id, stats, "550 File unavailable\r\n");
            return;
        },
        .io => {
            setLastError(stats, "dele-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 File lookup failed\r\n");
            return;
        },
    }
    const rc = app.sys.fileDelete(z);
    if (rc > 0) {
        stats.deletes_ok +%= 1;
        setLastError(stats, "dele-ok");
        _ = sendReply(app, session.conn_id, stats, "250 File deleted\r\n");
    } else {
        setLastError(stats, "dele-failed");
        _ = sendReply(app, session.conn_id, stats, "451 Delete failed\r\n");
    }
}

fn renameFrom(app: *const App, session: *Session, stats: *ServiceStats, arg: []const u8) void {
    var path_buf: [path_max]u8 = .{0} ** path_max;
    const path = normalizeFtpPath(session.cwd[0..session.cwd_len], arg, path_buf[0..]) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Bad path\r\n");
        return;
    };
    if (isDirectSystemWriteBlocked(path)) {
        setLastError(stats, "rnfr-system-path");
        _ = sendReply(app, session.conn_id, stats, "550 Use the update inbox for system files\r\n");
        return;
    }
    var path_z: [path_max:0]u8 = .{0} ** path_max;
    const z = copyZ(path_z[0..], path) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Path too long\r\n");
        return;
    };
    var info: r4os.abi.FileInfo = .{};
    switch (fileLookup(app, z, &info)) {
        .found => {},
        .not_found => {
            _ = sendReply(app, session.conn_id, stats, "550 Source unavailable\r\n");
            return;
        },
        .io => {
            setLastError(stats, "rnfr-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 Source lookup failed\r\n");
            return;
        },
    }
    copyPathInto(session.rename_from[0..], &session.rename_from_len, path) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Path too long\r\n");
        return;
    };
    copyFixed(stats.last_path[0..], path);
    setLastError(stats, "rnfr-ok");
    _ = sendReply(app, session.conn_id, stats, "350 Ready for RNTO\r\n");
}

fn renameTo(app: *const App, session: *Session, stats: *ServiceStats, arg: []const u8) void {
    if (session.rename_from_len == 0) {
        _ = sendReply(app, session.conn_id, stats, "503 RNFR required first\r\n");
        return;
    }
    var new_buf: [path_max]u8 = .{0} ** path_max;
    const new_path = normalizeFtpPath(session.cwd[0..session.cwd_len], arg, new_buf[0..]) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Bad path\r\n");
        return;
    };
    if (isDirectSystemWriteBlocked(session.rename_from[0..session.rename_from_len]) or
        isDirectSystemWriteBlocked(new_path))
    {
        setLastError(stats, "rnto-system-path");
        _ = sendReply(app, session.conn_id, stats, "550 Use the update inbox for system files\r\n");
        return;
    }
    if (isVirtualRoot(new_path) or driveRootLetter(new_path) != null) {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Target directory unavailable\r\n");
        return;
    }
    switch (parentDirectoryState(app, new_path)) {
        .found => {},
        .not_found => {
            stats.path_errors +%= 1;
            _ = sendReply(app, session.conn_id, stats, "550 Target directory unavailable\r\n");
            return;
        },
        .io => {
            setLastError(stats, "rnto-parent-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 Target directory lookup failed\r\n");
            return;
        },
    }
    var old_z: [path_max:0]u8 = .{0} ** path_max;
    var new_z: [path_max:0]u8 = .{0} ** path_max;
    const old_ptr = copyZ(old_z[0..], session.rename_from[0..session.rename_from_len]) orelse {
        _ = sendReply(app, session.conn_id, stats, "550 Source path too long\r\n");
        return;
    };
    const new_ptr = copyZ(new_z[0..], new_path) orelse {
        _ = sendReply(app, session.conn_id, stats, "550 Target path too long\r\n");
        return;
    };
    const rc = app.sys.fileRename(old_ptr, new_ptr);
    session.rename_from_len = 0;
    if (rc > 0) {
        stats.renames_ok +%= 1;
        copyFixed(stats.last_path[0..], new_path);
        setLastError(stats, "rnto-ok");
        _ = sendReply(app, session.conn_id, stats, "250 Rename successful\r\n");
    } else {
        setLastError(stats, "rnto-failed");
        _ = sendReply(app, session.conn_id, stats, "451 Rename failed\r\n");
    }
}

fn replySize(app: *const App, session: *Session, stats: *ServiceStats, arg: []const u8) void {
    var path_buf: [path_max]u8 = .{0} ** path_max;
    const path = normalizeFtpPath(session.cwd[0..session.cwd_len], arg, path_buf[0..]) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Bad path\r\n");
        return;
    };
    var path_z: [path_max:0]u8 = .{0} ** path_max;
    const z = copyZ(path_z[0..], path) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Path too long\r\n");
        return;
    };
    var info: r4os.abi.FileInfo = .{};
    switch (fileLookup(app, z, &info)) {
        .found => {},
        .not_found => {
            _ = sendReply(app, session.conn_id, stats, "550 File unavailable\r\n");
            return;
        },
        .io => {
            setLastError(stats, "size-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 File lookup failed\r\n");
            return;
        },
    }
    if (info.is_dir != 0) {
        _ = sendReply(app, session.conn_id, stats, "550 File unavailable\r\n");
        return;
    }
    var reply: [64]u8 = .{0} ** 64;
    var pos: usize = 0;
    _ = appendText(reply[0..], &pos, "213 ");
    _ = appendU64(reply[0..], &pos, info.size);
    _ = appendText(reply[0..], &pos, "\r\n");
    _ = sendReply(app, session.conn_id, stats, reply[0..pos]);
}

fn makeDirectory(app: *const App, session: *Session, stats: *ServiceStats, arg: []const u8) void {
    var path_buf: [path_max]u8 = .{0} ** path_max;
    const path = normalizeFtpPath(session.cwd[0..session.cwd_len], arg, path_buf[0..]) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Bad path\r\n");
        return;
    };
    if (isDirectoryCreateBlocked(path)) {
        setLastError(stats, "mkd-system-path");
        _ = sendReply(app, session.conn_id, stats, "550 Use the update inbox for system files\r\n");
        return;
    }
    if (isVirtualRoot(path) or driveRootLetter(path) != null) {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Parent directory unavailable\r\n");
        return;
    }
    switch (parentDirectoryState(app, path)) {
        .found => {},
        .not_found => {
            stats.path_errors +%= 1;
            _ = sendReply(app, session.conn_id, stats, "550 Parent directory unavailable\r\n");
            return;
        },
        .io => {
            setLastError(stats, "mkd-parent-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 Parent directory lookup failed\r\n");
            return;
        },
    }
    var path_z: [path_max:0]u8 = .{0} ** path_max;
    const z = copyZ(path_z[0..], path) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Path too long\r\n");
        return;
    };
    var existing: r4os.abi.FileInfo = .{};
    switch (fileLookup(app, z, &existing)) {
        .found => {
            _ = sendReply(app, session.conn_id, stats, "550 Target already exists\r\n");
            return;
        },
        .not_found => {},
        .io => {
            setLastError(stats, "mkd-target-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 Target lookup failed\r\n");
            return;
        },
    }
    const rc = app.sys.dirCreate(z);
    if (rc > 0) {
        stats.mkdir_ok +%= 1;
        copyFixed(stats.last_path[0..], path);
        setLastError(stats, "mkd-ok");
        _ = sendReply(app, session.conn_id, stats, "257 Directory created\r\n");
    } else {
        setLastError(stats, "mkd-failed");
        _ = sendReply(app, session.conn_id, stats, "451 MKD failed\r\n");
    }
}

fn removeDirectory(app: *const App, session: *Session, stats: *ServiceStats, arg: []const u8) void {
    var path_buf: [path_max]u8 = .{0} ** path_max;
    const path = normalizeFtpPath(session.cwd[0..session.cwd_len], arg, path_buf[0..]) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Bad path\r\n");
        return;
    };
    if (isVirtualRoot(path) or driveRootLetter(path) != null) {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Directory unavailable\r\n");
        return;
    }
    if (isDirectSystemWriteBlocked(path)) {
        setLastError(stats, "rmd-system-path");
        _ = sendReply(app, session.conn_id, stats, "550 Use the update inbox for system files\r\n");
        return;
    }
    var path_z: [path_max:0]u8 = .{0} ** path_max;
    const z = copyZ(path_z[0..], path) orelse {
        stats.path_errors +%= 1;
        _ = sendReply(app, session.conn_id, stats, "550 Path too long\r\n");
        return;
    };
    var info: r4os.abi.FileInfo = .{};
    switch (fileLookup(app, z, &info)) {
        .found => {
            if (info.is_dir == 0) {
                _ = sendReply(app, session.conn_id, stats, "550 Target is not a directory\r\n");
                return;
            }
        },
        .not_found => {
            _ = sendReply(app, session.conn_id, stats, "550 Directory unavailable\r\n");
            return;
        },
        .io => {
            setLastError(stats, "rmd-lookup");
            _ = sendReply(app, session.conn_id, stats, "451 Directory lookup failed\r\n");
            return;
        },
    }
    const rc = app.sys.dirDelete(z);
    if (rc > 0) {
        stats.rmdir_ok +%= 1;
        copyFixed(stats.last_path[0..], path);
        setLastError(stats, "rmd-ok");
        _ = sendReply(app, session.conn_id, stats, "250 Directory removed\r\n");
    } else {
        setLastError(stats, "rmd-failed");
        _ = sendReply(app, session.conn_id, stats, "451 RMD failed\r\n");
    }
}

fn openDataConnection(app: *const App, session: *Session, stats: *ServiceStats) ?u32 {
    switch (session.data_mode) {
        .none => return null,
        .passive => {
            if (!session.passive_open) return null;
            const wait_limit = app.sys.ticksFromMilliseconds(data_accept_wait_ms);
            const start = app.sys.ticks();
            while (app.sys.ticks() - start < wait_limit) {
                var accept: r4os.abi.TcpAcceptResult = .{};
                var structured: r4os.abi.NetServiceTcpResult = .{};
                const rc = app.net.tcpAcceptPollServiceResultWait(session.passive_port, &accept, &structured, tcpServiceWaitTicks(app));
                stats.last_tcp_result = if (rc == 0) structured.result else rc;
                if (rc == 1 and accept.conn_id != 0 and structured.result == r4os.abi.tcp_result_ok) {
                    session.data_conn_id = accept.conn_id;
                    closePassiveListener(app, session, stats);
                    stats.data_accepts +%= 1;
                    setLastError(stats, "data-accept");
                    return accept.conn_id;
                }
                if (rc < 0 or (rc != 0 and structured.result != r4os.abi.tcp_result_ok)) {
                    stats.tcp_errors +%= 1;
                    setLastError(stats, "data-accept-fail");
                    break;
                }
                app.sys.sleepTicks(1);
            }
            closeDataSetup(app, session, stats);
            return null;
        },
        .active => {
            var result: r4os.abi.NetServiceTcpResult = .{};
            const rc = app.net.tcpConnectServiceResult(session.active_ip[0], session.active_ip[1], session.active_ip[2], session.active_ip[3], session.active_port, &result);
            stats.last_tcp_result = if (rc > 0) result.result else rc;
            if (rc > 0 and result.result == r4os.abi.tcp_result_ok and result.handle != 0) {
                session.data_conn_id = result.handle;
                stats.data_connects +%= 1;
                setLastError(stats, "data-connect");
                return result.handle;
            }
            stats.tcp_errors +%= 1;
            closeDataSetup(app, session, stats);
            setLastError(stats, "data-connect-fail");
            return null;
        },
    }
}

fn finishDataConnection(app: *const App, session: *Session, stats: *ServiceStats) void {
    if (session.data_conn_id != 0) {
        closeTcpHandle(app, session.data_conn_id);
        session.data_conn_id = 0;
    }
    closePassiveListener(app, session, stats);
    resetDataState(session);
}

fn closeDataSetup(app: *const App, session: *Session, stats: *ServiceStats) void {
    if (session.data_conn_id != 0) {
        closeTcpHandle(app, session.data_conn_id);
        session.data_conn_id = 0;
    }
    closePassiveListener(app, session, stats);
    resetDataState(session);
}

fn abortData(app: *const App, session: *Session, stats: *ServiceStats, reason: []const u8) void {
    if (session.data_conn_id != 0 or session.passive_open or session.data_mode != .none) {
        stats.transfer_aborts +%= 1;
        setLastError(stats, reason);
    }
    closeDataSetup(app, session, stats);
}

fn closePassiveListener(app: *const App, session: *Session, stats: *ServiceStats) void {
    if (!session.passive_open) return;
    var result: r4os.abi.NetServiceTcpResult = .{};
    const rc = app.net.tcpCloseListenServiceResultWait(session.passive_port, &result, tcpServiceWaitTicks(app));
    stats.last_tcp_result = if (rc == 0) result.result else rc;
    session.passive_open = false;
}

fn resetDataState(session: *Session) void {
    session.data_mode = .none;
    session.passive_port = passive_data_port;
    session.passive_ip = .{0} ** 4;
    session.active_ip = .{0} ** 4;
    session.active_port = 0;
}

fn sendData(app: *const App, conn_id: u32, stats: *ServiceStats, data: []const u8) bool {
    if (data.len == 0) return true;
    const wrote = app.net.tcpWritePacedServiceBounded(conn_id, data, app.sys.ticksFromMilliseconds(tcp_write_wait_ms), tcpServiceWaitTicks(app));
    if (wrote != @as(i32, @intCast(data.len))) {
        stats.tcp_errors +%= 1;
        stats.last_tcp_result = wrote;
        setLastError(stats, "data-write");
        return false;
    }
    stats.bytes_tx +%= data.len;
    stats.data_bytes_tx +%= data.len;
    return true;
}

fn pumpServiceRequests(app: *const App, endpoint_handle: u32, stats: *ServiceStats) void {
    if (endpoint_handle == 0) return;
    const poll = app.sys.serviceEndpointPoll(endpoint_handle);
    if (poll > 0) _ = handleRequest(app, endpoint_handle, stats);
}

fn cooperateTransfer(app: *const App, offset: u64) void {
    if (offset != 0 and offset % (transfer_chunk_max * 8) == 0) {
        app.sys.sleepTicks(1);
    } else {
        app.sys.taskYield();
    }
}

fn parentDirectoryState(app: *const App, path: []const u8) FileLookupState {
    if (path.len <= 3) return .not_found;
    var end = path.len;
    while (end > 3) : (end -= 1) {
        if (isPathSeparator(path[end - 1])) {
            const parent_len = if (end <= 4) 3 else end - 1;
            return directoryState(app, path[0..parent_len]);
        }
    }
    return .not_found;
}

fn parsePortArgument(arg_raw: []const u8, out_ip: *[4]u8, out_port: *u16) bool {
    const arg = trim(arg_raw);
    var values: [6]u16 = .{0} ** 6;
    var index: usize = 0;
    var start: usize = 0;
    while (start <= arg.len and index < values.len) {
        var end = start;
        while (end < arg.len and arg[end] != ',') : (end += 1) {}
        const token = trim(arg[start..end]);
        values[index] = parseDecimalU16(token) orelse return false;
        if (values[index] > 255) return false;
        index += 1;
        if (end >= arg.len) break;
        start = end + 1;
    }
    if (index != values.len) return false;
    out_ip.* = .{
        @intCast(values[0]),
        @intCast(values[1]),
        @intCast(values[2]),
        @intCast(values[3]),
    };
    out_port.* = @intCast(values[4] * 256 + values[5]);
    return true;
}

fn parseDecimalU16(text: []const u8) ?u16 {
    if (text.len == 0) return null;
    var value: u32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch < '0' or ch > '9') return null;
        value = value * 10 + @as(u32, ch - '0');
        if (value > 65535) return null;
    }
    return @intCast(value);
}

fn appendIpTuple(dest: []u8, pos: *usize, ip: [4]u8) void {
    _ = appendU64(dest, pos, @intCast(ip[0]));
    _ = appendByte(dest, pos, ',');
    _ = appendU64(dest, pos, @intCast(ip[1]));
    _ = appendByte(dest, pos, ',');
    _ = appendU64(dest, pos, @intCast(ip[2]));
    _ = appendByte(dest, pos, ',');
    _ = appendU64(dest, pos, @intCast(ip[3]));
}

fn isZeroIp(ip: [4]u8) bool {
    return ip[0] == 0 and ip[1] == 0 and ip[2] == 0 and ip[3] == 0;
}

fn waitForListen(app: *const App, stats: *ServiceStats) bool {
    var waited: u32 = 0;
    while (waited < listen_wait_ticks) : (waited += 1) {
        var result: r4os.abi.NetServiceTcpResult = .{};
        const rc = app.net.tcpListenServiceResultWait(listen_port, &result, tcpServiceWaitTicks(app));
        stats.last_tcp_result = if (rc == 0) result.result else rc;
        if (rc == 0 and result.result == r4os.abi.tcp_result_ok) {
            stats.listen_ready = 1;
            setLastError(stats, "listen-ready");
            app.sys.println("FTPSVC listen 21: ready");
            return true;
        }
        if (waited == 0) app.sys.println("FTPSVC waiting for TCPSVC/network on port 21");
        app.sys.sleepTicks(1);
    }
    stats.tcp_errors +%= 1;
    setLastError(stats, "listen-timeout");
    return false;
}

fn closeListener(app: *const App, stats: *ServiceStats) void {
    var result: r4os.abi.NetServiceTcpResult = .{};
    const rc = app.net.tcpCloseListenServiceResultWait(listen_port, &result, tcpServiceWaitTicks(app));
    stats.last_tcp_result = if (rc == 0) result.result else rc;
}

fn closeSession(app: *const App, session: *Session, stats: *ServiceStats, reason: []const u8) void {
    if (session.stor_cleanup_pending) {
        _ = resolveStoreTransfer(app, session, stats);
    }
    if (!session.active) return;
    closeDataSetup(app, session, stats);
    closeTcpHandle(app, session.conn_id);
    session.active = false;
    session.conn_id = 0;
    session.line_len = 0;
    session.rename_from_len = 0;
    stats.active_sessions = 0;
    stats.closed +%= 1;
    setLastError(stats, reason);
}

fn closeTcpHandle(app: *const App, conn_id: u32) void {
    if (conn_id == 0) return;
    var result: r4os.abi.NetServiceTcpResult = .{};
    const rc = app.net.tcpCloseServiceResultWait(conn_id, &result, tcpServiceWaitTicks(app));
    if (rc != 0 or result.result != r4os.abi.tcp_result_ok) {
        _ = app.net.tcpAbortServiceWait(conn_id, tcpServiceWaitTicks(app));
    }
}

fn sendReply(app: *const App, conn_id: u32, stats: *ServiceStats, text: []const u8) bool {
    if (text.len == 0) return true;
    const wrote = app.net.tcpWritePacedServiceBounded(conn_id, text, app.sys.ticksFromMilliseconds(tcp_write_wait_ms), tcpServiceWaitTicks(app));
    if (wrote != @as(i32, @intCast(text.len))) {
        stats.tcp_write_transients +%= 1;
        stats.tcp_errors +%= 1;
        stats.last_tcp_result = wrote;
        setLastError(stats, "write");
        return false;
    }
    stats.bytes_tx +%= text.len;
    return true;
}

fn tcpServiceWaitTicks(app: *const App) u64 {
    return app.sys.ticksFromMilliseconds(tcp_service_wait_ms);
}

fn tcpReadTransientRecoverable(app: *const App, conn_id: u32, stats: *ServiceStats) bool {
    return tcpReadRecovery(app, conn_id, stats) == .transient;
}

fn tcpReadRecovery(app: *const App, conn_id: u32, stats: *ServiceStats) TcpReadRecovery {
    var poll: r4os.abi.NetServiceTcpResult = .{};
    const rc = app.net.tcpPollServiceWait(conn_id, &poll, tcpServiceWaitTicks(app));
    if (rc != 0) {
        noteTcpTransient(stats, null, rc, .read);
        return .transient;
    }
    noteTcpPollStats(stats, &poll);
    if (tcpPollConnectionClosed(&poll)) return .closed;
    if (tcpServiceTransientResult(&poll)) {
        noteTcpTransient(stats, &poll, poll.result, .read);
        return .transient;
    }
    if ((poll.flags & r4os.abi.net_service_tcp_flag_handle_valid) == 0) return .failed;
    if ((poll.flags & r4os.abi.net_service_tcp_flag_conn_valid) == 0) return .failed;
    stats.tcp_service_transients +%= 1;
    stats.tcp_read_transients +%= 1;
    return .transient;
}

const TcpTransientKind = enum {
    read,
    write,
};

fn noteTcpTransient(stats: *ServiceStats, poll: ?*const r4os.abi.NetServiceTcpResult, fallback_result: i32, kind: TcpTransientKind) void {
    stats.tcp_service_transients +%= 1;
    switch (kind) {
        .read => stats.tcp_read_transients +%= 1,
        .write => stats.tcp_write_transients +%= 1,
    }
    stats.last_tcp_result = fallback_result;
    if (poll) |p| noteTcpPollStats(stats, p);
}

fn noteTcpPollStats(stats: *ServiceStats, poll: *const r4os.abi.NetServiceTcpResult) void {
    stats.last_tcp_flags = poll.flags;
    stats.last_tcp_service_status = tcpServiceStatusCode(poll);
    stats.last_tcp_lifecycle = poll.lifecycle_cause;
    stats.last_tcp_result = poll.result;
}

fn tcpServiceStatusCode(result: *const r4os.abi.NetServiceTcpResult) u32 {
    if (result.service_status != 0) return result.service_status;
    return (result.flags & r4os.abi.net_service_status_mask) >> r4os.abi.net_service_status_shift;
}

fn tcpServiceTransientResult(result: *const r4os.abi.NetServiceTcpResult) bool {
    const status = tcpServiceStatusCode(result);
    if (status != r4os.abi.net_service_status_failed and status != r4os.abi.net_service_status_timeout) return false;
    if ((result.flags & r4os.abi.net_service_tcp_flag_handle_valid) != 0) return false;
    if ((result.flags & r4os.abi.net_service_tcp_flag_conn_valid) != 0) return false;
    return true;
}

fn tcpPollConnectionClosed(result: *const r4os.abi.NetServiceTcpResult) bool {
    if (result.pending_rx != 0) return false;
    if (tcpLifecycleTerminal(result.lifecycle_cause)) return true;
    const status = tcpServiceStatusCode(result);
    if (result.result != 0 and status != r4os.abi.net_service_status_would_block and status != r4os.abi.net_service_status_timeout) return true;
    if (status == r4os.abi.net_service_status_would_block or result.lifecycle_cause == r4os.abi.net_service_socket_lifecycle_would_block) return false;
    if ((result.flags & r4os.abi.net_service_tcp_flag_handle_valid) == 0) return true;
    if ((result.flags & r4os.abi.net_service_tcp_flag_conn_valid) == 0) return true;
    return false;
}

fn tcpLifecycleTerminal(cause: u32) bool {
    return switch (cause) {
        r4os.abi.net_service_socket_lifecycle_closed,
        r4os.abi.net_service_socket_lifecycle_reset,
        r4os.abi.net_service_socket_lifecycle_peer_gone,
        r4os.abi.net_service_socket_lifecycle_local_abort,
        r4os.abi.net_service_socket_lifecycle_local_close,
        r4os.abi.net_service_socket_lifecycle_bad_handle,
        r4os.abi.net_service_socket_lifecycle_owner_mismatch,
        r4os.abi.net_service_socket_lifecycle_dropped,
        => true,
        else => false,
    };
}

fn fileLookup(app: *const App, path: [*:0]const u8, out: *r4os.abi.FileInfo) FileLookupState {
    out.* = .{};
    const rc = app.sys.fileInfoRaw(path, out);
    if (rc < 0) return .io;
    if (rc == 0 or out.exists == 0) return .not_found;
    return .found;
}

fn directoryState(app: *const App, path: []const u8) FileLookupState {
    if (isVirtualRoot(path)) return .found;
    if (driveRootLetter(path)) |letter| {
        const index = driveIndexFromLetter(letter) orelse return .not_found;
        const info = app.sys.driveInfo(index) orelse return .not_found;
        return if (info.mounted != 0) .found else .not_found;
    }
    var path_z: [path_max:0]u8 = .{0} ** path_max;
    const z = copyZ(path_z[0..], path) orelse return .io;
    var info: r4os.abi.FileInfo = .{};
    return switch (fileLookup(app, z, &info)) {
        .found => if (info.is_dir != 0) .found else .not_found,
        .not_found => .not_found,
        .io => .io,
    };
}

fn normalizeFtpPath(cwd_raw: []const u8, arg_raw: []const u8, out: []u8) ?[]const u8 {
    const arg = trim(arg_raw);
    const cwd = trim(cwd_raw);
    if (arg.len == 0 or equalsBytes(arg, ".")) {
        if (cwd.len == 0) return setVirtualRoot(out);
        return copyPath(out, cwd);
    }
    if (isVirtualRootArg(arg)) return setVirtualRoot(out);

    if (splitDriveSelector(arg)) |drive| {
        return buildDrivePath(drive.letter, drive.rest, out);
    }

    if (isPathSeparator(arg[0])) {
        const rest = skipLeadingSeparators(arg);
        if (rest.len == 0) return setVirtualRoot(out);
        if (splitDriveSelector(rest)) |drive| return buildDrivePath(drive.letter, drive.rest, out);
        return null;
    }

    if (isVirtualRoot(cwd)) {
        if (equalsBytes(arg, "..")) return setVirtualRoot(out);
        return null;
    }

    var len: usize = 0;
    if (!appendText(out, &len, cwd)) return null;
    if (!appendNormalizedSegments(out, &len, arg)) return null;
    return out[0..len];
}

const DriveSelector = struct {
    letter: u8,
    rest: []const u8,
};

fn splitDriveSelector(text: []const u8) ?DriveSelector {
    if (text.len == 0) return null;
    const letter = upper(text[0]);
    if (letter < 'A' or letter > 'Z') return null;
    if (text.len == 1) return .{ .letter = letter, .rest = "" };
    if (text[1] == ':') {
        var rest = text[2..];
        if (rest.len != 0 and isPathSeparator(rest[0])) rest = skipLeadingSeparators(rest);
        return .{ .letter = letter, .rest = rest };
    }
    if (isPathSeparator(text[1])) {
        return .{ .letter = letter, .rest = skipLeadingSeparators(text[1..]) };
    }
    return null;
}

fn buildDrivePath(letter_raw: u8, rest: []const u8, out: []u8) ?[]const u8 {
    const letter = upper(letter_raw);
    if (letter < 'A' or letter > 'Z' or out.len < 3) return null;
    out[0] = letter;
    out[1] = ':';
    out[2] = '\\';
    var len: usize = 3;
    if (!appendNormalizedSegments(out, &len, rest)) return null;
    return out[0..len];
}

fn appendNormalizedSegments(out: []u8, len: *usize, text: []const u8) bool {
    var start: usize = 0;
    while (start < text.len) {
        while (start < text.len and isPathSeparator(text[start])) : (start += 1) {}
        const seg_start = start;
        while (start < text.len and !isPathSeparator(text[start])) : (start += 1) {}
        const segment = text[seg_start..start];
        if (segment.len == 0 or equalsBytes(segment, ".")) continue;
        if (equalsBytes(segment, "..")) {
            popPathSegment(out, len);
            continue;
        }
        if (len.* > 3 and !appendByte(out, len, '\\')) return false;
        if (!appendText(out, len, segment)) return false;
    }
    return true;
}

fn popPathSegment(out: []const u8, len: *usize) void {
    if (len.* <= 3) {
        len.* = 3;
        return;
    }
    var i = len.*;
    while (i > 3) : (i -= 1) {
        if (isPathSeparator(out[i - 1])) {
            len.* = if (i <= 4) 3 else i - 1;
            return;
        }
    }
    len.* = 3;
}

fn dosToFtpPath(path: []const u8, out: []u8) ?[]const u8 {
    if (isVirtualRoot(path)) return setVirtualRoot(out);
    if (path.len < 3 or path[1] != ':' or !isPathSeparator(path[2])) return null;
    var len: usize = 0;
    if (!appendByte(out, &len, '/')) return null;
    if (!appendByte(out, &len, upper(path[0]))) return null;
    if (path.len > 3 and !appendByte(out, &len, '/')) return null;
    var i: usize = 3;
    while (i < path.len) : (i += 1) {
        const ch = if (isPathSeparator(path[i])) '/' else path[i];
        if (!appendByte(out, &len, ch)) return null;
    }
    return out[0..len];
}

fn setVirtualRoot(out: []u8) ?[]const u8 {
    if (out.len < 1) return null;
    out[0] = '/';
    return out[0..1];
}

fn isVirtualRoot(path: []const u8) bool {
    return path.len == 1 and path[0] == '/';
}

fn isVirtualRootArg(arg: []const u8) bool {
    if (arg.len == 0) return false;
    var i: usize = 0;
    while (i < arg.len) : (i += 1) {
        if (!isPathSeparator(arg[i])) return false;
    }
    return true;
}

fn driveRootLetter(path: []const u8) ?u8 {
    if (path.len != 3 or path[1] != ':' or !isPathSeparator(path[2])) return null;
    const letter = upper(path[0]);
    if (letter < 'A' or letter > 'Z') return null;
    return letter;
}

fn driveIndexFromLetter(letter_raw: u8) ?u32 {
    const letter = upper(letter_raw);
    if (letter < 'A' or letter > 'Z') return null;
    return @intCast(letter - 'A');
}

fn baseName(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (isPathSeparator(path[i - 1])) return path[i..];
    }
    if (path.len >= 2 and path[1] == ':') return path[2..];
    return path;
}

fn isPathSeparator(ch: u8) bool {
    return ch == '\\' or ch == '/';
}

fn isDirectSystemWriteBlocked(path: []const u8) bool {
    if (isUpdateInboxFilePath(path)) return false;
    return isPathAtOrBelow(path, "C:\\R4OS") or
        isPathAtOrBelow(path, "C:\\BOOT") or
        isPathAtOrBelow(path, "C:\\EFI") or
        isPathAtOrBelow(path, "C:\\LIMINE") or
        // create-system exposes the FAT32 boot volume as D:, while the
        // updater addresses the same volume through its private /boot mount.
        isPathAtOrBelow(path, "D:\\BOOT") or
        isPathAtOrBelow(path, "D:\\EFI") or
        isPathAtOrBelow(path, "D:\\LIMINE");
}

fn isDirectoryCreateBlocked(path: []const u8) bool {
    if (isUpdateDirectoryPath(path)) return false;
    return isDirectSystemWriteBlocked(path);
}

fn isUpdateInboxFilePath(path: []const u8) bool {
    return startsWithIgnoreCase(path, "C:\\R4OS\\UPDATE\\INBOX\\");
}

fn isUpdateDirectoryPath(path: []const u8) bool {
    return equalsIgnoreCase(path, "C:\\R4OS\\UPDATE") or
        equalsIgnoreCase(path, "C:\\R4OS\\UPDATE\\INBOX") or
        startsWithIgnoreCase(path, "C:\\R4OS\\UPDATE\\INBOX\\");
}

fn isPathAtOrBelow(path: []const u8, root: []const u8) bool {
    if (equalsIgnoreCase(path, root)) return true;
    return path.len > root.len and
        path[root.len] == '\\' and
        startsWithIgnoreCase(path, root);
}

fn skipLeadingSeparators(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and isPathSeparator(text[start])) : (start += 1) {}
    return text[start..];
}

fn runPingClient(app: *const App) i32 {
    app.sys.println("FTPSVC ping");
    var info: r4os.abi.ServiceInfo = .{};
    const handle = waitServiceOpen(app, &info, 120) orelse {
        app.sys.println("FTPSVC ping failed: service not open");
        return 1;
    };
    var response_header: r4os.abi.ServiceMessageHeader = .{};
    var response: [32]u8 = undefined;
    const got = app.sys.serviceCall(handle, op_ping, "PING", &response_header, response[0..], 120);
    _ = app.sys.serviceClose(handle);
    if (got != 11 or response_header.status != r4os.abi.service_api_result_ok or !bytesEq(response[0..11], "FTPSVC PONG")) {
        app.sys.println("FTPSVC ping failed");
        return 1;
    }
    app.sys.println("FTPSVC ping: OK");
    return 0;
}

fn runStatusClient(app: *const App) i32 {
    var info: r4os.abi.ServiceInfo = .{};
    const handle = waitServiceOpen(app, &info, 120) orelse {
        app.sys.println("FTPSVC status failed: service not open");
        return 1;
    };
    var response_header: r4os.abi.ServiceMessageHeader = .{};
    var response: [r4os.abi.service_api_max_payload]u8 = undefined;
    const got = app.sys.serviceCall(handle, op_status, "STATUS", &response_header, response[0..], 120);
    _ = app.sys.serviceClose(handle);
    if (got <= 0 or response_header.status != r4os.abi.service_api_result_ok) {
        app.sys.println("FTPSVC status failed");
        return 1;
    }
    app.sys.write("FTPSVC status: ");
    app.sys.write(response[0..@intCast(got)]);
    app.sys.println("");
    return 0;
}

fn runSelfTest(app: *const App) i32 {
    app.sys.println("FTPSVC selftest");
    if (!expectNormalize(app, "/", "/", "/")) return 1;
    if (!expectNormalize(app, "/", "C", "C:\\")) return 1;
    if (!expectNormalize(app, "/", "/C/R4OS", "C:\\R4OS")) return 1;
    if (!expectNormalize(app, "/", "C:/R4OS", "C:\\R4OS")) return 1;
    if (!expectNormalize(app, "C:\\R4OS", "..", "C:\\")) return 1;
    if (!expectNormalize(app, "C:\\", "R4OS//CONFIG", "C:\\R4OS\\CONFIG")) return 1;
    if (!expectNormalize(app, "C:\\R4OS", ".\\CONFIG\\..\\SERVICES", "C:\\R4OS\\SERVICES")) return 1;
    if (!expectDisplayPath(app, "C:\\", "/C")) return 1;
    if (!expectDisplayPath(app, "C:\\R4OS", "/C/R4OS")) return 1;
    app.sys.println("FTPSVC selftest: OK");
    return 0;
}

fn expectNormalize(app: *const App, cwd: []const u8, input: []const u8, expected: []const u8) bool {
    var out: [path_max]u8 = .{0} ** path_max;
    const got = normalizeFtpPath(cwd, input, out[0..]) orelse {
        app.sys.write("FTPSVC selftest FAILED normalize-null input=");
        app.sys.println(input);
        return false;
    };
    if (!bytesEq(got, expected)) {
        app.sys.write("FTPSVC selftest FAILED normalize input=");
        app.sys.write(input);
        app.sys.write(" got=");
        app.sys.write(got);
        app.sys.write(" expected=");
        app.sys.println(expected);
        return false;
    }
    return true;
}

fn expectDisplayPath(app: *const App, path: []const u8, expected: []const u8) bool {
    var out: [path_max]u8 = .{0} ** path_max;
    const got = dosToFtpPath(path, out[0..]) orelse {
        app.sys.write("FTPSVC selftest FAILED display-null input=");
        app.sys.println(path);
        return false;
    };
    if (!bytesEq(got, expected)) {
        app.sys.write("FTPSVC selftest FAILED display input=");
        app.sys.write(path);
        app.sys.write(" got=");
        app.sys.write(got);
        app.sys.write(" expected=");
        app.sys.println(expected);
        return false;
    }
    return true;
}

fn waitServiceOpen(app: *const App, info: *r4os.abi.ServiceInfo, max_ticks: u32) ?u32 {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const rc = app.sys.serviceOpen(service_name, info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) return info.handle;
        app.sys.sleepTicks(1);
    }
    return null;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn copyPath(out: []u8, src: []const u8) ?[]const u8 {
    if (src.len > out.len) return null;
    if (src.len != 0) @memcpy(out[0..src.len], src);
    return out[0..src.len];
}

fn copyPathInto(out: []u8, out_len: *usize, src: []const u8) ?void {
    if (src.len > out.len) return null;
    @memset(out, 0);
    if (src.len != 0) @memcpy(out[0..src.len], src);
    out_len.* = src.len;
}

fn copyZ(out: [:0]u8, text: []const u8) ?[*:0]const u8 {
    if (text.len >= out.len) return null;
    if (text.len != 0) @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return @ptrCast(out.ptr);
}

fn copyFixed(dest: []u8, src: []const u8) void {
    if (dest.len == 0) return;
    @memset(dest, 0);
    const len = @min(dest.len - 1, src.len);
    if (len != 0) @memcpy(dest[0..len], src[0..len]);
}

fn spanZ(value: []const u8) []const u8 {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}
    return s[start..end];
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    return equalsIgnoreCase(text[0..prefix.len], prefix);
}

fn equalsBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn bytesEq(a: []const u8, b: []const u8) bool {
    return equalsBytes(a, b);
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn appendText(dest: []u8, pos: *usize, value: []const u8) bool {
    if (value.len > dest.len - pos.*) return false;
    if (value.len != 0) @memcpy(dest[pos.* .. pos.* + value.len], value);
    pos.* += value.len;
    return true;
}

fn appendByte(dest: []u8, pos: *usize, value: u8) bool {
    if (pos.* >= dest.len) return false;
    dest[pos.*] = value;
    pos.* += 1;
    return true;
}

fn appendU64(dest: []u8, pos: *usize, value: u64) bool {
    var tmp: [20]u8 = undefined;
    var n = value;
    var out_pos = tmp.len;
    if (n == 0) {
        out_pos -= 1;
        tmp[out_pos] = '0';
    } else {
        while (n > 0 and out_pos > 0) {
            out_pos -= 1;
            tmp[out_pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
    }
    return appendText(dest, pos, tmp[out_pos..]);
}

fn appendI64(dest: []u8, pos: *usize, value: i64) bool {
    if (value < 0) {
        if (!appendByte(dest, pos, '-')) return false;
        return appendU64(dest, pos, @intCast(-value));
    }
    return appendU64(dest, pos, @intCast(value));
}

fn setLastError(stats: *ServiceStats, label: []const u8) void {
    copyFixed(stats.last_error[0..], label);
}
