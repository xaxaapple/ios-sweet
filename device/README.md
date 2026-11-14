# Файлы с телефона (загружаются вручную в ваш форк, без шифрования)

Workflow `sweet-images` берёт отсюда всё, что уникально для телефона. Коммитьте файлы как есть.
Внимание: в публичном форке они станут публичными (прошивки Qualcomm/Xiaomi).

## 1. Обязательно: `device/dtb`

DTB из стокового boot.img (бэкап из шага 0 README):

```sh
python3 tools/unpack_bootv2.py backup/boot.img dtb/boot_unpacked
cp dtb/boot_unpacked/dtb device/dtb
```
(Вместо `device/dtb` можно положить весь `device/boot.img`, до 100 МБ.)

## 2. Для GPU-ускорения: `device/firmware/gpu/`

Нужны файлы из `/vendor/firmware` телефона (Android или OrangeFox с adb):

```
a618_gmu.bin   a630_sqe.fw   a615_zap.mdt   a615_zap.b00 ... a615_zap.bNN
```

Самый простой способ (скрипт проекта; соберёт и другие группы, нам нужна только папка `gpu`):

```sh
python3 tools/pull-sweet-firmware.py research/sweet-firmware
mkdir -p device/firmware && cp -r research/sweet-firmware/gpu device/firmware/
```

Или вручную:

```sh
mkdir -p device/firmware/gpu && cd device/firmware/gpu
for f in a618_gmu.bin a630_sqe.fw a615_zap.mdt; do adb pull /vendor/firmware/$f .; done
for f in $(adb shell ls /vendor/firmware | tr -d '\r' | grep '^a615_zap\.b[0-9][0-9]$'); do adb pull /vendor/firmware/$f .; done
```

Workflow сам находит «код ZAP» (файл `a615_zap.bNN` ровно 1984 байта) и проверяет размеры/SHA-256.

## Коммит

```sh
git add -f device && git commit -m "phone files" && git push
```

Не кладите сюда `persist`, `modemst1/2`, `fsg` и дампы с IMEI (см. PRIVACY.md).
