"""Журнал ключей: поиск по адресу, где висит ключ. Доступ только по логину."""

import csv
import io
import os
import re
import secrets
import sqlite3
import time
from functools import wraps

import click

from flask import (
    Flask, abort, flash, g, redirect, render_template, request, session, url_for,
)
from markupsafe import Markup, escape
from werkzeug.security import check_password_hash, generate_password_hash

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.environ.get("KEYS_DB", os.path.join(BASE_DIR, "keys.db"))
SECRET_FILE = os.path.join(BASE_DIR, ".secret_key")


def load_secret_key():
    if os.environ.get("KEYS_SECRET"):
        return os.environ["KEYS_SECRET"]
    if not os.path.exists(SECRET_FILE):
        with open(SECRET_FILE, "w") as f:
            f.write(secrets.token_hex(32))
        os.chmod(SECRET_FILE, 0o600)
    with open(SECRET_FILE) as f:
        return f.read().strip()


app = Flask(__name__)
app.config.update(
    SECRET_KEY=load_secret_key(),
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=os.environ.get("KEYS_HTTPS") == "1",
    PERMANENT_SESSION_LIFETIME=60 * 60 * 12,
)

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    is_admin INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS cabinets (
    id INTEGER PRIMARY KEY,
    number TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    kind TEXT NOT NULL DEFAULT 'rings',  -- 'rings': ключи на кольцах; 'walls': выдвижные стенки
    walls INTEGER NOT NULL DEFAULT 16    -- сколько стенок (для 'walls')
);
CREATE TABLE IF NOT EXISTS keys (
    id INTEGER PRIMARY KEY,
    cabinet_id INTEGER REFERENCES cabinets(id) ON DELETE RESTRICT,  -- NULL: не в шкафу, где - в info
    address TEXT NOT NULL,
    street TEXT NOT NULL DEFAULT '',
    house TEXT NOT NULL DEFAULT '',
    entrance TEXT NOT NULL DEFAULT '',
    ring TEXT NOT NULL DEFAULT '',
    ring_pos TEXT NOT NULL DEFAULT '',
    box TEXT NOT NULL DEFAULT '',
    floor TEXT NOT NULL DEFAULT '',
    ups TEXT NOT NULL DEFAULT '',       -- ИБП: 'да', 'нет' или '' (не выбрано - не показываем)
    electron TEXT NOT NULL DEFAULT '',  -- Электрон: так же
    info TEXT NOT NULL DEFAULT '',
    wall TEXT NOT NULL DEFAULT '',      -- шкаф со стенками: номер стенки,
    side TEXT NOT NULL DEFAULT '',      -- сторона ('левая' / 'правая'),
    wrow TEXT NOT NULL DEFAULT '',      -- ряд
    wcol TEXT NOT NULL DEFAULT ''       -- и место в ряду
);
CREATE INDEX IF NOT EXISTS keys_cabinet ON keys(cabinet_id);
-- примечание к дому: одно на все ключи этого дома (подъезды), например телефон УК
CREATE TABLE IF NOT EXISTS houses (
    street_key TEXT NOT NULL,
    house_key TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (street_key, house_key)
);
"""


# Слова, которые в адресе есть почти всегда и для поиска ничего не дают.
STOP_WORDS = {"ул", "улица", "д", "дом", "под", "подъезд", "п", "пр", "проспект", "пер", "переулок",
              "ш", "шоссе", "б", "бульвар", "пл", "площадь", "наб", "набережная", "кв", "г", "на", "в"}


def normalize(text):
    """«ул. Ленина д. 12а, под 3» -> « ул ленина д 12 а под 3 »."""
    if not text:
        return " "
    text = text.lower().replace("ё", "е")
    text = re.sub(r"(\d)([^\d\W])|([^\d\W])(\d)", r"\1\3 \2\4", text)  # 69а -> 69 а
    # нули в начале чисел не важны: ящик «Д-007-20» находится по «7» и «7-20»
    words = [str(int(w)) if w.isdigit() else w for w in re.findall(r"\w+", text)]
    return " " + " ".join(words) + " "


RING_WORDS = ("кольцо", "кольца", "кольце", "кольцу", "кольц", "кол")  # не «Кольцовская»


def search_tokens(query):
    """Слова запроса. Код через дефис («Д-007-13», «007-13») остаётся одним словом «д 002 13»,
    иначе «Д» потерялась бы как сокращение от «дом»."""
    tokens = []
    for piece in re.split(r"[\s,;]+", query):
        if re.search(r"\d", piece) and re.search(r"[-/]", piece.strip("-/")):
            code = normalize(piece).strip()
            if code:
                tokens.append(code)
        else:
            tokens += normalize(piece).split()
    return tokens


def build_search(query):
    """Одна строка поиска по всему сразу: адрес, информация, шкаф, кольцо, номер на кольце, ящик.

    Можно уточнить словами: «ящик 7», «кольцо 1», «номер 2» (номер на кольце), «не в шкафу».
    Номера и коды ищутся целым словом: 7 не находит 17, а «007-13» находит ящик «Д-007-13».
    Возвращает (условия SQL, параметры, слова для сортировки по релевантности)."""
    where, params, words = [], [], []
    if re.search(r"\bне\s+в\s+шкаф", query.lower()):
        where.append("k.cabinet_id IS NULL")
        query = re.sub(r"(?i)\bне\s+в\s+шкаф\w*", " ", query)
    tokens = search_tokens(query)
    i = 0
    while i < len(tokens):
        word = tokens[i]
        field = None
        if word in ("ибп", "электрон"):  # «ибп» - ключи, где ИБП есть
            where.append(f"k.{'ups' if word == 'ибп' else 'electron'} = 'да'")
            i += 1
            continue
        if word in ("ящик", "ящика", "ящ"):
            field = "box"
        elif word in ("этаж", "этаже"):
            field = "floor"
        elif word in ("стенка", "стенке", "стенки", "стенку", "ст"):
            field = "wall"
        elif word in ("ряд", "ряду", "ряда"):
            field = "wrow"
        elif word in ("место", "месте", "места"):
            field = "wcol"
        elif word in ("левая", "левой", "лев", "правая", "правой", "прав"):
            where.append("k.side = ?")
            params.append(norm_side(word))
            i += 1
            continue
        elif word in ("сторона", "стороне"):
            i += 1
            continue
        elif word == "номер":
            field = "ring_pos"
            while i + 1 < len(tokens) and tokens[i + 1] in ("на",) + RING_WORDS:
                i += 1
        elif word in RING_WORDS:
            field = "ring"
        if re.fullmatch(r"[a-z]+", word) and i + 1 < len(tokens) and tokens[i + 1].isdigit():
            # «fttb 1» - это номер шкафа целиком, а не «fttb» и отдельно «1»
            where.append("(norm(c.number) LIKE ? OR norm(c.number) LIKE ?)")
            params += [f"% {word} {tokens[i + 1]} %", f"% {word} % {tokens[i + 1]} %"]  # FTTB АТС 7
            i += 1
        elif field and i + 1 < len(tokens):
            i += 1
            where.append(f"norm(k.{field}) LIKE ?")
            params.append(f"% {tokens[i]} %")
        elif not field and word not in STOP_WORDS and not word.startswith("шкаф"):
            exact = " " in word or word.isdigit()  # код или число - целым словом
            like = f"% {word} %" if exact else f"% {word}%"
            fields = ["k.address", "k.info", "h.note", "c.number", "c.name"]
            if exact:
                fields += ["k.ring", "k.ring_pos", "k.box"]
            where.append("(" + " OR ".join(f"norm({f}) LIKE ?" for f in fields) + ")")
            params += [like] * len(fields)
            words.append(word)
        i += 1
    return where, params, words


def relevance(row, words):
    """Сначала ключи, у которых совпал адрес, потом — совпавшие только по ящику, кольцу и т. п."""
    address = normalize(row["address"])
    return -sum(1 for w in words if (f" {w} " if " " in w or w.isdigit() else f" {w}") in address)


STREET_TYPES = {"ул", "улица", "пр", "пр-т", "просп", "проспект", "пер", "переулок", "ш", "шоссе", "б-р",
                "бульвар", "пл", "площадь", "наб", "набережная", "проезд", "мкр", "тупик", "аллея", "кв-л"}
ADDRESS_RE = re.compile(
    r"^\s*(?P<street>.+?)[\s,]+(?:д\.|дом\b|д\b)\s*(?P<house>[^\s,]+)"
    r"(?:[\s,]+(?:под\.|подъезд\b|под\b|п\.)\s*(?P<entrance>[^\s,]+))?\s*$", re.I)


def compose_address(street, house, entrance):
    """Улица 'Среднемосковская', дом 69, подъезд 4 -> «ул. Среднемосковская д. 69, под 4»."""
    street = street.strip()
    first = street.split(" ", 1)[0].rstrip(".").lower() if street else ""
    if street and house and first not in STREET_TYPES:
        street = "ул. " + street
    address = street
    if house:
        address += f" д. {house}"
    if entrance:
        address += f", под {entrance}"
    return address.strip()


def split_address(address):
    """Обратно: «ул. Среднемосковская д. 69, под 4» -> ('Среднемосковская', '69', '4').
    Если адрес записан как-то иначе, он целиком остаётся в «улице»."""
    m = ADDRESS_RE.match(address or "")
    if not m:
        return (address or "").strip(), "", ""
    street = re.sub(r"^(?:улица\s+|ул\.\s*|ул\s+)", "", m["street"].strip(" ,"), flags=re.I)
    return street, m["house"], m["entrance"] or ""


def cabinet_number(text):
    """« fttb0 » -> «FTTB 0»: один вид записи, чтобы не было двух одинаковых шкафов."""
    text = re.sub(r"[a-z]+", lambda m: m.group().upper(), (text or "").strip())
    text = re.sub(r"(?<=[^\d\W])(?=\d)", " ", text)
    text = re.sub(r"\b[а-яё]{2,3}\b", lambda m: m.group().upper(), text)  # атс -> АТС
    return " ".join(text.split())


def fix_cabinet(number, name):
    """Номер «0» + название «FTTB» (или номер «0 FTTB») -> номер «FTTB 0», название пустое."""
    number, name = cabinet_number(number), (name or "").strip()
    if number.isdigit() and re.fullmatch(r"[A-Za-z]+", name):
        number, name = cabinet_number(f"{name} {number}"), ""
    m = re.fullmatch(r"(\d+)\s+([A-Z]+)", number)
    if m:
        number = f"{m[2]} {m[1]}"
    return number, name


def natural_key(text):
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", normalize(text))]


def connect():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    # Встроенный LOWER в SQLite не понимает кириллицу, поэтому сравниваем через свою функцию.
    db.create_function("norm", 1, normalize, deterministic=True)
    return db


def get_db():
    if "db" not in g:
        g.db = connect()
    return g.db


@app.teardown_appcontext
def close_db(_exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


# этаж переносим, только если за ним запятая/скобка/конец: «2 этаж подвала» оставляем как есть
FLOOR_RE = re.compile(r"(?:(\d+(?:/\d+)?)\s*(?:-?й\s*)?этаж\w*|этаж\s*(\d+(?:/\d+)?))(?=\s*(?:[,;(]|$))[\s,;]*", re.I)


def split_floor(info):
    """«1 этаж, высоко» -> ('1', 'высоко'): этаж из примечания переносится в своё поле."""
    m = FLOOR_RE.search(info or "")
    if not m:
        return "", info
    rest = (info[:m.start()] + info[m.end():]).lstrip(" ,;.").rstrip(" ,;")
    return m[1] or m[2], re.sub(r"\s{2,}", " ", rest)


YES_NO = ("да", "нет")
SIDES = ("левая", "правая")


def norm_side(value):
    """«Л», «лев.», «левая» -> «левая»; непонятное -> ''."""
    v = (value or "").strip().lower()
    return "левая" if v.startswith("л") else "правая" if v.startswith("п") else ""


def make_cabinet_optional(db):
    start = SCHEMA.index("CREATE TABLE IF NOT EXISTS keys")
    create = SCHEMA[start:SCHEMA.index(");", start) + 2]
    cols = ", ".join(r["name"] for r in db.execute("PRAGMA table_info(keys)"))
    db.commit()
    db.execute("PRAGMA foreign_keys = OFF")
    db.executescript(
        "BEGIN;"
        + create.replace("IF NOT EXISTS keys", "keys_new")
        + f"INSERT INTO keys_new ({cols}) SELECT {cols} FROM keys;"
        "DROP TABLE keys; ALTER TABLE keys_new RENAME TO keys;"
        "CREATE INDEX IF NOT EXISTS keys_cabinet ON keys(cabinet_id);"
        "COMMIT;"
    )
    db.execute("PRAGMA foreign_keys = ON")


def init_db():
    with connect() as db:
        db.executescript(SCHEMA)
        columns = {r["name"] for r in db.execute("PRAGMA table_info(keys)")}
        if "ring_pos" not in columns:  # база от первой версии
            db.execute("ALTER TABLE keys ADD COLUMN ring_pos TEXT NOT NULL DEFAULT ''")
        if "street" not in columns:  # раньше адрес был одной строкой - разбираем его на части
            for col in ("street", "house", "entrance"):
                db.execute(f"ALTER TABLE keys ADD COLUMN {col} TEXT NOT NULL DEFAULT ''")
            for row in db.execute("SELECT id, address FROM keys").fetchall():
                db.execute("UPDATE keys SET street=?, house=?, entrance=? WHERE id=?",
                           split_address(row["address"]) + (row["id"],))
        if "wall" not in columns:  # шкафы с выдвижными стенками
            for col in ("wall", "side", "wrow", "wcol"):
                db.execute(f"ALTER TABLE keys ADD COLUMN {col} TEXT NOT NULL DEFAULT ''")
        cab_columns = {r["name"] for r in db.execute("PRAGMA table_info(cabinets)")}
        if "kind" not in cab_columns:
            db.execute("ALTER TABLE cabinets ADD COLUMN kind TEXT NOT NULL DEFAULT 'rings'")
            db.execute("ALTER TABLE cabinets ADD COLUMN walls INTEGER NOT NULL DEFAULT 16")
        if "floor" not in columns:  # этаж, ИБП и электрон - отдельными полями
            for col in ("floor", "ups", "electron"):
                db.execute(f"ALTER TABLE keys ADD COLUMN {col} TEXT NOT NULL DEFAULT ''")
            for row in db.execute("SELECT id, info FROM keys WHERE info != ''").fetchall():
                floor, info = split_floor(row["info"])
                if floor:
                    db.execute("UPDATE keys SET floor = ?, info = ? WHERE id = ?", (floor, info, row["id"]))
        cab_col = next(r for r in db.execute("PRAGMA table_info(keys)") if r["name"] == "cabinet_id")
        if cab_col["notnull"]:  # раньше ключ обязательно был в шкафу - перестраиваем таблицу
            make_cabinet_optional(db)
        for row in db.execute("SELECT id, number, name FROM cabinets").fetchall():
            fixed = fix_cabinet(row["number"], row["name"])
            taken = db.execute("SELECT 1 FROM cabinets WHERE number = ? AND id != ?", (fixed[0], row["id"])).fetchone()
            if fixed != (row["number"], row["name"]) and not taken:
                db.execute("UPDATE cabinets SET number = ?, name = ? WHERE id = ?", fixed + (row["id"],))


PHONE_RE = re.compile(r"(?<![\w-])(?:\+7|8)[\s\-()]*\d{3}[\s\-()]*\d{3}[\s\-]*\d{2}[\s\-]*\d{2}(?![\w-])")


@app.template_filter("phones")
def phones_filter(text):
    """Номера вида 8-900-123-45-67 в тексте становятся ссылками tel:."""
    out, pos = [], 0
    text = text or ""
    for m in PHONE_RE.finditer(text):
        digits = re.sub(r"\D", "", m[0])
        out += [escape(text[pos:m.start()]), Markup('<a href="tel:%s">%s</a>') % (digits, m[0])]
        pos = m.end()
    out.append(escape(text[pos:]))
    return Markup("").join(out)


# ---------- Авторизация ----------

def current_user():
    uid = session.get("uid")
    if uid is None:
        return None
    if "user" not in g:
        g.user = get_db().execute("SELECT * FROM users WHERE id = ?", (uid,)).fetchone()
    return g.user


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if current_user() is None:
            session.clear()
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)
    return wrapped


def admin_required(view):
    @wraps(view)
    @login_required
    def wrapped(*args, **kwargs):
        if not current_user()["is_admin"]:
            abort(403)
        return view(*args, **kwargs)
    return wrapped


@app.context_processor
def inject_globals():
    if "csrf" not in session:
        session["csrf"] = secrets.token_hex(16)
    return {"user": current_user(), "csrf_token": session["csrf"]}


@app.before_request
def check_csrf():
    if request.method == "POST":
        token = request.form.get("csrf")
        if not token or token != session.get("csrf"):
            abort(400, "Форма устарела, обновите страницу.")


# Простая защита от подбора пароля: не более 5 неудачных попыток за 10 минут с одного IP.
_failed_logins = {}


def client_ip():
    # За Caddy (обратный прокси на этой же машине) настоящий адрес — в X-Forwarded-For.
    ip = request.remote_addr or "?"
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded and ip in ("127.0.0.1", "::1"):
        ip = forwarded.split(",")[-1].strip()
    return ip


def too_many_attempts(ip):
    now = time.time()
    attempts = [t for t in _failed_logins.get(ip, []) if now - t < 600]
    _failed_logins[ip] = attempts
    return len(attempts) >= 5


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        ip = client_ip()
        if too_many_attempts(ip):
            flash("Слишком много попыток. Подождите 10 минут.", "error")
            return render_template("login.html"), 429
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        row = get_db().execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
        if row and check_password_hash(row["password_hash"], password):
            _failed_logins.pop(ip, None)
            session.clear()
            session.permanent = True
            session["uid"] = row["id"]
            nxt = request.args.get("next", "")
            return redirect(nxt if nxt.startswith("/") and not nxt.startswith("//") else url_for("index"))
        _failed_logins.setdefault(ip, []).append(time.time())
        flash("Неверный логин или пароль.", "error")
    return render_template("login.html")


@app.route("/logout", methods=["POST"])
def logout():
    session.clear()
    return redirect(url_for("login"))


# ---------- Поиск ----------

KEY_SELECT = """
SELECT k.*, c.number AS cabinet_number, c.name AS cabinet_name, c.kind AS cabinet_kind, c.walls AS cabinet_walls,
       h.note AS house_note
FROM keys k LEFT JOIN cabinets c ON c.id = k.cabinet_id
LEFT JOIN houses h ON k.house != '' AND h.street_key = trim(norm(k.street)) AND h.house_key = trim(norm(k.house))
"""


def house_key(street, house):
    return normalize(street).strip(), normalize(house).strip()


def get_house_note(db, street, house):
    if not street or not house:
        return ""
    row = db.execute("SELECT note FROM houses WHERE street_key = ? AND house_key = ?", house_key(street, house)).fetchone()
    return row["note"] if row else ""


def set_house_note(db, street, house, note):
    """Записать (или стереть, если пусто) примечание к дому."""
    if not street or not house:
        return
    if note:
        db.execute("INSERT INTO houses (street_key, house_key, note) VALUES (?, ?, ?) "
                   "ON CONFLICT(street_key, house_key) DO UPDATE SET note = excluded.note",
                   house_key(street, house) + (note,))
    else:
        db.execute("DELETE FROM houses WHERE street_key = ? AND house_key = ?", house_key(street, house))


def save_house_note_from_form(db, street, house):
    """Примечание к дому меняем, только если его правда поменяли в форме -
    иначе сохранение одного ключа могло бы стереть общее примечание."""
    note = request.form.get("house_note", "").strip()
    if note != request.form.get("house_note_orig", "").strip():
        set_house_note(db, street, house, note)


@app.route("/house-note")
@login_required
def house_note_view():
    """Для формы: примечание к дому, когда ввели улицу и дом."""
    return {"note": get_house_note(get_db(), request.args.get("street", ""), request.args.get("house", ""))}


def next_box(box):
    """Д-007-10 -> Д-007-11: в журнале ящики на кольце обычно идут подряд."""
    m = re.search(r"(\d+)(\D*)$", box or "")
    if not m:
        return ""
    return box[:m.start(1)] + str(int(m[1]) + 1).zfill(len(m[1])) + m[2]


def side_order(side):
    return SIDES.index(side) if side in SIDES else 2


def group_walls(rows, cabinets_all=None):
    """Ключи шкафов со стенками -> стенки; внутри: сторона, ряд, место.
    cabinets_all: для открытого шкафа показать все его стенки, даже пустые (удобно заполнять)."""
    groups = {}
    for r in rows:
        groups.setdefault((r["cabinet_id"], normalize(r["wall"])), []).append(r)
    walls = []
    for keys in groups.values():
        keys.sort(key=lambda r: (side_order(r["side"]), natural_key(r["wrow"]), natural_key(r["wcol"]), natural_key(r["address"])))
        first = keys[0]
        walls.append({"kind": "walls", "cabinet_id": first["cabinet_id"], "cabinet_number": first["cabinet_number"],
                      "cabinet_name": first["cabinet_name"], "wall": first["wall"], "keys": keys, "lines": keys})
    for cab in cabinets_all or []:  # пустые стенки 1..N
        have = {normalize(g["wall"]) for g in walls if g["cabinet_id"] == cab["id"]}
        for n in range(1, (cab["walls"] or 0) + 1):
            if normalize(str(n)) not in have:
                walls.append({"kind": "walls", "cabinet_id": cab["id"], "cabinet_number": cab["number"],
                              "cabinet_name": cab["name"], "wall": str(n), "keys": [], "lines": []})
    walls.sort(key=lambda g: (natural_key(g["cabinet_number"]), not g["wall"], natural_key(g["wall"])))
    return walls


def group_places(rows, fill_gaps=False, cabinets_all=None):
    """Кольца для шкафов с кольцами и стенки для шкафов со стенками - одним списком."""
    walls = [r for r in rows if r["cabinet_kind"] == "walls"]
    return group_walls(walls, cabinets_all) + group_rings([r for r in rows if r["cabinet_kind"] != "walls"], fill_gaps)


def group_rings(rows, fill_gaps=False):
    """Ключи -> кольца, как в журнале: кольцо = шкаф + номер кольца, ключи по номеру на кольце.
    fill_gaps: показать пропущенные номера (в журнале бывает 1, 3, 4) пустыми строками."""
    groups = {}
    for r in rows:
        groups.setdefault((r["cabinet_id"], normalize(r["ring"])), []).append(r)
    rings = []
    for keys in groups.values():
        keys.sort(key=lambda r: (natural_key(r["ring_pos"]), natural_key(r["address"])))
        first, last = keys[0], keys[-1]
        positions = {int(k["ring_pos"]) for k in keys if k["ring_pos"].isdigit()}
        lines = list(keys)
        if fill_gaps and positions and len(positions) == len(keys):
            by_pos = {int(k["ring_pos"]): k for k in keys}
            lines = [by_pos.get(n, {"ring_pos": str(n), "empty": True}) for n in range(1, max(positions) + 1)]
        rings.append({
            "kind": "rings", "cabinet_id": first["cabinet_id"], "cabinet_number": first["cabinet_number"],
            "cabinet_name": first["cabinet_name"], "ring": first["ring"],
            "keys": keys, "lines": lines,
            "next_pos": max(positions) + 1 if positions else "", "next_box": next_box(last["box"]),
        })
    rings.sort(key=lambda g: (natural_key(g["cabinet_number"]), not g["ring"], natural_key(g["ring"])))
    return rings


@app.route("/ring")
@login_required
def ring_view():
    """Всё кольцо целиком: какие номера на нём висят и от каких адресов."""
    cabinet, ring = request.args.get("cabinet", ""), request.args.get("ring", "")
    where = ["k.cabinet_id = ?" if cabinet.isdigit() else "k.cabinet_id IS NULL", "norm(k.ring) = ?"]
    params = ([int(cabinet)] if cabinet.isdigit() else []) + [normalize(ring)]
    rows = get_db().execute(KEY_SELECT + " WHERE " + " AND ".join(where), params).fetchall()
    if not rows:
        abort(404)
    return render_template("ring.html", rings=group_rings(rows, fill_gaps=True))


@app.route("/wall")
@login_required
def wall_view():
    """Вся выдвижная стенка: обе стороны, ряды и места."""
    cabinet = request.args.get("cabinet", type=int)
    wall = request.args.get("wall", "")
    db = get_db()
    cab = db.execute("SELECT * FROM cabinets WHERE id = ?", (cabinet,)).fetchone() or abort(404)
    rows = db.execute(KEY_SELECT + " WHERE k.cabinet_id = ? AND norm(k.wall) = ?", (cabinet, normalize(wall))).fetchall()
    groups = group_walls(rows) or [{"kind": "walls", "cabinet_id": cab["id"], "cabinet_number": cab["number"],
                                    "cabinet_name": cab["name"], "wall": wall, "keys": [], "lines": []}]
    return render_template("ring.html", rings=groups)


@app.route("/")
@login_required
def index():
    q = request.args.get("q", "").strip()
    cabinet_id = request.args.get("cabinet", type=int)
    db = get_db()
    where, params, words = build_search(q)
    if cabinet_id:  # нажали на шкаф в списке
        where.append("k.cabinet_id = ?")
        params.append(cabinet_id)
    results = rings = None
    if where:
        sql = KEY_SELECT + " WHERE " + " AND ".join(where) + " LIMIT 300"
        results = sorted(db.execute(sql, params).fetchall(),
                         key=lambda r: (relevance(r, words), natural_key(r["address"])))
        # открыли шкаф или искали кольцо/стенку - показываем по кольцам и стенкам
        words_q = normalize(q).split()
        if cabinet_id or any(w in RING_WORDS or w.startswith("стенк") for w in words_q):
            opened = db.execute("SELECT * FROM cabinets WHERE id = ? AND kind = 'walls'", (cabinet_id,)).fetchall() \
                if cabinet_id and not q else None
            rings = group_places(results, fill_gaps=bool(cabinet_id and not q), cabinets_all=opened)
    cabinets = sorted(db.execute(
        "SELECT c.*, COUNT(k.id) AS key_count FROM cabinets c "
        "LEFT JOIN keys k ON k.cabinet_id = c.id GROUP BY c.id"
    ).fetchall(), key=lambda c: natural_key(c["number"]))
    if request.args.get("partial"):  # живой поиск - только список найденного
        if results is None:  # напечатали пока только «ул», «д.» и т. п. - искать нечего
            return ""
        return render_template("_results.html", q=q, results=results, rings=rings, cabinets=cabinets,
                               cabinet_id=cabinet_id)
    return render_template("index.html", q=q, results=results, rings=rings, cabinets=cabinets,
                           cabinet_id=cabinet_id)


# ---------- Шкафы (админ) ----------

@app.route("/cabinets/new", methods=["GET", "POST"])
@app.route("/cabinets/<int:cid>/edit", methods=["GET", "POST"])
@admin_required
def cabinet_edit(cid=None):
    db = get_db()
    cab = None
    if cid is not None:
        cab = db.execute("SELECT * FROM cabinets WHERE id = ?", (cid,)).fetchone() or abort(404)
    if request.method == "POST":
        number, name = fix_cabinet(request.form.get("number", ""), request.form.get("name", ""))
        same = db.execute("SELECT id FROM cabinets WHERE number = ? AND id != ?", (number, cid or 0)).fetchone()
        if not number:
            flash("Укажите номер шкафа.", "error")
        elif same:
            flash(f"Шкаф {number} уже есть.", "error")
        else:
            kind = "walls" if request.form.get("kind") == "walls" else "rings"
            walls = max(1, min(request.form.get("walls", 16, type=int) or 16, 99))
            if cab:
                db.execute("UPDATE cabinets SET number = ?, name = ?, kind = ?, walls = ? WHERE id = ?",
                           (number, name, kind, walls, cid))
            else:
                db.execute("INSERT INTO cabinets (number, name, kind, walls) VALUES (?, ?, ?, ?)", (number, name, kind, walls))
            db.commit()
            flash("Шкаф сохранён.", "ok")
            return redirect(url_for("index"))
    return render_template("cabinet_form.html", cab=cab)


@app.route("/cabinets/<int:cid>/delete", methods=["POST"])
@admin_required
def cabinet_delete(cid):
    db = get_db()
    if db.execute("SELECT 1 FROM keys WHERE cabinet_id = ? LIMIT 1", (cid,)).fetchone():
        flash("В шкафу есть ключи — сначала удалите или перенесите их.", "error")
    else:
        db.execute("DELETE FROM cabinets WHERE id = ?", (cid,))
        db.commit()
        flash("Шкаф удалён.", "ok")
    return redirect(url_for("index"))


# ---------- Ключи (админ) ----------

@app.route("/keys/new", methods=["GET", "POST"])
@app.route("/keys/<int:kid>/edit", methods=["GET", "POST"])
@admin_required
def key_edit(kid=None):
    db = get_db()
    key = None
    if kid is not None:
        key = db.execute(KEY_SELECT + " WHERE k.id = ?", (kid,)).fetchone() or abort(404)
    cabinets = sorted(db.execute("SELECT * FROM cabinets").fetchall(), key=lambda c: natural_key(c["number"]))
    if request.method == "POST":
        f = {k: request.form.get(k, "").strip()
             for k in ("street", "house", "entrance", "ring", "ring_pos", "box", "floor", "ups", "electron", "info",
                       "wall", "side", "wrow", "wcol")}
        f["side"] = norm_side(f["side"])
        for k in ("ups", "electron"):
            if f[k] not in YES_NO:
                f[k] = ""
        cabinet_id = request.form.get("cabinet_id", type=int)
        address = compose_address(f["street"], f["house"], f["entrance"])
        if not any(c["id"] == cabinet_id for c in cabinets):
            cabinet_id = None
        # у шкафа со стенками - стенка/сторона/ряд/место, у шкафа с кольцами - кольцо/номер
        kind = next((c["kind"] for c in cabinets if c["id"] == cabinet_id), "rings")
        if kind == "walls":
            f["ring"] = f["ring_pos"] = ""
        else:
            f["wall"] = f["side"] = f["wrow"] = f["wcol"] = ""
        if not f["street"]:
            flash("Укажите улицу.", "error")
        elif cabinet_id is None and not f["info"]:
            flash("Ключ не в шкафу — напишите в «Примечании», где он хранится.", "error")
        else:
            vals = (cabinet_id, address, f["street"], f["house"], f["entrance"],
                    f["ring"], f["ring_pos"], f["box"], f["floor"], f["ups"], f["electron"], f["info"],
                    f["wall"], f["side"], f["wrow"], f["wcol"])
            if key:
                db.execute("UPDATE keys SET cabinet_id=?, address=?, street=?, house=?, entrance=?, ring=?, ring_pos=?, "
                           "box=?, floor=?, ups=?, electron=?, info=?, wall=?, side=?, wrow=?, wcol=? WHERE id=?", vals + (kid,))
            else:
                db.execute("INSERT INTO keys (cabinet_id, address, street, house, entrance, ring, ring_pos, box, floor, "
                           "ups, electron, info, wall, side, wrow, wcol) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", vals)
            save_house_note_from_form(db, f["street"], f["house"])
            db.commit()
            flash(f"Ключ сохранён: {address}", "ok")
            if request.form.get("another"):
                # следующая строка журнала: то же кольцо, номер и ящик на один больше, часто та же улица
                if kind == "walls":  # следующее место в том же ряду
                    col = str(int(f["wcol"]) + 1) if f["wcol"].isdigit() else ""
                    return redirect(url_for("key_edit", cabinet=cabinet_id, wall=f["wall"], side=f["side"], wrow=f["wrow"],
                                            wcol=col, street=f["street"], house=f["house"]))
                pos = str(int(f["ring_pos"]) + 1) if f["ring_pos"].isdigit() else ""
                return redirect(url_for("key_edit", cabinet=cabinet_id or "none", ring=f["ring"], ring_pos=pos,
                                        street=f["street"], house=f["house"], box=next_box(f["box"])))
            return redirect(url_for("index", q=address))
    streets = [r[0] for r in db.execute(
        "SELECT DISTINCT street FROM keys WHERE street != '' ORDER BY street LIMIT 2000")]
    house_note = key["house_note"] if key else get_house_note(db, request.args.get("street", ""), request.args.get("house", ""))
    return render_template("key_form.html", key=key, cabinets=cabinets, streets=streets, house_note=house_note or "",
                           default_cabinet=request.args.get("cabinet", type=int), prefill=request.args)


@app.route("/keys/<int:kid>")
@login_required
def key_view(kid):
    """Один ключ со всей информацией."""
    key = get_db().execute(KEY_SELECT + " WHERE k.id = ?", (kid,)).fetchone() or abort(404)
    return render_template("key.html", k=key)


@app.route("/keys/<int:kid>/note", methods=["GET", "POST"])
@login_required
def key_note(kid):
    """Обычный пользователь может поправить только примечания (к ключу и к дому), ИБП и Электрон."""
    db = get_db()
    key = db.execute(KEY_SELECT + " WHERE k.id = ?", (kid,)).fetchone() or abort(404)
    back = request.values.get("back", "")
    if not back.startswith("/") or back.startswith("//"):
        back = url_for("index", q=key["address"])
    if request.method == "POST":
        info = request.form.get("info", "").strip()
        if key["cabinet_id"] is None and not info:
            flash("Ключ не в шкафу — в примечании должно быть написано, где он хранится.", "error")
        else:
            ups, electron = (v if v in YES_NO else "" for v in (request.form.get("ups"), request.form.get("electron")))
            db.execute("UPDATE keys SET info = ?, ups = ?, electron = ? WHERE id = ?", (info, ups, electron, kid))
            save_house_note_from_form(db, key["street"], key["house"])
            db.commit()
            flash("Сохранено.", "ok")
            return redirect(back)
    return render_template("note_form.html", key=key, back=back)


@app.route("/keys/<int:kid>/delete", methods=["POST"])
@admin_required
def key_delete(kid):
    db = get_db()
    db.execute("DELETE FROM keys WHERE id = ?", (kid,))
    db.commit()
    flash("Ключ удалён.", "ok")
    return redirect(request.referrer or url_for("index"))


# ---------- Импорт из таблицы (админ) ----------
# Журнал распознаётся с фото в таблицу (CSV), таблица загружается сюда: сначала предпросмотр,
# потом «Добавить». Строки, у которых в этом шкафу уже занят тот же номер на кольце, пропускаются.

IMPORT_COLUMNS = [  # поле, как может называться колонка (начало названия, без регистра)
    ("house_note", ("примечание к дому", "к дому")),
    ("cab_name", ("где стоит", "название", "место шкафа")), ("cabinet", ("шкаф",)),
    ("ring_pos", ("№ на кольце", "номер на кольце", "№ на кол", "под номер")), ("ring", ("кольц",)),
    ("street", ("улиц",)), ("house", ("дом",)), ("entrance", ("подъезд", "под")),
    ("address", ("адрес",)), ("floor", ("этаж",)), ("box", ("ящик", "№ ящика")),
    ("ups", ("ибп",)), ("electron", ("электрон",)), ("info", ("примеч", "коммент", "инф")),
    ("wall", ("стенк",)), ("side", ("сторон",)), ("wrow", ("ряд",)), ("wcol", ("место",)),
]


def read_import(text):
    """CSV -> список строк (словари). Первая строка - заголовки."""
    try:
        dialect = csv.Sniffer().sniff(text[:4096], delimiters=";,\t")
    except csv.Error:
        dialect = csv.excel
    rows = list(csv.reader(io.StringIO(text), dialect))
    if not rows:
        return []
    columns = {}
    for i, title in enumerate(rows[0]):
        title = title.strip().lower()
        for field, prefixes in IMPORT_COLUMNS:
            if field not in columns and title.startswith(prefixes):
                columns[field] = i
                break
    result = []
    for line, row in enumerate(rows[1:], start=2):
        v = {f: (row[i].strip() if i < len(row) else "") for f, i in columns.items()}
        if not any(v.values()):
            continue
        if not v.get("street") and v.get("address"):
            v["street"], v["house"], v["entrance"] = split_address(v["address"])
        for f in ("ups", "electron"):
            v[f] = v.get(f, "").lower() if v.get(f, "").lower() in YES_NO else ""
        v["cabinet"], v["cab_name"] = fix_cabinet(v.get("cabinet", ""), v.get("cab_name", ""))
        v["side"] = norm_side(v.get("side", ""))
        v["line"] = line
        v["address_text"] = compose_address(v.get("street", ""), v.get("house", ""), v.get("entrance", ""))
        result.append(v)
    return result


def check_import(db, rows):
    """Пометить каждую строку: добавить / пропустить и почему."""
    def place_of(cab, r):  # место ключа в шкафу: кольцо+номер или стенка+сторона+ряд+место
        if r.get("wall"):
            return (normalize(cab), "стенка", normalize(r["wall"]), r.get("side", ""), normalize(r.get("wrow")), normalize(r.get("wcol")))
        return (normalize(cab), normalize(r.get("ring")), normalize(r.get("ring_pos"))) if r.get("ring_pos") else None
    taken = {place_of(r["number"], dict(r)) for r in db.execute(
        "SELECT c.number, k.ring, k.ring_pos, k.wall, k.side, k.wrow, k.wcol FROM keys k JOIN cabinets c ON c.id = k.cabinet_id")}
    taken.discard(None)
    for v in rows:
        place = place_of(v["cabinet"], v)
        if not v.get("street"):
            v["status"] = "нет адреса"
        elif not v["cabinet"] and not v.get("info"):
            v["status"] = "не указан ни шкаф, ни где хранится"
        elif v["cabinet"] and place and place in taken:
            v["status"] = "уже есть"
        else:
            v["status"] = ""
            if v["cabinet"] and place:
                taken.add(place)
    return rows


@app.route("/import", methods=["GET", "POST"])
@admin_required
def import_keys():
    db = get_db()
    if request.method == "GET":
        return render_template("import.html", rows=None)
    if request.files.get("file") and request.files["file"].filename:
        raw = request.files["file"].read()
        for enc in ("utf-8-sig", "cp1251"):
            try:
                text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        else:
            flash("Не удалось прочитать файл.", "error")
            return redirect(url_for("import_keys"))
    else:
        text = request.form.get("data", "")
    rows = check_import(db, read_import(text))
    if not rows:
        flash("В файле не нашлось строк с ключами.", "error")
        return redirect(url_for("import_keys"))
    if not request.form.get("confirm"):  # сначала показать, что будет добавлено
        return render_template("import.html", rows=rows, data=text,
                               new=sum(1 for r in rows if not r["status"]))
    cab_ids = {r["number"]: r["id"] for r in db.execute("SELECT id, number FROM cabinets")}
    added = 0
    for v in rows:
        if v["status"]:
            continue
        cab_id = None
        if v["cabinet"]:
            if v["cabinet"] not in cab_ids:
                kind = "walls" if v.get("wall") else "rings"  # есть колонка «стенка» - значит шкаф со стенками
                cab_ids[v["cabinet"]] = db.execute("INSERT INTO cabinets (number, name, kind) VALUES (?, ?, ?)",
                                                   (v["cabinet"], v["cab_name"], kind)).lastrowid
            cab_id = cab_ids[v["cabinet"]]
        db.execute("INSERT INTO keys (cabinet_id, address, street, house, entrance, ring, ring_pos, box, floor, "
                   "ups, electron, info, wall, side, wrow, wcol) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                   (cab_id, v["address_text"], v["street"], v.get("house", ""), v.get("entrance", ""),
                    v.get("ring", ""), v.get("ring_pos", ""), v.get("box", ""), v.get("floor", ""),
                    v["ups"], v["electron"], v.get("info", ""),
                    v.get("wall", ""), v["side"], v.get("wrow", ""), v.get("wcol", "")))
        if v.get("house_note"):
            set_house_note(db, v["street"], v.get("house", ""), v["house_note"])
        added += 1
    db.commit()
    flash(f"Добавлено ключей: {added}. Пропущено: {len(rows) - added}.", "ok")
    return redirect(url_for("index"))


# ---------- Командная строка ----------

# Аккаунтов два: админ (меняет всё) и общий для сотрудников (только примечания, ИБП, Электрон).
# Логины и пароли задаются в окне управления на сервере (deploy\app.ps1 -> эти команды).
ROLES = {"admin": 1, "staff": 0}


@app.cli.command("set-account")
@click.option("--role", type=click.Choice(list(ROLES)), default="admin", show_default=True)
@click.option("--username", prompt="Логин")
@click.option("--password", envvar="KEYS_ADMIN_PASSWORD", prompt="Пароль",
              hide_input=True, confirmation_prompt="Ещё раз")
def set_account_cmd(role, username, password):
    """Задать логин и пароль админа или сотрудников (у каждой роли один аккаунт)."""
    username = username.strip()
    if not username or len(password) < 6:
        raise click.ClickException("Логин обязателен, пароль — не короче 6 символов.")
    is_admin = ROLES[role]
    init_db()
    with connect() as db:
        mine = db.execute("SELECT id FROM users WHERE is_admin = ? ORDER BY id LIMIT 1", (is_admin,)).fetchone()
        other = db.execute("SELECT id, is_admin FROM users WHERE username = ?", (username,)).fetchone()
        if other and (not mine or other["id"] != mine["id"]):
            if other["is_admin"] != is_admin:
                raise click.ClickException(f"Логин «{username}» уже занят другим аккаунтом — выберите другой.")
            mine = other
        if mine:
            db.execute("UPDATE users SET username = ?, password_hash = ? WHERE id = ?",
                       (username, generate_password_hash(password), mine["id"]))
            # лишние аккаунты этой роли (остались от старых версий) убираем - их должно быть по одному
            db.execute("DELETE FROM users WHERE is_admin = ? AND id != ?", (is_admin, mine["id"]))
        else:
            db.execute("INSERT INTO users (username, password_hash, is_admin) VALUES (?, ?, ?)",
                       (username, generate_password_hash(password), is_admin))
    click.echo(("Админ" if is_admin else "Сотрудники") + f": логин {username}, пароль сохранён.")


@app.cli.command("create-admin")
@click.pass_context
def create_admin_cmd(ctx):
    """То же, что set-account --role admin (для старых инструкций)."""
    ctx.invoke(set_account_cmd, role="admin")


@app.cli.command("accounts")
def accounts_cmd():
    """Какие логины заданы: строки admin=<логин> и staff=<логин> (пусто - нет)."""
    init_db()
    with connect() as db:
        for role, is_admin in ROLES.items():
            row = db.execute("SELECT username FROM users WHERE is_admin = ? ORDER BY id LIMIT 1", (is_admin,)).fetchone()
            click.echo(f"{role}={row['username'] if row else ''}")


init_db()

if __name__ == "__main__":
    app.run(host=os.environ.get("HOST", "127.0.0.1"), port=int(os.environ.get("PORT", 5000)))
