# R/01_fetch_sirene.R
# Télécharge et filtre les données Sirene via DuckDB (lecture HTTP parquet).
# Les résultats sont mis en cache localement dans data/cache/ au format RDS.
#
# PREMIÈRE EXÉCUTION : lente (~5-15 min selon la connexion) car DuckDB scanne
# les fichiers parquet distants (2 Go + 803 Mo). Les exécutions suivantes
# utilisent le cache.

library(DBI)
library(duckdb)
library(dplyr)
library(readr)

# ---- URLs Sirene (data.gouv.fr) ----------------------------------------

SIRENE_STOCK_URL <- paste0(
  "https://object.files.data.gouv.fr/data-pipeline-open/siren/stock/",
  "StockEtablissement_utf8.parquet"
)
SIRENE_HISTO_URL <- paste0(
  "https://object.files.data.gouv.fr/data-pipeline-open/siren/stock/",
  "StockEtablissementHistorique_utf8.parquet"
)
SIRENE_UL_URL <- paste0(
  "https://object.files.data.gouv.fr/data-pipeline-open/siren/stock/",
  "StockUniteLegale_utf8.parquet"
)

CACHE_STOCK <- "data/cache/stock_communes.rds"
CACHE_HISTO <- "data/cache/histo_communes.rds"
CACHE_UL    <- "data/cache/unite_legale.rds"

# ---- Référentiel communes -----------------------------------------------

communes_ref <- read_csv("data/communes_ref.csv", show_col_types = FALSE,
                         col_types = cols(code_insee = col_character()))
codes_communes <- communes_ref$code_insee

# Année de début pour le filtre historique (5 ans en arrière)
HISTO_START_YEAR <- as.integer(format(Sys.Date(), "%Y")) - 5

# ---- Connexion DuckDB ---------------------------------------------------

open_duckdb <- function() {
  con <- dbConnect(duckdb(), dbdir = ":memory:")
  dbExecute(con, "INSTALL httpfs; LOAD httpfs;")
  dbExecute(con, "SET enable_progress_bar = true;")
  con
}

# ---- Extraction StockEtablissement (créations + infos communes) ---------

fetch_stock <- function(force_refresh = FALSE) {
  if (!force_refresh && file.exists(CACHE_STOCK)) {
    message("Cache StockEtablissement trouvé, chargement...")
    return(readRDS(CACHE_STOCK))
  }

  message("Connexion DuckDB pour lecture StockEtablissement (~2 Go)...")
  message("Cela peut prendre 5-15 minutes selon votre connexion.")
  con <- open_duckdb()
  on.exit(dbDisconnect(con, shutdown = TRUE))

  codes_sql <- paste0("('", paste(codes_communes, collapse = "','"), "')")

  query <- glue::glue("
    SELECT
      siret,
      siren,
      dateCreationEtablissement,
      codeCommuneEtablissement,
      etatAdministratifEtablissement,
      activitePrincipaleEtablissement,
      etablissementSiege,
      denominationUsuelleEtablissement,
      enseigne1Etablissement
    FROM read_parquet('{SIRENE_STOCK_URL}')
    WHERE codeCommuneEtablissement IN {codes_sql}
  ")

  message("Interrogation en cours...")
  result <- dbGetQuery(con, query)

  message(glue::glue("  → {nrow(result)} établissements extraits pour les 25 communes."))

  dir.create("data/cache", showWarnings = FALSE, recursive = TRUE)
  saveRDS(result, CACHE_STOCK)
  message("Cache sauvegardé : ", CACHE_STOCK)
  result
}

# ---- Extraction StockEtablissementHistorique (clôtures) ----------------

fetch_histo <- function(sirets, force_refresh = FALSE) {
  if (!force_refresh && file.exists(CACHE_HISTO)) {
    message("Cache StockEtablissementHistorique trouvé, chargement...")
    return(readRDS(CACHE_HISTO))
  }

  message("Connexion DuckDB pour lecture StockEtablissementHistorique (~803 Mo)...")
  message("Cela peut prendre 3-8 minutes selon votre connexion.")
  con <- open_duckdb()
  on.exit(dbDisconnect(con, shutdown = TRUE))

  sirets_sql <- paste0("('", paste(sirets, collapse = "','"), "')")

  query <- glue::glue("
    SELECT
      siret,
      dateDebut,
      dateFin,
      etatAdministratifEtablissement,
      changementEtatAdministratifEtablissement,
      activitePrincipaleEtablissement
    FROM read_parquet('{SIRENE_HISTO_URL}')
    WHERE siret IN {sirets_sql}
      AND etatAdministratifEtablissement = 'F'
      AND changementEtatAdministratifEtablissement = 'true'
      AND YEAR(dateDebut) >= {HISTO_START_YEAR}
  ")

  message("Interrogation en cours...")
  result <- dbGetQuery(con, query)

  message(glue::glue("  → {nrow(result)} événements de clôture extraits."))

  saveRDS(result, CACHE_HISTO)
  message("Cache sauvegardé : ", CACHE_HISTO)
  result
}

# ---- Extraction StockUniteLegale (noms d'entreprises) ------------------

fetch_unite_legale <- function(sirens, force_refresh = FALSE) {
  if (!force_refresh && file.exists(CACHE_UL)) {
    message("Cache StockUniteLegale trouvé, chargement...")
    return(readRDS(CACHE_UL))
  }

  message("Connexion DuckDB pour lecture StockUniteLegale (noms d'entreprises)...")
  con <- open_duckdb()
  on.exit(dbDisconnect(con, shutdown = TRUE))

  sirens_sql <- paste0("('", paste(unique(sirens), collapse = "','"), "')")

  query <- glue::glue("
    SELECT
      siren,
      denominationUniteLegale,
      denominationUsuelle1UniteLegale,
      nomUniteLegale,
      prenomUsuelUniteLegale
    FROM read_parquet('{SIRENE_UL_URL}')
    WHERE siren IN {sirens_sql}
  ")

  message("Interrogation en cours...")
  result <- dbGetQuery(con, query)

  message(glue::glue("  → {nrow(result)} unités légales extraites."))

  saveRDS(result, CACHE_UL)
  message("Cache sauvegardé : ", CACHE_UL)
  result
}

# ---- Fonction principale : charge les trois tables ----------------------

load_sirene_data <- function(force_refresh = FALSE) {
  stock  <- fetch_stock(force_refresh)
  histo  <- fetch_histo(unique(stock$siret), force_refresh)
  sirens <- unique(substr(stock$siret, 1, 9))
  ul     <- fetch_unite_legale(sirens, force_refresh)
  list(stock = stock, histo = histo, ul = ul)
}
