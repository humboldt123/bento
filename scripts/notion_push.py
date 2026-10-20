"""Upload decks, gyms and workout history to the app's Notion databases.

    python3 scripts/notion_push.py decks <dir of deck .json>
    python3 scripts/notion_push.py gyms <gyms.json>
    python3 scripts/notion_push.py gym-log <history .txt in the app's export format>

Rows are matched by Card ID / Deck ID / name / date and updated in place, so re-running is safe.
Card progress (Box, Due, Reviewed) is never overwritten. Reads the secret and database ids from
Config.xcconfig and never prints them.

Deck file: { id, title, subtitle, symbol, order, cards: [ { id, kind, tag?, ...kind fields } ] }
(see DeckJSON in Bento/Flashcards/DeckStore.swift for every kind's fields).
"""
import json, os, re, sys, time, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = open(os.path.join(ROOT, "Config.xcconfig")).read()


def cfg(key):
    m = re.search(rf"^{key}\s*=\s*(\S+)", CONFIG, re.M)
    if not m:
        sys.exit(f"{key} missing from Config.xcconfig")
    return m.group(1)


SECRET = cfg("NOTION_SECRET")


def api(method, path, body=None):
    for attempt in range(5):
        req = urllib.request.Request(
            "https://api.notion.com/v1/" + path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": "Bearer " + SECRET, "Notion-Version": "2022-06-28",
                     "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as r:
                time.sleep(0.34)  # ~3 requests/second
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code in (429, 502, 503) and attempt < 4:
                time.sleep(2 * (attempt + 1)); continue
            detail = e.read().decode()[:300]
            if e.code == 404:
                sys.exit("Notion can't see that database. Share the Bento page with the app's connection.")
            sys.exit(f"Notion {e.code}: {detail}")


def rows(db):
    out, cursor = [], None
    while True:
        body = {"page_size": 100, **({"start_cursor": cursor} if cursor else {})}
        r = api("POST", f"databases/{db}/query", body)
        out += r["results"]
        if not r.get("has_more"):
            return out
        cursor = r["next_cursor"]


def plain(page, key):
    p = page["properties"].get(key, {})
    return "".join(t["plain_text"] for t in p.get("title", p.get("rich_text", [])))


def text(s, kind="rich_text"):
    s = s or ""
    return {kind: [{"type": "text", "text": {"content": s[i:i + 1900]}} for i in range(0, len(s), 1900)]}


def upsert(db, existing, key, props):
    if key in existing:
        api("PATCH", f"pages/{existing[key]}", {"properties": props})
        return "updated"
    api("POST", "pages", {"parent": {"database_id": db}, "properties": props})
    return "created"


def label(card):
    for k in ("front", "prompt", "name", "text"):
        if card.get(k):
            s = re.sub(r"\[\[\d+\]\]", "___", card[k]).split("\n")[0]
            return re.sub(r"\*\*|\$", "", s)[:120]
    return card["id"]


def push_decks(folder):
    decks_db, cards_db = cfg("DECKS_DB"), cfg("CARDS_DB")
    deck_rows = {plain(p, "Deck ID"): p["id"] for p in rows(decks_db)}
    card_rows = {plain(p, "Card ID"): p["id"] for p in rows(cards_db)}
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".json"):
            continue
        deck = json.load(open(os.path.join(folder, name)))
        upsert(decks_db, deck_rows, deck["id"], {
            "Name": text(deck["title"], "title"), "Deck ID": text(deck["id"]),
            "Subtitle": text(deck.get("subtitle", "")), "Symbol": text(deck.get("symbol", "")),
            "Order": {"number": deck.get("order", 0)}})
        counts = {"created": 0, "updated": 0}
        for i, card in enumerate(deck["cards"]):
            data = {k: v for k, v in card.items() if k not in ("id", "kind")}
            counts[upsert(cards_db, card_rows, card["id"], {
                "Name": text(label(card), "title"), "Card ID": text(card["id"]),
                "Deck": {"select": {"name": deck["id"]}}, "Kind": {"select": {"name": card.get("kind", "flip")}},
                "Tag": text(card.get("tag", "")), "Order": {"number": i},
                "Data": text(json.dumps(data, ensure_ascii=False, separators=(",", ":"))),
            })] += 1
        print(f"{deck['id']}: {counts['created']} created, {counts['updated']} updated")


def push_gyms(path):
    db = cfg("GYMS_DB")
    existing = {plain(p, "Name"): p["id"] for p in rows(db)}
    for i, g in enumerate(json.load(open(path))):
        print(g["name"], upsert(db, existing, g["name"], {
            "Name": text(g["name"], "title"), "Exercises": text(", ".join(g.get("exercises", []))),
            "Equipment": text(", ".join(map(str, g.get("equipment", [])))),
            "Single Dumbbell": {"checkbox": g.get("singleDumbbell", False)},
            "Dumbbell Max": {"number": g.get("dumbbellMax")}, "Dumbbell Step": {"number": g.get("dumbbellStep")},
            "Logo": {"url": g.get("logo")}, "Default": {"checkbox": g.get("default", False)}, "Order": {"number": i}}))


def push_gym_log(path):
    db = cfg("GYMLOG_DB")
    existing = {plain(p, "Log")[:10]: p["id"] for p in rows(db)}
    days = [d.strip() for d in open(path).read().split("\n\n") if d.strip()]
    counts = {"created": 0, "updated": 0}
    for day in days:
        header = day.split("\n")[0]
        parts = [p.strip() for p in header.split("·")]
        props = {"Name": text(header, "title"), "Date": {"date": {"start": header[:10]}}, "Log": text(day)}
        if len(parts) >= 3:
            props["Gym"] = {"select": {"name": parts[2]}}
        counts[upsert(db, existing, header[:10], props)] += 1
    print(f"gym log: {counts['created']} created, {counts['updated']} updated")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("decks", "gyms", "gym-log"):
        sys.exit(__doc__)
    {"decks": push_decks, "gyms": push_gyms, "gym-log": push_gym_log}[sys.argv[1]](sys.argv[2])
