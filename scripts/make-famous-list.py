#!/usr/bin/env python3
"""Makes the list of famous paintings built into the app (App/Models/famous-paintings.json).

The famous paintings are those in Wikidata with an image and articles in at least five Wikipedias (about
5,000). The app fetches their thumbnails itself; this list only spares it a query that Wikidata's query service
often can't finish in time. Wikidata's data is CC0 (public domain).

    python3 scripts/make-famous-list.py              # query Wikidata (tries a few times; it can be slow)
    python3 scripts/make-famous-list.py saved.json   # use a query result saved earlier
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

QUERY = """
SELECT ?w ?wLabel ?creatorLabel ?inception ?img ?mLabel ?article WHERE {
  ?w wdt:P31 wd:Q3305213 ; wdt:P18 ?img ; wikibase:sitelinks ?links .
  FILTER(?links >= 5)
  OPTIONAL { ?w wdt:P170 ?creator }
  OPTIONAL { ?w wdt:P571 ?inception }
  OPTIONAL { ?w wdt:P195 ?m }
  OPTIONAL { ?article schema:about ?w ; schema:isPartOf <https://en.wikipedia.org/> }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en,fr,de,nl,it,es". }
}
"""
AGENT = "PaintingExhibit/0.2 (https://github.com/pedroserano/PaintingExhibit)"
OUT = os.path.join(os.path.dirname(__file__), "..", "PaintingExhibit.swiftpm", "App", "Models", "famous-paintings.json")


def fetch():
    url = "https://query.wikidata.org/sparql?" + urllib.parse.urlencode({"query": QUERY})
    for attempt in range(5):
        try:
            request = urllib.request.Request(url, headers={"Accept": "application/sparql-results+json", "User-Agent": AGENT})
            with urllib.request.urlopen(request, timeout=90) as response:
                return json.load(response)
        except Exception as error:  # timeouts are common; wait and try again
            print(f"Wikidata didn't answer ({error}); trying again…", file=sys.stderr)
            time.sleep(20 * (attempt + 1))
    sys.exit("Wikidata couldn't run the query; try again later.")


def label(value):
    if not value or value.startswith("http"):
        return None
    if value[0] == "Q" and value[1:].isdigit():
        return None
    return value


def year(value):
    if not value:
        return None
    digits = value.lstrip("-").split("-")[0]
    return ("-" if value.startswith("-") else "") + digits if digits.isdigit() else None


def main():
    data = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else fetch()
    works, seen = [], set()
    for row in data["results"]["bindings"]:
        get = lambda k: row.get(k, {}).get("value")
        item, title, image = get("w"), label(get("wLabel")), get("img")
        if not (item and title and image):
            continue
        q = item.rsplit("/", 1)[-1]
        if q in seen:
            continue
        seen.add(q)
        work = {"q": q, "title": title, "image": image,
                "link": get("article") or item.replace("http://", "https://")}
        for key, value in (("artist", label(get("creatorLabel"))), ("year", year(get("inception"))),
                           ("museum", label(get("mLabel")))):
            if value:
                work[key] = value
        works.append(work)
    works.sort(key=lambda w: int(w["q"][1:]))
    with open(OUT, "w") as f:
        json.dump(works, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{len(works)} famous paintings written to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
