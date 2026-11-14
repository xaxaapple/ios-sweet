# Сборка готовых образов с GPU-ускорением (`sweet-images`)

Результат: `shim-boot.img` (`fastboot boot`) и `ios16-root.simg` (`fastboot flash userdata`).

## Порядок
1. Загрузите файлы с телефона в `device/` (см. `device/README.md`): `device/dtb` и `device/firmware/gpu/*`.
2. Если ядра ещё нет: Actions → **xnu** → Run workflow (macOS, ~1 ч). Берётся последний успешный запуск либо `kernel_run_id`.
3. Actions → **sweet-images** → Run workflow. Первый раз включите `only_preflight` (~3 мин) — проверка раннера.
4. Полный запуск (по умолчанию `gpu=true`):
   - `metal`: macOS собирает `sweet-native-metal` (~1 ч). Можно указать `metal_run_id` готового запуска.
   - `boot`: прошивки GMU/SQE/ZAP вшиваются в ADT, к boot-args добавляется `sweetgpu=9 sweetmtl=2 sweetgles=0` (`gpu_boot_args`).
   - `root`: IPSW 16.7.16 → корень → `SweetMetal2.bundle` (нативный Metal) в `/System/Library/Extensions`.
5. Скачайте артефакты и прошейте:
   ```sh
   gh run download RUN_ID -R DC28088/ios-sweet -n sweet-ios16-root -D root && cd root
   cat ios16-root.simg.zst.part-* | zstd -d > ios16-root.simg
   sha256sum -c ios16-root.simg.sha256
   fastboot -S 512M flash userdata ios16-root.simg
   fastboot boot shim-boot.img     # из артефакта sweet-boot-image
   ```
`gpu=false` даёт базовую цепочку README (без GPU, только DTB).

## Как устроено GPU (по репозиторию)
- Ядро берёт GMU/SQE/ZAP из узла `sweet-adreno` в ADT (`tools/sweet-adreno-firmware.py`).
- `sweetgpu=9` включает запуск CP (код `stage >= 9` в патче 0096); `sweetmtl=2 sweetgles=0` — то, что требует `native-legacy/build.json`.
- Бандл — `native-legacy/SweetMetal2.bundle` (тот же, что авторы ставят вручную через `install-live`), проверяется по SHA-256 из `build.json`.

## Что не проверено
- Workflow не запускался на реальном раннере. Значение `sweetgpu=9` выведено из патчей, а не из записанной рабочей командной строки автора: если GPU не поднялся, смотрите лог (`SWEET ADRENO`, `SWEET RENDER`) и меняйте `gpu_boot_args`.
- Авторы отмечают, что Metal-бандл «не квалифицирован на железе»: возможны сбои backboardd. Откат: бандл в корне заменяется прошивкой образа без `gpu`.
- Wi-Fi/SIM (`wland`), звук, SSH ставятся отдельно существующими `tools/sweet-install-*.sh`.
- Публичный репозиторий: артефакты с файлами Apple доступны залогиненным пользователям (хранение 2–3 дня).
