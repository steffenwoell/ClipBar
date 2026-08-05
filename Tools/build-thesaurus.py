#!/usr/bin/env python3
"""Build ClipBar's offline German/English thesaurus database."""

import argparse
import re
import sqlite3
import tarfile
import tempfile
import unicodedata
import zipfile
from pathlib import Path


def normalize(value: str) -> str:
    return unicodedata.normalize("NFC", value).lower().strip()


def clean_german_term(value: str) -> str:
    value = value.strip()
    while re.search(r"\s+\([^()]*(?:Hauptform|ugs\.|fachspr\.|geh\.|veraltet|regional|fig\.|salopp|ironisierend|literarisch|technisch|Kindersprache|süddt\.|norddeutsch|berlinerisch|poetisch|variabel)[^()]*\)$", value):
        value = re.sub(r"\s+\([^()]*\)$", "", value).strip()
    return value


def insert_group(connection, language, group_id, terms):
    seen = set()
    rows = []
    for rank, display in enumerate(terms):
        display = display.replace("_", " ").strip()
        key = normalize(display)
        if not key or key in seen:
            continue
        seen.add(key)
        rows.append((language, key, display, group_id, rank))
    if len(rows) > 1:
        connection.executemany(
            "INSERT INTO entries(language, term, display, group_id, rank) VALUES(?,?,?,?,?)",
            rows,
        )


def import_openthesaurus(connection, archive):
    with zipfile.ZipFile(archive) as source:
        lines = source.read("openthesaurus.txt").decode("utf-8").splitlines()
    group = 0
    for line in lines:
        if not line or line.startswith("#"):
            continue
        terms = [clean_german_term(value) for value in line.split(";")]
        insert_group(connection, "de", f"de:{group}", terms)
        group += 1


def import_wordnet(connection, archive):
    members = {
        "noun": "n",
        "verb": "v",
        "adj": "a",
        "adv": "r",
    }
    with tarfile.open(archive, "r:gz") as source:
        for filename, part_of_speech in members.items():
            member = source.extractfile(f"WordNet-3.0/dict/data.{filename}")
            if member is None:
                raise RuntimeError(f"WordNet data.{filename} missing")
            for raw_line in member:
                line = raw_line.decode("utf-8").strip()
                if not re.match(r"^\d{8}\s", line):
                    continue
                fields = line.split("|")[0].split()
                offset = fields[0]
                word_count = int(fields[3], 16)
                terms = [fields[4 + index * 2] for index in range(word_count)]
                insert_group(
                    connection,
                    "en",
                    f"en:{part_of_speech}:{offset}",
                    terms,
                )

        for filename in ("noun", "verb", "adj", "adv"):
            member = source.extractfile(f"WordNet-3.0/dict/{filename}.exc")
            if member is None:
                continue
            for raw_line in member:
                fields = raw_line.decode("utf-8").strip().split()
                if len(fields) >= 2:
                    connection.execute(
                        "INSERT OR IGNORE INTO forms(language, form, lemma) VALUES('en', ?, ?)",
                        (normalize(fields[0].replace("_", " ")), normalize(fields[1].replace("_", " "))),
                    )


def write_licenses(open_archive, wordnet_archive, directory):
    directory.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(open_archive) as source:
        (directory / "OpenThesaurus-LGPL.txt").write_bytes(source.read("LICENSE.txt"))
    with tarfile.open(wordnet_archive, "r:gz") as source:
        member = source.extractfile("WordNet-3.0/LICENSE")
        if member is None:
            raise RuntimeError("WordNet license missing")
        (directory / "WordNet-3.0-License.txt").write_bytes(member.read())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--openthesaurus", type=Path, required=True)
    parser.add_argument("--wordnet", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--licenses", type=Path, required=True)
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as temporary:
        database = Path(temporary) / "Thesaurus.sqlite"
        connection = sqlite3.connect(database)
        connection.executescript(
            """
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            CREATE TABLE entries(
                language TEXT NOT NULL,
                term TEXT NOT NULL,
                display TEXT NOT NULL,
                group_id TEXT NOT NULL,
                rank INTEGER NOT NULL
            );
            CREATE TABLE forms(
                language TEXT NOT NULL,
                form TEXT NOT NULL,
                lemma TEXT NOT NULL,
                PRIMARY KEY(language, form, lemma)
            ) WITHOUT ROWID;
            """
        )
        import_openthesaurus(connection, args.openthesaurus)
        import_wordnet(connection, args.wordnet)
        connection.executescript(
            """
            CREATE INDEX entries_lookup ON entries(language, term);
            CREATE INDEX entries_group ON entries(language, group_id, rank);
            ANALYZE;
            VACUUM;
            """
        )
        connection.close()
        database.replace(args.output)

    write_licenses(args.openthesaurus, args.wordnet, args.licenses)


if __name__ == "__main__":
    main()
