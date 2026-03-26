#!/usr/bin/env python3
"""
ClickForge Engine — HTTP сервер для SwiftUI фронтенда.
Порт: 47291 (localhost only).
"""

import os
# Расширяем PATH до поиска ffmpeg — при запуске из .app окружение может быть пустым
_path_extra = "/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/opt/ffmpeg/bin"
if _path_extra not in os.environ.get("PATH", ""):
    os.environ["PATH"] = os.environ.get("PATH", "") + (":" if os.environ.get("PATH") else "") + _path_extra
import sys, json, re, threading, traceback, subprocess, time
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs
import numpy as np

# ── аудио ──────────────────────────────────────────────────────────────────
import librosa
import soundfile as sf
import sounddevice as sd
from pydub import AudioSegment

def _get_ffmpeg() -> str:
    """Путь к ffmpeg: bundled, imageio, homebrew, which, системный."""
    # 1. В бандле .app: Resources/tools/ffmpeg (рядом с engine/)
    try:
        _engine_dir = os.path.dirname(os.path.abspath(__file__))
        _tools_dir = os.path.join(os.path.dirname(_engine_dir), "tools")
        _bundled = os.path.join(_tools_dir, "ffmpeg")
        if os.path.isfile(_bundled):
            return _bundled
    except Exception:
        pass
    try:
        import imageio_ffmpeg
        exe = imageio_ffmpeg.get_ffmpeg_exe()
        if exe and os.path.isfile(exe):
            return exe
    except Exception:
        pass
    for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/opt/ffmpeg/bin/ffmpeg"]:
        if os.path.isfile(path):
            return path
    try:
        import shutil
        which = shutil.which("ffmpeg")
        if which:
            return which
    except Exception:
        pass
    return "ffmpeg"

_FFMPEG_PATH = _get_ffmpeg()
AudioSegment.converter = _FFMPEG_PATH
AudioSegment.ffmpeg = _FFMPEG_PATH
if "/" in _FFMPEG_PATH:
    _ffprobe = _FFMPEG_PATH.replace("ffmpeg", "ffprobe")
    if os.path.isfile(_ffprobe):
        AudioSegment.ffprobe = _ffprobe

def _check_ffmpeg() -> str:
    """Проверяет, что ffmpeg доступен. Возвращает ошибку или пустую строку."""
    if "/" in _FFMPEG_PATH and os.path.isfile(_FFMPEG_PATH):
        return ""
    try:
        r = subprocess.run(
            [_FFMPEG_PATH, "-version"],
            capture_output=True,
            timeout=5,
        )
        if r.returncode == 0:
            return ""
    except (FileNotFoundError, OSError) as e:
        pass
    return (
        "FFmpeg не найден. Установите: brew install ffmpeg\n"
        "или: pip install imageio-ffmpeg"
    )

AUDIO_EXT = {".wav", ".mp3", ".aiff", ".aif", ".flac", ".m4a", ".ogg"}
PORT = 47291
_DEBUG_LOG = "/tmp/clickforge.log"

def _log(msg: str):
    """Пишет в лог-файл (добавлением)."""
    try:
        with open(_DEBUG_LOG, "a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except Exception:
        pass

# ── производительность ────────────────────────────────────────────────────
_perf_cpu = 0.0
_perf_mem = 0.0

def _start_perf_thread():
    global _perf_cpu, _perf_mem
    def _loop():
        global _perf_cpu, _perf_mem
        try:
            import psutil
            proc = psutil.Process()
            proc.cpu_percent()  # первый вызов — инициализация
            while True:
                _perf_cpu = proc.cpu_percent()
                _perf_mem = proc.memory_info().rss / 1_048_576
                time.sleep(1)
        except ImportError:
            try:
                import resource
                while True:
                    ru = resource.getrusage(resource.RUSAGE_SELF)
                    _perf_mem = ru.ru_maxrss / 1_048_576
                    time.sleep(2)
            except Exception:
                pass
    threading.Thread(target=_loop, daemon=True).start()

_start_perf_thread()

# ── аудио устройство и роутинг ────────────────────────────────────────────
_mt_device_idx = None  # None = системное по умолчанию
_mt_n_ch       = 2     # количество выходных каналов устройства

# ── глобальный прогресс ────────────────────────────────────────────────────
_progress      = {"stage": "idle", "pct": 0, "msg": ""}
_progress_lock = threading.Lock()

def _set_progress(stage: str, pct: int, msg: str = ""):
    with _progress_lock:
        _progress["stage"] = stage
        _progress["pct"]   = pct
        _progress["msg"]   = msg

def _get_progress() -> dict:
    with _progress_lock:
        return dict(_progress)

# ── многодорожечный плеер ─────────────────────────────────────────────────
# Callback работает в real-time потоке — блокировки недопустимы.
# GIL в CPython защищает атомарные присваивания bool/int/list-элементов.

_mt_lock         = threading.Lock()
_mt_stream       = None
_mt_tracks_raw   = []      # list[np.ndarray (N,) float32] — все треки в памяти
_mt_tracks_lr    = []      # list[tuple[np.ndarray, np.ndarray]] — per-track L/R для индикации
_mt_gain_factors = []      # list[float] — линейный gain, меняется из main thread
_mt_active       = []      # list[bool]  — True если трек слышен (не muted / solo)
_mt_levels       = []      # list[float] — пиковый уровень из callback [0..1]
_mt_lr_levels    = []      # list[list[float,float]] — per-track L/R пики [0..1]
_mt_ch_starts    = []      # list[int]   — стартовый канал вывода (0-based, шаг 2)
_mt_ch_levels    = []      # list[float] — уровни выходных каналов [0..1]
_mt_pos          = 0       # текущий фрейм
_mt_total        = 0       # всего фреймов
_mt_sr           = 44100
_mt_playing      = False

def _mt_callback(outdata, frames, time_info, status):
    """Real-time микширование всех треков с per-track роутингом на каналы."""
    global _mt_pos, _mt_playing, _mt_ch_levels
    pos = _mt_pos
    if not _mt_playing or _mt_total == 0 or pos >= _mt_total:
        outdata[:] = 0
        _mt_playing = False
        raise sd.CallbackStop()

    end    = min(pos + frames, _mt_total)
    actual = end - pos
    n_ch   = outdata.shape[1]
    outdata[:] = 0.0

    tracks    = _mt_tracks_raw
    tracks_lr = _mt_tracks_lr
    gains     = _mt_gain_factors
    active    = _mt_active
    levels    = _mt_levels
    lr_levels = _mt_lr_levels
    ch_starts = _mt_ch_starts

    for i, track in enumerate(tracks):
        chunk = track[pos:end] if pos < len(track) else np.array([], dtype=np.float32)
        n = len(chunk)
        is_active = i < len(active) and active[i]

        if not is_active or n == 0:
            # Трек muted / solo-excluded → VU = 0
            if i < len(levels): levels[i] = 0.0
            if i < len(lr_levels): lr_levels[i] = [0.0, 0.0]
            continue

        gain = gains[i] if i < len(gains) else 1.0
        data = chunk[:n] * gain if gain != 1.0 else chunk[:n]

        # VU трека — ПОСЛЕ применения gain
        if i < len(levels):
            levels[i] = float(np.amax(np.abs(data)))
        if i < len(lr_levels):
            if i < len(tracks_lr):
                l_full, r_full = tracks_lr[i]
                l_chunk = l_full[pos:end] if pos < len(l_full) else np.array([], dtype=np.float32)
                r_chunk = r_full[pos:end] if pos < len(r_full) else np.array([], dtype=np.float32)
                if gain != 1.0:
                    if len(l_chunk): l_chunk = l_chunk * gain
                    if len(r_chunk): r_chunk = r_chunk * gain
                l_peak = float(np.amax(np.abs(l_chunk))) if len(l_chunk) else 0.0
                r_peak = float(np.amax(np.abs(r_chunk))) if len(r_chunk) else 0.0
                lr_levels[i] = [l_peak, r_peak]
            else:
                lr_levels[i] = [levels[i], levels[i]]

        ch = ch_starts[i] if i < len(ch_starts) else 0
        if ch >= n_ch:
            ch = 0   # канал не существует на этом устройстве → fallback L/R
        if ch < n_ch:
            outdata[:n, ch] += data
        if ch + 1 < n_ch:
            outdata[:n, ch + 1] += data

    # Мягкое ограничение + измерение мастер-уровней по каждому каналу
    ch_lv = []
    for c in range(n_ch):
        peak = float(np.amax(np.abs(outdata[:actual, c]))) if actual > 0 else 0.0
        if peak > 0.95:
            outdata[:actual, c] *= 0.95 / peak
            peak = 0.95
        ch_lv.append(round(peak, 3))
    _mt_ch_levels = ch_lv

    if actual < frames:
        outdata[actual:] = 0.0
    _mt_pos = end
    if end >= _mt_total:
        _mt_playing = False
        raise sd.CallbackStop()

def _mt_load(tracks_info: list, sr_target: int = 44100):
    """Загружает все треки в RAM. tracks_info: [{path, gain_db, muted, solo, ch_start}]"""
    global _mt_tracks_raw, _mt_tracks_lr, _mt_gain_factors, _mt_active, _mt_levels, _mt_lr_levels, _mt_ch_starts
    global _mt_pos, _mt_total, _mt_sr, _mt_playing

    _mt_pause()

    raw, tracks_lr, gains, active, ch_starts = [], [], [], [], []
    solo_any = any(t.get("solo") for t in tracks_info)
    max_len  = 0

    def _decode_sf(path: str):
        y2d, sr = sf.read(path, dtype='float32', always_2d=True)
        y2d = np.asarray(y2d, dtype=np.float32)
        if y2d.shape[1] == 1:
            l = y2d[:, 0].copy()
            r = l.copy()
        else:
            l = y2d[:, 0].copy()
            r = y2d[:, 1].copy()
        mono = y2d.mean(axis=1).astype(np.float32)
        return mono, l, r, int(sr), "sf"

    def _decode_pydub(path: str):
        seg = AudioSegment.from_file(path)
        samples = np.array(seg.get_array_of_samples())
        if seg.channels > 1:
            s2d = samples.reshape((-1, seg.channels)).astype(np.float32)
            l = s2d[:, 0]
            r = s2d[:, 1] if seg.channels > 1 else s2d[:, 0]
            mono = s2d.mean(axis=1)
        else:
            mono = samples.astype(np.float32)
            l = mono.copy()
            r = mono.copy()
        denom = float(1 << (8 * seg.sample_width - 1))
        scale = max(denom, 1.0)
        mono = (mono / scale).astype(np.float32)
        l = (l / scale).astype(np.float32)
        r = (r / scale).astype(np.float32)
        return mono, l, r, int(seg.frame_rate), "pydub"

    for t in tracks_info:
        path = t.get("path", "")
        if not os.path.isfile(path):
            raw.append(np.zeros(1, dtype=np.float32))
            tracks_lr.append((np.zeros(1, dtype=np.float32), np.zeros(1, dtype=np.float32)))
            gains.append(1.0)
            active.append(False)
            ch_starts.append(0)
            continue
        ext = os.path.splitext(path)[1].lower()
        decoders = [_decode_pydub, _decode_sf] if ext == ".mp3" else [_decode_sf, _decode_pydub]
        y, yl, yr, sr, src = None, None, None, sr_target, ""
        errs = []
        for dec in decoders:
            try:
                y_try, yl_try, yr_try, sr_try, src_try = dec(path)
                if y_try is None or len(y_try) == 0:
                    raise RuntimeError("decoded empty audio")
                # Для mp3 иногда sf может вернуть почти тишину — перепробуем второй декодер.
                if ext == ".mp3" and src_try == "sf":
                    rms = float(np.sqrt(np.mean(np.square(y_try)))) if len(y_try) else 0.0
                    if rms < 1e-6:
                        raise RuntimeError("sf decode near-silent rms")
                y, yl, yr, sr, src = y_try, yl_try, yr_try, sr_try, src_try
                break
            except Exception as e:
                errs.append(f"{dec.__name__}: {e}")
        if y is None:
            _log(f"_mt_load: skip unreadable file {path!r}: {' | '.join(errs)}")
            raw.append(np.zeros(1, dtype=np.float32))
            tracks_lr.append((np.zeros(1, dtype=np.float32), np.zeros(1, dtype=np.float32)))
            gains.append(1.0)
            active.append(False)
            ch_starts.append(0)
            continue
        if sr != sr_target:
            y = librosa.resample(y, orig_sr=sr, target_sr=sr_target)
            yl = librosa.resample(yl, orig_sr=sr, target_sr=sr_target)
            yr = librosa.resample(yr, orig_sr=sr, target_sr=sr_target)
        raw.append(y)
        tracks_lr.append((yl, yr))
        gains.append(10 ** (float(t.get("gain_db", 0)) / 20.0))
        is_active = not t.get("muted", False) and (not solo_any or t.get("solo", False))
        active.append(is_active)
        ch_starts.append(int(t.get("ch_start", 0)))
        max_len = max(max_len, len(y))
        _log(f"_mt_load: loaded {os.path.basename(path)!r} via {src}, samples={len(y)}, active={is_active}")

    _mt_tracks_raw   = raw
    _mt_tracks_lr    = tracks_lr
    _mt_gain_factors = gains
    _mt_active       = active
    _mt_ch_starts    = ch_starts
    _mt_levels       = [0.0] * len(raw)
    _mt_lr_levels    = [[0.0, 0.0] for _ in raw]
    _mt_pos          = 0
    _mt_total        = max_len
    _mt_sr           = sr_target

def _mt_pause():
    """Остановить стрим, сохранить позицию и треки в RAM."""
    global _mt_stream, _mt_playing
    _mt_playing = False
    with _mt_lock:
        if _mt_stream is not None:
            try:
                _mt_stream.stop()
                _mt_stream.close()
            except Exception:
                pass
            _mt_stream = None

def _mt_resume():
    """Возобновить воспроизведение с текущей позиции _mt_pos."""
    global _mt_stream, _mt_playing, _mt_pos, _mt_device_idx, _mt_n_ch
    if _mt_total == 0:
        return
    # Если дошли до конца — перематываем на начало
    if _mt_pos >= _mt_total:
        _mt_pos = 0
    # Останавливаем стрим только если он реально запущен
    if _mt_stream is not None:
        _mt_pause()
    with _mt_lock:
        try:
            kw = dict(samplerate=_mt_sr, channels=_mt_n_ch, dtype='float32', callback=_mt_callback)
            if _mt_device_idx is not None:
                kw['device'] = _mt_device_idx
            stream = sd.OutputStream(**kw)
            _mt_stream  = stream
            _mt_playing = True
            stream.start()
        except Exception as e:
            err_str = str(e)
            _mt_playing = False
            _mt_stream  = None
            _log(f"_mt_resume FAIL: device_idx={_mt_device_idx} err={err_str[:120]}")
            # Всегда пробуем fallback при любой ошибке открытия
            if True:
                fallbacks = [
                    {"device": None, "channels": 2},
                    {"device": None, "channels": 2, "latency": "high"},
                    {"device": None, "channels": 2, "blocksize": 1024},
                ]
                last_err = e
                for opts in fallbacks:
                    ch = opts.pop("channels", 2)
                    dev = opts.pop("device", None)
                    try:
                        kw = dict(samplerate=_mt_sr, channels=ch, dtype='float32',
                                  callback=_mt_callback, **opts)
                        if dev is not None:
                            kw['device'] = dev
                        _log(f"fallback attempt: kw={list(kw.keys())}")
                        stream = sd.OutputStream(**kw)
                        _mt_stream  = stream
                        _mt_playing = True
                        stream.start()
                        _mt_device_idx = None
                        _mt_n_ch = ch
                        _log("fallback OK")
                        return  # успех
                    except Exception as ex:
                        _log(f"fallback fail: {str(ex)[:80]}")
                        last_err = ex
                _log("all fallbacks failed, raising RuntimeError")
                raise RuntimeError(
                    "Не удалось открыть аудио. Возможные причины:\n"
                    "• Устройство занято другим приложением\n"
                    "• Выберите «Системное» в настройках (Устройство вывода)\n"
                    "• Закройте DAW, браузер и другие аудио-приложения\n"
                    "• Перезапустите ClickForge"
                ) from last_err

def _mt_start():
    """Начать воспроизведение с позиции 0."""
    global _mt_pos
    _mt_pos = 0
    # Если предыдущий стрим ещё живой — гасим
    if _mt_stream is not None:
        _mt_pause()
    _mt_resume()

def _mt_stop():
    """Полная остановка: стрим остановлен, позиция сброшена в 0."""
    global _mt_pos
    _mt_pause()
    _mt_pos = 0

def _mt_update(tracks_info: list):
    """Обновляет gain/mute/solo/routing без перезагрузки — работает в реальном времени."""
    solo_any = any(t.get("solo") for t in tracks_info)
    for i, t in enumerate(tracks_info):
        if i >= len(_mt_tracks_raw):
            break
        if i < len(_mt_gain_factors):
            _mt_gain_factors[i] = 10 ** (float(t.get("gain_db", 0)) / 20.0)
        if i < len(_mt_active):
            _mt_active[i] = not t.get("muted", False) and (not solo_any or t.get("solo", False))
        if i < len(_mt_ch_starts):
            _mt_ch_starts[i] = int(t.get("ch_start", 0))

def _mt_status() -> dict:
    dur    = _mt_total / _mt_sr if _mt_sr > 0 and _mt_total > 0 else 0.0
    pos    = min(_mt_pos / _mt_sr, dur) if _mt_sr > 0 else 0.0
    loaded = _mt_total > 0
    at_end = _mt_total > 0 and _mt_pos >= _mt_total
    return {
        "playing":   _mt_playing,
        "pos_sec":   round(pos, 2),
        "dur_sec":   round(dur, 2),
        "levels":    [round(v, 3) for v in _mt_levels],
        "track_lr_levels": [[round(v[0], 3), round(v[1], 3)] for v in _mt_lr_levels],
        "ch_levels": list(_mt_ch_levels),   # уровни выходных каналов (мастер)
        "loaded":    loaded,
        "at_end":    at_end,
    }

# ── helpers ────────────────────────────────────────────────────────────────

def _json(obj):
    return json.dumps(obj, ensure_ascii=False).encode()

def _rms_dbfs(path: str) -> float:
    try:
        y, sr = sf.read(path, dtype='float32', always_2d=False)
        if y.ndim > 1:
            y = y.mean(axis=1)
        rms = float(np.sqrt(np.mean(y ** 2)))
        return float(20 * np.log10(rms + 1e-9))
    except Exception:
        return -99.0

def _waveform(path: str, n_bars: int = 80) -> list:
    """Возвращает n_bars нормализованных RMS значений [0..1]."""
    try:
        y, sr = sf.read(path, dtype='float32', always_2d=False)
        if y.ndim > 1:
            y = y.mean(axis=1).astype(np.float32)
        hop = max(1, len(y) // n_bars)
        bars = []
        for i in range(n_bars):
            chunk = y[i * hop: (i + 1) * hop]
            rms = float(np.sqrt(np.mean(chunk ** 2))) if len(chunk) else 0.0
            bars.append(rms)
        peak = max(bars) or 1.0
        return [round(v / peak, 3) for v in bars]
    except Exception:
        return [0.0] * n_bars

def _scan_folder(folder: str) -> list:
    files = []
    for name in sorted(os.listdir(folder)):
        ext = os.path.splitext(name)[1].lower()
        if ext in AUDIO_EXT:
            full = os.path.join(folder, name)
            size_mb = round(os.path.getsize(full) / 1_048_576, 1)
            files.append({
                "name":        name,
                "path":        full,
                "rms_db":      round(_rms_dbfs(full), 1),
                "waveform":    _waveform(full),
                "file_size_mb": size_mb,
            })
    return files

def _analyze_folder_beat_times_ms(folder: str) -> list:
    """
    Beat map как в оригинальном PreClick Tool:
    суммируем все треки папки и считаем beat_times (в мс).
    """
    files = sorted([
        os.path.join(folder, f) for f in os.listdir(folder)
        if os.path.splitext(f)[1].lower() in AUDIO_EXT
    ])
    y_sum, sr = None, 22050
    for fp in files:
        try:
            yt, _ = librosa.load(fp, sr=sr, mono=True)
            if y_sum is None:
                y_sum = yt
            else:
                l = min(len(y_sum), len(yt))
                y_sum = y_sum[:l] + yt[:l]
        except Exception:
            pass

    if y_sum is None:
        return []

    peak = np.max(np.abs(y_sum))
    if peak > 0:
        y_sum /= peak

    _, beat_frames = librosa.beat.beat_track(y=y_sum, sr=sr, trim=False)
    return (librosa.frames_to_time(beat_frames, sr=sr) * 1000).tolist()

def _analyze(path: str, analyze_all: bool = False) -> dict:
    """BPM + тональность + биты. analyze_all — суммировать все треки папки."""
    if analyze_all:
        folder = os.path.dirname(path)
        files  = sorted([os.path.join(folder, f) for f in os.listdir(folder)
                         if os.path.splitext(f)[1].lower() in AUDIO_EXT])
        y_sum, sr = None, 22050
        for fp in files:
            try:
                yt, _ = librosa.load(fp, sr=sr, mono=True)
                if y_sum is None:
                    y_sum = yt
                else:
                    l = min(len(y_sum), len(yt))
                    y_sum = y_sum[:l] + yt[:l]
            except Exception:
                pass
        if y_sum is not None:
            peak = np.max(np.abs(y_sum))
            if peak > 0: y_sum /= peak
            y = y_sum
        else:
            y, sr = librosa.load(path, sr=22050, mono=True)
    else:
        y, sr = librosa.load(path, sr=22050, mono=True)

    tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr, trim=False)
    beat_times = librosa.frames_to_time(beat_frames, sr=sr).tolist()
    bpm = float(np.round(float(tempo[0]) if hasattr(tempo, '__len__') else float(tempo), 1))

    # first_beat_ms — для выравнивания предклика: пре-клик ведёт в первый бит трека
    if len(beat_times) >= 4:
        first_beat_ms = float(beat_times[0]) * 1000
        beat_ms_med = float(np.median(np.diff(beat_times))) * 1000 if len(beat_times) > 1 else 60000.0 / bpm
    else:
        onset_times = librosa.onset.onset_detect(y=y, sr=sr, units="time", backtrack=True)
        if len(onset_times) == 0:
            first_beat_ms = 0
            beat_ms_med = 60000.0 / bpm
        else:
            first_beat_ms = float(onset_times[0]) * 1000
            n = min(40, len(onset_times) - 1)
            beat_ms_med = (float(onset_times[n]) - float(onset_times[0])) / max(1, n) * 1000 if n > 0 else 60000.0 / bpm

    chroma        = librosa.feature.chroma_cqt(y=y, sr=sr)
    chroma_mean   = chroma.mean(axis=1)
    key_names     = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']
    major_profile = np.array([6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88])
    minor_profile = np.array([6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17])
    best_score, best_key = -np.inf, "C major"
    for i in range(12):
        rolled = np.roll(chroma_mean, -i)
        s_maj = float(np.corrcoef(rolled, major_profile)[0, 1])
        s_min = float(np.corrcoef(rolled, minor_profile)[0, 1])
        if s_maj > best_score:
            best_score, best_key = s_maj, f"{key_names[i]} major"
        if s_min > best_score:
            best_score, best_key = s_min, f"{key_names[i]} minor"

    # Для стыковки предклика важнее измеренный интервал между битами,
    # чем пересчёт из округлённого BPM.
    beat_ms  = beat_ms_med if beat_ms_med > 0 else ((60000.0 / bpm) if bpm > 0 else 500.0)
    num_bars = max(1, int(len(beat_times) / 4)) if beat_times else 1

    return {
        "bpm":           bpm,
        "key":           best_key,
        "beat_ms":       round(beat_ms, 1),
        "num_bars":      num_bars,
        "beat_count":    len(beat_times),
        "first_beat_ms": round(first_beat_ms, 1),
    }

def _generate_beep(freq=880, duration_ms=70, sr=44100, volume_db=-6):
    # Как в оригинальном PreClick Tool: атака + экспоненциальный спад.
    n = int(sr * duration_ms / 1000)
    t = np.linspace(0, duration_ms / 1000, n, endpoint=False)
    wave = np.sin(2 * np.pi * freq * t)
    attack = min(int(0.005 * sr), n)
    wave[:attack] *= np.linspace(0, 1, attack)
    wave *= np.exp(-np.linspace(0, 6, n))
    wave *= 10 ** (volume_db / 20)
    pcm = (wave * 32767).clip(-32767, 32767).astype(np.int16)
    return AudioSegment(pcm.tobytes(), frame_rate=sr, sample_width=2, channels=1)

def _process(folder: str, out_dir: str, tracks: list, groups: dict = None,
             bpm: float = 120, beat_ms: float = None, first_beat_ms: float = 0, click_db: float = -6,
             preclick_bars: int = 1, preclick_start_beat: int = 1, fmt: str = "mp3", bit_depth: int = 24,
             voice: bool = False, voice_vol_db: float = -6,
             create_metro: bool = True) -> dict:
    """
    tracks — список {"name": ..., "gain_db": ..., "muted": bool, "solo": bool}
    groups — {имя_группы: [имя1, имя2, ...]} — треки в группе микшируются в один файл
    """
    err = _check_ffmpeg()
    if err:
        raise RuntimeError(err)

    groups = groups or {}
    if bpm <= 0:
        raise ValueError(f"Недопустимый BPM: {bpm}")

    out_dir = os.path.abspath(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    # Очищаем папку назначения — чтобы не оставались файлы от прошлых запусков
    for f in os.listdir(out_dir):
        path = os.path.join(out_dir, f)
        if os.path.isfile(path) or os.path.islink(path):
            try:
                os.remove(path)
            except OSError:
                pass
    _set_progress("process", 0, "Подготовка…")
    _log(f"process start folder={folder!r} out_dir={out_dir!r} tracks={len(tracks)} groups={list((groups or {}).keys())}")

    beat_ms        = float(beat_ms) if beat_ms and beat_ms > 0 else (60000.0 / bpm)
    preclick_beats = preclick_bars * 4
    start_beat = max(1, min(4, int(preclick_start_beat or 1)))
    beat_order = [((start_beat - 1 + i) % 4) + 1 for i in range(4)]

    beep_hi = _generate_beep(freq=880, duration_ms=70, volume_db=click_db)
    beep_lo = _generate_beep(freq=660, duration_ms=70, volume_db=click_db - 3)

    # Пре-клик
    preclick = AudioSegment.silent(duration=int(beat_ms * preclick_beats))
    for i in range(preclick_beats):
        beat_num = beat_order[i % 4]
        b = beep_hi if beat_num == 1 else beep_lo
        preclick = preclick.overlay(b, position=int(i * beat_ms))

    exp_kw = {"format": fmt}
    if fmt == "mp3":
        exp_kw["bitrate"] = "192k"
    elif fmt == "wav":
        exp_kw["parameters"] = ["-acodec", f"pcm_s{bit_depth}le"]

    # ── Голосовой отсчёт (macOS say) — по логике PreClick Tool ─────────────
    voice_clips = []
    if voice:
        _set_progress("process", 2, "Генерация голоса…")
        TEMP_DIR = "/tmp/clickforge_voice"
        os.makedirs(TEMP_DIR, exist_ok=True)
        word_by_num = {1: "one", 2: "two", 3: "three", 4: "four"}
        ordered_words = [word_by_num[n] for n in beat_order]
        for i, word in enumerate(ordered_words):
            aiff = f"{TEMP_DIR}/{i+1}.aiff"
            wav  = f"{TEMP_DIR}/{i+1}.wav"
            try:
                subprocess.run(["say", "-v", "Samantha", "-r", "220", "-o", aiff, word],
                               check=True)
                subprocess.run([_FFMPEG_PATH, "-y", "-i", aiff, wav],
                               check=True, capture_output=True)
                clip = AudioSegment.from_wav(wav)
                y_c, sr_c = librosa.load(wav)
                onsets_bt = librosa.onset.onset_detect(y=y_c, sr=sr_c, units="time", backtrack=True)
                onset_off = int(float(onsets_bt[0]) * 1000) if len(onsets_bt) > 0 else 0
                clip = clip[onset_off : onset_off + int(beat_ms * 0.85)]
                clip = clip.apply_gain(voice_vol_db)
                voice_clips.append(clip)
            except Exception:
                voice_clips.append(AudioSegment.silent(duration=int(beat_ms * 0.85)))

    # Голос в пре-клике — для треков, групп и метронома
    if voice_clips:
        for bar in range(preclick_bars):
            for i, clip in enumerate(voice_clips):
                preclick = preclick.overlay(clip, position=int(beat_ms * (bar * 4 + i)))

    solo_active = any(t.get("solo") for t in tracks)
    tracks_by_name = {t["name"]: t for t in tracks}

    def _get_gain(name): return float(tracks_by_name.get(name, {}).get("gain_db", 0))
    def _is_active(t): return not t.get("muted") and (not solo_active or t.get("solo"))
    def _analyze_active_mix_beat_times_ms() -> list:
        """
        Beat map по активному миксу (с учётом solo/mute/gain), а не по отдельным трекам.
        """
        y_sum, sr = None, 22050
        for t in tracks:
            if not _is_active(t):
                continue
            name = t.get("name", "")
            if not name:
                continue
            path = os.path.join(folder, name)
            if not os.path.exists(path):
                continue
            try:
                yt, _ = librosa.load(path, sr=sr, mono=True)
                gain = _get_gain(name)
                if gain != 0:
                    yt = yt * (10 ** (gain / 20.0))
                if y_sum is None:
                    y_sum = yt
                else:
                    l = min(len(y_sum), len(yt))
                    y_sum = y_sum[:l] + yt[:l]
            except Exception:
                pass

        if y_sum is None:
            return []

        peak = np.max(np.abs(y_sum))
        if peak > 0:
            y_sum /= peak

        _, beat_frames = librosa.beat.beat_track(y=y_sum, sr=sr, trim=False)
        return (librosa.frames_to_time(beat_frames, sr=sr) * 1000).tolist()

    # Треки в группах — микшируются в один файл, НЕ экспортируются по отдельности
    # groups: {имя_группы: [имя1, имя2, ...]} — нормализуем на случай разного формата
    grouped_names = set()
    normalized_groups = {}
    for gname, gfiles in (groups or {}).items():
        if not isinstance(gfiles, (list, tuple)):
            continue
        names = [str(f).strip() for f in gfiles if f]
        if names:
            normalized_groups[gname] = names
            grouped_names.update(names)

    # Одиночные активные треки — ТОЛЬКО те, что НЕ в группах
    solo_tracks = []
    missing = []
    for t in tracks:
        if not _is_active(t):
            continue
        path = os.path.join(folder, t["name"])
        if not os.path.exists(path):
            missing.append(t["name"])
            continue
        tname = t.get("name", "")
        if tname in grouped_names:
            continue  # трек в группе — экспортируем только микс группы
        solo_tracks.append((t, path))

    # Активные группы (хотя бы один трек в группе активен и существует)
    active_groups = []
    for gname, gfiles in normalized_groups.items():
        active_files = [f for f in gfiles if f in tracks_by_name and _is_active(tracks_by_name[f])
                        and os.path.exists(os.path.join(folder, f))]
        if active_files:
            active_groups.append((gname, active_files))

    total = max(len(solo_tracks) + len(active_groups), 1)
    exported = []
    loaded_segs = {}
    done = 0

    def _strip_click(s: str) -> str:
        """Удаляет хвосты click: _click, -click, ' click', _click2, повторения."""
        out = s
        # Снимаем хвосты вида "_click", "-click", " click", "_click2", "_click_02"
        # и повторения на конце: "..._click_click".
        while True:
            updated = re.sub(r"(?i)(?:[_\-\s\uFF3F]*click(?:[_\-\s]*\d*)?)$", "", out).strip("_- ")
            if updated == out:
                break
            out = updated
        return out

    def _out_basename(name: str) -> str:
        """Имя без расширения и без _click."""
        base = os.path.splitext(name)[0]
        return _strip_click(base)

    # Как в оригинальном PreClick Tool:
    # не режем начало трека, а добавляем тишину так, чтобы первый бит трека
    # совпал с концом предклика.
    pad_ms = max(0, int(beat_ms * preclick_beats) - int(first_beat_ms))
    silence_pad = AudioSegment.silent(duration=pad_ms)
    for t, path in solo_tracks:
        done += 1
        pct = int(10 + (done / total) * 75)
        _set_progress("process", pct, f"Трек {done}/{total}: {t['name']}")
        seg = AudioSegment.from_file(path)
        loaded_segs[path] = seg
        gain = _get_gain(t["name"])
        if gain != 0:
            seg = seg + gain
        out = silence_pad + seg
        out_name = _out_basename(t["name"]) + f".{fmt}"
        out.export(os.path.join(out_dir, out_name), **exp_kw)
        exported.append(out_name)
        _log(f"  export track {t['name']!r} -> {out_name!r}")

    # Группы — микшируем треки без обрезки начала, затем добавляем silence_pad
    for gname, gfiles in active_groups:
        done += 1
        pct = int(10 + (done / total) * 75)
        _set_progress("process", pct, f"Группа {done}/{total}: {gname}")
        mixed = None
        for fname in gfiles:
            path = os.path.join(folder, fname)
            seg = loaded_segs.get(path)
            if seg is None:
                seg = AudioSegment.from_file(path)
                loaded_segs[path] = seg
            gain = _get_gain(fname)
            if gain != 0:
                seg = seg + gain
            mixed = seg if mixed is None else mixed.overlay(seg)
        gbase = _strip_click(gname)
        out_name = f"{gbase}.{fmt}"
        (silence_pad + mixed).export(os.path.join(out_dir, out_name), **exp_kw)
        exported.append(out_name)
        _log(f"  export group {gname!r} -> {out_name!r}")

    # Метроном-трек — как в оригинальном PreClick Tool:
    # строим клики по реальным beat_times, а не по идеально ровной сетке.
    if loaded_segs and create_metro:
        _set_progress("process", 88, "Метроном…")
        beat_times_ms = _analyze_active_mix_beat_times_ms()
        if not beat_times_ms:
            # Fallback: если активный микс пуст/неанализируем, используем старый способ по папке.
            beat_times_ms = _analyze_folder_beat_times_ms(folder)
        if beat_times_ms:
            total_click_dur = int(beat_times_ms[-1] + beat_ms * 2)
            click_seg = AudioSegment.silent(duration=total_click_dur)
            for i, ms in enumerate(beat_times_ms):
                click_seg = click_seg.overlay(beep_hi if i % 4 == 0 else beep_lo, position=int(ms))
            metro = preclick + click_seg[int(first_beat_ms):]
        else:
            # Fallback: если beat map не удалось получить, используем ровную сетку.
            max_dur  = max(len(s) for s in loaded_segs.values())
            total_ms = int(beat_ms * preclick_beats) + max_dur + int(beat_ms * 8)
            click_seg = AudioSegment.silent(duration=total_ms)
            pos = int(beat_ms * preclick_beats)
            while pos < total_ms:
                beat_num = int((pos - int(beat_ms * preclick_beats)) / beat_ms)
                b = beep_hi if beat_num % 4 == 0 else beep_lo
                click_seg = click_seg.overlay(b, position=pos)
                pos += int(beat_ms)
            metro = preclick + click_seg[int(beat_ms * preclick_beats):]
        metro.export(os.path.join(out_dir, f"METRONOME.{fmt}"), **exp_kw)
        exported.append(f"METRONOME.{fmt}")

    msg = f"Готово: {len(exported)} файлов"
    if missing:
        msg += f" (пропущено {len(missing)}: {', '.join(missing)})"
    _set_progress("idle", 100, msg)
    # Маркер целостности результата: если файл есть, output сформирован полностью.
    try:
        manifest_path = os.path.join(out_dir, "clickforge_output_manifest.json")
        with open(manifest_path, "w", encoding="utf-8") as mf:
            json.dump({"exported": exported}, mf, ensure_ascii=False)
    except Exception as e:
        _log(f"process manifest write failed: {e!r}")
    _log(f"process done exported={exported}")
    return {"exported": exported, "out_dir": out_dir, "missing": missing}


# ── HTTP handler ───────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # тихий режим

    def _send(self, code: int, body: bytes, ct="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1")
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length)) if length else {}

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "http://127.0.0.1")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        qs     = parse_qs(parsed.query)

        if parsed.path == "/ping":
            self._send(200, _json({"ok": True}))

        elif parsed.path == "/scan":
            folder = qs.get("folder", [""])[0]
            if not os.path.isdir(folder):
                self._send(400, _json({"error": "not a directory"}))
                return
            try:
                self._send(200, _json({"files": _scan_folder(folder)}))
            except Exception as e:
                self._send(500, _json({"error": str(e)}))

        elif parsed.path == "/analyze":
            path        = qs.get("path", [""])[0]
            analyze_all = qs.get("analyze_all", ["0"])[0] == "1"
            if not os.path.isfile(path):
                self._send(400, _json({"error": "file not found"}))
                return
            try:
                _set_progress("analyze", 0, "Анализ…")
                result = _analyze(path, analyze_all=analyze_all)
                _set_progress("idle", 100, "Анализ завершён")
                self._send(200, _json(result))
            except Exception as e:
                _set_progress("idle", 0, "Ошибка анализа")
                self._send(500, _json({"error": str(e), "trace": traceback.format_exc()}))

        elif parsed.path == "/progress":
            self._send(200, _json(_get_progress()))

        elif parsed.path == "/devices":
            try:
                devs = []
                for i, d in enumerate(sd.query_devices()):
                    if int(d['max_output_channels']) > 0:
                        devs.append({"id": i, "name": d['name'],
                                     "channels": int(d['max_output_channels'])})
                self._send(200, _json({"devices": devs}))
            except Exception as e:
                self._send(500, _json({"error": str(e)}))

        elif parsed.path == "/perf":
            self._send(200, _json({"cpu_pct": round(_perf_cpu, 1),
                                   "mem_mb":  round(_perf_mem, 1)}))

        elif parsed.path == "/player/set_device":
            global _mt_device_idx, _mt_n_ch
            raw = qs.get("id", [None])[0]
            _mt_device_idx = int(raw) if raw is not None and raw != "null" else None
            try:
                if _mt_device_idx is not None:
                    d = sd.query_devices(_mt_device_idx)
                    _mt_n_ch = max(2, int(d['max_output_channels']))
                else:
                    _mt_n_ch = 2
            except Exception:
                _mt_n_ch = 2
            self._send(200, _json({"ok": True, "n_ch": _mt_n_ch}))

        elif parsed.path == "/player/status":
            self._send(200, _json(_mt_status()))

        elif parsed.path == "/player/stop":
            _mt_stop()
            self._send(200, _json(_mt_status()))

        elif parsed.path == "/player/pause":
            _mt_pause()
            self._send(200, _json(_mt_status()))

        elif parsed.path == "/player/resume":
            _mt_resume()
            self._send(200, _json(_mt_status()))

        elif parsed.path == "/player/seek":
            global _mt_pos
            sec = float(qs.get("sec", ["0"])[0])
            _mt_pos = max(0, min(int(sec * _mt_sr), _mt_total))
            self._send(200, _json(_mt_status()))

        else:
            self._send(404, _json({"error": "not found"}))

    def do_POST(self):
        parsed = urlparse(self.path)

        if parsed.path == "/player/load":
            # Загрузка всех треков в RAM + старт воспроизведения
            try:
                body   = self._body()
                tracks = body.get("tracks", [])
                _set_progress("load", 0, f"Загрузка {len(tracks)} треков…")
                _mt_load(tracks)
                _set_progress("idle", 100, "Загружено")
                _mt_start()
                self._send(200, _json(_mt_status()))
            except Exception as e:
                _set_progress("idle", 0, f"Ошибка: {e}")
                self._send(500, _json({"error": str(e), "trace": traceback.format_exc()}))

        elif parsed.path == "/player/update":
            # Обновление gain/mute/solo без перезагрузки (real-time)
            try:
                body = self._body()
                _mt_update(body.get("tracks", []))
                self._send(200, _json({"ok": True}))
            except Exception as e:
                self._send(500, _json({"error": str(e)}))

        elif parsed.path == "/process":
            try:
                body   = self._body()
                _log(f"POST /process folder={body.get('folder','')!r} tracks={len(body.get('tracks',[]))} groups={list((body.get('groups') or {}).keys())}")
                result = _process(
                    folder         = body["folder"],
                    out_dir        = body["out_dir"],
                    tracks         = body["tracks"],
                    groups         = body.get("groups", {}),
                    bpm            = float(body["bpm"]),
                    beat_ms        = float(body.get("beat_ms", 0) or 0),
                    first_beat_ms  = float(body.get("first_beat_ms", 0)),
                    click_db       = float(body.get("click_db", -6)),
                    preclick_bars  = int(body.get("preclick_bars", 1)),
                    preclick_start_beat = int(body.get("preclick_start_beat", 1)),
                    fmt            = body.get("fmt", "mp3"),
                    bit_depth      = int(body.get("bit_depth", 24)),
                    voice          = bool(body.get("voice", False)),
                    voice_vol_db   = float(body.get("voice_vol_db", -6)),
                    create_metro   = bool(body.get("create_metro", True)),
                )
                self._send(200, _json(result))
            except Exception as e:
                _set_progress("idle", 0, f"Ошибка: {e}")
                _log(f"process ERROR: {e!r}\n{traceback.format_exc()}")
                self._send(500, _json({"error": str(e), "trace": traceback.format_exc()}))

        else:
            self._send(404, _json({"error": "not found"}))


# ── main ───────────────────────────────────────────────────────────────────

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

def run():
    _log(f"engine start script={__file__!r} port={PORT} log={_DEBUG_LOG}")
    server = ThreadedHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"ClickForge Engine listening on http://127.0.0.1:{PORT}", flush=True)
    server.serve_forever()

if __name__ == "__main__":
    run()
