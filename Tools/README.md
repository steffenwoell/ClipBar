# Thesaurus database

ClipBar ships an offline SQLite database derived from OpenThesaurus and
Princeton WordNet 3.0.

To rebuild it, download the official archives and run:

```zsh
curl -fL -o /tmp/clipbar-openthesaurus.zip \
  https://www.openthesaurus.de/export/OpenThesaurus-Textversion.zip
curl -fL -o /tmp/clipbar-wordnet.tar.gz \
  https://wordnetcode.princeton.edu/3.0/WordNet-3.0.tar.gz

python3 Tools/build-thesaurus.py \
  --openthesaurus /tmp/clipbar-openthesaurus.zip \
  --wordnet /tmp/clipbar-wordnet.tar.gz \
  --output Resources/Thesaurus.sqlite \
  --licenses Resources/ThirdPartyLicenses
```

The generator also extracts the license texts that must be distributed with
the database.
