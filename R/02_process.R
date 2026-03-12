# R/02_process.R
# Transforme les données Sirene brutes en table agrégée :
#   commune × secteur A10 × année-mois → (n_créations, n_clôtures)
# Couvre les 5 dernières années complètes + les mois complets de l'année en cours.

library(dplyr)
library(lubridate)
library(readr)
library(tidyr)

# ---- Référentiels -------------------------------------------------------

communes_ref <- read_csv("data/communes_ref.csv", show_col_types = FALSE,
                         col_types = cols(code_insee = col_character()))
a10_ref      <- read_csv("data/a10_labels.csv",   show_col_types = FALSE)

# ---- Mapping NAF → A10 --------------------------------------------------

naf_to_a10 <- function(naf) {
  prefix <- suppressWarnings(as.integer(substr(gsub("\\.", "", naf), 1, 2)))
  dplyr::case_when(
    is.na(prefix)  ~ NA_character_,
    prefix <= 3    ~ "AZ",
    prefix <= 33   ~ "BE",
    prefix <= 43   ~ "FZ",
    prefix <= 56   ~ "GI",
    prefix <= 63   ~ "JZ",
    prefix <= 66   ~ "KZ",
    prefix <= 68   ~ "LZ",
    prefix <= 82   ~ "MN",
    prefix <= 88   ~ "OQ",
    TRUE           ~ "RU"
  )
}

# ---- Calcul de la plage de dates cible ----------------------------------

#' Retourne list(start_ym, end_ym) couvrant :
#'   - les 5 dernières années complètes
#'   - les mois complets de l'année en cours
compute_date_range <- function() {
  today      <- Sys.Date()
  curr_year  <- as.integer(format(today, "%Y"))
  curr_month <- as.integer(format(today, "%m"))

  if (curr_month == 1) {
    end_year  <- curr_year - 1
    end_month <- 12L
  } else {
    end_year  <- curr_year
    end_month <- curr_month - 1L
  }

  start_year <- curr_year - 5

  list(
    start_ym = sprintf("%d-01", start_year),
    end_ym   = sprintf("%d-%02d", end_year, end_month)
  )
}

# ---- Séquence de tous les mois d'une plage ------------------------------

months_in_range <- function(start_ym, end_ym) {
  start <- as.Date(paste0(start_ym, "-01"))
  end   <- as.Date(paste0(end_ym,   "-01"))
  seq_dates <- seq(start, end, by = "month")
  format(seq_dates, "%Y-%m")
}

# ---- Table des créations ------------------------------------------------

build_creations <- function(stock, start_ym, end_ym) {
  stock |>
    filter(
      !is.na(dateCreationEtablissement),
      substr(dateCreationEtablissement, 1, 7) >= start_ym,
      substr(dateCreationEtablissement, 1, 7) <= end_ym
    ) |>
    mutate(
      annee_mois = substr(dateCreationEtablissement, 1, 7),
      code_a10   = dplyr::coalesce(naf_to_a10(activitePrincipaleEtablissement), "??")
    ) |>
    group_by(code_insee = codeCommuneEtablissement, code_a10, annee_mois) |>
    summarise(n_creations = n(), .groups = "drop")
}

# ---- Table des clôtures -------------------------------------------------

build_clotures <- function(histo, stock, start_ym, end_ym) {
  commune_map <- stock |>
    select(siret, codeCommuneEtablissement,
           naf_stock = activitePrincipaleEtablissement) |>
    distinct(siret, .keep_all = TRUE)

  histo |>
    filter(
      !is.na(dateDebut),
      substr(dateDebut, 1, 7) >= start_ym,
      substr(dateDebut, 1, 7) <= end_ym
    ) |>
    inner_join(commune_map, by = "siret") |>
    filter(!is.na(codeCommuneEtablissement)) |>
    mutate(
      annee_mois = substr(dateDebut, 1, 7),
      naf        = dplyr::if_else(
        !is.na(activitePrincipaleEtablissement) & activitePrincipaleEtablissement != "",
        activitePrincipaleEtablissement,
        naf_stock
      ),
      code_a10   = dplyr::coalesce(naf_to_a10(naf), "??")
    ) |>
    group_by(code_insee = codeCommuneEtablissement, code_a10, annee_mois) |>
    summarise(n_clotures = n(), .groups = "drop")
}

# ---- Table finale agrégée -----------------------------------------------

build_aggregated <- function(stock, histo) {
  dr <- compute_date_range()
  message(glue::glue("Plage de données : {dr$start_ym} → {dr$end_ym}"))

  creations <- build_creations(stock, dr$start_ym, dr$end_ym)
  clotures  <- build_clotures(histo, stock, dr$start_ym, dr$end_ym)

  all_months <- months_in_range(dr$start_ym, dr$end_ym)
  codes_a10  <- a10_ref$code_a10

  grid <- tidyr::expand_grid(
    code_insee = communes_ref$code_insee,
    code_a10   = codes_a10,
    annee_mois = all_months
  )

  result <- grid |>
    left_join(creations, by = c("code_insee", "code_a10", "annee_mois")) |>
    left_join(clotures,  by = c("code_insee", "code_a10", "annee_mois")) |>
    replace_na(list(n_creations = 0L, n_clotures = 0L)) |>
    left_join(communes_ref, by = "code_insee") |>
    left_join(a10_ref |> select(code_a10, label_secteur = label), by = "code_a10") |>
    mutate(
      ratio_val = dplyr::case_when(
        n_creations == 0 & n_clotures == 0 ~ NA_real_,
        n_clotures   == 0                  ~  5,
        n_creations  == 0                  ~  0,
        TRUE ~ n_creations / n_clotures
      ),
      annee_mois_date = as.Date(paste0(annee_mois, "-01"))
    )

  attr(result, "start_ym") <- dr$start_ym
  attr(result, "end_ym")   <- dr$end_ym
  result
}
