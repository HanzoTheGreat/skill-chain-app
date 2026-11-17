use flutter_rust_bridge::frb;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

// Globale, Thread-sichere Datenbankverbindung
static DB_PATH: Mutex<Option<PathBuf>> = Mutex::new(None);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TensionZone {
    Low,       // 0 - 50
    High,      // 55 - 70
    Emergency, // > 70 (Hochanspannung / Notfall)
}

impl TensionZone {
    pub fn to_db_int(self) -> i32 {
        match self {
            TensionZone::Low => 1,
            TensionZone::High => 2,
            TensionZone::Emergency => 3,
        }
    }

    pub fn from_db_int(val: i32) -> Self {
        match val {
            1 => TensionZone::Low,
            2 => TensionZone::High,
            _ => TensionZone::Emergency,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Skill {
    pub id: i64,
    pub title: String,
    pub description: String,
    pub zone: TensionZone,
    pub only_private: bool,
    pub is_custom: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillChain {
    pub id: i64,
    pub name: String,
    pub is_active_private: bool, // Feuert im Modus "Privat / Zuhause"
    pub is_active_public: bool,  // Feuert im Modus "Unterwegs"
    pub skills: Vec<Skill>,
}

fn get_conn() -> Result<Connection, String> {
    let guard = DB_PATH.lock().map_err(|e| e.to_string())?;
    let path = guard
        .as_ref()
        .ok_or_else(|| "Datenbank wurde noch nicht initialisiert!".to_string())?;
    Connection::open(path).map_err(|e| e.to_string())
}

/// Initialisiert die SQLite-Datenbank im App-Verzeichnis und legt Basis-Skills + zwei Beispielketten an.
pub fn init_db(app_dir: String) -> Result<(), String> {
    let mut path = PathBuf::from(app_dir);
    path.push("skills_database.sqlite");

    {
        let mut guard = DB_PATH.lock().map_err(|e| e.to_string())?;
        *guard = Some(path);
    }

    let conn = get_conn()?;

    conn.execute_batch(
        "
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS skills (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            zone INTEGER NOT NULL,
            only_private INTEGER NOT NULL DEFAULT 0,
            is_custom INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS chains (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            is_active_private INTEGER NOT NULL DEFAULT 0,
            is_active_public INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS chain_steps (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chain_id INTEGER NOT NULL,
            skill_id INTEGER NOT NULL,
            position INTEGER NOT NULL,
            FOREIGN KEY(chain_id) REFERENCES chains(id) ON DELETE CASCADE,
            FOREIGN KEY(skill_id) REFERENCES skills(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS app_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            is_out_in_public INTEGER NOT NULL DEFAULT 0
        );

        INSERT OR IGNORE INTO app_state (id, is_out_in_public) VALUES (1, 0);
        ",
    )
    .map_err(|e| e.to_string())?;

    // Sanftes Upgrade falls alte DB-Tabelle ohne is_active_public existiert:
    let _ = conn.execute(
        "ALTER TABLE chains RENAME COLUMN is_active_emergency TO is_active_private",
        [],
    );
    let _ = conn.execute(
        "ALTER TABLE chains ADD COLUMN is_active_public INTEGER NOT NULL DEFAULT 0",
        [],
    );

    seed_defaults_if_empty(&conn)?;
    Ok(())
}

/// Liest den zuletzt gewählten Modus (false = Privat/Zuhause, true = Unterwegs) aus der DB.
pub fn get_public_mode() -> Result<bool, String> {
    let conn = get_conn()?;
    let val: i32 = conn
        .query_row(
            "SELECT is_out_in_public FROM app_state WHERE id = 1",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    Ok(val != 0)
}

/// Speichert den gewählten Modus dauerhaft in der DB (für das Homescreen-Widget).
pub fn set_public_mode(is_out_in_public: bool) -> Result<(), String> {
    let conn = get_conn()?;
    conn.execute(
        "UPDATE app_state SET is_out_in_public = ?1 WHERE id = 1",
        params![if is_out_in_public { 1 } else { 0 }],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

fn seed_defaults_if_empty(conn: &Connection) -> Result<(), String> {
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM skills", [], |row| row.get(0))
        .map_err(|e| e.to_string())?;

    if count > 0 {
        return Ok(());
    }

    // Standard-Skills für den Start (0-50, 55-70, Notfall)
    let default_skills = vec![
        (
            "5-4-3-2-1 Methode",
            "Nenne 5 Dinge die du siehst, 4 die du fühlst, 3 die du hörst, 2 die du riechst, 1 das du schmeckst.",
            TensionZone::Low,
            false,
        ),
        (
            "Lieblingsmusik (Bewusst hören)",
            "Setz Kopfhörer auf und konzentriere dich ausschließlich auf ein einzelnes Instrument oder den Rhythmus.",
            TensionZone::Low,
            false,
        ),
        (
            "Heißer Tee / Kaffee",
            "Trinke langsam und spüre bewusst die Wärme in den Händen und beim Schlucken.",
            TensionZone::Low,
            true,
        ),
        (
            "Rückwärts rechnen (1000 minus 7)",
            "Zähle im Kopf oder laut von 1000 in 7er-Schritten rückwärts (993, 986, ...). Blockiert Grübel- und Zwangsschleifen.",
            TensionZone::High,
            false,
        ),
        (
            "Igelball / Akupressurring",
            "Rolle den Ball oder Ring mit starkem Druck über Handflächen oder Finger.",
            TensionZone::High,
            false,
        ),
        (
            "Wanddrücken / Wandsitzen",
            "Drücke mit voller Kraft gegen eine Wand oder geh in den Wandsitz, bis die Oberschenkel brennen.",
            TensionZone::High,
            true,
        ),
        (
            "Eiswasser-Tauchreflex (TIPP)",
            "Gesicht für 15-30 Sekunden in eiskaltes Wasser tauchen oder Kühlpack auf Augen und Wangen drücken.",
            TensionZone::Emergency,
            true,
        ),
        (
            "Chili / Ammoniak / Sauer",
            "Maximaler sensorischer Reiz: In eine Chilischote beißen, starkes Sauerbonbon oder Riechsalz nutzen.",
            TensionZone::Emergency,
            false,
        ),
        (
            "4-7-8 Atmung (Abklingen)",
            "4 Sek. einatmen, 7 Sek. halten, 8 Sek. kräftig ausatmen. 4 Durchgänge zum Runterfahren nach dem Reiz.",
            TensionZone::High,
            false,
        ),
    ];

    for (title, desc, zone, only_priv) in default_skills {
        conn.execute(
            "INSERT INTO skills (title, description, zone, only_private, is_custom) VALUES (?1, ?2, ?3, ?4, 0)",
            params![title, desc, zone.to_db_int(), if only_priv { 1 } else { 0 }],
        )
        .map_err(|e| e.to_string())?;
    }

    // 1. Standard-Kette für ZUHAUSE / PRIVAT
    conn.execute(
        "INSERT INTO chains (name, is_active_private, is_active_public) VALUES ('Notfallkaskade (Zuhause)', 1, 0)",
        [],
    )
    .map_err(|e| e.to_string())?;
    let private_chain_id = conn.last_insert_rowid();

    for (pos, skill_id) in [7_i64, 6_i64, 9_i64, 3_i64].iter().enumerate() {
        conn.execute(
            "INSERT INTO chain_steps (chain_id, skill_id, position) VALUES (?1, ?2, ?3)",
            params![private_chain_id, skill_id, pos as i32],
        )
        .map_err(|e| e.to_string())?;
    }

    // 2. Standard-Kette für UNTERWEGS
    conn.execute(
        "INSERT INTO chains (name, is_active_private, is_active_public) VALUES ('Notfallkaskade (Unterwegs)', 0, 1)",
        [],
    )
    .map_err(|e| e.to_string())?;
    let public_chain_id = conn.last_insert_rowid();

    for (pos, skill_id) in [8_i64, 4_i64, 5_i64, 1_i64].iter().enumerate() {
        conn.execute(
            "INSERT INTO chain_steps (chain_id, skill_id, position) VALUES (?1, ?2, ?3)",
            params![public_chain_id, skill_id, pos as i32],
        )
        .map_err(|e| e.to_string())?;
    }

    Ok(())
}

/// Holt alle Skills, optional gefiltert nach Anspannungszone.
pub fn get_skills(zone_filter: Option<TensionZone>) -> Result<Vec<Skill>, String> {
    let conn = get_conn()?;
    let mut skills = Vec::new();

    let map_row = |row: &rusqlite::Row| -> rusqlite::Result<Skill> {
        Ok(Skill {
            id: row.get(0)?,
            title: row.get(1)?,
            description: row.get(2)?,
            zone: TensionZone::from_db_int(row.get(3)?),
            only_private: row.get::<_, i32>(4)? != 0,
            is_custom: row.get::<_, i32>(5)? != 0,
        })
    };

    if let Some(zone) = zone_filter {
        let mut stmt = conn
            .prepare("SELECT id, title, description, zone, only_private, is_custom FROM skills WHERE zone = ?1 ORDER BY title ASC")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![zone.to_db_int()], map_row)
            .map_err(|e| e.to_string())?;
        for r in rows {
            skills.push(r.map_err(|e| e.to_string())?);
        }
    } else {
        let mut stmt = conn
            .prepare("SELECT id, title, description, zone, only_private, is_custom FROM skills ORDER BY zone ASC, title ASC")
            .map_err(|e| e.to_string())?;
        let rows = stmt.query_map([], map_row).map_err(|e| e.to_string())?;
        for r in rows {
            skills.push(r.map_err(|e| e.to_string())?);
        }
    }

    Ok(skills)
}

/// Fügt einen neuen eigenen Skill hinzu.
pub fn add_custom_skill(
    title: String,
    description: String,
    zone: TensionZone,
    only_private: bool,
) -> Result<Skill, String> {
    let conn = get_conn()?;
    conn.execute(
        "INSERT INTO skills (title, description, zone, only_private, is_custom) VALUES (?1, ?2, ?3, ?4, 1)",
        params![
            title,
            description,
            zone.to_db_int(),
            if only_private { 1 } else { 0 }
        ],
    )
    .map_err(|e| e.to_string())?;

    let id = conn.last_insert_rowid();
    Ok(Skill {
        id,
        title,
        description,
        zone,
        only_private,
        is_custom: true,
    })
}

/// Aktualisiert einen bestehenden Skill (Name, Beschreibung, Zone, Privat-Status).
pub fn update_skill(
    skill_id: i64,
    title: String,
    description: String,
    zone: TensionZone,
    only_private: bool,
) -> Result<(), String> {
    let conn = get_conn()?;
    conn.execute(
        "UPDATE skills SET title = ?1, description = ?2, zone = ?3, only_private = ?4 WHERE id = ?5",
        params![
            title,
            description,
            zone.to_db_int(),
            if only_private { 1 } else { 0 },
            skill_id
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// Löscht einen Skill (entfernt ihn durch ON DELETE CASCADE auch automatisch aus Ketten).
pub fn delete_skill(skill_id: i64) -> Result<(), String> {
    let conn = get_conn()?;
    conn.execute("DELETE FROM skills WHERE id = ?1", params![skill_id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Lädt alle gespeicherten Skillketten inklusive ihrer sortierten Skills.
pub fn get_all_chains() -> Result<Vec<SkillChain>, String> {
    let conn = get_conn()?;
    let mut stmt = conn
        .prepare("SELECT id, name, is_active_private, is_active_public FROM chains ORDER BY id ASC")
        .map_err(|e| e.to_string())?;

    let chain_headers: Vec<(i64, String, bool, bool)> = stmt
        .query_map([], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get::<_, i32>(2)? != 0,
                row.get::<_, i32>(3)? != 0,
            ))
        })
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    let mut result = Vec::new();
    for (chain_id, name, is_priv, is_pub) in chain_headers {
        let skills = get_steps_for_chain(&conn, chain_id)?;
        result.push(SkillChain {
            id: chain_id,
            name,
            is_active_private: is_priv,
            is_active_public: is_pub,
            skills,
        });
    }

    Ok(result)
}

fn get_steps_for_chain(conn: &Connection, chain_id: i64) -> Result<Vec<Skill>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT s.id, s.title, s.description, s.zone, s.only_private, s.is_custom
             FROM chain_steps cs
             JOIN skills s ON cs.skill_id = s.id
             WHERE cs.chain_id = ?1
             ORDER BY cs.position ASC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map(params![chain_id], |row| {
            Ok(Skill {
                id: row.get(0)?,
                title: row.get(1)?,
                description: row.get(2)?,
                zone: TensionZone::from_db_int(row.get(3)?),
                only_private: row.get::<_, i32>(4)? != 0,
                is_custom: row.get::<_, i32>(5)? != 0,
            })
        })
        .map_err(|e| e.to_string())?;

    let mut skills = Vec::new();
    for r in rows {
        skills.push(r.map_err(|e| e.to_string())?);
    }
    Ok(skills)
}

/// Holt gezielt die passende Notfallkette für den aktuellen Modus (Zuhause vs. Unterwegs).
pub fn get_active_emergency_chain(is_out_in_public: bool) -> Result<Option<SkillChain>, String> {
    let chains = get_all_chains()?;
    let active = if is_out_in_public {
        chains
            .iter()
            .find(|c| c.is_active_public)
            .cloned()
            .or_else(|| chains.into_iter().next())
    } else {
        chains
            .iter()
            .find(|c| c.is_active_private)
            .cloned()
            .or_else(|| chains.into_iter().next())
    };

    if let Some(mut chain) = active {
        if is_out_in_public {
            chain.skills.retain(|s| !s.only_private);
        }
        Ok(Some(chain))
    } else {
        Ok(None)
    }
}

/// Speichert die neu sortierte Reihenfolge (aus dem Drag & Drop Editor in Flutter) für eine Kette.
pub fn update_chain_steps(chain_id: i64, ordered_skill_ids: Vec<i64>) -> Result<(), String> {
    let mut conn = get_conn()?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    tx.execute(
        "DELETE FROM chain_steps WHERE chain_id = ?1",
        params![chain_id],
    )
    .map_err(|e| e.to_string())?;

    for (pos, skill_id) in ordered_skill_ids.iter().enumerate() {
        tx.execute(
            "INSERT INTO chain_steps (chain_id, skill_id, position) VALUES (?1, ?2, ?3)",
            params![chain_id, skill_id, pos as i32],
        )
        .map_err(|e| e.to_string())?;
    }

    tx.commit().map_err(|e| e.to_string())?;
    Ok(())
}

/// Erstellt eine neue leere Skillkette und gibt ihre ID zurück.
pub fn create_chain(
    name: String,
    set_for_private: bool,
    set_for_public: bool,
) -> Result<i64, String> {
    let conn = get_conn()?;
    if set_for_private {
        conn.execute("UPDATE chains SET is_active_private = 0", [])
            .map_err(|e| e.to_string())?;
    }
    if set_for_public {
        conn.execute("UPDATE chains SET is_active_public = 0", [])
            .map_err(|e| e.to_string())?;
    }
    conn.execute(
        "INSERT INTO chains (name, is_active_private, is_active_public) VALUES (?1, ?2, ?3)",
        params![
            name,
            if set_for_private { 1 } else { 0 },
            if set_for_public { 1 } else { 0 }
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(conn.last_insert_rowid())
}

/// Legt fest, welche Kette für "Privat / Zuhause" oder "Unterwegs" beim Druck auf den Notfallknopf startet.
pub fn set_active_chain_for_mode(chain_id: i64, for_public_mode: bool) -> Result<(), String> {
    let conn = get_conn()?;
    if for_public_mode {
        conn.execute("UPDATE chains SET is_active_public = 0", [])
            .map_err(|e| e.to_string())?;
        conn.execute(
            "UPDATE chains SET is_active_public = 1 WHERE id = ?1",
            params![chain_id],
        )
        .map_err(|e| e.to_string())?;
    } else {
        conn.execute("UPDATE chains SET is_active_private = 0", [])
            .map_err(|e| e.to_string())?;
        conn.execute(
            "UPDATE chains SET is_active_private = 1 WHERE id = ?1",
            params![chain_id],
        )
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}