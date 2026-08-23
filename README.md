# comics-ldap

A ready-to-use OpenLDAP directory pre-loaded with **~23,000+ DC and Marvel comic
characters** organised into a realistic nested group structure — heroes, villains,
living, deceased — mirroring real-world LDAP deployments.

Built as a rich test dataset for LDAP development, authentication testing, SSO
integration, and directory service learning.

---

## Dataset at a glance

| Publisher | Total   | Heroes  | Villains | Neutral | Living  | Deceased |
|-----------|---------|---------|----------|---------|---------|----------|
| DC Comics | ~6,896  | ~3,837  | ~1,699   | ~585    | ~4,602  | ~1,410   |
| Marvel    | ~16,376 | ~7,490  | ~6,677   | ~1,001  | ~10,636 | ~3,606   |
| **Total** | ~23,272 | ~11,327 | ~8,376   | ~1,586  | ~15,238 | ~5,016   |

> Data sourced from [FiveThirtyEight comic characters dataset](https://github.com/fivethirtyeight/data/tree/master/comic-characters)
> (CC Attribution 4.0). ~11% of entries have no alignment or status value.

**Key insight:** Marvel nearly has as many villains (40.8%) as heroes (45.7%) —
far more conflict-heavy than DC's 55.6% heroes vs 24.6% villains split.

---

## LDAP schema and group structure

### Directory tree

```
dc=comics,dc=com
├── ou=users                   All characters searchable here
│   ├── ou=dc                  DC Comics characters
│   │   ├── uid=batman
│   │   ├── uid=superman
│   │   └── ... (~6,896 entries)
│   └── ou=marvel              Marvel characters
│       ├── uid=spider-man
│       ├── uid=iron_man
│       └── ... (~16,376 entries)
└── ou=groups                  All groups
    ├── cn=heroes              Parent group
    │   ├── cn=dc-heroes           DC subgroup
    │   └── cn=marvel-heroes       Marvel subgroup
    ├── cn=villains            Parent group
    │   ├── cn=dc-villains         DC subgroup
    │   └── cn=marvel-villains     Marvel subgroup
    ├── cn=neutral             Parent group
    │   ├── cn=dc-neutral          DC subgroup
    │   └── cn=marvel-neutral      Marvel subgroup
    ├── cn=living              Parent group
    │   ├── cn=dc-living           DC subgroup
    │   └── cn=marvel-living       Marvel subgroup
    └── cn=deceased            Parent group
        ├── cn=dc-deceased         DC subgroup
        └── cn=marvel-deceased     Marvel subgroup
```

### Nested group membership — how it works

Characters are added **only to their publisher-specific subgroup**
(e.g. `cn=dc-heroes`). The parent group (e.g. `cn=heroes`) does not
list individual users — instead it has the **subgroup DN as a member**.

```
cn=heroes
  uniqueMember: cn=dc-heroes,ou=groups,dc=comics,dc=com    <- subgroup
  uniqueMember: cn=marvel-heroes,ou=groups,dc=comics,dc=com <- subgroup

cn=dc-heroes
  uniqueMember: uid=batman,ou=dc,ou=users,dc=comics,dc=com
  uniqueMember: uid=superman,ou=dc,ou=users,dc=comics,dc=com
  uniqueMember: ...
```

This mirrors real-world LDAP patterns used in enterprise directories.
Applications that perform **recursive group lookup** (Spring Security,
Keycloak, Active Directory compatible clients, most SSO providers) will
automatically resolve:

```
batman  ─member of─▶  dc-heroes  ─member of─▶  heroes
```

So a query for members of `cn=heroes` transitively includes all DC and
Marvel heroes without duplicating entries.

### Why this structure is useful for testing

| Scenario | How to test it |
|---|---|
| Basic group membership | Search `cn=dc-heroes` for direct members |
| Nested/recursive group lookup | Search `cn=heroes` and follow `uniqueMember` refs |
| Cross-publisher queries | Search `ou=users` with any filter |
| Publisher isolation | Search `ou=dc` or `ou=marvel` separately |
| Role-based access control | Use `cn=heroes` / `cn=villains` as RBAC roles |
| Status-based filtering | Use `cn=living` / `cn=deceased` groups |

---

## Option A — Pull the pre-built Docker image (zero setup)

```bash
docker run -d \
  --name comics-ldap \
  -p 389:389 -p 636:636 \
  asyncpoint/comics-ldap:latest \
  --copy-service
```

| Setting | Value |
|---|---|
| LDAP URL | `ldap://localhost:389` |
| Admin DN | `cn=admin,dc=comics,dc=com` |
| Password | `P@ssw0rd` |
| Base DN | `dc=comics,dc=com` |

---

## Option B — Run with Docker Compose + phpLDAPadmin UI

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) or Docker Engine
- PowerShell 5.1+ (Windows) or [PowerShell 7+](https://github.com/PowerShell/PowerShell) (cross-platform)

### Step 1 — Clone the repository

```bash
git clone https://github.com/yourname/comics-ldap.git
cd comics-ldap
```

### Step 2 — Generate LDIF files

```powershell
.\Fetch-And-Convert.ps1
```

This downloads both CSVs from GitHub, converts them using the shared logic
in `ConvertTo-LDIF.ps1`, and generates the following files in `ldifs/`:

| File | Contents |
|---|---|
| `00-structure.ldif` | OU tree + empty group definitions (pre-included in repo) |
| `01-dc-users.ldif` | ~6,896 DC character entries |
| `02-marvel-users.ldif` | ~16,376 Marvel character entries |
| `03-groups-membership.ldif` | Two-section file: user→subgroup memberships + subgroup→parent wiring |

Optional parameters:

| Parameter | Default | Description |
|---|---|---|
| `-Password` | `P@ssw0rd` | Default password for all user entries |
| `-Target` | `OpenLDAP` | `OpenLDAP` or `ActiveDirectory` |
| `-OutputDir` | `.\ldifs` | Output folder for generated files |
| `-RootDN` | `dc=comics,dc=com` | Root DN |
| `-Verbose` | off | Show per-record processing detail |

### Step 3 — Start the containers

```bash
docker compose up -d
```

OpenLDAP loads all four LDIF files automatically on first start.
Allow 1-2 minutes for ~23,000 entries plus group memberships to load.

### Step 4 — Browse with phpLDAPadmin

Open **http://localhost:8080** and log in:
- **Login DN:** `cn=admin,dc=comics,dc=com`
- **Password:** `P@ssw0rd`

---

## Useful ldapsearch queries

**Count all characters:**
```bash
docker exec openldap ldapsearch -x -H ldap://localhost \
  -D "cn=admin,dc=comics,dc=com" -w "P@ssw0rd" \
  -b "ou=users,dc=comics,dc=com" "(objectClass=inetOrgPerson)" dn \
  | grep -c "^dn:"
```

**List members of dc-heroes (direct members of subgroup):**
```bash
docker exec openldap ldapsearch -x -H ldap://localhost \
  -D "cn=admin,dc=comics,dc=com" -w "P@ssw0rd" \
  -b "ou=groups,dc=comics,dc=com" "(cn=dc-heroes)" uniqueMember
```

**Inspect heroes parent group (shows subgroup DNs as members):**
```bash
docker exec openldap ldapsearch -x -H ldap://localhost \
  -D "cn=admin,dc=comics,dc=com" -w "P@ssw0rd" \
  -b "ou=groups,dc=comics,dc=com" "(cn=heroes)" uniqueMember
```

**Look up a specific character:**
```bash
docker exec openldap ldapsearch -x -H ldap://localhost \
  -D "cn=admin,dc=comics,dc=com" -w "P@ssw0rd" \
  -b "ou=dc,ou=users,dc=comics,dc=com" "(uid=Batman)"
```

**Test user authentication:**
```bash
docker exec openldap ldapwhoami -x -H ldap://localhost \
  -D "uid=batman,ou=dc,ou=users,dc=comics,dc=com" \
  -w "P@ssw0rd"
```

---

## Generating LDIF files

Two equivalent toolchains are provided — use whichever suits your platform.
Both produce **identical LDIF output**.

### Script pairing — same design, two languages

| Role | PowerShell (Windows) | Bash (Linux / macOS) |
|---|---|---|
| All conversion logic | `ConvertTo-LDIF.ps1` | `convert-to-ldif.sh` |
| Download + orchestration | `Fetch-And-Convert.ps1` | `fetch-and-convert.sh` |

The orchestration script **sources/dot-sources** the conversion script to share
functions — one place to maintain all LDIF logic regardless of which toolchain
you use.

---

### PowerShell (Windows / cross-platform)

**Requirements:** PowerShell 5.1+ (Windows built-in) or [PowerShell 7+](https://github.com/PowerShell/PowerShell) for macOS/Linux.

**One-command setup — downloads CSVs and generates all four LDIF files:**
```powershell
.\Fetch-And-Convert.ps1
```

**Convert a single local CSV manually:**
```powershell
.\ConvertTo-LDIF.ps1 -CsvPath "dc-wikia-data.csv"
.\ConvertTo-LDIF.ps1 -CsvPath "marvel-wikia-data.csv" -Password "Secret1!"
.\ConvertTo-LDIF.ps1 -CsvPath "dc-wikia-data.csv" -Target ActiveDirectory
```

| Parameter | Default | Description |
|---|---|---|
| `-Password` | `P@ssw0rd` | Password for all user entries |
| `-Target` | `OpenLDAP` | `OpenLDAP` or `ActiveDirectory` |
| `-OutputDir` | `.\ldifs` | Output folder |
| `-RootDN` | `dc=comics,dc=com` | Root DN |
| `-Verbose` | off | Per-record processing detail |

---

### Bash (Linux / macOS)

**Requirements:** `bash` 4+, `python3`, `curl`. Python3 handles all CSV parsing
and LDIF encoding — no fragile shell text processing.

```bash
# Debian / Ubuntu
sudo apt-get install python3 curl

# macOS
brew install python3 curl
```

**One-command setup — downloads CSVs and generates all four LDIF files:**
```bash
chmod +x fetch-and-convert.sh convert-to-ldif.sh
./fetch-and-convert.sh
```

**Convert a single local CSV manually:**
```bash
./convert-to-ldif.sh dc-wikia-data.csv
./convert-to-ldif.sh marvel-wikia-data.csv --password "Secret1!" --verbose
./convert-to-ldif.sh dc-wikia-data.csv --target ActiveDirectory
```

| Flag | Default | Description |
|---|---|---|
| `--password`, `-p` | `P@ssw0rd` | Password for all user entries |
| `--target`, `-t` | `OpenLDAP` | `OpenLDAP` or `ActiveDirectory` |
| `--output-dir`, `-o` | `./ldifs` | Output folder |
| `--root-dn`, `-r` | `dc=comics,dc=com` | Root DN |
| `--verbose`, `-v` | off | Per-record processing detail |

---

### What both toolchains generate

After running either `Fetch-And-Convert.ps1` or `fetch-and-convert.sh`, the
`ldifs/` folder will contain:

| File | Contents |
|---|---|
| `00-structure.ldif` | OU tree + empty group shells (pre-committed to repo) |
| `01-dc-users.ldif` | ~6,896 DC character entries |
| `02-marvel-users.ldif` | ~16,376 Marvel character entries |
| `03-groups-membership.ldif` | Section 1: user→subgroup memberships; Section 2: subgroup→parent nesting |

---

## Building and publishing the Docker image

```bash
# 1. Generate LDIF files (either toolchain)
./fetch-and-convert.sh          # Linux / macOS
# .\Fetch-And-Convert.ps1       # Windows

# 2. Build — all ~23k characters baked in, zero setup for end users
docker build -t yourname/comics-ldap:latest .

# 3. Verify
docker run -d --name test -p 389:389 yourname/comics-ldap:latest --copy-service
docker exec test ldapsearch -x -H ldap://localhost \
  -D "cn=admin,dc=comics,dc=com" -w "P@ssw0rd" \
  -b "ou=users,dc=comics,dc=com" "(objectClass=inetOrgPerson)" dn \
  | grep -c "^dn:"

# 4. Push to Docker Hub
docker login
docker push yourname/comics-ldap:latest
```

---

## Resetting the directory

```bash
docker compose down -v   # -v wipes volumes, forces fresh bootstrap on next start
docker compose up -d
```

> Without `-v` Docker retains the existing volumes and OpenLDAP skips the
> bootstrap — it only runs once on a fresh empty volume.

---

## Repository structure

```
.
├── README.md                      <- this file
├── docker-compose.yml             <- OpenLDAP + phpLDAPadmin
├── Dockerfile                     <- self-contained image for Docker Hub
├── .gitignore
│
├── ConvertTo-LDIF.ps1             <- PowerShell: all conversion logic
├── Fetch-And-Convert.ps1          <- PowerShell: downloads CSVs + orchestrates
│
├── convert-to-ldif.sh             <- Bash: all conversion logic (sourced by below)
├── fetch-and-convert.sh           <- Bash: downloads CSVs + orchestrates
│
└── ldifs/
    ├── 00-structure.ldif          <- OU tree + group shells (committed to repo)
    ├── 01-dc-users.ldif           <- generated — gitignored
    ├── 02-marvel-users.ldif       <- generated — gitignored
    └── 03-groups-membership.ldif  <- generated — gitignored
```

---

## Data source & licence

- Character data from the [FiveThirtyEight data repository](https://github.com/fivethirtyeight/data/tree/master/comic-characters),
licensed under [CC Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).
Original article: [Comic Books Are Still Made By Men, For Men And About Men](https://fivethirtyeight.com/features/women-in-comic-books/)
- osixia/openldap:1.5.0 is used as base image
