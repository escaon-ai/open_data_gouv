# R/04_map_helpers.R
# Fonctions utilitaires pour la carte Leaflet et le tableau de détail.

library(dplyr)
library(tidyr)
library(leaflet)
library(glue)

# ---- Palette de couleurs ------------------------------------------------
# Echelle linéaire par morceaux centrée sur ratio = 1 :
#   ratio ≤ 0.2  → rouge foncé   (0   sur [0,1])
#   ratio = 1    → jaune/neutre  (0.5 sur [0,1])
#   ratio ≥ 5    → vert foncé    (1   sur [0,1])

rescale_ratio <- function(r) {
  r_clamp <- pmax(0.2, pmin(5, r))
  ifelse(
    r_clamp <= 1,
    (r_clamp - 0.2) / (1 - 0.2) * 0.5,
    0.5 + (r_clamp - 1) / (5 - 1) * 0.5
  )
}

COULEURS_PALETTE <- c(
  "#d73027", "#f46d43", "#fdae61", "#fee08b",
  "#ffffbf",
  "#d9ef8b", "#a6d96a", "#66bd63", "#1a9850"
)

make_palette <- function() {
  colorNumeric(palette = COULEURS_PALETTE, domain = c(0, 1), na.color = "#cccccc")
}

ratio_to_color <- function(pal, ratio_val) {
  pal(rescale_ratio(ratio_val))
}

ratio_to_label <- function(n_cre, n_clo) {
  dplyr::case_when(
    n_cre == 0 & n_clo == 0 ~ "Aucune activité",
    n_clo == 0              ~ glue("+{n_cre} créations, 0 clôture"),
    n_cre == 0              ~ glue("0 création, {n_clo} clôtures"),
    TRUE ~ glue("{n_cre} créations / {n_clo} clôtures (ratio: {round(n_cre/n_clo, 2)})")
  )
}

# ---- Agrégation selon les filtres ---------------------------------------

aggregate_for_map <- function(data, secteurs, start_ym, end_ym, groupement) {
  filtered <- data |>
    filter(annee_mois >= start_ym, annee_mois <= end_ym)

  if (!is.null(secteurs) && length(secteurs) > 0) {
    filtered <- filtered |> filter(code_a10 %in% secteurs)
  }

  group_vars <- if (groupement == "communes") {
    c("code_insee", "nom", "agglomeration")
  } else {
    c("agglomeration")
  }

  filtered |>
    group_by(across(all_of(group_vars))) |>
    summarise(n_creations = sum(n_creations), n_clotures = sum(n_clotures), .groups = "drop") |>
    mutate(
      ratio_val = dplyr::case_when(
        n_creations == 0 & n_clotures == 0 ~ NA_real_,
        n_clotures   == 0                  ~  5,
        n_creations  == 0                  ~  0,
        TRUE ~ n_creations / n_clotures
      ),
      label_ratio = ratio_to_label(n_creations, n_clotures)
    )
}

# ---- Popups HTML --------------------------------------------------------

make_popup <- function(nom, agglomeration = NULL, n_cre, n_clo, data_secteurs = NULL) {
  titre <- if (!is.null(agglomeration) && nom == agglomeration) {
    glue("<b>{nom}</b>")
  } else {
    glue("<b>{nom}</b><br><small>{agglomeration}</small>")
  }

  ratio_txt <- if (n_clo == 0 && n_cre == 0) {
    "<i>Aucune donnée</i>"
  } else if (n_clo == 0) {
    glue("<span style='color:green'>+{n_cre} créations, 0 clôture</span>")
  } else {
    r <- round(n_cre / n_clo, 2)
    couleur <- if (r >= 1) "green" else "red"
    glue("<span style='color:{couleur}'>Ratio: {r} ({n_cre} / {n_clo})</span>")
  }

  secteurs_html <- ""
  if (!is.null(data_secteurs) && nrow(data_secteurs) > 0) {
    rows <- data_secteurs |>
      filter(n_creations > 0 | n_clotures > 0) |>
      arrange(desc(n_creations)) |>
      glue::glue_data(
        "<tr><td>{label_secteur}</td>",
        "<td style='text-align:center'>{n_creations}</td>",
        "<td style='text-align:center'>{n_clotures}</td></tr>"
      )
    if (length(rows) > 0) {
      secteurs_html <- paste0(
        "<hr><table style='font-size:11px;width:100%'>",
        "<thead><tr><th>Secteur</th><th>Cré.</th><th>Clô.</th></tr></thead>",
        "<tbody>", paste(rows, collapse = ""), "</tbody></table>"
      )
    }
  }

  paste0(titre, "<br>", ratio_txt, secteurs_html)
}

# ---- Détail entreprises (tableau au clic) --------------------------------

#' Retourne un data.frame des entreprises créées/clôturées sur une zone.
#' Dépend de naf_to_a10 (02_process.R), communes_ref et a10_ref (globals).
get_enterprise_detail <- function(stock, histo, ul, codes_communes, secteurs, start_ym, end_ym) {

  # ---- Créations ----
  cre <- stock |>
    filter(
      codeCommuneEtablissement %in% codes_communes,
      !is.na(dateCreationEtablissement),
      substr(dateCreationEtablissement, 1, 7) >= start_ym,
      substr(dateCreationEtablissement, 1, 7) <= end_ym
    ) |>
    mutate(
      code_a10 = dplyr::coalesce(naf_to_a10(activitePrincipaleEtablissement), "??"),
      type     = "Création",
      date     = substr(dateCreationEtablissement, 1, 7)
    )

  if (length(secteurs) > 0) cre <- cre |> filter(code_a10 %in% secteurs)

  # ---- Clôtures ----
  commune_map <- stock |>
    filter(codeCommuneEtablissement %in% codes_communes) |>
    select(siret, codeCommuneEtablissement,
           naf_stock = activitePrincipaleEtablissement,
           denominationUsuelleEtablissement, enseigne1Etablissement) |>
    distinct(siret, .keep_all = TRUE)

  clo <- histo |>
    filter(
      !is.na(dateDebut),
      substr(dateDebut, 1, 7) >= start_ym,
      substr(dateDebut, 1, 7) <= end_ym
    ) |>
    inner_join(commune_map, by = "siret") |>
    mutate(
      naf = dplyr::if_else(
        !is.na(activitePrincipaleEtablissement) & activitePrincipaleEtablissement != "",
        activitePrincipaleEtablissement, naf_stock
      ),
      code_a10 = dplyr::coalesce(naf_to_a10(naf), "??"),
      type     = "Clôture",
      date     = substr(dateDebut, 1, 7)
    )

  if (length(secteurs) > 0) clo <- clo |> filter(code_a10 %in% secteurs)

  # ---- Assemblage + résolution des noms via StockUniteLegale ----
  shared_cols <- c("siret", "codeCommuneEtablissement", "type", "date", "code_a10",
                   "denominationUsuelleEtablissement", "enseigne1Etablissement")

  bind_rows(
    cre |> select(all_of(shared_cols)),
    clo |> select(all_of(shared_cols))
  ) |>
    mutate(siren = substr(siret, 1, 9)) |>
    left_join(
      ul |> select(siren, denominationUniteLegale,
                   denominationUsuelle1UniteLegale,
                   nomUniteLegale, prenomUsuelUniteLegale),
      by = "siren"
    ) |>
    mutate(
      # Priorité : enseigne > dénomination établissement > dénomination usuelle UL
      # > dénomination UL > prénom + nom (personnes physiques) > SIRET fallback
      nom_entreprise = dplyr::coalesce(
        dplyr::na_if(trimws(enseigne1Etablissement),              ""),
        dplyr::na_if(trimws(denominationUsuelleEtablissement),    ""),
        dplyr::na_if(trimws(denominationUsuelle1UniteLegale),     ""),
        dplyr::na_if(trimws(denominationUniteLegale),             ""),
        dplyr::if_else(
          !is.na(nomUniteLegale) & nomUniteLegale != "",
          trimws(paste(
            dplyr::coalesce(prenomUsuelUniteLegale, ""),
            nomUniteLegale
          )),
          NA_character_
        ),
        paste("SIRET :", siret)
      )
    ) |>
    left_join(a10_ref     |> select(code_a10, label_secteur = label), by = "code_a10") |>
    left_join(communes_ref |> select(code_insee, nom_commune = nom),
              by = c("codeCommuneEtablissement" = "code_insee")) |>
    select(
      `Entreprise` = nom_entreprise,
      `SIRET`      = siret,
      `Secteur`    = label_secteur,
      `Type`       = type,
      `Date`       = date,
      `Commune`    = nom_commune
    ) |>
    arrange(Date, Type, Entreprise)
}
