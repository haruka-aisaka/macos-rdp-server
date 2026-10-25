/**
 * 音の E2E の道具: 正弦波の WAV を作り、届いた PCM がその正弦波のままかを調べる。
 * サーバの E2E（e2e.ts）と mRemote の E2E（e2e/mac-host/e2e.ts）の両方が使う。
 */

export const TONE_HZ = 997; // 標本化周波数と割り切れない周波数（48000/44100 のどちらとも整数比にならない）
export const TONE_SECONDS = 4;

export async function writeToneWav(path: string) {
  const rate = 48000, channels = 2, frames = rate * TONE_SECONDS;
  const data = new DataView(new ArrayBuffer(44 + frames * channels * 2));
  const str = (o: number, s: string) => [...s].forEach((c, i) => data.setUint8(o + i, c.charCodeAt(0)));
  str(0, "RIFF");
  data.setUint32(4, 36 + frames * channels * 2, true);
  str(8, "WAVE");
  str(12, "fmt ");
  data.setUint32(16, 16, true);
  data.setUint16(20, 1, true);
  data.setUint16(22, channels, true);
  data.setUint32(24, rate, true);
  data.setUint32(28, rate * channels * 2, true);
  data.setUint16(32, channels * 2, true);
  data.setUint16(34, 16, true);
  str(36, "data");
  data.setUint32(40, frames * channels * 2, true);
  for (let i = 0; i < frames; i++) {
    // 端で 20ms かけて上げ下げし、クリックを入れない
    const edge = Math.min(1, i / (rate * 0.02), (frames - i) / (rate * 0.02));
    const v = Math.round(Math.sin((2 * Math.PI * TONE_HZ * i) / rate) * 0.5 * edge * 32767);
    data.setInt16(44 + i * 4, v, true);
    data.setInt16(44 + i * 4 + 2, v, true);
  }
  await Deno.writeFile(path, new Uint8Array(data.buffer));
}

export interface ToneReport {
  rate: number;
  seconds: number;
  frequency: number;
  snrDb: number;
  dropouts: number;
  peak: number;
}

/** 16bit 符号付き・インターリーブの PCM から、鳴っている区間の左チャネルを調べる */
export function analyzeTone(raw: Uint8Array, rate: number, channels: number): ToneReport {
  const view = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
  const frames = Math.floor(raw.byteLength / (2 * channels));
  const x = new Float64Array(frames);
  for (let i = 0; i < frames; i++) x[i] = view.getInt16(i * 2 * channels, true) / 32768;
  // 10ms ごとの実効値で鳴っている区間を探す
  const block = Math.round(rate / 100);
  const rms: number[] = [];
  for (let b = 0; b + block <= frames; b += block) {
    let s = 0;
    for (let i = b; i < b + block; i++) s += x[i] * x[i];
    rms.push(Math.sqrt(s / block));
  }
  const loud = rms.map((r) => r > 0.1);
  const first = loud.indexOf(true), last = loud.lastIndexOf(true);
  if (first < 0) return { rate, seconds: 0, frequency: 0, snrDb: -Infinity, dropouts: 0, peak: 0 };
  // 端の 100ms を除いた区間
  const start = (first + 10) * block, end = (last - 10) * block;
  const seconds = (end - start) / rate;
  // 途切れ: 区間の中で、実効値が期待（0.5/√2 ≈ 0.35）の半分を切った 10ms の数
  let dropouts = 0;
  for (let b = first + 10; b < last - 10; b++) if (rms[b] < 0.17) dropouts++;
  // 周波数: 990〜1004Hz を 0.05Hz 刻みで当てはめ、残差が最小のもの。その残差から SN 比
  const fit = (f: number) => {
    let ss = 0, sc = 0, cc = 0, xs = 0, xc = 0, xx = 0;
    const w = (2 * Math.PI * f) / rate;
    for (let i = start; i < end; i++) {
      const s = Math.sin(w * i), c = Math.cos(w * i);
      ss += s * s; cc += c * c; sc += s * c; xs += x[i] * s; xc += x[i] * c; xx += x[i] * x[i];
    }
    const det = ss * cc - sc * sc;
    const a = (xs * cc - xc * sc) / det, b = (xc * ss - xs * sc) / det;
    const signal = a * xs + b * xc;
    return { f, signal, noise: xx - signal };
  };
  let best = fit(TONE_HZ);
  for (let f = TONE_HZ - 7; f <= TONE_HZ + 7; f += 0.05) {
    const r = fit(f);
    if (r.noise < best.noise) best = r;
  }
  // 区間全体での当てはめはわずかな時計のずれでも残差が出るので、200ms ごとに当てはめて最悪値を見る
  let worst = Infinity;
  const seg = Math.round(rate * 0.2);
  for (let s0 = start; s0 + seg <= end; s0 += seg) {
    let ss = 0, sc = 0, cc = 0, xs = 0, xc = 0, xx = 0;
    const w = (2 * Math.PI * best.f) / rate;
    for (let i = s0; i < s0 + seg; i++) {
      const s = Math.sin(w * i), c = Math.cos(w * i);
      ss += s * s; cc += c * c; sc += s * c; xs += x[i] * s; xc += x[i] * c; xx += x[i] * x[i];
    }
    const det = ss * cc - sc * sc;
    const a = (xs * cc - xc * sc) / det, b = (xc * ss - xs * sc) / det;
    const signal = a * xs + b * xc;
    worst = Math.min(worst, 10 * Math.log10(signal / Math.max(xx - signal, 1e-12)));
  }
  let peak = 0;
  for (let i = start; i < end; i++) peak = Math.max(peak, Math.abs(x[i]));
  return { rate, seconds, frequency: best.f, snrDb: worst, dropouts, peak };
}

