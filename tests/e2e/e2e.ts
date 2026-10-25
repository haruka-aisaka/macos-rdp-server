#!/usr/bin/env -S deno run --allow-run --allow-read --allow-write --allow-env
/**
 * macos-rdp-server の E2E テスト（この Mac の中だけで完結する）。
 *
 *   deno run -A tests/e2e/e2e.ts [--only 名前,名前] [--keep-server]
 *   deno run -A tests/e2e/e2e.ts --serve [--keep 秒] [--log debug] [--env K=V]...   テスト用サーバを起動して残す（クライアントの E2E 用）
 *   deno run -A tests/e2e/e2e.ts --stop                テスト用サーバを止める
 *
 * いま入っているサーバ（~/.macos-rdp/bin/macos-rdp-daemon）を、本番の LaunchAgent とは別のラベル
 * （com.macosrdp.e2e）で 127.0.0.1:3390 に起動し、テスト用クライアント（rdp-e2e-client、Homebrew の
 * FreeRDP で動く）でつないで確かめる。画面収録などの許可はバイナリの場所と署名に付いているので、
 * 同じバイナリを使えば許可を取り直さずに済む。本番（3389）は止めない。
 *
 * 確かめること:
 *   connect      接続して画面が届く。Retina の仮想ディスプレイがメインになる。ポインタが狙った所へ行く
 *   resize       表示制御チャネルでの大きさ・拡大率の変更に、画面とストリームが追従する
 *   audio        Mac で鳴らした正弦波が、崩れずに（周波数・SN 比・途切れ）届く
 *   audio-silence 音が止まったら音声を送らず、次に鳴った音は欠けずに届く
 *   audio-aac    省データの AAC で、音声が 1/10 以下の量で崩れずに届く
 *   reconnect    きれいな切断・強制切断のあと、同じ仮想ディスプレイを使い回して何度でもつなげる
 *   takeover     前の接続が残ったまま新しい接続が来ると、新しい方に切り替わる
 *   rescale      つなぎ直したときに頼んだ拡大率（Retina / 等倍）が反映される
 *   bitmap-resize H.264 を使わないクライアントで、送信中に大きさを続けて変えても落ちない
 *   idle         放置すると仮想ディスプレイを解放してプロセスが終わり、launchd が起動し直す。その後もつながる
 *
 * 前提: brew install freerdp（クライアントとして使うだけ）。Deno。
 */

import { analyzeTone, TONE_HZ, TONE_SECONDS, writeToneWav } from "./tone.ts";

const HOME = Deno.env.get("HOME")!;
const HERE = new URL(".", import.meta.url).pathname;
const WORK = "/tmp/rdp-e2e";
const BIN = `${HOME}/.macos-rdp/bin/macos-rdp-daemon`;
const LABEL = "com.macosrdp.e2e";
const PLIST = `${HOME}/Library/LaunchAgents/${LABEL}.plist`;
const PORT = 3390;
// 無接続でこの秒数たつと仮想ディスプレイを解放する（本番は 300）
const KEEP = Deno.args.includes("--keep") ? Number(Deno.args[Deno.args.indexOf("--keep") + 1]) : 15;
const SERVER_LOG = `${WORK}/server.log`;
const CLIENT = `${WORK}/rdp-e2e-client`;
const PROBE = `${WORK}/display-probe`;

const args = Deno.args;
const only = args.includes("--only") ? args[args.indexOf("--only") + 1].split(",") : null;
const keepServer = args.includes("--keep-server");

// ── 小道具 ─────────────────────────────────────────────────────────────

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function run(cmd: string, argv: string[], check = true): Promise<string> {
  const r = await new Deno.Command(cmd, { args: argv, stdout: "piped", stderr: "piped" }).output();
  const out = new TextDecoder().decode(r.stdout) + new TextDecoder().decode(r.stderr);
  if (check && r.code !== 0) throw new Error(`${cmd} ${argv.join(" ")} が失敗しました:\n${out}`);
  return out;
}

async function uid() {
  return (await run("id", ["-u"])).trim();
}

interface Display {
  id: number;
  main: boolean;
  x: number;
  y: number;
  w: number;
  h: number;
  pw: number;
  ph: number;
  hidpi: boolean;
  vendor: number;
}
interface Probe {
  displays: Display[];
  mouse: { x: number; y: number };
}

async function probe(): Promise<Probe> {
  return JSON.parse(await run(PROBE, []));
}

/** サーバが作る仮想ディスプレイのベンダー番号（display/VirtualDisplay.m） */
const VIRTUAL_VENDOR = 0x5244500;
/** テストを始めたときにあった仮想ディスプレイ（本番のサーバが再接続のために残しているもの） */
let foreign: number[] = [];

/** テスト用サーバの仮想ディスプレイ */
async function virtualDisplays(): Promise<Display[]> {
  return (await probe()).displays.filter((d) => d.vendor === VIRTUAL_VENDOR && !foreign.includes(d.id));
}

/** テスト用サーバのプロセス（待ち受けを始めていれば）。lsof は 40 秒かかることがあるので使わない */
async function listenerPid(): Promise<number | null> {
  const out = await run("launchctl", ["list", LABEL], false);
  const pid = Number(out.match(/"PID" = (\d+);/)?.[1] ?? 0);
  if (!pid) return null;
  // 起動してから待ち受けを始めるまでの間は数えない
  const started = (await serverLog()).split("\n").filter((l) => l.includes(`listening on port ${PORT}`)).length;
  return started >= startsSeen(pid) ? pid : null;
}

/** pid ごとに、その pid が待ち受けを始めたときのログの「listening」の数を覚えておく */
const listening = new Map<number, number>();
function startsSeen(pid: number): number {
  if (!listening.has(pid)) listening.set(pid, listening.size + 1);
  return listening.get(pid)!;
}

async function waitFor<T>(what: string, fn: () => Promise<T | null | undefined | false>, timeoutMs = 15000) {
  const end = Date.now() + timeoutMs;
  let last: unknown;
  while (Date.now() < end) {
    try {
      const v = await fn();
      if (v) return v as T;
      last = v;
    } catch (e) {
      last = e;
    }
    await sleep(250);
  }
  throw new Error(`待ちきれませんでした: ${what}（最後: ${JSON.stringify(last)}）`);
}

async function serverLog(): Promise<string> {
  return await Deno.readTextFile(SERVER_LOG).catch(() => "");
}

// ── テスト用クライアント ────────────────────────────────────────────────

type Event = Record<string, unknown> & { ev: string };

/** 動いているクライアント。テストが途中で失敗しても、次のテストへ持ち越さない */
const live = new Set<Client>();

class Client {
  private proc: Deno.ChildProcess;
  private writer: WritableStreamDefaultWriter<Uint8Array>;
  readonly events: Event[] = [];
  private waiters: { pred: (e: Event) => boolean; resolve: (e: Event) => void }[] = [];
  readonly done: Promise<void>;

  constructor(opts: { width: number; height: number; scale: number; audio?: string; gfx?: string; aac?: boolean }) {
    const argv = [];
    if (opts.audio) argv.push("--audio", opts.audio);
    if (opts.aac) argv.push("--aac");
    argv.push(
      "--",
      "/v:127.0.0.1",
      `/port:${PORT}`,
      "/u:e2e",
      "/p:e2e",
      "/cert:ignore",
      `/size:${opts.width}x${opts.height}`,
      `/scale-desktop:${opts.scale}`,
      opts.gfx ?? "/gfx:AVC420",
      "/dynamic-resolution",
      "/sound:sys:e2e",
      "/log-level:ERROR",
    );
    this.proc = new Deno.Command(CLIENT, { args: argv, stdin: "piped", stdout: "piped", stderr: "piped" }).spawn();
    this.writer = this.proc.stdin.getWriter();
    this.done = this.read();
    live.add(this);
    this.proc.status.then(() => live.delete(this));
    // クライアント側の FreeRDP のログ（調べるとき用）
    this.proc.stderr.pipeTo(Deno.openSync(`${WORK}/client.log`, { create: true, append: true, write: true }).writable)
      .catch(() => {});
  }

  private async read() {
    const decoder = new TextDecoder();
    let buf = "";
    for await (const chunk of this.proc.stdout) {
      buf += decoder.decode(chunk, { stream: true });
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line.startsWith("{")) continue;
        const ev = JSON.parse(line) as Event;
        this.events.push(ev);
        this.waiters = this.waiters.filter((w) => {
          if (w.pred(ev)) {
            w.resolve(ev);
            return false;
          }
          return true;
        });
      }
    }
  }

  wait(pred: (e: Event) => boolean, what: string, timeoutMs = 15000, fromIndex = 0): Promise<Event> {
    const found = this.events.slice(fromIndex).find(pred);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`待ちきれませんでした: ${what}`)), timeoutMs);
      this.waiters.push({ pred, resolve: (e) => (clearTimeout(timer), resolve(e)) });
    });
  }

  async send(line: string) {
    await this.writer.write(new TextEncoder().encode(line + "\n"));
  }

  async stats(): Promise<Event> {
    const from = this.events.length;
    await this.send("stats");
    return await this.wait((e) => e.ev === "stats", "stats", 5000, from);
  }

  /** フレームが届き続け、画面が黒くないこと */
  async waitForPicture(width: number, height: number) {
    return await waitFor(`${width}x${height} の画面`, async () => {
      const s = await this.stats();
      return s.w === width && s.h === height && (s.frames as number) > 0 && (s.lit as number) > 0.05 && s;
    }, 20000);
  }

  async quit() {
    await this.send("quit").catch(() => {});
    await this.writer.close().catch(() => {});
    const ended = await Promise.race([this.proc.status.then(() => true), sleep(10000).then(() => false)]);
    if (!ended) {
      log("⚠️ クライアントが 10 秒で終わらないので止める");
      this.kill();
    }
    log("切断");
  }

  kill() {
    try {
      this.proc.kill("SIGKILL");
    } catch { /* 終わっている */ }
  }

  get status() {
    return this.proc.status;
  }
}

async function connect(
  width: number, height: number, scale: number, audio?: string, gfx?: string, aac?: boolean,
): Promise<Client> {
  const client = new Client({ width, height, scale, audio, gfx, aac });
  const first = await Promise.race([
    client.wait((e) => e.ev === "connected" || e.ev === "connect-failed", "接続", 20000),
    client.status.then((s) => ({ ev: "exited", code: s.code } as Event)),
  ]);
  if (first.ev !== "connected") throw new Error(`接続できませんでした: ${JSON.stringify(first)}`);
  await client.waitForPicture(width, height);
  log(`接続 ${width}x${height}@${scale}%`);
  return client;
}

// ── サーバの準備 ──────────────────────────────────────────────────────

async function buildTools() {
  await Deno.mkdir(WORK, { recursive: true });
  const prefix = (await run("brew", ["--prefix", "freerdp"])).trim();
  await run("cc", [
    "-O1", "-g", "-Wall", "-Wno-deprecated-declarations", "-o", CLIENT, `${HERE}rdp-e2e-client.c`,
    `-I${prefix}/include/freerdp3`, `-I${prefix}/include/winpr3`, `-L${prefix}/lib`,
    "-lfreerdp-client3", "-lfreerdp3", "-lwinpr3", "-framework", "AudioToolbox",
  ]);
  await run("swiftc", ["-O", "-o", PROBE, `${HERE}display-probe.swift`]);
  // クライアント（mRemote）の E2E で Mac の画面に出す目印の窓
  await run("swiftc", ["-O", "-o", `${WORK}/e2e-target`, `${HERE}e2e-target.swift`]);
}

function plist(extraEnv: Record<string, string> = {}): string {
  const env: Record<string, string> = {
    RDP_LISTEN_ADDRESS: "127.0.0.1",
    RDP_ALLOW_NO_AUTH: "1", // 127.0.0.1 でしか待ち受けないので、テストの間だけ
    RDP_DISPLAY_MODE: "virtual",
    RDP_KEYBOARD_TYPE: "ansi",
    RDP_CERT_DIR: `${HOME}/.macos-rdp`,
    RDP_LOG_LEVEL: args.includes("--log") ? args[args.indexOf("--log") + 1] : "verbose",
    RDP_UPDATE_ENABLED: "0",
    RDP_VIRTUAL_DISPLAY_KEEP: String(KEEP),
    RDP_AUDIO_LOCAL: "0", // テストの正弦波をスピーカーから鳴らさない
  };
  // --env K=V（何度でも）: 足す・上書きする設定。RDP_DISP=0 で表示制御チャネルのないサーバにするなど
  args.forEach((a, i) => {
    if (a !== "--env") return;
    const [k, ...v] = args[i + 1].split("=");
    env[k] = v.join("=");
  });
  Object.assign(env, extraEnv);
  const envXml = Object.entries(env).map(([k, v]) => `\t\t<key>${k}</key>\n\t\t<string>${v}</string>`).join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${BIN}</string>
		<string>--port</string>
		<string>${PORT}</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
${envXml}
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>2</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>StandardOutPath</key>
	<string>${SERVER_LOG}</string>
	<key>StandardErrorPath</key>
	<string>${SERVER_LOG}</string>
</dict>
</plist>
`;
}

async function startServer(extraEnv: Record<string, string> = {}) {
  await stopServer();
  await Deno.writeTextFile(SERVER_LOG, "");
  await Deno.writeTextFile(PLIST, plist(extraEnv));
  await run("launchctl", ["bootstrap", `gui/${await uid()}`, PLIST]);
  await waitFor("テスト用サーバの待ち受け", listenerPid);
}

async function stopServer() {
  await run("launchctl", ["bootout", `gui/${await uid()}/${LABEL}`], false);
  await Deno.remove(PLIST).catch(() => {});
  listening.clear();
  await waitFor("テスト用サーバの停止", async () => !(await run("launchctl", ["list", LABEL], false)).includes('"PID"'), 10000)
    .catch(() => {});
}

async function productionInUse(): Promise<boolean> {
  const out = await run("netstat", ["-anp", "tcp"], false);
  return /\.3389\s+\S+\s+ESTABLISHED/.test(out);
}

// ── 確かめ方 ──────────────────────────────────────────────────────────

class Failure extends Error {}

function expect(ok: unknown, message: string, detail?: unknown) {
  if (!ok) throw new Failure(`${message}${detail === undefined ? "" : `: ${JSON.stringify(detail)}`}`);
}

/**
 * 仮想ディスプレイが 1 枚、頼んだ画素数・密度で、メインになっていること。
 * hidpi が null なら密度は問わない（macOS が Retina を出さない大きさがある）
 */
async function expectVirtualDisplay(width: number, height: number, hidpi: boolean | null): Promise<Display> {
  const d = await waitFor(`仮想ディスプレイ ${width}x${height}${hidpi ? " Retina" : ""}`, async () => {
    const vds = await virtualDisplays();
    return vds.length === 1 && vds[0].pw === width && vds[0].ph === height &&
      (hidpi === null || vds[0].hidpi === hidpi) && vds[0];
  }, 15000).catch(async (e) => {
    throw new Failure(`${(e as Error).message}\n  いまの画面: ${JSON.stringify((await probe()).displays)}`);
  });
  expect(d.main, "仮想ディスプレイがメインになっていない", d);
  return d;
}

/** デスクトップの (x, y) 画素にポインタを動かすと、Mac のポインタがそこへ行くこと */
async function expectPointer(client: Client, display: Display, x: number, y: number) {
  await client.send(`mouse ${x} ${y}`);
  const perPoint = display.pw / display.w;
  const want = { x: display.x + x / perPoint, y: display.y + y / perPoint };
  await waitFor(`ポインタ (${want.x}, ${want.y})`, async () => {
    const m = (await probe()).mouse;
    return Math.abs(m.x - want.x) <= 1.5 && Math.abs(m.y - want.y) <= 1.5;
    // 画面の構成が変わった直後は、構成を読むだけで数秒かかることがある
  }, 15000).catch(async () => {
    throw new Failure(`ポインタが ${JSON.stringify(want)} に来ない（いま ${JSON.stringify((await probe()).mouse)}）`);
  });
}

// ── テスト本体 ─────────────────────────────────────────────────────────

interface Result {
  name: string;
  ok: boolean;
  detail: string;
  ms: number;
}
const results: Result[] = [];
let testStarted = Date.now();
const log = (s: string) => console.log(`  [${((Date.now() - testStarted) / 1000).toFixed(1).padStart(5)}s] ${s}`);

async function test(name: string, title: string, body: () => Promise<string | void>) {
  if (only && !only.includes(name)) return;
  console.log(`▶ ${name}: ${title}`);
  const t0 = testStarted = Date.now();
  try {
    const detail = (await body()) ?? "";
    results.push({ name, ok: true, detail, ms: Date.now() - t0 });
    console.log(`✅ ${name} ${detail}`);
  } catch (e) {
    const detail = e instanceof Failure ? e.message : `${(e as Error).stack ?? e}`;
    results.push({ name, ok: false, detail, ms: Date.now() - t0 });
    console.log(`❌ ${name}\n${detail.replace(/^/gm, "   ")}`);
  } finally {
    for (const c of [...live]) await c.quit();
  }
}

/** 前のテストのセッションが閉じるのを待つ（サーバ側の後片付けが終わるまで） */
async function settle() {
  await sleep(1500);
}

async function main() {
  if (await productionInUse() && !args.includes("--force")) {
    console.error("本番のサーバ（3389）に接続中のクライアントがあります。仮想ディスプレイの並びを乱すので、切断してから実行してください（--force で無視）");
    Deno.exit(2);
  }
  console.log("準備: テスト用クライアントとプローブをビルド");
  await buildTools();
  const before = (await probe()).displays;
  foreign = before.filter((d) => d.vendor === VIRTUAL_VENDOR).map((d) => d.id);
  if (foreign.length) console.log(`  本番のサーバが残している仮想ディスプレイ: ${foreign.join(", ")}（数えない）`);
  console.log(`準備: テスト用サーバを ${LABEL}（127.0.0.1:${PORT}）で起動`);
  await startServer();
  const version = (await run(BIN, ["--version"], false)).trim().split("\n")[0];
  console.log(`  サーバ: ${BIN} ${version}`);

  let displayId = 0;

  await test("connect", "接続して画面が届き、Retina の仮想ディスプレイがメインになる", async () => {
    const c = await connect(2560, 1600, 200);
    try {
      const d = await expectVirtualDisplay(2560, 1600, true);
      displayId = d.id;
      expect(d.w === 1280 && d.h === 800, "Retina なら 1280x800 ポイントのはず", d);
      await expectPointer(c, d, 100, 100);
      await expectPointer(c, d, 2400, 1500);
      const s = await c.stats();
      return `画面 ${s.w}x${s.h}・フレーム ${s.frames}・点灯 ${(s.lit as number * 100).toFixed(0)}%・ディスプレイ ${d.id}`;
    } finally {
      await c.quit();
    }
  });

  await settle();
  await test("resize", "表示制御チャネルでの大きさ・拡大率の変更に追従する", async () => {
    const c = await connect(2560, 1600, 200);
    try {
      const steps: [number, number, number][] = [
        [1920, 1200, 200], [1600, 1000, 100], [3840, 2160, 300], [2732, 2048, 200], [2560, 1600, 200],
      ];
      const done: string[] = [];
      for (const [w, h, scale] of steps) {
        const from = c.events.length;
        await c.send(`resize ${w} ${h} ${scale}`);
        await c.wait((e) => e.ev === "desktop" && e.w === w && e.h === h, `desktop ${w}x${h}`, 15000, from);
        await c.waitForPicture(w, h);
        const d = await expectVirtualDisplay(w, h, scale >= 150);
        await expectPointer(c, d, Math.round(w / 2), Math.round(h / 2));
        done.push(`${w}x${h}@${scale}%`);
      }
      return done.join(" → ");
    } finally {
      await c.quit();
    }
  });

  await settle();
  await test("audio", "Mac で鳴らした正弦波が崩れずに届く", async () => {
    const wav = `${WORK}/tone.wav`, raw = `${WORK}/audio.raw`;
    await writeToneWav(wav);
    const c = await connect(1920, 1200, 200, raw);
    let format: Event;
    try {
      await sleep(1000); // 音声チャネルが開くまで
      await run("afplay", [wav]);
      await sleep(1500); // 後ろの方が届くまで
      format = await c.wait((e) => e.ev === "audio-format", "音声の形式", 5000);
    } finally {
      await c.quit();
    }
    expect(format.tag === 1 && format.bits === 16, "16bit PCM で届いていない", format);
    const report = analyzeTone(await Deno.readFile(raw), format.rate as number, format.channels as number);
    log(`届いた音: ${JSON.stringify(report)}`);
    expect(report.seconds > TONE_SECONDS - 0.5, "鳴っている区間が短い（途中で途切れた）", report);
    expect(Math.abs(report.frequency - TONE_HZ) < TONE_HZ * 0.005, "周波数がずれている（標本化周波数の取り違え）", report);
    expect(report.snrDb > 35, "SN 比が低い（音が崩れている）", report);
    expect(report.dropouts === 0, "途中で音が抜けている", report);
    expect(report.peak > 0.4 && report.peak < 0.6, "振幅が元（0.5）と違う", report);
    return `${format.rate}Hz ${format.channels}ch・${report.frequency.toFixed(2)}Hz・SN 比 ${report.snrDb.toFixed(1)}dB・${report.seconds.toFixed(1)}秒`;
  });

  await settle();
  await test("audio-silence", "音が止まったら音声を送らず、次に鳴った音は欠けずに届く", async () => {
    const wav = `${WORK}/tone.wav`, raw = `${WORK}/audio-silence.raw`;
    await writeToneWav(wav);
    const c = await connect(1920, 1200, 200, raw);
    let format: Event;
    let silentBytes = 0, before = 0;
    try {
      await sleep(1000);
      await run("afplay", [wav]);
      format = await c.wait((e) => e.ev === "audio-format", "音声の形式", 5000);
      await sleep(2000); // 鳴り終わりの余韻（0.5 秒）が送られ終わるまで
      const a = (await c.stats()).audioBytes as number;
      await sleep(5000);
      before = (await c.stats()).audioBytes as number;
      silentBytes = before - a;
      log(`無音の 5 秒に届いた音声: ${silentBytes} バイト`);
      await run("afplay", [wav]);
      await sleep(1500);
    } finally {
      await c.quit();
    }
    // 非圧縮 44.1kHz ステレオなら 5 秒で約 880KB
    expect(silentBytes < 20000, "無音の間も音声を送っている", { silentBytes });
    const all = await Deno.readFile(raw);
    const report = analyzeTone(all.subarray(before - (before % 4)), format.rate as number, format.channels as number);
    log(`2 回目の音: ${JSON.stringify(report)}`);
    expect(report.seconds > TONE_SECONDS - 0.5, "2 回目の音が欠けている（鳴り始めが遅れた）", report);
    expect(Math.abs(report.frequency - TONE_HZ) < TONE_HZ * 0.005 && report.snrDb > 35 && report.dropouts === 0,
      "2 回目の音が崩れている", report);
    return `無音 5 秒で ${silentBytes} バイト・2 回目 ${report.seconds.toFixed(1)} 秒・SN 比 ${report.snrDb.toFixed(1)}dB`;
  });

  await settle();
  await test("audio-aac", "省データの AAC: 音声が 1/10 以下の量で、崩れずに届く", async () => {
    // mRemote は Mac 拡張で頼むが、テスト用クライアントは Mac 拡張を持たないので、サーバ側で最初から AAC にする
    await startServer({ RDP_AUDIO_AAC: "1" });
    const wav = `${WORK}/tone.wav`, raw = `${WORK}/audio-aac.raw`;
    await writeToneWav(wav);
    let format: Event, bytes = 0;
    const c = await connect(1920, 1200, 200, raw, undefined, true);
    try {
      await sleep(1000);
      await run("afplay", [wav]);
      await sleep(1500);
      format = await c.wait((e) => e.ev === "audio-format" && e.tag === 0x4D52, "AAC の形式", 5000);
      bytes = (await c.stats()).audioBytes as number;
    } finally {
      await c.quit();
      await startServer();
      displayId = 0; // 起動し直したので、仮想ディスプレイは新しく作られる
    }
    // 4 秒の音（と余韻）で、非圧縮なら 44.1kHz で約 800KB
    const kbps = (bytes * 8) / 1000 / (TONE_SECONDS + 0.5);
    log(`届いた AAC: ${bytes} バイト（約 ${kbps.toFixed(0)}kbps）`);
    expect(kbps < 150, "AAC なのに量が多い", { bytes, kbps });
    const report = analyzeTone(await Deno.readFile(raw), format.rate as number, format.channels as number);
    log(`展開した音: ${JSON.stringify(report)}`);
    expect(report.seconds > TONE_SECONDS - 0.5, "鳴っている区間が短い", report);
    expect(Math.abs(report.frequency - TONE_HZ) < TONE_HZ * 0.005, "周波数がずれている", report);
    expect(report.snrDb > 30, "SN 比が低い（音が崩れている）", report);
    expect(report.dropouts === 0, "途中で音が抜けている", report);
    return `${format.rate}Hz・約 ${kbps.toFixed(0)}kbps・SN 比 ${report.snrDb.toFixed(1)}dB・${report.seconds.toFixed(1)}秒`;
  });

  await settle();
  await test("reconnect", "切断（きれいに・強制で）のあと、同じ仮想ディスプレイでつなぎ直せる", async () => {
    const rounds: string[] = [];
    for (let i = 0; i < 4; i++) {
      const [w, h] = i % 2 ? [2400, 1500] : [2560, 1600];
      const c = await connect(w, h, 200);
      const d = await expectVirtualDisplay(w, h, true);
      if (displayId) expect(d.id === displayId, "仮想ディスプレイが使い回されていない", { before: displayId, now: d.id });
      displayId = d.id;
      log(`ディスプレイ ${d.id}`);
      await expectPointer(c, d, 200, 200);
      log("ポインタ");
      const pid = await listenerPid();
      if (i % 2) {
        c.kill(); // 強制切断（TCP が切れるだけ）
        await c.status;
        rounds.push(`強制切断 ${w}x${h}`);
      } else {
        await c.quit();
        rounds.push(`切断 ${w}x${h}`);
      }
      await settle();
      expect((await listenerPid()) === pid, "切断でサーバのプロセスが変わった（落ちた）", { pid, now: await listenerPid() });
    }
    const text = await serverLog();
    expect(!/double free|SIGSEGV|SIGABRT|EXC_BAD_ACCESS/.test(text), "サーバのログに異常終了の跡がある");
    return rounds.join(" → ");
  });

  await settle();
  await test("takeover", "前の接続が残ったまま新しい接続が来ると、新しい方に切り替わる", async () => {
    // 通信が途切れた iPhone がつなぎ直すとき、サーバはまだ前の接続を生きていると思っている
    const a = await connect(2560, 1600, 200);
    const pid = await listenerPid();
    const b = await connect(3840, 2160, 300);
    const gone = await Promise.race([a.status.then(() => true), sleep(10000).then(() => false)]);
    expect(gone, "前の接続が切られていない");
    const d = await expectVirtualDisplay(3840, 2160, true);
    if (displayId) expect(d.id === displayId, "仮想ディスプレイが使い回されていない", { before: displayId, now: d.id });
    await expectPointer(b, d, 1920, 1080);
    const s = await b.stats();
    expect((s.frames as number) > 0 && (s.lit as number) > 0.05, "新しい接続に画面が届いていない", s);
    await b.quit();
    expect((await listenerPid()) === pid, "サーバのプロセスが変わった（落ちた）");
    return `${d.w}x${d.h}pt・ディスプレイ ${d.id}`;
  });

  await settle();
  await test("rescale", "つなぎ直したときに頼んだ拡大率（Retina / 等倍）が反映される", async () => {
    // 3840x2160@300% は iPhone から mRemote で 4K 固定にしたときの頼み方
    const steps: [number, number, number][] = [
      [2560, 1600, 200], [1600, 1000, 100], [3840, 2160, 300], [2560, 1600, 200], [1920, 1200, 150],
    ];
    const done: string[] = [];
    for (const [w, h, scale] of steps) {
      const c = await connect(w, h, scale);
      try {
        const d = await expectVirtualDisplay(w, h, scale >= 150);
        await expectPointer(c, d, Math.round(w / 3), Math.round(h / 3));
        done.push(`${w}x${h}@${scale}%→${d.w}x${d.h}pt`);
      } finally {
        await c.quit();
      }
      await settle();
    }
    return done.join(" → ");
  });

  await settle();
  await test("bitmap-resize", "H.264 を使わないクライアント（Progressive）で、送信中に大きさを続けて変えても落ちない", async () => {
    // Windows App for iPhone のように AVC を断るクライアントは、タイルの差分で送る経路に乗る
    const gfx = "/gfx:progressive:on,AVC420:off,AVC444:off";
    const pid = await listenerPid();
    const c = await connect(1920, 1200, 200, undefined, gfx);
    try {
      expect(/GFX codec: progressive/.test(await serverLog()), "Progressive の経路になっていない");
      const sizes: [number, number][] = [[1600, 1000], [2560, 1600], [1280, 800], [1920, 1200], [2400, 1500], [1366, 768]];
      // 画面が動いているときに送信と重なるよう、ポインタを動かしながら間を空けずに頼む
      for (let round = 0; round < 3; round++) {
        for (const [w, h] of sizes) {
          await c.send(`resize ${w} ${h} 200`);
          await c.send(`mouse ${Math.round(w / 3)} ${Math.round(h / 3)}`);
          await sleep(120);
        }
      }
      const [w, h] = sizes[sizes.length - 1];
      await c.waitForPicture(w, h);
      // 1366x768 の Retina（683x384 ポイント）は macOS が使わせないので、等倍でよい。画素数はストリームと同じこと
      const d = await expectVirtualDisplay(w, h, null);
      await expectPointer(c, d, Math.round(w / 2), Math.round(h / 3));
      expect((await listenerPid()) === pid, "サーバのプロセスが変わった（落ちた）", { pid, now: await listenerPid() });
      const s = await c.stats();
      return `${sizes.length * 3} 回の変更のあと ${s.w}x${s.h}・フレーム ${s.frames}`;
    } finally {
      await c.quit();
    }
  });

  await settle();
  await test("idle", `放置（${KEEP}秒）で仮想ディスプレイを解放し、起動し直したサーバにつながる`, async () => {
    // ここまでのテストで仮想ディスプレイができている。最後の切断から KEEP 秒で解放される
    const pid = await listenerPid();
    expect(pid, "サーバが待ち受けていない");
    expect((await virtualDisplays()).length === 1, "放置前に仮想ディスプレイが残っていない", await virtualDisplays());
    await waitFor("仮想ディスプレイの解放", async () => (await virtualDisplays()).length === 0, (KEEP + 10) * 1000)
      .catch(async () => {
        throw new Failure(`解放されない: ${JSON.stringify(await virtualDisplays())}`);
      });
    const restarted = await waitFor("サーバの起動し直し", async () => {
      const now = await listenerPid();
      return now && now !== pid && now;
    }, 20000).catch(() => {
      throw new Failure("プロセスが起動し直されていない");
    });
    const main = (await probe()).displays.find((d) => d.main)!;
    expect(main.vendor !== VIRTUAL_VENDOR || foreign.includes(main.id), "解放後もテスト用の仮想ディスプレイがメインのまま", main);
    // 起動し直したサーバで、また Retina の仮想ディスプレイが使える（最初の 1 枚が作れる）
    const c = await connect(2560, 1600, 200);
    try {
      const d = await expectVirtualDisplay(2560, 1600, true);
      await expectPointer(c, d, 1280, 800);
      return `pid ${pid} → ${restarted}・新しいディスプレイ ${d.id}`;
    } finally {
      await c.quit();
    }
  });

  // ── 後片付け ──
  if (!keepServer) {
    await stopServer();
    // 仮想ディスプレイはプロセスと一緒に消える
    await waitFor("仮想ディスプレイの消滅", async () => (await virtualDisplays()).length === 0, 10000).catch(() => {});
  }
  const left = await virtualDisplays();
  if (left.length && !keepServer) console.log(`⚠️ 仮想ディスプレイが残っています: ${JSON.stringify(left)}`);
  // 物理モニターの番号は仮想ディスプレイを作るたびに変わることがあるので、仮想ディスプレイでないことだけ見る
  const main = (await probe()).displays.find((d) => d.main);
  if (!keepServer && main && main.vendor === VIRTUAL_VENDOR && !foreign.includes(main.id)) {
    console.log(`⚠️ テスト用の仮想ディスプレイがメインのまま残っています: ${JSON.stringify(main)}`);
  }

  console.log("\n結果");
  for (const r of results) console.log(`${r.ok ? "✅" : "❌"} ${r.name.padEnd(10)} ${(r.ms / 1000).toFixed(1)}s ${r.ok ? r.detail : r.detail.split("\n")[0]}`);
  await Deno.writeTextFile(`${WORK}/results.json`, JSON.stringify(results, null, 2));
  console.log(`サーバのログ: ${SERVER_LOG}`);
  Deno.exit(results.every((r) => r.ok) ? 0 : 1);
}

if (args.includes("--stop")) {
  await stopServer();
  Deno.exit(0);
}
if (args.includes("--serve")) {
  if (await productionInUse() && !args.includes("--force")) {
    console.error("本番のサーバ（3389）に接続中のクライアントがあります（--force で無視）");
    Deno.exit(2);
  }
  await buildTools();
  await startServer();
  console.log(`テスト用サーバ: 127.0.0.1:${PORT}（${LABEL}、KEEP ${KEEP}s）ログ ${SERVER_LOG}`);
  Deno.exit(0);
}

try {
  await main();
} catch (e) {
  console.error(e);
  if (!keepServer) await stopServer();
  Deno.exit(1);
}
