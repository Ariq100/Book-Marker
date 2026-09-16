# Book Marker

A native iOS app for tracking what you're reading, saving quotes, and building a personal vocabulary list from the books you read.

## Features

- **Library** — search Open Library for books and add them to your shelf as *Reading*, *Bucket List*, or *Done*, with cached cover art.
- **Quotes** — save memorable passages tied to a book title.
- **Vocab** — save unfamiliar words with definitions, auto-fetched from a free dictionary API.
- **Spotlight search** — quickly find books, quotes, or words across your library.
- **Account sync** — sign in with email/password or Sign in with Apple; your library, quotes, and vocab sync across devices via Supabase.
- **Offline-first** — data is stored locally with SwiftData and pushed to Supabase in the background, using last-write-wins conflict resolution.

## Tech stack

- **SwiftUI** for the UI, **SwiftData** for local persistence.
- **[Open Library API](https://openlibrary.org/developers/api)** for book search and cover images.
- **[Free Dictionary API](https://dictionaryapi.dev/)** for word definitions.

## Project structure

```
Book Marker/
├── Models/          Book, Quote, VocabWord — SwiftData models
├── Services/         AuthManager, SyncManager, OpenLibraryService, DictionaryService, ...
├── Views/
│   ├── Library/       Book shelf UI
│   ├── Quotes/         Quote list and add-quote form
│   ├── Vocab/           Word list and add-word form
│   ├── Search/           Book search, Spotlight overlay
│   └── AuthView, SettingsView
└── Info.plist
```
