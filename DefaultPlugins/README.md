# ClipBar Plugins

ClipBar plugins add web searches and prompt-based actions to the floating action bar. Each plugin is defined by a JSON file in:

```text
~/.config/clipbar/plugins
```

Open the folder from the ClipBar menu with **Plugins → Open Plugins Folder**. After adding or editing a file, choose **Plugins → Reload Plugins**.

## Web Plugin

A basic web plugin looks like this:

```json
{
  "id": "wikipedia",
  "title": "Wikipedia",
  "symbol": "book.closed",
  "url": "https://en.wikipedia.org/w/index.php?search={{text}}",
  "priority": 50,
  "maximum_length": 200
}
```

The selected text is substituted for `{{text}}` and percent-encoded automatically.

The placeholder must use exactly two opening and two closing braces:

```text
{{text}}
```

Placeholders such as `{text}`, `{query}`, or `{{query}}` are not recognized and cause the plugin to fail validation.

## Fields

| Field | Required | Description |
| --- | --- | --- |
| `id` | Yes | Unique identifier containing no user-facing text. |
| `title` | Yes | Name displayed in ClipBar and the Plugins menu. |
| `symbol` | Yes | Name of an SF Symbol used as the action icon. |
| `url` | Yes | URL template containing `{{text}}` for web plugins. |
| `type` | No | `web` or `ai`; defaults to `web`. |
| `prompt` | AI only | Prompt template containing `{{text}}`. |
| `priority` | No | Sort priority; lower values appear earlier. External actions use priority 50 or higher in the action bar. |
| `maximum_length` | No | Hides the action when the selected text exceeds this number of characters. |
| `enabled` | No | Initial enabled state; defaults to `true`. |
| `group` | No | Identifier of a submenu used to group related plugins. |
| `group_symbol` | No | SF Symbol used by an automatically generated group. |

Unknown JSON fields are ignored.

## Examples

### DuckDuckGo Images

```json
{
  "id": "duckduckgo-images",
  "title": "DuckDuckGo Images",
  "symbol": "photo.on.rectangle",
  "url": "https://duckduckgo.com/?q={{text}}&iax=images&ia=images",
  "priority": 56,
  "maximum_length": 200
}
```

### Google Maps

```json
{
  "id": "google-maps",
  "title": "Google Maps",
  "symbol": "map",
  "url": "https://www.google.com/maps/search/{{text}}",
  "priority": 52,
  "maximum_length": 200
}
```

### IMDb

```json
{
  "id": "imdb",
  "title": "IMDb",
  "symbol": "film",
  "url": "https://www.imdb.com/find/?q={{text}}",
  "priority": 53,
  "maximum_length": 200
}
```

## AI Plugin

AI plugins first insert the selected text into `prompt`, encode the resulting prompt, and then insert it into `{{prompt}}` in the URL:

```json
{
  "id": "explain",
  "title": "Explain",
  "symbol": "lightbulb",
  "type": "ai",
  "prompt": "Explain the following text clearly: {{text}}",
  "url": "https://example.com/?prompt={{prompt}}",
  "priority": 60,
  "maximum_length": 2000
}
```

An AI plugin requires both `{{text}}` in `prompt` and `{{prompt}}` in `url`.

## Groups

Assign the same `group` identifier to several plugins to place them in a submenu:

```json
{
  "id": "wikipedia",
  "title": "Wikipedia",
  "symbol": "book.closed",
  "url": "https://en.wikipedia.org/w/index.php?search={{text}}",
  "group": "research",
  "group_symbol": "books.vertical",
  "priority": 50
}
```

ClipBar can generate the group automatically. An optional group definition provides an explicit title, symbol, and priority:

```json
{
  "type": "group",
  "id": "research",
  "title": "Research",
  "symbol": "books.vertical",
  "priority": 50
}
```

## Validation

A plugin fails to load when:

- `id`, `title`, or `symbol` is empty;
- a web URL does not contain `{{text}}`;
- an AI prompt does not contain `{{text}}`;
- an AI URL does not contain `{{prompt}}`;
- its `id` duplicates another plugin ID;
- its JSON syntax or field types are invalid.

ClipBar displays **Plugin Failed to Load** in the Plugins menu when at least one file is invalid. Correct the JSON and choose **Reload Plugins**.

## Notes

- Plugin files must use the `.json` extension.
- Only `http` and `https` URLs are opened.
- Plugin IDs should remain stable because enabled and disabled states are stored by ID.
- Verify SF Symbol names in Apple’s SF Symbols app; an invalid name produces no icon.
- Keep URL templates on one line and save files as UTF-8.

