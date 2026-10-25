"""Запуск сайта в фоне (его вызывает задача Планировщика Windows «Журнал ключей»).

Порт берётся из deploy/app-settings.json (по умолчанию 8090). Раз в сутки делает
копию базы в папку backups/ и хранит последние 30 копий.
"""

import datetime
import glob
import json
import logging
import os
import sqlite3
import sys
import threading
import time

DEPLOY = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(DEPLOY)
sys.path.insert(0, ROOT)
os.chdir(ROOT)

os.makedirs(os.path.join(DEPLOY, "logs"), exist_ok=True)
logging.basicConfig(
    filename=os.path.join(DEPLOY, "logs", "server.log"), level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s", encoding="utf-8",
)
log = logging.getLogger("keys")

BACKUP_DIR = os.path.join(ROOT, "backups")
KEEP_BACKUPS = 30


def read_port():
    try:
        with open(os.path.join(DEPLOY, "app-settings.json"), encoding="utf-8-sig") as f:
            return int(json.load(f).get("port") or 8090)
    except (OSError, ValueError):
        return 8090


def backup(db_path, force=False):
    if not os.path.exists(db_path):
        return None
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M" if force else "%Y-%m-%d")
    target = os.path.join(BACKUP_DIR, f"keys-{stamp}.db")
    if os.path.exists(target) and not force:
        return None
    src = sqlite3.connect(db_path)
    dst = sqlite3.connect(target)
    with dst:
        src.backup(dst)
    src.close()
    dst.close()
    for old in sorted(glob.glob(os.path.join(BACKUP_DIR, "keys-*.db")))[:-KEEP_BACKUPS]:
        os.remove(old)
    return target


def backup_loop(db_path):
    while True:
        try:
            made = backup(db_path)
            if made:
                log.info("резервная копия: %s", made)
        except Exception:
            log.exception("не удалось сделать резервную копию")
        time.sleep(3600)


def main():
    from waitress import serve
    from app import DB_PATH, app

    if "--backup-now" in sys.argv:
        print(backup(DB_PATH, force=True) or "базы ещё нет")
        return
    port = read_port()
    threading.Thread(target=backup_loop, args=(DB_PATH,), daemon=True).start()
    log.info("сайт запущен на порту %s", port)
    try:
        serve(app, host="0.0.0.0", port=port, threads=8, ident=None)
    except Exception:
        log.exception("сайт упал")
        raise


if __name__ == "__main__":
    main()
