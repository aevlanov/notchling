#!/bin/bash
# Режим разработки: ждёт файл-сигнал .rebuild (его кладёт Claude вместе с новыми исходниками)
# и запускает build.sh. Ничего больше не выполняет. Остановить: Ctrl+C.
cd "$(dirname "$0")"
echo "Жду новых исходников… (Ctrl+C — остановить)"
while true; do
  if [ -f .rebuild ]; then
    rm -f .rebuild
    sleep 1   # дать файлам докопироваться
    bash build.sh
    echo "Жду новых исходников…"
  fi
  sleep 2
done
