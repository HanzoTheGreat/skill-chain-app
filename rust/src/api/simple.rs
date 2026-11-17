use flutter_rust_bridge::frb;
use rusqlite::{params, Connection, OptionalExtension};
use std::path::PathBuf;
use std::sync::Mutex;

static DB_PATH: Mutex<Option<PathBuf>> = Mutex::new(None);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TensionZone {
    Low,       // 0 - 50
    High,      // 55 - 70
    Emergency, // > 70
}

impl TensionZone {
    fn to_db_int(self) -> i32 {
        match self {
            TensionZone::Low => 0,
            TensionZone::High => 1,
            TensionZone::Emergency => 2,
        }
    }

    fn from_db_int(val: i32) -> Self {
        match val {
            0 => TensionZone::Low,
            1 => TensionZone::High,
            _ => TensionZone::Emergency,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Skill {
    pub id: i64,
    pub title: String,
    pub description: String,
    pub zone: TensionZone,
    pub is_custom: bool,
    pub only_private: bool,
    pub duration_seconds: i32,
}

#[derive(Clone, Debug)]
pub struct SkillChain {
    pub id: i64,
    pub name: String,
    pub is_active_private: bool,
    pub is_active_public: bool,
    pub skills: Vec<Skill>,
}

fn get_conn() -> Result<Connection, String> {
    let guard = DB_PATH.lock().map_err(|e| e.to_string())?;
    let path = guard
        .as_ref()
        .ok_or_else(|| "Datenbank noch nicht initialisiert!".to_string())?;
    let conn = Connection::open(path).map_err(|e| e.to_string())?;
    conn.execute_batch("PRAGMA foreign_keys = ON;")
        .map_err(|e| e.to_string())?;
    Ok(conn)
}

#[frb]
pub fn init_db(app_dir: String) -> Result<(), String> {
    let mut path = PathBuf::from(app_dir);
    std::fs::create_dir_all(&path).map_err(|e| e.to_string())?;
    path.push("skills_local.sqlite");

    {
        let mut guard = DB_PATH.lock().map_err(|e| e.to_string())?;
        *guard = Some(path);
    }

    let conn = get_conn()?;

    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS skills (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            zone INTEGER NOT NULL,
            is_custom INTEGER NOT NULL DEFAULT 0,
            only_private INTEGER NOT NULL DEFAULT 0,
            duration_seconds INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS chains (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            is_active_private INTEGER NOT NULL DEFAULT 0,
            is_active_public INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS chain_steps (
            chain_id INTEGER NOT NULL,
            step_order INTEGER NOT NULL,
            skill_id INTEGER NOT NULL,
            PRIMARY KEY (chain_id, step_order),
            FOREIGN KEY (chain_id) REFERENCES chains(id) ON DELETE CASCADE,
            FOREIGN KEY (skill_id) REFERENCES skills(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY,
            val_int INTEGER NOT NULL DEFAULT 0
        );",
    )
    .map_err(|e| e.to_string())?;

    // Sanfte Migration für bestehende Datenbanken (fügt duration_seconds hinzu, falls noch nicht vorhanden)
    let _ = conn.execute(
        "ALTER TABLE skills ADD COLUMN duration_seconds INTEGER NOT NULL DEFAULT 0",
        [],
    );

    seed_defaults_if_empty(&conn)?;
    Ok(())
}

fn seed_defaults_if_empty(conn: &Connection) -> Result<(), String> {
    let skill_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM skills", [], |row| row.get(0))
        .map_err(|e| e.to_string())?;

    if skill_count == 0 {
        let default_skills: Vec<(&str, &str, TensionZone, bool, i32)> = vec![
            // Zone > 70 (Emergency / Akut)
            (
                "Eiswasser / Tauchreflex (TIPP)",
                "Schüssel mit kaltem Wasser + Eiswürfeln. Luft anhalten und Gesicht für 30 Sekunden eintauchen (senkt sofort die Herzfrequenz).",
                TensionZone::Emergency,
                true,
                30,
            ),
            (
                "Kühlpack in den Nacken / Puls",
                "Eiskaltes Kühlpack oder gefrorene Erbsen für 60 Sekunden fest in den Nacken oder auf die Handgelenke drücken.",
                TensionZone::Emergency,
                true,
                60,
            ),
            (
                "Chili / Extrem scharfer Reiz",
                "Auf eine Chilischote, Ingwer oder eine extrem saure Zitrone beißen. Konzentriere dich 45 Sekunden voll auf das Brennen.",
                TensionZone::Emergency,
                false,
                45,
            ),
            (
                "Wandsitzen / Maximale Muskelspannung",
                "Rücken an die Wand, Knie im 90-Grad-Winkel beugen und 60 Sekunden halten, bis die Oberschenkel brennen.",
                TensionZone::Emergency,
                false,
                60,
            ),
            (
                "Igelball / Akupressurring fest rollen",
                "Den Igelball oder Metallring 60 Sekunden lang mit maximalem Druck über Handflächen und Finger rollen.",
                TensionZone::Emergency,
                false,
                60,
            ),
            // Zone 55 - 70 (High)
            (
                "4-7-8 Tiefenatmung",
                "4 Sek. durch die Nase einatmen, 7 Sek. Luft anhalten, 8 Sek. hörbar durch den Mund ausatmen. Für 90 Sekunden wiederholen.",
                TensionZone::High,
                false,
                90,
            ),
            (
                "5-4-3-2-1 Grounding",
                "Nenne 5 Dinge, die du siehst, 4 die du fühlst, 3 die du hörst, 2 die du riechst und 1 Sache, die du schmeckst.",
                TensionZone::High,
                false,
                0,
            ),
            (
                "Rückwärts rechnen (100 minus 7)",
                "Zähle laut oder im Kopf von 100 in 7er-Schritten rückwärts (100, 93, 86, 79 ...).",
                TensionZone::High,
                false,
                60,
            ),
            (
                "Kaltes Wasser über die Unterarme",
                "Lass für 60 Sekunden eiskaltes Leitungswasser über beide Handgelenke und Unterarme laufen.",
                TensionZone::High,
                false,
                60,
            ),
            // Zone 0 - 50 (Low)
            (
                "Bewusster Tee / Warmgetränk",
                "Koche dir einen Tee und konzentriere dich 3 Minuten lang nur auf die Wärme der Tasse und den Geruch.",
                TensionZone::Low,
                true,
                180,
            ),
            (
                "Kurzer Spaziergang ohne Handy",
                "Geh für 5 Minuten an die frische Luft und achte bewusst auf deine Schritte auf dem Boden.",
                TensionZone::Low,
                false,
                300,
            ),
            (
                "Progressive Muskelentspannung (PMR)",
                "Spanne nacheinander Fäuste, Schultern und Gesicht für je 5 Sekunden fest an und lass 10 Sekunden komplett locker.",
                TensionZone::Low,
                false,
                120,
            ),
        ];

        for (title, desc, zone, only_priv, duration_sec) in default_skills {
            conn.execute(
                "INSERT INTO skills (title, description, zone, is_custom, only_private, duration_seconds)
                 VALUES (?1, ?2, ?3, 0, ?4, ?5)",
                params![
                    title,
                    desc,
                    zone.to_db_int(),
                    if only_priv { 1 } else { 0 },
                    duration_sec
                ],
            )
            .map_err(|e| e.to_string())?;
        }
    }

    let chain_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM chains", [], |row| row.get(0))
        .map_err(|e| e.to_string())?;

    if chain_count == 0 {
        conn.execute(
            "INSERT INTO chains (name, is_active_private, is_active_public) VALUES (?1, 1, 0)",
            params!["Zuhause Akut-Kaskade"],
        )
        .map_err(|e| e.to_string())?;
        let home_chain_id = conn.last_insert_rowid();

        let mut stmt = conn
            .prepare("SELECT id FROM skills WHERE zone IN (1, 2) ORDER BY zone DESC, id ASC LIMIT 4")
            .map_err(|e| e.to_string())?;
        let home_skill_ids: Vec<i64> = stmt
            .query_map([], |r| r.get(0))
            .map_err(|e| e.to_string())?
            .filter_map(Result::ok)
            .collect();

        for (idx, s_id) in home_skill_ids.iter().enumerate() {
            conn.execute(
                "INSERT INTO chain_steps (chain_id, step_order, skill_id) VALUES (?1, ?2, ?3)",
                params![home_chain_id, idx as i32, s_id],
            )
            .map_err(|e| e.to_string())?;
        }

        conn.execute(
            "INSERT INTO chains (name, is_active_private, is_active_public) VALUES (?1, 0, 1)",
            params!["Unterwegs Notfall-Kette"],
        )
        .map_err(|e| e.to_string())?;
        let pub_chain_id = conn.last_insert_rowid();

        let mut stmt_pub = conn
            .prepare("SELECT id FROM skills WHERE only_private = 0 AND zone IN (1, 2) ORDER BY zone DESC, id ASC LIMIT 4")
            .map_err(|e| e.to_string())?;
        let pub_skill_ids: Vec<i64> = stmt_pub
            .query_map([], |r| r.get(0))
            .map_err(|e| e.to_string())?
            .filter_map(Result::ok)
            .collect();

        for (idx, s_id) in pub_skill_ids.iter().enumerate() {
            conn.execute(
                "INSERT INTO chain_steps (chain_id, step_order, skill_id) VALUES (?1, ?2, ?3)",
                params![pub_chain_id, idx as i32, s_id],
            )
            .map_err(|e| e.to_string())?;
        }
    }

    Ok(())
}

#[frb]
pub fn get_public_mode() -> Result<bool, String> {
    let conn = get_conn()?;
    let val: Option<i32> = conn
        .query_row(
            "SELECT val_int FROM app_settings WHERE key = 'is_out_in_public'",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    Ok(val.unwrap_or(0) != 0)
}

#[frb]
pub fn set_public_mode(is_out_in_public: bool) -> Result<(), String> {
    let conn = get_conn()?;
    conn.execute(
        "INSERT INTO app_settings (key, val_int) VALUES ('is_out_in_public', ?1)
         ON CONFLICT(key) DO UPDATE SET val_int = excluded.val_int",
        params![if is_out_in_public { 1 } else { 0 }],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[frb]
pub fn get_skills(zone_filter: Option<TensionZone>) -> Result<Vec<Skill>, String> {
    let conn = get_conn()?;
    let mut skills = Vec::new();

    if let Some(zone) = zone_filter {
        let mut stmt = conn
            .prepare(
                "SELECT id, title, description, zone, is_custom, only_private, duration_seconds
                 FROM skills WHERE zone = ?1 ORDER BY id ASC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![zone.to_db_int()], map_skill_row)
            .map_err(|e| e.to_string())?;
        for r in rows {
            skills.push(r.map_err(|e| e.to_string())?);
        }
    } else {
        let mut stmt = conn
            .prepare(
                "SELECT id, title, description, zone, is_custom, only_private, duration_seconds
                 FROM skills ORDER BY zone DESC, id ASC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], map_skill_row)
            .map_err(|e| e.to_string())?;
        for r in rows {
            skills.push(r.map_err(|e| e.to_string())?);
        }
    }

    Ok(skills)
}

fn map_skill_row(row: &rusqlite::Row) -> rusqlite::Result<Skill> {
    Ok(Skill {
        id: row.get(0)?,
        title: row.get(1)?,
        description: row.get(2)?,
        zone: TensionZone::from_db_int(row.get(3)?),
        is_custom: row.get::<_, i32>(4)? != 0,
        only_private: row.get::<_, i32>(5)? != 0,
        duration_seconds: row.get::<_, i32>(6).unwrap_or(0),
    })
}

#[frb]
pub fn add_custom_skill(
    title: String,
    description: String,
    zone: TensionZone,
    only_private: bool,
    duration_seconds: i32,
) -> Result<i64, String> {
    let conn = get_conn()?;
    conn.execute(
        "INSERT INTO skills (title, description, zone, is_custom, only_private, duration_seconds)
         VALUES (?1, ?2, ?3, 1, ?4, ?5)",
        params![
            title,
            description,
            zone.to_db_int(),
            if only_private { 1 } else { 0 },
            duration_seconds.max(0)
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(conn.last_insert_rowid())
}

#[frb]
pub fn update_skill(
    skill_id: i64,
    title: String,
    description: String,
    zone: TensionZone,
    only_private: bool,
    duration_seconds: i32,
) -> Result<(), String> {
    let conn = get_conn()?;
    conn.execute(
        "UPDATE skills
         SET title = ?1, description = ?2, zone = ?3, only_private = ?4, duration_seconds = ?5
         WHERE id = ?6",
        params![
            title,
            description,
            zone.to_db_int(),
            if only_private { 1 } else { 0 },
            duration_seconds.max(0),
            skill_id
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[frb]
pub fn delete_skill(skill_id: i64) -> Result<(), String> {
    let conn = get_conn()?;
    conn.execute("DELETE FROM skills WHERE id = ?1", params![skill_id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn load_chain_skills(conn: &Connection, chain_id: i64) -> Result<Vec<Skill>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT s.id, s.title, s.description, s.zone, s.is_custom, s.only_private, s.duration_seconds
             FROM chain_steps cs
             JOIN skills s ON s.id = cs.skill_id
             WHERE cs.chain_id = ?1
             ORDER BY cs.step_order ASC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map(params![chain_id], map_skill_row)
        .map_err(|e| e.to_string())?;

    let mut skills = Vec::new();
    for r in rows {
        skills.push(r.map_err(|e| e.to_string())?);
    }
    Ok(skills)
}

#[frb]
pub fn get_all_chains() -> Result<Vec<SkillChain>, String> {
    let conn = get_conn()?;
    let mut stmt = conn
        .prepare("SELECT id, name, is_active_private, is_active_public FROM chains ORDER BY id ASC")
        .map_err(|e| e.to_string())?;

    let chain_headers: Vec<(i64, String, bool, bool)> = stmt
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get::<_, i32>(2)? != 0,
                r.get::<_, i32>(3)? != 0,
            ))
        })
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;

    let mut result = Vec::new();
    for (id, name, is_priv, is_pub) in chain_headers {
        let skills = load_chain_skills(&conn, id)?;
        result.push(SkillChain {
            id,
            name,
            is_active_private: is_priv,
            is_active_public: is_pub,
            skills,
        });
    }
    Ok(result)
}

#[frb]
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

#[frb]
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

#[frb]
pub fn update_chain_steps(chain_id: i64, ordered_skill_ids: Vec<i64>) -> Result<(), String> {
    let mut conn = get_conn()?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    tx.execute(
        "DELETE FROM chain_steps WHERE chain_id = ?1",
        params![chain_id],
    )
    .map_err(|e| e.to_string())?;

    for (idx, skill_id) in ordered_skill_ids.iter().enumerate() {
        tx.execute(
            "INSERT INTO chain_steps (chain_id, step_order, skill_id) VALUES (?1, ?2, ?3)",
            params![chain_id, idx as i32, skill_id],
        )
        .map_err(|e| e.to_string())?;
    }

    tx.commit().map_err(|e| e.to_string())?;
    Ok(())
}

#[frb]
pub fn get_active_emergency_chain(is_out_in_public: bool) -> Result<Option<SkillChain>, String> {
    let conn = get_conn()?;
    let query = if is_out_in_public {
        "SELECT id, name, is_active_private, is_active_public FROM chains WHERE is_active_public = 1 LIMIT 1"
    } else {
        "SELECT id, name, is_active_private, is_active_public FROM chains WHERE is_active_private = 1 LIMIT 1"
    };

    let header: Option<(i64, String, bool, bool)> = conn
        .query_row(query, [], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get::<_, i32>(2)? != 0,
                r.get::<_, i32>(3)? != 0,
            ))
        })
        .optional()
        .map_err(|e| e.to_string())?;

    let Some((id, name, is_priv, is_pub)) = header else {
        return Ok(None);
    };

    let mut skills = load_chain_skills(&conn, id)?;
    if is_out_in_public {
        skills.retain(|s| !s.only_private);
    }

    Ok(Some(SkillChain {
        id,
        name,
        is_active_private: is_priv,
        is_active_public: is_pub,
        skills,
    }))
}