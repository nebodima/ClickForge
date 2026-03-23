# ClickForge

Нативное macOS приложение: SwiftUI фронтенд + Python движок.

## Сборка и запуск

```bash
cd /Users/dk/Documents/ClickForge
./build-app.sh
```

Скрипт создаёт **`ClickForge.app`** — единственный файл для запуска. Двойной клик или `open ClickForge.app`.

Вручную:
```bash
swift build
./build-app.sh   # создаёт ClickForge.app
open ClickForge.app
```

Приложение само запускает Python-движок (`engine.py`), ничего вручную запускать не нужно.

## GitHub

Репозиторий: [nebodima/ClickForge](https://github.com/nebodima/ClickForge)

Отправить все локальные изменения одной командой:

```bash
./scripts/sync-github.sh "кратко, что изменил"
```

Без аргумента сообщение коммита будет `Update ClickForge`.

## FFmpeg (для обработки/экспорта)

Обработка треков с метрономом требует **FFmpeg**. Установи:

```bash
brew install ffmpeg
```

Альтернатива: `pip install imageio-ffmpeg` (для Python-окружения движка).

## Ошибка PortAudio (-9986)

Если при воспроизведении возникает «Error opening Output-Stream: PaErrorCode -9986»:
- Выбери **«Системное»** в настройках (Устройство вывода)
- Закрой другие приложения, использующие звук
- Перезапусти ClickForge

## Настройки папки (группы, gain и т.п.)

Сохраняются в **`clickforge_settings.json`** внутри папки с треками (видимый файл в Finder).
При первом запуске старый скрытый `.clickforge_settings.json` мигрируется автоматически.

## Лог

Движок пишет лог в **`/tmp/clickforge.log`** (добавлением, фоном):
- запуск engine, путь к скрипту
- каждый запрос `/process` (папка, число треков, группы)
- каждое экспортируемое имя: исходное → итоговое (для отладки `_click`)
- ошибки с traceback

```bash
tail -f /tmp/clickforge.log   # смотреть в реальном времени
```

## Структура

```
ClickForge/
├── engine/
│   └── engine.py          ← Python HTTP сервер (librosa, pydub)
└── ClickForge/
    ├── ClickForgeApp.swift
    ├── Models/
    │   ├── Track.swift
    │   └── AppState.swift
    ├── Services/
    │   └── EngineService.swift
    └── Views/
        └── ContentView.swift
```

## Как работает

- Swift запускает `engine.py` как subprocess
- Общение через HTTP на `localhost:47291`
- Endpoints: `/ping`, `/scan`, `/analyze`, `/process`
