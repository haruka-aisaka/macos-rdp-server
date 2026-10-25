/*
 * rdp-e2e-client: E2E テスト用の、画面を持たない RDP クライアント。
 *
 *   rdp-e2e-client [--audio <file.raw>] [--aac] -- <FreeRDP の引数 (/v: /port: /u: /p: /size: /cert:ignore ...)>
 *
 * --aac: mRemote と同じく、Mac 拡張の AAC（形式 0x4D52、ADTS）も受け取れると申告し、届いたら展開して書く。
 * stats の audioBytes は届いたままのバイト数（AAC なら圧縮されたまま）。
 *
 * Homebrew の FreeRDP 3（クライアント側）で動かす。届いた画面は gdi の枠に描かせ、
 * 届いた音は加工せずに --audio のファイルへ書く（16bit PCM だけを受けると申告する）。
 * 標準入力から 1 行ずつ命令を受け、結果を標準出力に JSON で 1 行ずつ返す。
 *
 *   stats                          画面の大きさ・届いたフレーム数・黒くない画素の割合・音のバイト数
 *   resize <幅> <高さ> <拡大率%>    表示制御チャネルで画面の大きさを頼む
 *   mouse <x> <y>                  ポインタを動かす（デスクトップの画素で）
 *   click <x> <y>                  左クリック
 *   key <スキャンコード16進>         キーを押して離す（拡張キーは 0xE0 を上位に付ける: e04b）
 *   unicode <文字コード10進>        Unicode の文字を送る
 *   shot <file.ppm>                いまの画面を書き出す
 *   quit                           切断して終わる（きれいな切断）
 *
 * 出来事も JSON で流す: connected / desktop / audio-format / disconnected。
 */
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <freerdp/freerdp.h>
#include <freerdp/addin.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/rdpsnd.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/disp.h>
#include <freerdp/codec/audio.h>
#include <freerdp/event.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <winpr/synch.h>
#include <AudioToolbox/AudioToolbox.h>

typedef struct
{
	rdpClientContext common;
	DispClientContext* disp;
	unsigned long long frames;
} e2eContext;

static FILE* g_audio;
static BOOL g_acceptAac;
#define WAVE_FORMAT_MRX_AAC 0x4D52
/* AAC を受けている間の展開器 */
static AudioConverterRef g_aac;
static UInt32 g_aacChannels;
static const BYTE* g_aacPacket;
static UInt32 g_aacPacketSize;
static AudioStreamPacketDescription g_aacDescription;
static unsigned long long g_audioBytes;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static char* g_queue[64];
static int g_queued;
static int g_stdinClosed;

static void emit(const char* fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
	fflush(stdout);
}

/* ── 音: 届いた PCM をそのまま書く ─────────────────────────────────── */

typedef struct
{
	rdpsndDevicePlugin device;
} e2eSound;

static BOOL snd_format_supported(rdpsndDevicePlugin* device, const AUDIO_FORMAT* format)
{
	(void)device;
	if (g_acceptAac && format->wFormatTag == WAVE_FORMAT_MRX_AAC)
		return TRUE;
	return format->wFormatTag == WAVE_FORMAT_PCM && format->wBitsPerSample == 16;
}

static void aac_close(void)
{
	if (g_aac)
		AudioConverterDispose(g_aac);
	g_aac = NULL;
}

static BOOL aac_open(const AUDIO_FORMAT* format)
{
	aac_close();
	AudioStreamBasicDescription in = { .mSampleRate = format->nSamplesPerSec,
		                               .mFormatID = kAudioFormatMPEG4AAC,
		                               .mFormatFlags = kMPEG4Object_AAC_LC,
		                               .mFramesPerPacket = 1024,
		                               .mChannelsPerFrame = format->nChannels };
	AudioStreamBasicDescription out = { .mSampleRate = format->nSamplesPerSec,
		                                .mFormatID = kAudioFormatLinearPCM,
		                                .mFormatFlags = kAudioFormatFlagIsSignedInteger |
		                                                kAudioFormatFlagIsPacked,
		                                .mBytesPerPacket = 2 * format->nChannels,
		                                .mFramesPerPacket = 1,
		                                .mBytesPerFrame = 2 * format->nChannels,
		                                .mChannelsPerFrame = format->nChannels,
		                                .mBitsPerChannel = 16 };
	g_aacChannels = format->nChannels;
	return AudioConverterNew(&in, &out, &g_aac) == noErr;
}

static OSStatus aac_input(AudioConverterRef converter, UInt32* ioPackets, AudioBufferList* data,
                          AudioStreamPacketDescription** descriptions, void* user)
{
	(void)converter;
	(void)user;
	if (!g_aacPacket)
	{
		*ioPackets = 0;
		return 'mrxE';
	}
	data->mNumberBuffers = 1;
	data->mBuffers[0].mNumberChannels = g_aacChannels;
	data->mBuffers[0].mData = (void*)g_aacPacket;
	data->mBuffers[0].mDataByteSize = g_aacPacketSize;
	g_aacDescription.mStartOffset = 0;
	g_aacDescription.mVariableFramesInPacket = 0;
	g_aacDescription.mDataByteSize = g_aacPacketSize;
	if (descriptions)
		*descriptions = &g_aacDescription;
	*ioPackets = 1;
	g_aacPacket = NULL;
	return noErr;
}

/* ADTS の枠ごとに展開して、PCM を書く */
static void aac_play(const BYTE* data, size_t size)
{
	size_t at = 0;
	while (g_aac && at + 7 <= size && data[at] == 0xFF && (data[at + 1] & 0xF0) == 0xF0)
	{
		size_t header = (data[at + 1] & 1) ? 7 : 9;
		size_t length = ((size_t)(data[at + 3] & 3) << 11) | ((size_t)data[at + 4] << 3) |
		                (data[at + 5] >> 5);
		if (length < header || at + length > size)
			break;
		g_aacPacket = data + at + header;
		g_aacPacketSize = (UInt32)(length - header);
		int16_t pcm[2048 * 2];
		UInt32 frames = 2048;
		AudioBufferList list = { .mNumberBuffers = 1 };
		list.mBuffers[0].mNumberChannels = g_aacChannels;
		list.mBuffers[0].mData = pcm;
		list.mBuffers[0].mDataByteSize = sizeof pcm;
		AudioConverterFillComplexBuffer(g_aac, aac_input, NULL, &frames, &list, NULL);
		if (frames && g_audio)
			fwrite(pcm, 1, (size_t)frames * 2 * g_aacChannels, g_audio);
		g_aacPacket = NULL;
		at += length;
	}
}

static BOOL snd_open(rdpsndDevicePlugin* device, const AUDIO_FORMAT* format, UINT32 latency)
{
	(void)device;
	(void)latency;
	if (format->wFormatTag == WAVE_FORMAT_MRX_AAC)
	{
		if (!aac_open(format))
			return FALSE;
	}
	else
		aac_close();
	emit("{\"ev\":\"audio-format\",\"tag\":%u,\"rate\":%u,\"channels\":%u,\"bits\":%u}",
	     format->wFormatTag, format->nSamplesPerSec, format->nChannels, format->wBitsPerSample);
	return TRUE;
}

static BOOL snd_set_volume(rdpsndDevicePlugin* device, UINT32 value)
{
	(void)device;
	(void)value;
	return TRUE;
}

static UINT32 snd_get_volume(rdpsndDevicePlugin* device)
{
	(void)device;
	return 0xFFFFFFFF;
}

static UINT snd_play(rdpsndDevicePlugin* device, const BYTE* data, size_t size)
{
	(void)device;
	if (g_aac)
		aac_play(data, size);
	else if (g_audio)
		fwrite(data, 1, size, g_audio);
	g_audioBytes += size;
	return 0; /* 遅延（ミリ秒） */
}

static void snd_close(rdpsndDevicePlugin* device)
{
	(void)device;
	if (g_audio)
		fflush(g_audio);
}

static void snd_free(rdpsndDevicePlugin* device)
{
	free(device);
}

static UINT VCAPITYPE e2e_rdpsnd_entry(PFREERDP_RDPSND_DEVICE_ENTRY_POINTS entry)
{
	e2eSound* snd = calloc(1, sizeof(e2eSound));
	if (!snd)
		return CHANNEL_RC_NO_MEMORY;
	snd->device.FormatSupported = snd_format_supported;
	snd->device.Open = snd_open;
	snd->device.SetVolume = snd_set_volume;
	snd->device.GetVolume = snd_get_volume;
	snd->device.Play = snd_play;
	snd->device.Close = snd_close;
	snd->device.Free = snd_free;
	entry->pRegisterRdpsndDevice(entry->rdpsnd, &snd->device);
	return CHANNEL_RC_OK;
}

/* /sound:sys:e2e で、組み込みの出力の代わりにこれを使わせる */
static PVIRTUALCHANNELENTRY e2e_addin_provider(LPCSTR name, LPCSTR subsystem, LPCSTR type,
                                               DWORD flags)
{
	if (name && subsystem && strcmp(name, RDPSND_CHANNEL_NAME) == 0 && strcmp(subsystem, "e2e") == 0)
		return (PVIRTUALCHANNELENTRY)e2e_rdpsnd_entry;
	return freerdp_channels_load_static_addin_entry(name, subsystem, type, flags);
}

/* ── 画面 ──────────────────────────────────────────────────────────── */

static BOOL e2e_end_paint(rdpContext* context)
{
	((e2eContext*)context)->frames++;
	return TRUE;
}

static BOOL e2e_desktop_resize(rdpContext* context)
{
	rdpSettings* settings = context->settings;
	UINT32 w = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
	UINT32 h = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
	emit("{\"ev\":\"desktop\",\"w\":%u,\"h\":%u}", w, h);
	return gdi_resize(context->gdi, w, h);
}

/* 黒（ほぼ黒）でない画素の割合。画面が届いているかの目安 */
static double non_black_ratio(rdpGdi* gdi)
{
	if (!gdi || !gdi->primary_buffer || gdi->width <= 0 || gdi->height <= 0)
		return 0;
	unsigned long long lit = 0, total = 0;
	for (INT32 y = 0; y < gdi->height; y += 4)
	{
		const BYTE* row = gdi->primary_buffer + (size_t)y * gdi->stride;
		for (INT32 x = 0; x < gdi->width; x += 4)
		{
			const BYTE* p = row + (size_t)x * 4;
			if (p[0] > 16 || p[1] > 16 || p[2] > 16)
				lit++;
			total++;
		}
	}
	return total ? (double)lit / (double)total : 0;
}

static BOOL write_ppm(rdpGdi* gdi, const char* path)
{
	FILE* f = fopen(path, "wb");
	if (!f)
		return FALSE;
	fprintf(f, "P6\n%d %d\n255\n", gdi->width, gdi->height);
	for (INT32 y = 0; y < gdi->height; y++)
	{
		const BYTE* row = gdi->primary_buffer + (size_t)y * gdi->stride;
		for (INT32 x = 0; x < gdi->width; x++)
		{
			const BYTE* p = row + (size_t)x * 4; /* BGRX */
			BYTE rgb[3] = { p[2], p[1], p[0] };
			fwrite(rgb, 1, 3, f);
		}
	}
	fclose(f);
	return TRUE;
}

static void on_channel_connected(void* ctx, const ChannelConnectedEventArgs* e)
{
	e2eContext* context = ctx;
	if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
	{
		context->disp = (DispClientContext*)e->pInterface;
		emit("{\"ev\":\"channel\",\"name\":\"disp\"}");
	}
	else
		freerdp_client_OnChannelConnectedEventHandler(ctx, e);
}

static void on_channel_disconnected(void* ctx, const ChannelDisconnectedEventArgs* e)
{
	e2eContext* context = ctx;
	if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
		context->disp = NULL;
	else
		freerdp_client_OnChannelDisconnectedEventHandler(ctx, e);
}

static BOOL e2e_pre_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	freerdp_register_addin_provider(e2e_addin_provider, 0);
	PubSub_SubscribeChannelConnected(context->pubSub, on_channel_connected);
	PubSub_SubscribeChannelDisconnected(context->pubSub, on_channel_disconnected);
	return TRUE;
}

static BOOL e2e_post_connect(freerdp* instance)
{
	if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
		return FALSE;
	rdpContext* context = instance->context;
	context->update->EndPaint = e2e_end_paint;
	context->update->DesktopResize = e2e_desktop_resize;
	emit("{\"ev\":\"connected\",\"w\":%u,\"h\":%u}",
	     freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth),
	     freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight));
	return TRUE;
}

static void e2e_post_disconnect(freerdp* instance)
{
	gdi_free(instance);
}

static BOOL e2e_client_new(freerdp* instance, rdpContext* context)
{
	(void)context;
	instance->PreConnect = e2e_pre_connect;
	instance->PostConnect = e2e_post_connect;
	instance->PostDisconnect = e2e_post_disconnect;
	return TRUE;
}

/* ── 命令 ──────────────────────────────────────────────────────────── */

static void* stdin_reader(void* arg)
{
	(void)arg;
	char line[512];
	while (fgets(line, sizeof(line), stdin))
	{
		line[strcspn(line, "\r\n")] = 0;
		pthread_mutex_lock(&g_lock);
		if (g_queued < 64)
			g_queue[g_queued++] = strdup(line);
		pthread_mutex_unlock(&g_lock);
	}
	pthread_mutex_lock(&g_lock);
	g_stdinClosed = 1;
	pthread_mutex_unlock(&g_lock);
	return NULL;
}

/* 戻り値 FALSE: 終わる */
static BOOL run_command(e2eContext* context, const char* line)
{
	rdpContext* rc = &context->common.context;
	rdpGdi* gdi = rc->gdi;
	unsigned a = 0, b = 0, c = 0;
	char path[400];
	if (strcmp(line, "stats") == 0)
	{
		emit("{\"ev\":\"stats\",\"w\":%d,\"h\":%d,\"frames\":%llu,\"lit\":%.4f,\"audioBytes\":%llu,"
		     "\"disp\":%s}",
		     gdi ? gdi->width : 0, gdi ? gdi->height : 0, context->frames, non_black_ratio(gdi),
		     g_audioBytes, context->disp ? "true" : "false");
	}
	else if (sscanf(line, "resize %u %u %u", &a, &b, &c) == 3)
	{
		if (!context->disp)
		{
			emit("{\"ev\":\"error\",\"msg\":\"disp channel not connected\"}");
			return TRUE;
		}
		DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
		layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
		layout.Width = a;
		layout.Height = b;
		layout.DesktopScaleFactor = c;
		layout.DeviceScaleFactor = c >= 175 ? 180 : (c >= 125 ? 140 : 100);
		layout.Orientation = ORIENTATION_LANDSCAPE;
		layout.PhysicalWidth = a * 254 / 960; /* 96 dpi 相当 */
		layout.PhysicalHeight = b * 254 / 960;
		UINT rv = context->disp->SendMonitorLayout(context->disp, 1, &layout);
		emit("{\"ev\":\"resize-sent\",\"w\":%u,\"h\":%u,\"scale\":%u,\"rv\":%u}", a, b, c, rv);
	}
	else if (sscanf(line, "mouse %u %u", &a, &b) == 2)
	{
		freerdp_input_send_mouse_event(rc->input, PTR_FLAGS_MOVE, (UINT16)a, (UINT16)b);
		emit("{\"ev\":\"ok\",\"cmd\":\"mouse\"}");
	}
	else if (sscanf(line, "click %u %u", &a, &b) == 2)
	{
		freerdp_input_send_mouse_event(rc->input, PTR_FLAGS_MOVE, (UINT16)a, (UINT16)b);
		freerdp_input_send_mouse_event(rc->input, PTR_FLAGS_DOWN | PTR_FLAGS_BUTTON1, (UINT16)a,
		                               (UINT16)b);
		freerdp_input_send_mouse_event(rc->input, PTR_FLAGS_BUTTON1, (UINT16)a, (UINT16)b);
		emit("{\"ev\":\"ok\",\"cmd\":\"click\"}");
	}
	else if (sscanf(line, "key %x", &a) == 1)
	{
		DWORD rdpCode = MAKE_RDP_SCANCODE(a & 0xFF, (a & 0xE000) ? TRUE : FALSE);
		freerdp_input_send_keyboard_event_ex(rc->input, TRUE, FALSE, rdpCode);
		freerdp_input_send_keyboard_event_ex(rc->input, FALSE, FALSE, rdpCode);
		emit("{\"ev\":\"ok\",\"cmd\":\"key\"}");
	}
	else if (sscanf(line, "unicode %u", &a) == 1)
	{
		freerdp_input_send_unicode_keyboard_event(rc->input, 0, (UINT16)a);
		freerdp_input_send_unicode_keyboard_event(rc->input, KBD_FLAGS_RELEASE, (UINT16)a);
		emit("{\"ev\":\"ok\",\"cmd\":\"unicode\"}");
	}
	else if (sscanf(line, "shot %399s", path) == 1)
	{
		emit("{\"ev\":\"shot\",\"ok\":%s}", gdi && write_ppm(gdi, path) ? "true" : "false");
	}
	else if (strcmp(line, "quit") == 0)
	{
		return FALSE;
	}
	else if (line[0])
	{
		emit("{\"ev\":\"error\",\"msg\":\"unknown command\"}");
	}
	return TRUE;
}

int main(int argc, char* argv[])
{
	int sep = 1;
	const char* audioPath = NULL;
	for (; sep < argc && strcmp(argv[sep], "--") != 0; sep++)
	{
		if (strcmp(argv[sep], "--audio") == 0 && sep + 1 < argc)
			audioPath = argv[++sep];
		else if (strcmp(argv[sep], "--aac") == 0)
			g_acceptAac = TRUE;
	}
	if (sep >= argc)
	{
		fprintf(stderr, "usage: %s [--audio file.raw] -- <FreeRDP arguments>\n", argv[0]);
		return 2;
	}
	if (audioPath && !(g_audio = fopen(audioPath, "wb")))
	{
		fprintf(stderr, "cannot open %s: %s\n", audioPath, strerror(errno));
		return 2;
	}

	RDP_CLIENT_ENTRY_POINTS ep = { 0 };
	ep.Version = RDP_CLIENT_INTERFACE_VERSION;
	ep.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	ep.ContextSize = sizeof(e2eContext);
	ep.ClientNew = e2e_client_new;
	rdpContext* context = freerdp_client_context_new(&ep);
	if (!context)
		return 1;

	/* FreeRDP の引数は argv[0] を先頭に置いて渡す */
	char** fargv = calloc((size_t)(argc - sep + 1), sizeof(char*));
	int fargc = 0;
	fargv[fargc++] = argv[0];
	for (int i = sep + 1; i < argc; i++)
		fargv[fargc++] = argv[i];
	if (freerdp_client_settings_parse_command_line(context->settings, fargc, fargv, FALSE) != 0)
	{
		fprintf(stderr, "bad FreeRDP arguments\n");
		return 2;
	}

	freerdp* instance = context->instance;
	if (!freerdp_connect(instance))
	{
		emit("{\"ev\":\"connect-failed\",\"error\":\"0x%08x\"}",
		     freerdp_get_last_error(context));
		freerdp_client_context_free(context);
		return 1;
	}

	pthread_t reader;
	pthread_create(&reader, NULL, stdin_reader, NULL);
	pthread_detach(reader);

	BOOL running = TRUE;
	while (running && !freerdp_shall_disconnect_context(context))
	{
		HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
		DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
		if (count == 0)
			break;
		if (WaitForMultipleObjects(count, handles, FALSE, 50) == WAIT_FAILED)
			break;
		if (!freerdp_check_event_handles(context))
			break;

		pthread_mutex_lock(&g_lock);
		int n = g_queued;
		char* lines[64];
		memcpy(lines, g_queue, sizeof(char*) * (size_t)n);
		g_queued = 0;
		int closed = g_stdinClosed;
		pthread_mutex_unlock(&g_lock);
		for (int i = 0; i < n; i++)
		{
			if (running && !run_command((e2eContext*)context, lines[i]))
				running = FALSE;
			free(lines[i]);
		}
		if (closed && n == 0)
			running = FALSE;
	}
	UINT32 error = freerdp_get_last_error(context);
	freerdp_disconnect(instance);
	emit("{\"ev\":\"disconnected\",\"byServer\":%s,\"error\":\"0x%08x\"}",
	     running ? "true" : "false", error);
	if (g_audio)
		fclose(g_audio);
	freerdp_client_context_free(context);
	free(fargv);
	return 0;
}
