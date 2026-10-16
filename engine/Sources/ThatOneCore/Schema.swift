import Foundation

enum Schema {
    /// Applied in order; the list index + 1 is the schema version. Never edit a shipped entry, append a new one.
    static let migrations: [(Store, Int) throws -> Void] = [
        { store, dim in  // v1: content tables, FTS5 and vectors
            try store.run("""
                create table contents(
                    id integer primary key, hash text not null unique, kind text not null,
                    status text not null, note text not null default '', indexed_at integer not null)
                """)
            try store.run("""
                create table files(
                    id integer primary key, path text not null unique,
                    content_id integer references contents(id), kind text not null,
                    size integer not null, mtime integer not null, status text not null,
                    note text not null default '', updated_at integer not null)
                """)
            try store.run("create index files_content on files(content_id)")
            try store.run("""
                create table segments(
                    id integer primary key, content_id integer not null references contents(id),
                    modality text not null, anchor text not null default '{}', text text not null default '')
                """)
            try store.run("create index segments_content on segments(content_id)")
            // 'M*' keeps Indic vowel signs inside words; the default tokenizer splits Kannada/Hindi words.
            try store.run("create virtual table segments_fts using fts5(text, tokenize = \"unicode61 categories 'L* N* Co M*'\")")
            try store.run("create virtual table segment_vectors using vec0(embedding float[\(dim)] distance_metric=cosine)")
        },
        { store, _ in  // v2: persisted job queue
            try store.run("""
                create table jobs(
                    path text primary key, priority integer not null, state text not null,
                    attempts integer not null default 0, next_attempt integer not null default 0,
                    last_error text not null default '')
                """)
            try store.run("create index jobs_state on jobs(state, priority)")
        },
    ]
}

extension Store {
    /// The embedding dimension this database was created for; nil for a database never migrated.
    public func storedDim() throws -> Int? {
        guard try int("select count(*) from sqlite_master where name = 'meta'") == 1 else { return nil }
        return try query("select value from meta where key = 'dim'") { Int($0.text(0)) }.compactMap { $0 }.first
    }

    public func migrate(dim: Int) throws {
        try run("create table if not exists meta(key text primary key, value text not null)")
        if let stored = try storedDim(), stored != dim {
            throw StoreError.dimensionMismatch(stored: stored, requested: dim)
        }
        let version = try query("select value from meta where key = 'schema_version'") { Int($0.text(0)) ?? 0 }.first ?? 0
        guard version <= Schema.migrations.count else { throw StoreError.unsupportedSchema(version) }
        for (index, migration) in Schema.migrations.enumerated() where index + 1 > version {
            try transaction {
                try migration(self, dim)
                try run("insert or replace into meta(key, value) values ('schema_version', ?)", [.text(String(index + 1))])
                try run("insert or replace into meta(key, value) values ('dim', ?)", [.text(String(dim))])
            }
        }
        self.dim = dim
    }

    public static func open(path: String, key: Data, dim: Int) throws -> Store {
        let store = try Store(path: path, key: key)
        try store.migrate(dim: dim)
        return store
    }
}
